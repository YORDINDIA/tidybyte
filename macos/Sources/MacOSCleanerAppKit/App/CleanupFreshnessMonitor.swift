import CoreServices
import Foundation
import MacOSCleanerCore
@preconcurrency import Photos

/// PSA-01 tripwire: records how often the FSEventStream was built on the
/// main thread. `FSEventStreamCreate` can block indefinitely (watch_path →
/// open on a stalled mount), so creation must stay off the main actor.
final class FreshnessCreationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var _mainThreadCreations = 0
    private var _totalCreations = 0

    func record(isMainThread: Bool) {
        lock.lock()
        defer { lock.unlock() }
        _totalCreations += 1
        if isMainThread { _mainThreadCreations += 1 }
    }

    var totalCreations: Int {
        lock.lock()
        defer { lock.unlock() }
        return _totalCreations
    }

    var mainThreadCreations: Int {
        lock.lock()
        defer { lock.unlock() }
        return _mainThreadCreations
    }
}

/// Retained callback bridge so CoreServices never holds a dangling unretained pointer
/// to `CleanupFreshnessMonitor` if an event arrives concurrently with teardown.
private final class MonitorCallbackBox: @unchecked Sendable {
    private let lock = NSLock()
    private var isStopped = false
    private weak var owner: CleanupFreshnessMonitor?

    init(_ owner: CleanupFreshnessMonitor) {
        self.owner = owner
    }

    func notifyChanged() {
        lock.lock()
        let target = isStopped ? nil : owner
        lock.unlock()
        target?.dispatchChanged()
    }

    func invalidate() {
        lock.lock()
        isStopped = true
        owner = nil
        lock.unlock()
    }
}

/// System callback bridge; all observable state is updated on the main actor.
final class CleanupFreshnessMonitor: NSObject, PHPhotoLibraryChangeObserver, @unchecked Sendable {
    /// Shared probe asserting the stream is never created on the main thread.
    static let creationProbe = FreshnessCreationProbe()

    private let streamLock = NSLock()
    private var stream: FSEventStreamRef?
    private let includesPhotos: Bool
    private var didUnregisterPhotos = false
    private var callbackBox: MonitorCallbackBox?
    private let changed: @Sendable () -> Void

    // Deliberately NOT @MainActor (PSA-01): the caller builds this in a
    // detached task because FSEventStreamCreate can stall. Photo-library
    // registration and stream setup are thread-safe.
    nonisolated init(roots: [URL], includesPhotos: Bool, changed: @escaping @Sendable () -> Void) {
        Self.creationProbe.record(isMainThread: Thread.isMainThread)
        self.includesPhotos = includesPhotos
        self.changed = changed
        super.init()
        let box = MonitorCallbackBox(self)
        self.callbackBox = box
        if !roots.isEmpty {
            startStream(roots: roots, box: box)
        }
        if includesPhotos { PHPhotoLibrary.shared().register(self) }
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        callbackBox?.notifyChanged()
    }

    fileprivate func dispatchChanged() {
        changed()
    }

    /// Stops FSEvents and PhotoKit observations idempotently.
    func stop() {
        callbackBox?.invalidate()
        let streamToClose: FSEventStreamRef?
        let shouldUnregisterPhotos: Bool
        streamLock.lock()
        streamToClose = stream
        stream = nil
        shouldUnregisterPhotos = includesPhotos && !didUnregisterPhotos
        didUnregisterPhotos = true
        streamLock.unlock()

        if shouldUnregisterPhotos {
            PHPhotoLibrary.shared().unregisterChangeObserver(self)
        }
        if let streamToClose {
            FSEventStreamStop(streamToClose)
            FSEventStreamInvalidate(streamToClose)
            FSEventStreamRelease(streamToClose)
        }
    }

    nonisolated private func startStream(roots: [URL], box: MonitorCallbackBox) {
        let retained = Unmanaged.passRetained(box)
        var context = FSEventStreamContext(
            version: 0,
            info: retained.toOpaque(),
            retain: { pointer in
                guard let pointer else { return nil }
                _ = Unmanaged<MonitorCallbackBox>.fromOpaque(pointer).retain()
                return pointer
            },
            release: { pointer in
                guard let pointer else { return }
                Unmanaged<MonitorCallbackBox>.fromOpaque(pointer).release()
            },
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)
        let created = FSEventStreamCreate(
            nil,
            { _, pointer, count, paths, _, _ in
                guard let pointer else { return }
                let entries = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
                let relevant = (0..<count).contains { index in
                    ReviewSafety.isAllowed(URL(fileURLWithPath: String(cString: entries[index])))
                }
                if relevant {
                    Unmanaged<MonitorCallbackBox>.fromOpaque(pointer).takeUnretainedValue().notifyChanged()
                }
            },
            &context,
            roots.map(\.path) as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1,
            flags
        )
        // `FSEventStreamCreate` invokes `context.retain`; release our initial passRetained.
        retained.release()
        guard let created else { return }
        streamLock.lock()
        stream = created
        streamLock.unlock()
        FSEventStreamSetDispatchQueue(created, .main)
        FSEventStreamStart(created)
    }

    deinit {
        stop()
    }
}
