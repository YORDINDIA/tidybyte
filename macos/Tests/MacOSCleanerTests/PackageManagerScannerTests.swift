import Foundation
@testable import MacOSCleanerCore
import XCTest

final class PackageManagerScannerTests: XCTestCase {
    func testScannerLinksEachCandidateToItsFindingAndRecommendation() async {
        let (findings, recommendations, candidates) = await PackageManagerScanner().scan(sessionID: "test")
        XCTAssertEqual(findings.count, candidates.count)
        XCTAssertEqual(recommendations.count, candidates.count)
        for (finding, candidate) in zip(findings, candidates) {
            XCTAssertEqual(finding.targetFileIDs, [candidate.id])
        }
        for (recommendation, finding) in zip(recommendations, findings) {
            XCTAssertEqual(recommendation.findingID, finding.id)
            XCTAssertTrue(recommendation.requiresConfirmation)
        }
    }

    func testPackageCleanupCandidateHasRequiredFields() {
        let candidate = PackageCleanupCandidate(
            id: "test-cleanup",
            title: "Test Cleanup",
            commandPath: URL(fileURLWithPath: "/usr/bin/echo"),
            arguments: ["test"],
            dryRunOutput: "Would remove test",
            risk: .low,
            category: .packageManagerCleanup
        )

        XCTAssertEqual(candidate.id, "test-cleanup")
        XCTAssertEqual(candidate.title, "Test Cleanup")
        XCTAssertEqual(candidate.risk, .low)
        XCTAssertEqual(candidate.category, .packageManagerCleanup)
    }

    func testPackageCleanupCandidateRiskLevels() {
        let lowRisk = PackageCleanupCandidate(
            id: "low", title: "Low", commandPath: URL(fileURLWithPath: "/usr/bin/echo"),
            arguments: [], dryRunOutput: "", risk: .low, category: .packageManagerCleanup
        )
        let highRisk = PackageCleanupCandidate(
            id: "high", title: "High", commandPath: URL(fileURLWithPath: "/usr/bin/echo"),
            arguments: [], dryRunOutput: "", risk: .high, category: .packageManagerCleanup
        )

        XCTAssertTrue(lowRisk.risk < highRisk.risk)
    }
}
