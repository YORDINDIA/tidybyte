import SwiftUI
@testable import MacOSCleanerAppKit
@testable import MacOSCleanerCore
import XCTest

/// DB-14 evidence: protected paths can never render green in the treemap.
///
/// Two independent layers are asserted:
/// 1. Color mapping — the protected finding category maps to the purple
///    `CategoricalPalette.protected`, and the forbidden risk level maps to
///    `RiskScale.forbidden` purple (the 2026-07-31 "protected overlay was
///    green" fix). Green palettes exist for real cleanup categories only.
/// 2. Data path — the rule engine's policy pass drops protected records
///    before findings are produced, so `dashboardSections` (the treemap's
///    bucketing input) never receives protected bytes to color at all.
final class DesignEvidenceTests: XCTestCase {

    // MARK: - Color mapping layer

    func testProtectedFindingCategoryPaletteIsPurpleNotGreen() {
        let protected = FindingCategory.protected.palette
        XCTAssertEqual(protected.mid, CategoricalPalette.protected.mid,
                       "FindingCategory.protected must use the dedicated purple palette")
        XCTAssertNotEqual(protected.mid, CategoricalPalette.green.mid,
                          "The protected category must never render green")
    }

    func testForbiddenRiskColorIsPurpleNeverGreen() {
        XCTAssertEqual(RiskScale.color(for: .forbidden), RiskScale.forbidden,
                       "RiskScale.color(for:) must map .forbidden to the purple token")
        XCTAssertNotEqual(RiskScale.color(for: .forbidden), RiskScale.color(for: .low),
                          "The forbidden (protected) risk color must differ from the green low-risk color")
    }

    func testProtectedPaletteIsTheForbiddenPurpleToken() {
        // The palette constant itself is system purple, matching RiskScale.forbidden.
        XCTAssertEqual(CategoricalPalette.protected.mid, RiskScale.forbidden)
    }

    // MARK: - Data-path layer

    func testRuleEngineDropsProtectedRecordsFromFindings() async throws {
        let root = try TestFixtures.makeTemporaryDirectory(named: "DB14-Protected-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let envURL = root.appendingPathComponent(".env", isDirectory: false)
        try Data("SECRET=1".utf8).write(to: envURL)
        let sshDir = root.appendingPathComponent(".ssh", isDirectory: true)
        try FileManager.default.createDirectory(at: sshDir, withIntermediateDirectories: true)
        try Data("not-a-real-key".utf8).write(to: sshDir.appendingPathComponent("id_ed25519"))

        let policy = PathSafetyPolicy()
        let protectedRecords = [envURL, sshDir].map { url in
            TestFixtures.makeFileRecord(
                id: url.lastPathComponent, path: url.path, sizeBytes: 9)
        }.map { record -> FileRecord in
            var flagged = record
            flagged.riskFlags = policy.riskFlags(for: record.url, isDirectory: record.kind == .directory)
            return flagged
        }
        for record in protectedRecords {
            XCTAssertTrue(policy.isProtectedFromCleanup(record),
                          "\(record.fileName) must be recognized as protected")
        }

        // A sibling unprotected log file produces findings; the protected
        // paths beside it produce none. (A regular file keeps its own
        // sizeBytes out of the directory-rollup path.)
        let logURL = root.appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("big.log", isDirectory: false)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Logs", isDirectory: true), withIntermediateDirectories: true)
        try Data(repeating: 7, count: 2_000_000).write(to: logURL)
        let controlRecord = TestFixtures.makeFileRecord(
            id: "log", path: logURL.path, sizeBytes: 2_000_000)

        let engine = CleanerRuleEngine(policy: policy)
        let (findings, recommendations) = try await engine.analyze(
            files: protectedRecords + [controlRecord], projects: [], sessionID: "db14")

        XCTAssertFalse(findings.isEmpty, "The unprotected log file must still be found (control)")
        for finding in findings {
            for targetID in finding.targetFileIDs {
                let record = (protectedRecords + [controlRecord]).first { $0.id == targetID }
                XCTAssertFalse(
                    record.map { policy.isProtectedFromCleanup($0) } ?? false,
                    "A finding (\(finding.summary)) targets a protected path")
            }
        }
        XCTAssertTrue(recommendations.allSatisfy { recommendation in
            let targets = recommendation.targetFileIDs.compactMap { id in
                (protectedRecords + [controlRecord]).first { $0.id == id }
            }
            return targets.allSatisfy { !policy.isProtectedFromCleanup($0) }
        }, "A recommendation targets a protected path")
    }
}
