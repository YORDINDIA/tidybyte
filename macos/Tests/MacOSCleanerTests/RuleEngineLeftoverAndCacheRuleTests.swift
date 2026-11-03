import Foundation
import XCTest
@testable import MacOSCleanerCore

/// SP-23 (app leftovers) and SP-24 (package manager caches): both rules run in
/// `CleanerRuleEngine.analyze`. SP-23 flags DIRECT children of any
/// "Application Support" folder that do not normalize to an installed app and
/// exceed 50 MB. SP-24 flags the two package cache directories under the home
/// folder (`~/.npm`, `~/.cache/pip`). The SP-24 records are synthetic by
/// necessity — the rule matches absolute home paths, and tests must not create
/// directories in the real home. `analyze` is pure string work over records
/// (the policy gate reads precomputed risk flags, no filesystem round-trips),
/// so synthetic records exercise the real rule.
final class RuleEngineLeftoverAndCacheRuleTests: XCTestCase {
    private var root = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        root = try TestFixtures.makeTemporaryDirectory(named: "LeftoverCacheRules-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A rolled-up directory record: the crawler summarizes `.npm` (it is in
    /// `rolledUpFolderNames`), so the real record carries the subtree size in
    /// `sizeBytes` with `rolledUpItemCount` set.
    private func makeDirectoryRecord(id: String, path: String, sizeBytes: Int64 = 0) -> FileRecord {
        let url = URL(fileURLWithPath: path)
        var record = FileRecord(
            id: id, scanSessionID: "test-scan", source: .local, url: url,
            displayPath: path, fileName: url.lastPathComponent,
            fileExtension: nil, utiDescription: nil,
            kind: .directory, sizeBytes: sizeBytes,
            createdAt: Date(), modifiedAt: Date(), lastOpenedAt: nil,
            owner: nil, permissions: nil, isSymlink: false, symlinkTarget: nil,
            isPackage: false, isCloudPlaceholder: false, cloudProvider: nil,
            finderTags: [], spotlightMetadata: [:], riskFlags: [],
            identity: FileIdentity(deviceIdentifier: 1, inodeIdentifier: 1, resourceIdentifier: nil),
            capabilities: [])
        record.rolledUpItemCount = sizeBytes > 0 ? 12 : nil
        return record
    }

    // MARK: - SP-23: app leftovers

    func testAppLeftoverRuleFlagsUninstalledAppSupportFolder() async throws {
        let support = root.appendingPathComponent("Library/Application Support", isDirectory: true)
        let zombie = support.appendingPathComponent("Zombie Craft 2000", isDirectory: true)
        try FileManager.default.createDirectory(at: zombie, withIntermediateDirectories: true)
        // The rule only proposes folders above 50 MB; a sparse blob keeps the test cheap.
        let blob = zombie.appendingPathComponent("blob.bin", isDirectory: false)
        try TestFileFixtures.makeSparseFile(at: blob, logicalSize: 50_500_000)

        let crawler = FileCrawler()
        let crawlOutcome22 = await crawler.crawl(rootURLs: [root], sessionID: "scan")
        let (records, _) = (crawlOutcome22.files, crawlOutcome22.errors)
        let engine = CleanerRuleEngine()
        let (findings, recommendations) = try await engine.analyze(files: records, projects: [], sessionID: "scan")

        let leftovers = findings.filter { $0.category == .appLeftover }
        XCTAssertEqual(leftovers.count, 1, "Exactly the uninstalled app's folder should be flagged")
        let leftover = try XCTUnwrap(leftovers.first)
        let zombieRecord = try XCTUnwrap(records.first { $0.fileName == "Zombie Craft 2000" })
        XCTAssertTrue(leftover.targetFileIDs.contains(zombieRecord.id))
        let recommendation = try XCTUnwrap(recommendations.first { $0.findingID == leftover.id })
        XCTAssertEqual(recommendation.policyTraceID, "app_leftover_rule")
        XCTAssertEqual(recommendation.risk, .medium)
        XCTAssertLessThanOrEqual(recommendation.confidence, 0.85,
                                 "The leftover match is heuristic; confidence must stay in review range")
    }

    func testAppLeftoverRuleSkipsInstalledAppNameAndSmallFolders() async throws {
        let support = root.appendingPathComponent("Library/Application Support", isDirectory: true)
        // A folder named after an actually installed app must never be flagged.
        let appURL = URL(fileURLWithPath: "/Applications")
        let apps = (try? FileManager.default.contentsOfDirectory(at: appURL, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "app" } ?? []
        guard let installedApp = apps.first else {
            throw XCTSkip("No /Applications bundle to exercise the installed-app skip against")
        }
        let installedName = installedApp.deletingPathExtension().lastPathComponent
        let installedFolder = support.appendingPathComponent(installedName, isDirectory: true)
        try FileManager.default.createDirectory(at: installedFolder, withIntermediateDirectories: true)
        let blob = installedFolder.appendingPathComponent("blob.bin", isDirectory: false)
        try TestFileFixtures.makeSparseFile(at: blob, logicalSize: 50_500_000)
        // A small uninstalled folder is below the size gate and must not be flagged.
        let smallFolder = support.appendingPathComponent("Tiny Ghost App", isDirectory: true)
        try FileManager.default.createDirectory(at: smallFolder, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 1_000).write(to: smallFolder.appendingPathComponent("settings.plist", isDirectory: false))

        let crawler = FileCrawler()
        let crawlOutcome23 = await crawler.crawl(rootURLs: [root], sessionID: "scan")
        let (records, _) = (crawlOutcome23.files, crawlOutcome23.errors)
        let engine = CleanerRuleEngine()
        let (findings, _) = try await engine.analyze(files: records, projects: [], sessionID: "scan")

        XCTAssertTrue(findings.filter { $0.category == .appLeftover }.isEmpty,
                      "Installed-app names and below-gate folders must not be flagged as leftovers")
    }

    // MARK: - SP-24: package manager caches

    func testPackageManagerCacheRuleFlagsNpmAndPipCacheDirectories() async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let npm = makeDirectoryRecord(id: "npm", path: home.appendingPathComponent(".npm").path, sizeBytes: 60_000_000)
        let pip = makeDirectoryRecord(id: "pip", path: home.appendingPathComponent(".cache/pip").path, sizeBytes: 250_000_000)
        let unrelated = makeDirectoryRecord(id: "docs", path: home.appendingPathComponent("Documents").path, sizeBytes: 900_000_000)

        let engine = CleanerRuleEngine()
        let (findings, recommendations) = try await engine.analyze(
            files: [npm, pip, unrelated], projects: [], sessionID: "scan")

        let cacheFindings = findings.filter { $0.category == .packageManagerCleanup }
        XCTAssertEqual(cacheFindings.count, 2, "~/.npm and ~/.cache/pip must both be flagged; ~/Documents must not")
        XCTAssertEqual(recommendations.filter { $0.policyTraceID == "package_manager_cache_rule" }.count, 2)
        for recommendation in recommendations.filter({ $0.policyTraceID == "package_manager_cache_rule" }) {
            XCTAssertEqual(recommendation.risk, .low, "Package caches are rebuildable; the rule is low-risk")
        }
    }

    func testPackageManagerCacheRuleCarriesSubtreeBytes() async throws {
        // A rolled-up `.npm` record's sizeBytes IS the subtree total; the
        // finding and its recommendation must carry it through untouched.
        let home = FileManager.default.homeDirectoryForCurrentUser
        let npm = makeDirectoryRecord(id: "npm", path: home.appendingPathComponent(".npm").path, sizeBytes: 734_003_200)
        let engine = CleanerRuleEngine()
        let (findings, recommendations) = try await engine.analyze(files: [npm], projects: [], sessionID: "scan")

        let finding = try XCTUnwrap(findings.first { $0.category == .packageManagerCleanup })
        XCTAssertEqual(finding.bytesReclaimable, 734_003_200, "The subtree total must feed the byte estimate")
        XCTAssertEqual(recommendations.first { $0.findingID == finding.id }?.expectedBytesReclaimed, 734_003_200)
    }
}
