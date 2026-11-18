import AppKit
import Foundation
import MacOSCleanerCore

/// Watches /Applications, /System/Applications, and ~/Applications. When an app
/// bundle disappears, stays gone for 10 seconds, and LaunchServices confirms it
/// was not simply relocated or upgraded in place, the owner offers to review
/// its leftovers.
@MainActor
final class ApplicationRemovalWatcher {
    private var sources: [DispatchSourceFileSystemObject] = []
    private var known: [String: InstalledApplication] = [:]
    private var pending: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    private let folders: [URL]
    private let onRemoved: (InstalledApplication) -> Void

    init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        onRemoved: @escaping (InstalledApplication) -> Void
    ) {
        folders = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            home.appendingPathComponent("Applications", isDirectory: true)
        ]
        self.onRemoved = onRemoved
    }

    func start() {
        guard sources.isEmpty else { return }
        let watchedFolders = folders
        startTask?.cancel()
        startTask = Task { [weak self] in
            let initial = await Task.detached(priority: .utility) {
                Self.installedApps(in: watchedFolders)
            }.value
            guard !Task.isCancelled, let self else { return }
            known = initial
            installDirectoryWatchers()
        }
    }

    func stop() {
        startTask?.cancel()
        startTask = nil
        pending?.cancel()
        pending = nil
        sources.forEach { $0.cancel() }
        sources = []
    }

    private func installDirectoryWatchers() {
        guard sources.isEmpty else { return }
        for folder in folders {
            let descriptor = open(folder.path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .rename, .delete],
                queue: .main
            )
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.scheduleCheck() }
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            sources.append(source)
        }
    }

    private func scheduleCheck() {
        pending?.cancel()
        let watchedFolders = folders
        pending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self else { return }
            let current = await Task.detached(priority: .utility) {
                Self.installedApps(in: watchedFolders)
            }.value
            guard !Task.isCancelled else { return }
            for (id, app) in known where current[id] == nil {
                guard !Self.isApplicationStillInstalled(
                    bundleIdentifier: id,
                    previousURL: app.bundleURL,
                    folders: watchedFolders
                ) else {
                    continue
                }
                onRemoved(app)
            }
            known = current
        }
    }

    /// Checks whether an app bundle still exists at its original path, in any
    /// watched Applications directory, or via LaunchServices (`NSWorkspace`)
    /// outside Trash — preventing false-positive orphan triggers during
    /// Homebrew Cask upgrades, Sparkle replacements, or user relocations.
    static func isApplicationStillInstalled(
        bundleIdentifier: String,
        previousURL: URL,
        folders: [URL] = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        ]
    ) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: previousURL.path) {
            return true
        }
        if let resolved = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            let path = resolved.standardizedFileURL.path
            let userTrash = fm.homeDirectoryForCurrentUser
                .appendingPathComponent(".Trash", isDirectory: true)
                .standardizedFileURL.path
            let inTrash = path == userTrash
                || path.hasPrefix(userTrash + "/")
                || path.contains("/.Trash/")
                || path.contains("/.Trashes/")
            if !inTrash, fm.fileExists(atPath: path) {
                return true
            }
        }
        let current = installedApps(in: folders)
        return current[bundleIdentifier] != nil
    }

    /// Bundle ID → app across watched Applications folders (including immediate
    /// subfolders such as Utilities, skipping inside `.app` bundles).
    nonisolated static func installedApps(in folders: [URL]) -> [String: InstalledApplication] {
        var apps: [String: InstalledApplication] = [:]
        let fm = FileManager.default
        for folder in folders {
            let entries = (try? fm.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for url in entries {
                if url.pathExtension == "app" {
                    registerApp(at: url, into: &apps)
                } else if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    let nested = (try? fm.contentsOfDirectory(
                        at: url,
                        includingPropertiesForKeys: nil,
                        options: [.skipsHiddenFiles]
                    )) ?? []
                    for child in nested where child.pathExtension == "app" {
                        registerApp(at: child, into: &apps)
                    }
                }
            }
        }
        return apps
    }

    nonisolated private static func registerApp(
        at url: URL,
        into apps: inout [String: InstalledApplication]
    ) {
        guard let id = Bundle(url: url)?.bundleIdentifier else { return }
        apps[id] = InstalledApplication(
            id: id,
            name: url.deletingPathExtension().lastPathComponent,
            bundleURL: url,
            bundleIdentifier: id,
            bundleSizeBytes: 0
        )
    }
}
