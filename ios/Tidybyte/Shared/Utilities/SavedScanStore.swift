import Foundation
import Photos

/// Keeps a Cleanup tool's last scan and its checked items on disk, so both
/// survive a quit. One JSON file per name in Application Support (iOS may purge
/// Caches). Settings > Clear Saved Scans removes them all.
///
/// A file records the settings that produced it (`stamp`, such as the blur
/// sensitivity). A load with a different stamp, or from an older file format,
/// returns nil, so a tool never shows results its current settings would not
/// produce.
///
/// Encoding, writing and reading run on one serial queue, off the main thread
/// and in call order: a load always sees every save made before it.
@MainActor
enum SavedScanStore {
    /// Bump when a payload changes shape: older files then stop loading.
    static let formatVersion = 1

    /// Where the files live. Tests point it at a temporary folder.
    static var directory: URL = URL.applicationSupportDirectory.appending(path: "SavedScans", directoryHint: .isDirectory)

    /// Off in unit tests, which run inside the app: a save from one test must
    /// not change what another test loads. The store's own tests turn it on
    /// with a temporary `directory`.
    static var isEnabled = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil

    /// True when PhotoKit sees the whole library. With limited access a photo
    /// missing from a read may still exist, so nothing is restored (a restore
    /// drops missing photos and saves the shorter list) and picks are not
    /// saved (the visible picks would replace the full set). Tests replace it.
    static var canTrustLibrary: () -> Bool = {
        CompressionJournal.canReadLibrary(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    private static let queue = DispatchQueue(label: "SavedScanStore", qos: .utility)

    private struct Envelope<Payload: Codable>: Codable {
        let version: Int
        let savedAt: Date
        let stamp: String
        let payload: Payload
    }

    static func save<Payload: Codable & Sendable>(_ payload: Payload, name: String, stamp: String = "") {
        guard isEnabled else { return }
        let folder = directory, file = url(name), version = formatVersion
        queue.async {
            let envelope = Envelope(version: version, savedAt: .now, stamp: stamp, payload: payload)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try JSONEncoder().encode(envelope).write(to: file, options: [.atomic])
            } catch {
                AppLog.data.error("Saving \(name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// The saved payload and when it was saved, or nil when there is none, it
    /// cannot be read, or it was made with other settings or an older format.
    static func load<Payload: Codable & Sendable>(_ type: Payload.Type, name: String, stamp: String = "") async -> (payload: Payload, savedAt: Date)? {
        guard isEnabled else { return nil }
        let file = url(name), version = formatVersion
        return await withCheckedContinuation { continuation in
            queue.async {
                guard let data = try? Data(contentsOf: file),
                      let envelope = try? JSONDecoder().decode(Envelope<Payload>.self, from: data),
                      envelope.version == version, envelope.stamp == stamp else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: (envelope.payload, envelope.savedAt))
            }
        }
    }

    /// The checked items of a tool, saved on every change.
    static func saveSelection(_ ids: Set<String>, name: String) {
        guard canTrustLibrary() else { return }
        save(ids.sorted(), name: "\(name).selection")
    }

    static func selection(name: String) async -> Set<String> {
        guard canTrustLibrary() else { return [] }
        return Set(await load([String].self, name: "\(name).selection")?.payload ?? [])
    }

    /// Complete summaries for saved ids, read off the main thread. Ids no longer
    /// in the library are missing from the result.
    static func summaries(for ids: [String]) async -> [String: AssetSummary] {
        let service = PhotoLibraryService.shared
        return await Task.detached(priority: .userInitiated) { service.fetchSummaries(for: ids) }.value
    }

    /// Settings > Clear Saved Scans.
    static func removeAll() {
        let folder = directory
        queue.async { try? FileManager.default.removeItem(at: folder) }
    }

    private static func url(_ name: String) -> URL {
        directory.appending(path: "\(name).json", directoryHint: .notDirectory)
    }
}
