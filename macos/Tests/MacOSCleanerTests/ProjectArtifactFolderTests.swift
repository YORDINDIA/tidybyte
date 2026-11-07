import Foundation
@testable import MacOSCleanerCore
import XCTest

final class ProjectArtifactFolderTests: XCTestCase {
    func testGradleIsReportedAndOnlyRecommendedInsideAProject() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project", isDirectory: true)
        let artifact = project.appendingPathComponent(".gradle", isDirectory: true)
        let outside = root.appendingPathComponent("outside/.gradle", isDirectory: true)
        try FileManager.default.createDirectory(at: artifact, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("plugins {}".utf8).write(to: project.appendingPathComponent("build.gradle"))
        try Data(repeating: 1, count: 32).write(to: artifact.appendingPathComponent("cache"))
        try Data(repeating: 1, count: 32).write(to: outside.appendingPathComponent("cache"))
        let files = await FileCrawler().crawl(rootURLs: [root], sessionID: "scan").files
        let projects = try await ProjectDetector().detectProjects(in: files)
        let unit = try XCTUnwrap(projects.first { $0.rootURL == project.standardizedFileURL })
        XCTAssertGreaterThan(unit.generatedFilesCount, 0)
        XCTAssertGreaterThanOrEqual(unit.reclaimableBytes, 32)
        let insideRecord = try XCTUnwrap(files.first { $0.url == artifact.standardizedFileURL })
        let outsideRecord = try XCTUnwrap(files.first { $0.url == outside.standardizedFileURL })
        let (_, recommendations) = try await CleanerRuleEngine().analyze(files: files, projects: projects, sessionID: "scan")
        XCTAssertTrue(recommendations.contains { $0.targetFileIDs.contains(insideRecord.id) })
        XCTAssertFalse(recommendations.contains { $0.targetFileIDs.contains(outsideRecord.id) })
    }

    func testLowRiskCacheIsReportedAndRecommended() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent(".next", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: root.appendingPathComponent("package.json"))
        try Data(repeating: 1, count: 32).write(to: cache.appendingPathComponent("cache"))
        let files = await FileCrawler().crawl(rootURLs: [root], sessionID: "scan").files
        let projects = try await ProjectDetector().detectProjects(in: files)
        let project = try XCTUnwrap(projects.first { $0.rootURL == root.standardizedFileURL })
        XCTAssertGreaterThanOrEqual(project.reclaimableBytes, 32)
        let record = try XCTUnwrap(files.first { $0.url == cache.standardizedFileURL })
        let (_, recommendations) = try await CleanerRuleEngine().analyze(files: files, projects: projects, sessionID: "scan")
        let recommendation = try XCTUnwrap(recommendations.first { $0.targetFileIDs.contains(record.id) })
        XCTAssertEqual(recommendation.risk, .low)
    }

}
