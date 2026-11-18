import AppKit
import Foundation
@testable import MacOSCleanerAppKit
@testable import MacOSCleanerCore
import SwiftUI
import XCTest

final class MonitorAndAppStateTests: XCTestCase {
    private func writeAppBundle(at bundleURL: URL, bundleID: String) throws {
        let contents = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleName": bundleURL.deletingPathExtension().lastPathComponent
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
    }

    // MARK: - ChartDownsampler (LTTB)

    func testLTTBDownsamplerPreservesEndpointsAndSpikePeaks() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var points = (0..<400).map { idx in
            MetricsHistoryStore.SeriesPoint(
                timestamp: base.addingTimeInterval(Double(idx * 10)),
                average: 20.0 + Double(idx % 5),
                peak: 30.0
            )
        }
        points[150] = MetricsHistoryStore.SeriesPoint(
            timestamp: base.addingTimeInterval(1_500),
            average: 98.0,
            peak: 99.5
        )
        points.insert(
            MetricsHistoryStore.SeriesPoint(timestamp: base.addingTimeInterval(55), average: .nan, peak: nil),
            at: 5
        )

        let sampled = ChartDownsampler.downsample(points, targetCount: 180)
        XCTAssertEqual(sampled.count, 180)
        XCTAssertEqual(sampled.first?.timestamp, points.first?.timestamp)
        XCTAssertEqual(sampled.last?.timestamp, points.last?.timestamp)
        XCTAssertTrue(sampled.allSatisfy { $0.average.isFinite })
        XCTAssertGreaterThanOrEqual(sampled.map(\.average).max() ?? 0, 95.0, "LTTB must preserve prominent peaks")

