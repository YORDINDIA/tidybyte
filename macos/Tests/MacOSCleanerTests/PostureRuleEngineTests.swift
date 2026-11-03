import Foundation
@testable import MacOSCleanerCore
import XCTest

/// S-01 (ST-03/SB-06): the cleanup posture must change what the rule engine
/// proposes — Conservative asks for older, larger candidates than Balanced,
/// and Aggressive for younger, smaller ones than Balanced. Records come from
/// a real crawl of tiny fixture files; only size/age are overridden in
/// memory, so no large file is ever written.
@MainActor
final class PostureRuleEngineTests: XCTestCase {
    private func daysAgo(_ days: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: -days, to: Date())!
    }

    /// Crawls a tiny fixture and overrides the record's size and age in
    /// memory. The folder is named "Downloads" so the download rules match.
    private func record(
        fileName: String, ageDays: Int, sizeBytes: Int64, in root: URL
    ) async throws -> FileRecord {
        let downloads = root.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let fileURL = downloads.appendingPathComponent(fileName)
        try Data("posture-probe".utf8).write(to: fileURL)
        let crawler = FileCrawler()
        let outcome = await crawler.crawl(rootURLs: [root], sessionID: "posture")
        var record = try XCTUnwrap(outcome.files.first { $0.url == fileURL.standardizedFileURL })
        record.sizeBytes = sizeBytes
        record.modifiedAt = daysAgo(ageDays)
        return record
    }

    private func analyze(_ records: [FileRecord], posture: CleanupPosture) async throws -> Set<String> {
        let engine = CleanerRuleEngine(policy: PathSafetyPolicy())
        let (findings, _) = try await engine.analyze(
            files: records, projects: [], sessionID: "posture", posture: posture)
        return Set(findings.map(\.category.displayName))
    }

    private func makeFixtureRoot(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// The same 45-day-old download is proposed by Balanced and Aggressive
    /// but held back by Conservative's 60-day gate.
    func testPostureChangesOldDownloadGate() async throws {
        let root = try makeFixtureRoot("posture-download")
        defer { try? FileManager.default.removeItem(at: root) }
        let record = try await record(fileName: "posture-probe.zip", ageDays: 45, sizeBytes: 4_000_000, in: root)
        let conservative = try await analyze([record], posture: .conservative)
        let balanced = try await analyze([record], posture: .balanced)
        let aggressive = try await analyze([record], posture: .aggressive)
        XCTAssertFalse(conservative.contains("Old Download"), "Conservative must hold a 45-day download")
        XCTAssertTrue(balanced.contains("Old Download"), "Balanced proposes it at the 30-day gate")
        XCTAssertTrue(aggressive.contains("Old Download"), "Aggressive proposes it at the 14-day gate")
    }

    /// Large-file thresholds scale with posture: 1.5 GB is proposed by
    /// Aggressive (≥ 512 MB) and Balanced (≥ 1 GB) but not Conservative (≥ 2 GB).
    func testPostureChangesLargeFileGate() async throws {
        let root = try makeFixtureRoot("posture-large")
        defer { try? FileManager.default.removeItem(at: root) }
        let record = try await record(
            fileName: "posture-large.bin", ageDays: 10, sizeBytes: 1_500_000_000, in: root)
        let conservative = try await analyze([record], posture: .conservative)
        let balanced = try await analyze([record], posture: .balanced)
        let aggressive = try await analyze([record], posture: .aggressive)
        XCTAssertFalse(conservative.contains("Large File"), "Conservative's floor is 2 GB")
        XCTAssertTrue(balanced.contains("Large File"), "Balanced's floor is 1 GB")
        XCTAssertTrue(aggressive.contains("Large File"), "Aggressive's floor is 512 MB")
    }

    /// Monotonicity: for any fixture, aggressive findings ⊇ balanced ⊇
    /// conservative across all three postures.
    func testFindingsAreMonotonicAcrossPostures() async throws {
        let root = try makeFixtureRoot("posture-mono")
        defer { try? FileManager.default.removeItem(at: root) }
        let records = [
            try await record(fileName: "young.zip", ageDays: 45, sizeBytes: 4_000_000, in: root),
            try await record(fileName: "old.zip", ageDays: 100, sizeBytes: 4_000_000, in: root),
            try await record(fileName: "huge.bin", ageDays: 10, sizeBytes: 3_000_000_000, in: root)
        ]
        let conservative = try await analyze(records, posture: .conservative)
        let balanced = try await analyze(records, posture: .balanced)
        let aggressive = try await analyze(records, posture: .aggressive)
        XCTAssertTrue(balanced.isSuperset(of: conservative), "balanced ⊇ conservative")
        XCTAssertTrue(aggressive.isSuperset(of: balanced), "aggressive ⊇ balanced")
    }
}
