import Foundation

/// How a process relates to the thing a person thinks of as "an app". Helper
/// processes roll into their parent app so "what is using my memory" has a
/// one-line answer; un-bundled executables group by name.
public enum ProcessGroupKind: String, Codable, Sendable {
    /// A .app bundle the user (or login items) launched.
    case app
    /// A launchd agent/daemon or helper outside any bundle.
    case background
    /// Kernel-resident work.
    case kernel
    /// Sort rank: the apps a person launched come first.
    var rank: Int {
        switch self {
        case .app: 0
        case .background: 1
        case .kernel: 2
        }
    }
}

/// One row of the "apps, not processes" table: either an app with all of its
/// helpers folded in, or a standalone process.
public struct AppProcessGroup: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var kind: ProcessGroupKind
    public var bundlePath: String?
    public var bundleID: String?
    public var members: [ProcessSample]

    public var cpuPercent: Double { members.reduce(0) { $0 + $1.cpuPercent } }
    public var memoryBytes: Int64 { members.reduce(0) { $0 + max($1.residentBytes, 0) } }
    public var footprintBytes: Int64 { members.reduce(0) { $0 + max($1.physFootprintBytes, 0) } }
    public var diskReadPerSecond: Double { members.reduce(0) { $0 + $1.diskReadPerSecond } }
    public var diskWritePerSecond: Double { members.reduce(0) { $0 + $1.diskWritePerSecond } }
    public var downloadPerSecond: Double { members.reduce(0) { $0 + $1.downloadPerSecond } }
    public var uploadPerSecond: Double { members.reduce(0) { $0 + $1.uploadPerSecond } }
    public var energyIndex: Double { members.reduce(0) { $0 + $1.energyDelta } + wakeupsPerSecond }
    public var wakeupsPerSecond: Double { members.reduce(0) { $0 + $1.wakeupsPerSecond } }
    public var cpuTimeSeconds: Double { members.reduce(0) { $0 + $1.cpuTimeSeconds } }

    public var isIdle: Bool { cpuPercent < 1 && wakeupsPerSecond < 2 }

    public func value(for metric: UsageMetric) -> Double {
        switch metric {
        case .cpu: cpuPercent
        case .memory: Double(memoryBytes)
        case .disk: diskReadPerSecond + diskWritePerSecond
        case .network: downloadPerSecond + uploadPerSecond
        case .energy: energyIndex
        }
    }
}

extension ProcessSample {
    var downloadPerSecond: Double { networkUsage?.downloadPerSecond ?? 0 }
    var uploadPerSecond: Double { networkUsage?.uploadPerSecond ?? 0 }
}

/// Per-process network rates, sampled separately (nettop) and merged in.
public struct ProcessNetworkUsage: Sendable, Equatable {
    public var downloadPerSecond: Double
    public var uploadPerSecond: Double

    public init(downloadPerSecond: Double = 0, uploadPerSecond: Double = 0) {
        self.downloadPerSecond = downloadPerSecond
        self.uploadPerSecond = uploadPerSecond
    }
}

/// Groups raw process samples into app rows. Pure and injectable so tests can
/// feed synthetic tables; the network usage map is optional and merged by pid.
public enum AppProcessCatalog {
    /// Groups `processes` by the app each executable belongs to. `mode` picks
    /// the row granularity; apps and their helpers always roll up under
    /// `.byApp`, while standalone processes keep their own rows either way.
    public static func group(
        _ processes: [ProcessSample],
        mode: GroupingMode,
        networkUsage: [pid_t: ProcessNetworkUsage] = [:],
        systemName: String = "macOS"
    ) -> [AppProcessGroup] {
        var decorated: [ProcessSample] = processes
        for index in decorated.indices {
            if let usage = networkUsage[decorated[index].pid] {
                decorated[index].networkUsage = usage
            }
        }
        var groups: [String: AppProcessGroup] = [:]
        var order: [String] = []

        for sample in decorated {
            let key = groupKey(for: sample, mode: mode, systemName: systemName)
            if groups[key] != nil {
                groups[key]?.members.append(sample)
            } else {
                groups[key] = makeGroup(key: key, sample: sample, mode: mode, systemName: systemName)
                order.append(key)
            }
        }
        let built = order.compactMap { groups[$0] }
        // User-launched apps lead the table; system background work and the
        // kernel sink to the bottom. Within a section, busiest first.
        return built.sorted { lhs, rhs in
            if lhs.kind != rhs.kind { return lhs.kind.rank < rhs.kind.rank }
            return lhs.cpuPercent > rhs.cpuPercent
        }
    }

