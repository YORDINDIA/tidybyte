import Foundation
@testable import MacOSCleanerAppKit
@testable import MacOSCleanerCore
import XCTest

/// Never-silent scan evidence (2026-11-04): S-02 and S-03.
///
/// - S-02: an AI classification failure must reach the outcome's notices —
///   the plan used to render as if AI had run, with the failure log-only.
/// - S-03: a requested scan root the safety policy refuses must surface as a
///   scan notice, not look like a clean folder.
@MainActor
final class ScanNoticeEvidenceTests: XCTestCase {
    private func makeModel() throws -> AppViewModel {
        let store = try SQLiteStore.inMemory()
        let memory = MemoryEngine(store: store)
        let orchestrator = ScanOrchestrator(store: store, memory: memory)
        let model = AppViewModel(
            store: store,
            keychain: KeychainStore(inMemory: true),
            memory: memory,
            orchestrator: orchestrator,
            executor: TestFixtures.makeExecutor(store: store),
            undoService: UndoManagerService(store: store, memory: memory),
            reportGenerator: ReportGenerator(store: store),
            notifications: NotificationScheduler(),
            planner: PlannerAgent(),
            defaults: makeIsolatedDefaults()
        )
        return model
    }

    private func runScanOnFixture(_ model: AppViewModel, root: URL) async -> Bool {
        model.selectedMode = .selectedFolders
        model.selectedFolders = [root]
        model.runScan()
        let deadline = Date().addingTimeInterval(20)
        var settled = false
        while Date() < deadline {
            if model.plan != nil || model.errorMessage != nil { settled = true; break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        if settled {
            let clearDeadline = Date().addingTimeInterval(20)
            while Date() < clearDeadline, model.isScanning {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        return settled
    }

    /// S-02: AI enabled with no key for the provider — the scan completes
    /// with local results AND the outcome carries a visible AI-skip notice.
    func testAIFailureAddsVisibleNoticeToOutcome() async throws {
        let model = try makeModel()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScanNotice-AI-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("cache".utf8).write(to: root.appendingPathComponent("keep.txt"))
        defer { try? FileManager.default.removeItem(at: root) }

        model.includeAI = true
        // A non-default provider name skips the legacy-keychain fallback, so
        // the gateway fails offline with missingAPIKey.
        model.providerSettings.providerName = "audit-test-provider"
        model.providerSettings.privacyMode = .metadataOnlyAI

        let completed = await runScanOnFixture(model, root: root)
        XCTAssertTrue(completed, "The scan must complete despite the AI failure")
        let outcome = try XCTUnwrap(model.outcome)
        XCTAssertTrue(
            outcome.notices.contains { $0.message.localizedCaseInsensitiveContains("AI classification was skipped") },
            "The AI failure must surface as a scan notice, not stay log-only; got \(outcome.notices.map(\.message))")
        XCTAssertNil(model.errorMessage, "The AI failure is a notice, not a scan error")
    }

    /// S-03: crawling a root the policy refuses yields a skip notice instead
    /// of an indistinguishable-from-clean empty result.
    func testSkippedProtectedRootAddsScanNotice() async throws {
        // /tmp is in the SIP-protected set (only /var/folders temp space is
        // exempted), so a root under /tmp is dropped by the crawler.
        let protectedRoot = URL(fileURLWithPath: "/tmp/tidybyte-skip-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: protectedRoot, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: protectedRoot.appendingPathComponent("inside.txt"))
        defer { try? FileManager.default.removeItem(at: protectedRoot) }

        let crawler = FileCrawler()
        let crawlOutcome1 = await crawler.crawl(rootURLs: [protectedRoot], sessionID: "skip-probe")
        let (records, _, notices) = (crawlOutcome1.files, crawlOutcome1.errors, crawlOutcome1.skippedRootNotices)
        XCTAssertTrue(records.isEmpty, "A protected root must not be crawled")
        XCTAssertTrue(
            notices.contains { $0.message.contains(protectedRoot.path) && $0.message.contains("skipped") },
            "The skipped root must surface as a scan notice; got \(notices.map(\.message))")
    }
}
