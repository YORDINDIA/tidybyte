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

/// System callback bridge; all observable state is updated on the main actor.
final class CleanupFreshnessMonitor: NSObject, PHPhotoLibraryChangeObserver, @unchecked Sendable {
    /// Shared probe asserting the stream is never created on the main thread.
    static let creationProbe = FreshnessCreationProbe()

    private var stream: FSEventStreamRef?
    private let changed: @Sendable () -> Void

    // Deliberately NOT @MainActor (PSA-01): the caller builds this in a
    // detached task because FSEventStreamCreate can stall. Photo-library
    // registration and stream setup are thread-safe.
    nonisolated init(roots: [URL], includesPhotos: Bool, changed: @escaping @Sendable () -> Void) {
        Self.creationProbe.record(isMainThread: Thread.isMainThread)
        self.changed = changed
        super.init()
        if !roots.isEmpty {
            var context = FSEventStreamContext(
                version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                retain: nil, release: nil, copyDescription: nil)
            stream = FSEventStreamCreate(
                nil,
                { _, pointer, count, paths, _, _ in
                    guard let pointer else { return }
                    let entries = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
                    let relevant = (0..<count).contains { index in
                        ReviewSafety.isAllowed(URL(fileURLWithPath: String(cString: entries[index])))
                    }
                    if relevant {
                        Unmanaged<CleanupFreshnessMonitor>.fromOpaque(pointer).takeUnretainedValue().changed()
                    }
                },
                &context, roots.map(\.path) as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1,
                FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot))
            if let stream {
                FSEventStreamSetDispatchQueue(stream, .main)
                FSEventStreamStart(stream)
            }
        }
        if includesPhotos { PHPhotoLibrary.shared().register(self) }
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) { changed() }

    deinit {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
