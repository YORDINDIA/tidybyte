import Foundation
@testable import MacOSCleanerCore
import XCTest

final class CodingAgentProtectionTests: XCTestCase {
    func testMixedCaseAgentLogsAreCandidatesButMemoryDescendantsStayProtected() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let logs = root.appendingPathComponent(".CoDeX/logs", isDirectory: true)
        let memoryLogs = root.appendingPathComponent(".CoDeX/memory/logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: memoryLogs, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 32).write(to: logs.appendingPathComponent("session.log"))
        try Data(repeating: 1, count: 32).write(to: memoryLogs.appendingPathComponent("context.log"))

        let records = await FileCrawler().crawl(rootURLs: [root], sessionID: "scan").files
        let allowed = try XCTUnwrap(records.first { $0.url == logs.standardizedFileURL })
        let protected = try XCTUnwrap(records.first { $0.url == memoryLogs.standardizedFileURL })
        XCTAssertFalse(allowed.riskFlags.contains(.codingAgentMemoryOrConfig))
        XCTAssertTrue(protected.riskFlags.contains(.codingAgentMemoryOrConfig))
        XCTAssertTrue(PathSafetyPolicy().isProtectedFromCleanup(url: memoryLogs, isDirectory: true))

        let (_, recommendations) = try await CleanerRuleEngine().analyze(files: records, projects: [], sessionID: "scan")
        XCTAssertTrue(recommendations.contains { $0.targetFileIDs.contains(allowed.id) && $0.actionType == .archive })
        XCTAssertFalse(recommendations.contains { $0.targetFileIDs.contains(protected.id) })
    }
}