        let tuples = (0..<200).map { (base.addingTimeInterval(Double($0)), $0 == 80 ? 100.0 : Double($0 % 7)) }
        let sampledTuples = ChartDownsampler.downsampleTuples(tuples, targetCount: 60)
        XCTAssertEqual(sampledTuples.count, 60)
        XCTAssertEqual(sampledTuples.first?.0, tuples.first?.0)
        XCTAssertEqual(sampledTuples.last?.0, tuples.last?.0)
        XCTAssertEqual(sampledTuples.map(\.1).max() ?? 0, 100.0, accuracy: 0.001)
    }

    // MARK: - MonitorModel polling lifecycle & chartPoints

    @MainActor
    func testMonitorModelPausesPollingWhenMenuBarOffAndWindowHidden() async throws {
        let defaults = makeIsolatedDefaults()
        defaults.set(false, forKey: MonitoringKeys.menuBarPanelEnabled)
        defaults.set(1.0, forKey: MonitoringKeys.intervalSeconds)
        let settings = MonitoringSettings(defaults: defaults)
        let model = MonitorModel(settings: settings)
        defer { model.stop() }

        model.setWindowVisible(false)
        model.start()
        XCTAssertTrue(model.isRunning)

        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(model.snapshot, "Polling must stay paused when menu bar extra is disabled and window is hidden")
        XCTAssertTrue(model.liveSeries.isEmpty)

        model.setWindowVisible(true)
        let deadline = Date().addingTimeInterval(6)
        while model.snapshot == nil && Date() < deadline {
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertNotNil(model.snapshot, "Showing the Monitor window must attach polling")
        XCTAssertFalse(model.liveSeries.isEmpty)

        model.setWindowVisible(false)
        try await Task.sleep(for: .milliseconds(150))
        let countBeforeMenuBar = model.liveSeries.count

        defaults.set(true, forKey: MonitoringKeys.menuBarPanelEnabled)
        let attachDeadline = Date().addingTimeInterval(6)
        while model.liveSeries.count == countBeforeMenuBar && Date() < attachDeadline {
            try await Task.sleep(for: .milliseconds(40))
        }
        XCTAssertGreaterThan(model.liveSeries.count, countBeforeMenuBar, "Enabling menu bar must resume polling")
    }

    @MainActor
    func testMonitorModelChartPointsDownsamplesDenseStoredHistory() {
        let model = MonitorModel(settings: MonitoringSettings(defaults: makeIsolatedDefaults()))
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let stored = (0..<500).map { idx in
            MetricsHistoryStore.SeriesPoint(
                timestamp: base.addingTimeInterval(Double(idx * 60)),
                average: Double(idx % 100),
                peak: nil
            )
        }
        let points = model.chartPoints(metricKey: "cpu", stored: stored)
        XCTAssertEqual(points.count, 180)
        XCTAssertEqual(points.first?.timestamp, stored.first?.timestamp)
        XCTAssertEqual(points.last?.timestamp, stored.last?.timestamp)
    }

    // MARK: - ApplicationRemovalWatcher

    @MainActor
    func testApplicationRemovalWatcherDetectsDuplicateCopyAndNestedBundles() throws {
        let root = try TestFixtures.makeTemporaryDirectory(named: "AppWatcher-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let appsA = root.appendingPathComponent("AppsA", isDirectory: true)
        let appsB = root.appendingPathComponent("AppsB", isDirectory: true)
        let bundleID = "com.tidybyte.test.\(UUID().uuidString)"

        let copyA = appsA.appendingPathComponent("FixtureApp.app", isDirectory: true)
        let copyB = appsB.appendingPathComponent("FixtureApp.app", isDirectory: true)
        let helper = appsA.appendingPathComponent("Utilities/Helper.app", isDirectory: true)
        let nestedInside = copyA.appendingPathComponent("Contents/Resources/Internal.app", isDirectory: true)

        try writeAppBundle(at: copyA, bundleID: bundleID)
        try writeAppBundle(at: copyB, bundleID: bundleID)
        try writeAppBundle(at: helper, bundleID: "com.tidybyte.test.helper")
        try writeAppBundle(at: nestedInside, bundleID: "com.tidybyte.test.internal")

        let discovered = ApplicationRemovalWatcher.installedApps(in: [appsA, appsB])
        XCTAssertNotNil(discovered[bundleID])
        XCTAssertNotNil(discovered["com.tidybyte.test.helper"])
        XCTAssertNil(discovered["com.tidybyte.test.internal"], "Bundles nested inside .app must not be registered")

        XCTAssertTrue(ApplicationRemovalWatcher.isApplicationStillInstalled(
            bundleIdentifier: bundleID, previousURL: copyA, folders: [appsA, appsB]
        ))

        // Trashing copyA still leaves copyB installed in appsB.
        try FileManager.default.removeItem(at: copyA)
        XCTAssertTrue(ApplicationRemovalWatcher.isApplicationStillInstalled(
            bundleIdentifier: bundleID, previousURL: copyA, folders: [appsA, appsB]
        ))

        try FileManager.default.removeItem(at: copyB)
        XCTAssertFalse(ApplicationRemovalWatcher.isApplicationStillInstalled(
            bundleIdentifier: bundleID, previousURL: copyA, folders: [appsA, appsB]
        ))
    }

    // MARK: - ExploreTree & TreemapView

    @MainActor
    func testExploreNormalizationMultiDepthFindGroupSectorsAndTreemapRender() throws {
        XCTAssertEqual(ExploreSubtreeIndex.normalizedPath("/Users/demo/sub/../Projects/"), "/Users/demo/Projects")
        XCTAssertTrue(ExploreSubtreeIndex.normalizedPath("~/Downloads").hasSuffix("/Downloads"))

        let files = [
            TestFixtures.makeFileRecord(id: "f1", path: "/Root/Alpha/Deep/Leaf/one.bin", sizeBytes: 600),
            TestFixtures.makeFileRecord(id: "f2", path: "/Root/Alpha/Deep/two.bin", sizeBytes: 300),
            TestFixtures.makeFileRecord(id: "f3", path: "/Root/Beta/three.bin", sizeBytes: 100)
        ]
        let totals = ExploreSubtreeIndex.totals(files: files)
        XCTAssertEqual(totals["/Root/Alpha/Deep/Leaf"], 600)
        XCTAssertEqual(totals["/Root/Alpha/Deep"], 900)
        XCTAssertEqual(totals["/Root"], 1000)

        let groups = ExploreTreeBuilder.build(files: files, grouping: .byFolder, maxDepth: 4)
        XCTAssertNotNil(ExploreTreeBuilder.findGroup(id: "/Root/Alpha", in: groups))
        XCTAssertNotNil(ExploreTreeBuilder.findGroup(id: "/Root/Alpha/Deep", in: groups))
        XCTAssertNotNil(ExploreTreeBuilder.findGroup(id: "/Root/Alpha/Deep/Leaf", in: groups))
        XCTAssertNil(ExploreTreeBuilder.findGroup(id: "/Root/DoesNotExist", in: groups))

        let sectors = ExploreTreeBuilder.sectors(groups: groups, maxDepth: 4)
        let depth1 = sectors.filter { $0.depth == 1 }
        XCTAssertEqual(depth1.reduce(0.0) { $0 + $1.sweepFraction }, 1.0, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(ExploreTreeBuilder.flameRows(groups: groups, maxDepth: 4).count, 3)

        let size = CGSize(width: 720, height: 340)
        let view = TreemapView(files: files, grouping: .byFolder, maxDepth: 4)
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        window.setFrame(NSRect(origin: .zero, size: size), display: true)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        XCTAssertGreaterThan(rep.pixelsWide, 0)
        XCTAssertGreaterThan(rep.pixelsHigh, 0)
    }
}

final class LanguageCoverageTests: XCTestCase {
    func testAll21ConcreteLanguagesRTLFlagsAndMatching() {
        let concrete = AppLanguage.concreteLanguages
        XCTAssertEqual(concrete.count, 21)
        XCTAssertEqual(AppLanguage.allCases.count, 22)
        XCTAssertEqual(Set(concrete.map(\.rawValue)).count, 21)

        for lang in AppLanguage.allCases {
            XCTAssertFalse(lang.endonym.isEmpty)
            XCTAssertFalse(lang.englishName.isEmpty)
            let expectedRTL = (lang == .arabic || lang == .hebrew)
            XCTAssertEqual(lang.isRightToLeft, expectedRTL, "\(lang.rawValue) RTL flag mismatch")
            XCTAssertEqual(lang.isRTL, expectedRTL)
        }

        XCTAssertEqual(AppLanguage.match(identifier: "zh_CN"), .chineseSimplified)
        XCTAssertEqual(AppLanguage.match(identifier: "zh-Hans-SG"), .chineseSimplified)
        XCTAssertNil(AppLanguage.match(identifier: "zh-Hant"))
        XCTAssertNil(AppLanguage.match(identifier: "zh-TW"))
        XCTAssertEqual(AppLanguage.match(identifier: "pt_PT"), .portugueseBrazil)
        XCTAssertEqual(AppLanguage.match(identifier: "pt-BR"), .portugueseBrazil)
        XCTAssertEqual(AppLanguage.match(identifier: "ar-SA"), .arabic)
        XCTAssertEqual(AppLanguage.match(identifier: "he-IL"), .hebrew)
    }

    @MainActor
    func testPreferenceRoundTripLanguageStoreAndL10nBundlesAcrossAll21Languages() throws {
        let suiteName = "TidybyteTests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suiteName) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let store = LanguageStore(defaults: defaults)
        defer { store.reset() }

        for lang in AppLanguage.concreteLanguages {
            LanguagePreferenceStore.save(lang, to: defaults)
            XCTAssertEqual(LanguagePreferenceStore.stored(in: defaults), lang)
            LanguagePreferenceStore.applyToSystem(lang, to: defaults)
            XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), [lang.rawValue])

            store.selectedLanguage = lang
            XCTAssertEqual(store.effectiveLanguage, lang)
            XCTAssertEqual(store.layoutDirection, lang.isRightToLeft ? .rightToLeft : .leftToRight)

            let resolvedBundle = L10n.bundle(for: lang)
            XCTAssertNotEqual(resolvedBundle, .main, "Expected .lproj bundle for \(lang.rawValue)")

            let localizedCancel = L10n.string("Cancel", language: lang)
            XCTAssertFalse(localizedCancel.isEmpty)
            if lang == .english {
                XCTAssertEqual(localizedCancel, "Cancel")
            } else {
                XCTAssertNotEqual(localizedCancel, "Cancel", "Expected non-English translation for \(lang.rawValue)")
            }
        }

        XCTAssertNotEqual(L10n.string("Duplicates", language: .arabic), "Duplicates")
        store.reset()
        XCTAssertEqual(store.language, .system)
        XCTAssertNil(LanguagePreferenceStore.stored(in: defaults))
        XCTAssertNil(defaults.persistentDomain(forName: suiteName)?["AppleLanguages"])
    }
}