    public enum GroupingMode: String, CaseIterable, Codable, Sendable {
        case byApp, byProcess
    }

    /// Stable identity for a row: the app bundle when there is one, else the
    /// executable path (or name for kernel threads with no path).
    static func groupKey(for sample: ProcessSample, mode: GroupingMode, systemName: String) -> String {
        if sample.isKernelProcess || sample.pid == 0 { return "kernel" }
        if mode == .byProcess, sample.bundlePath == nil { return "proc:\(sample.pid)" }
        if let bundle = sample.bundlePath { return "app:\(bundle)" }
        if isSystemExecutable(sample) { return "system:\(systemName)" }
        return "exec:\(sample.executablePath ?? sample.name)"
    }

    static func makeGroup(
        key: String, sample: ProcessSample, mode: GroupingMode, systemName: String
    ) -> AppProcessGroup {
        let kind: ProcessGroupKind
        let name: String
        if key == "kernel" {
            kind = .kernel
            name = systemName
        } else if let bundleName = sample.bundleName ?? sample.bundlePath.map(fallbackBundleName) {
            kind = .app
            name = bundleName
        } else if key.hasPrefix("system:") {
            kind = .background
            name = systemName
        } else {
            kind = .background
            name = sample.name
        }
        return AppProcessGroup(id: key, name: name, kind: kind, bundlePath: sample.bundlePath, bundleID: sample.bundleID, members: [sample])
    }

    /// "Foo.app" → "Foo": the fallback display name when bundle metadata is
    /// unreadable. Shared with AppIdentityResolver.
    static func fallbackBundleName(from path: String) -> String {
        URL(fileURLWithPath: path)
            .lastPathComponent
            .replacingOccurrences(of: ".app", with: "")
    }

    static func isSystemExecutable(_ sample: ProcessSample) -> Bool {
        guard let path = sample.executablePath else { return sample.userID == 0 }
        return path.hasPrefix("/System/") || path.hasPrefix("/usr/") || path.hasPrefix("/sbin/")
            || path.hasPrefix("/private/var/db/") || path.hasPrefix("/Library/Apple/")
    }
}

/// Resolves which installed .app an executable path belongs to, with a small
/// cache so the per-second tick does not walk the filesystem repeatedly.
struct AppIdentityResolver {
    struct Identity: Sendable, Equatable {
        var bundlePath: String
        var bundleID: String?
        var displayName: String?
    }

    private var cache: [String: Identity?] = [:]
    private var cachePrunedAt = Date.distantPast

    mutating func identity(forExecutablePath path: String) -> Identity? {
        if let cached = cache[path] { return cached }
        let resolved = Self.resolve(path)
        cache[path] = resolved
        return resolved
    }

    /// Bounds the cache; called each tick with the set of live paths.
    mutating func prune(keptPaths: Set<String>) {
        guard cachePrunedAt.distance(to: .now) > 60 || cache.count > 4_000 else { return }
        cache = cache.filter { keptPaths.contains($0.key) }
        cachePrunedAt = .now
    }

    /// Walks up from the executable to the OUTERMOST enclosing .app bundle.
    /// Helpers ship as nested .app bundles inside their parent (Chrome's
    /// renderer, Xcode's helpers), and the table rolls them into the app the
    /// person actually launched.
    static func resolve(_ executablePath: String) -> Identity? {
        var url = URL(fileURLWithPath: executablePath)
        var outermost: URL?
        while url.pathComponents.count > 1 {
            if url.pathExtension == "app" {
                outermost = url
            }
            url.deleteLastPathComponent()
        }
        guard let bundleURL = outermost else { return nil }
        return identity(forBundleURL: bundleURL)
    }

    static func identity(forBundleURL url: URL) -> Identity? {
        guard let bundle = Bundle(url: url) else {
            return Identity(bundlePath: url.path, bundleID: nil, displayName: fallbackName(url))
        }
        let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? fallbackName(url)
        return Identity(bundlePath: url.path, bundleID: bundle.bundleIdentifier, displayName: name)
    }

    private static func fallbackName(_ url: URL) -> String {
        AppProcessCatalog.fallbackBundleName(from: url.path)
    }
}
