import Foundation

/// Keeps a Cleanup tool's last scan and its checked items on disk, so both
/// survive a quit. One JSON file per name in Application Support (iOS may purge
/// Caches). Settings > Clear Saved Scans removes them all.
///
/// A file records the settings that produced it (`stamp`, such as the blur
/// sensitivity). A load with a different stamp, or from an older file format,
/// returns nil, so a tool never shows results its current settings would not
/// produce.
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

    private struct Envelope<Payload: Codable>: Codable {
        let version: Int
        let savedAt: Date
        let stamp: String
        let payload: Payload
    }

    static func save<Payload: Codable>(_ payload: Payload, name: String, stamp: String = "") {
        guard isEnabled else { return }
        let envelope = Envelope(version: formatVersion, savedAt: .now, stamp: stamp, payload: payload)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(envelope).write(to: url(name), options: [.atomic])
        } catch {
            AppLog.data.error("Saving \(name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The saved payload and when it was saved, or nil when there is none, it
    /// cannot be read, or it was made with other settings.
    static func load<Payload: Codable>(_ type: Payload.Type, name: String, stamp: String = "") -> (payload: Payload, savedAt: Date)? {
        guard isEnabled, let data = try? Data(contentsOf: url(name)),
              let envelope = try? JSONDecoder().decode(Envelope<Payload>.self, from: data),
              envelope.version == formatVersion, envelope.stamp == stamp else { return nil }
        return (envelope.payload, envelope.savedAt)
    }

    /// The checked items of a tool, saved on every change.
    static func saveSelection(_ ids: Set<String>, name: String) {
        save(ids.sorted(), name: "\(name).selection")
    }

    static func selection(name: String) -> Set<String> {
        Set(load([String].self, name: "\(name).selection")?.payload ?? [])
    }

    /// Complete summaries for saved ids, read off the main thread. Ids no longer
    /// in the library are missing from the result.
    static func summaries(for ids: [String]) async -> [String: AssetSummary] {
        let service = PhotoLibraryService.shared
        return await Task.detached(priority: .userInitiated) { service.fetchSummaries(for: ids) }.value
    }

    static func remove(name: String) {
        try? FileManager.default.removeItem(at: url(name))
    }

    /// Settings > Clear Saved Scans.
    static func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    private static func url(_ name: String) -> URL {
        directory.appending(path: "\(name).json", directoryHint: .notDirectory)
    }
}
