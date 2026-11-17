import Foundation

/// Bundle IDs of every installed app, used to decide whether data named
/// after a bundle ID is orphaned. Built once per scan.
public struct InstalledAppIndex: Sendable {
    public var bundleIDs: Set<String>

    public init(bundleIDs: Set<String>) {
        self.bundleIDs = Set(bundleIDs.map { $0.lowercased() })
    }

    /// Helpers and extensions extend the main app's ID (com.x.app.helper),
    /// so a prefix relation in either direction counts as installed. Vendors
    /// share data across their apps (com.microsoft.office.licensingV2), so
    /// any installed app of the same vendor (com.microsoft) counts too.
    public func isInstalled(_ bundleID: String) -> Bool {
        let id = bundleID.lowercased()
        let vendor = id.split(separator: ".").prefix(2).joined(separator: ".") + "."
        return bundleIDs.contains(id)
            || bundleIDs.contains { id.hasPrefix($0 + ".") || $0.hasPrefix(id + ".") || $0.hasPrefix(vendor) }
    }

    /// Spotlight's list of application bundles plus the standard app folders.
    /// Uses `mdutil`/`mdfind` on Direct builds and `NSMetadataQuery` + bundle scan
    /// inside the App Store sandbox. Nil when no inventory can be determined.
    public static func live(home: URL) async -> InstalledAppIndex? {
        if DistributionChannel.supportsAdvanced {
            let status = await ProcessRunner.run(
                URL(fileURLWithPath: "/usr/bin/mdutil"), arguments: ["-s", "/"], timeout: 10)
            guard status.exitCode == 0, status.stdout.contains("Indexing enabled") else { return nil }
            let found = await ProcessRunner.run(
                URL(fileURLWithPath: "/usr/bin/mdfind"),
                arguments: ["kMDItemContentType == 'com.apple.application-bundle'"], timeout: 30)
            guard found.exitCode == 0, !found.truncated else { return nil }
            let bundles = found.stdout.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
                + standardBundles(home: home)
            return InstalledAppIndex(bundleIDs: Set(bundles.compactMap { Bundle(url: $0)?.bundleIdentifier }))
        }
        let queryBundles = await spotlightBundlesViaMetadataQuery(timeoutSeconds: 5)
        let bundles = queryBundles + standardBundles(home: home) + nestedApplicationBundles(home: home)
        let ids = Set(bundles.compactMap { Bundle(url: $0)?.bundleIdentifier })
        return ids.isEmpty ? nil : InstalledAppIndex(bundleIDs: ids)
    }

    @MainActor
    private static func spotlightBundlesViaMetadataQuery(timeoutSeconds: UInt64) async -> [URL] {
        await AppMetadataQueryRunner().run(timeoutSeconds: timeoutSeconds)
    }

    private static func nestedApplicationBundles(home: URL) -> [URL] {
        let roots = ["/Applications", home.appendingPathComponent("Applications").path]
        return roots.flatMap { root -> [URL] in
            let rootURL = URL(fileURLWithPath: root, isDirectory: true)
            guard let children = try? FileManager.default.contentsOfDirectory(
                at: rootURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { return [] }
            return children.filter { $0.pathExtension != "app" }.flatMap { subfolder -> [URL] in
                let contents = (try? FileManager.default.contentsOfDirectory(
                    at: subfolder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
                )) ?? []
                return contents.filter { $0.pathExtension == "app" }
            }
        }
    }

    /// App bundles in the standard app folders. Fast; no Spotlight.
    public static func standardBundles(home: URL) -> [URL] {
        ["/Applications", "/Applications/Utilities", "/System/Applications",
            "/System/Applications/Utilities", home.appendingPathComponent("Applications").path].flatMap { folder in
            ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [])
                .filter { $0.hasSuffix(".app") }
                .map { URL(fileURLWithPath: folder, isDirectory: true).appendingPathComponent($0) }
        }
    }

    /// True for names like `com.vendor.app`: three or more dot-separated parts,
    /// a lowercase first part, and not Apple's own namespace.
    public static func isThirdPartyBundleID(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts.allSatisfy({ !$0.isEmpty }), !name.contains(" "),
            let first = parts.first, first.allSatisfy({ $0.isLowercase && $0.isLetter }) else { return false }
        return !name.lowercased().hasPrefix("com.apple.")
    }
}

@MainActor
private final class AppMetadataQueryRunner: NSObject {
    private var query: NSMetadataQuery?
    private var continuation: CheckedContinuation<[URL], Never>?
    private var timeoutTask: Task<Void, Never>?

    func run(timeoutSeconds: UInt64) async -> [URL] {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            let metadataQuery = NSMetadataQuery()
            metadataQuery.predicate = NSPredicate(format: "kMDItemContentType == 'com.apple.application-bundle'")
            metadataQuery.searchScopes = [NSMetadataQueryIndexedLocalComputerScope]
            self.query = metadataQuery
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleQueryFinish(_:)),
                name: .NSMetadataQueryDidFinishGathering,
                object: metadataQuery
            )
            self.timeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                self?.finish(urls: [])
            }
            if !metadataQuery.start() {
                finish(urls: [])
            }
        }
    }

    @objc private func handleQueryFinish(_ notification: Notification) {
        guard let query else {
            finish(urls: [])
            return
        }
        query.disableUpdates()
        var urls: [URL] = []
        for case let item as NSMetadataItem in query.results {
            if let path = item.value(forAttribute: kMDItemPath as String) as? String {
                urls.append(URL(fileURLWithPath: path))
            }
        }
        finish(urls: urls)
    }

    private func finish(urls: [URL]) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        if let query {
            NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidFinishGathering, object: query)
            query.stop()
            self.query = nil
        }
        continuation.resume(returning: urls)
    }
}
