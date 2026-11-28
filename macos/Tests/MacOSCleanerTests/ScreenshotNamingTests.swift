import AppKit
import CoreGraphics
import Foundation
import XCTest
@testable import MacOSCleanerAppKit
@testable import MacOSCleanerCore

final class ScreenshotNamingTests: XCTestCase {

    // MARK: - VagueFilenameDetector

    func testVagueFilenameDetectorIdentifiesVagueNamesAndLeavesGoodNamesAlone() throws {
        let root = try TestFixtures.makeTemporaryDirectory(named: "VagueDetector-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let vagueNames = [
            "Screenshot 2026-11-11 at 7.12.33 PM.png",
            "Screen Shot 2024-01-01 at 10.00.00.png",
            "Bildschirmfoto 2026-05-01 um 12.00.00.png",
            "Capture d’écran 2026-05-01 à 12.00.00.png",
            "CleanShot 2026-11-11 at 10.12.00@2x.png",
            "Photo on 11-11-26 at 7.12 PM.jpg",
            "Capture 2026-11-11.png",
            "IMG_4471.jpg",
            "DSC_0123.jpeg",
            "PXL_20261111_191233.png",
            "image (2).png",
            "Untitled-3.png",
            "2026-11-11 19.12.33.png",
            "9f86d081884c7d659a2feaa0c55ad015.png"
        ]
        for name in vagueNames {
            let url = root.appendingPathComponent(name)
            try Data("img".utf8).write(to: url)
            XCTAssertTrue(
                VagueFilenameDetector.isEligibleVagueImage(at: url),
                "\(name) should be recognized as vague"
            )
        }

        let goodNames = [
            "Lisbon Flight Booking.png",
            "Architecture Diagram.png",
            "Harbor Street Coffee Receipt.jpg",
            "Quarterly Tax Summary 2026.png",
            "Photo Album Cover.png",
            "Capture the Flag.png",
            "Screenshot Guide for Users.png",
            "lisbon-flight-booking.png"
        ]
        for name in goodNames {
            let url = root.appendingPathComponent(name)
            try Data("img".utf8).write(to: url)
            XCTAssertFalse(
                VagueFilenameDetector.isEligibleVagueImage(at: url),
                "\(name) already has a real name and must not be flagged"
            )
        }
    }

    func testVagueFilenameDetectorRejectsCredentialsProtectedPathsAndSymlinks() throws {
        let root = try TestFixtures.makeTemporaryDirectory(named: "VagueSafety-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let secretNamed = root.appendingPathComponent("api_key_screenshot.png")
        try Data("secret".utf8).write(to: secretNamed)
        XCTAssertFalse(VagueFilenameDetector.isEligibleVagueImage(at: secretNamed))

        let sshDir = root.appendingPathComponent(".ssh", isDirectory: true)
        try FileManager.default.createDirectory(at: sshDir, withIntermediateDirectories: true)
        let inProtected = sshDir.appendingPathComponent("Screenshot 2026-11-11.png")
        try Data("x".utf8).write(to: inProtected)
        XCTAssertFalse(VagueFilenameDetector.isEligibleVagueImage(at: inProtected))

        let target = root.appendingPathComponent("Screenshot 2026-11-11 at 9.41.00 AM.png")
        try Data("x".utf8).write(to: target)
        let link = root.appendingPathComponent("Screenshot 2026-11-11 at 9.42.00 AM.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertFalse(VagueFilenameDetector.isEligibleVagueImage(at: link))
    }

    // MARK: - ScreenshotNameFormatter

    func testFormatterProducesAllFourNamingStylesAndSanitizes() throws {
        var components = DateComponents()
        components.year = 2026
        components.month = 11
        components.day = 11
        components.timeZone = TimeZone(secondsFromGMT: 0)
        let date = try XCTUnwrap(Calendar(identifier: .gregorian).date(from: components))

        XCTAssertEqual(
            ScreenshotNameFormatter.formatTitle("lisbon flight booking", style: .titleCase, date: date),
            "Lisbon Flight Booking"
        )
        XCTAssertEqual(
            ScreenshotNameFormatter.formatTitle("Lisbon Flight Booking", style: .sentenceCase, date: date),
            "Lisbon flight booking"
        )
        XCTAssertEqual(
            ScreenshotNameFormatter.formatTitle("Lisbon Flight Booking", style: .lowercaseDashes, date: date),
            "lisbon-flight-booking"
        )
        XCTAssertEqual(
            ScreenshotNameFormatter.formatTitle("lisbon flight booking", style: .dateFirst, date: date),
            "2026-11-11 Lisbon Flight Booking"
        )
        XCTAssertEqual(
            ScreenshotNameFormatter.formatTitle("\"Checkout: typeError / staging.png\"", style: .titleCase, date: date),
            "Checkout typeError Staging"
        )
    }

    func testFormatterAppliesLearnedPrefixAndResolvesCollisions() throws {
        let formatted = ScreenshotNameFormatter.formatTitle(
            "Hotel Check-In Confirmation",
            style: .sentenceCase,
            learnedPrefix: "Trip LIS",
            learnedSeparator: " · "
        )
        XCTAssertEqual(formatted, "Trip LIS · Hotel check-in confirmation")

        let root = try TestFixtures.makeTemporaryDirectory(named: "FormatterCollision-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let existing = root.appendingPathComponent("Lisbon Flight Booking.png")
        try Data("a".utf8).write(to: existing)

        let next = ScreenshotNameFormatter.collisionFreeURL(
            forFileName: "Lisbon Flight Booking.png",
            in: root,
            style: .titleCase
        )
        XCTAssertEqual(next.lastPathComponent, "Lisbon Flight Booking 2.png")
    }

    // MARK: - Title Generation & Style Learning

    func testTitleGeneratorFallbackFiltersChromeAndAppliesLearnedStyle() async {
        let generator = ScreenshotTitleGenerator()
        let signals = ScreenshotVisualSignals(
            prominentLines: ["File", "9:41 AM", "Hotel Check In Confirmation", "Booking Reference LIS-884"],
            bodyText: "File\n9:41 AM\nHotel Check In Confirmation",
            visionLabels: ["document"]
        )
        let example = StyleLearningAnalyzer.analyzeOverride(
            suggestedTitle: "Flight Booking Confirmation",
            userChosenTitle: "Trip LIS · flight out"
        )
        XCTAssertEqual(example.learnedPrefix, "Trip LIS")
        XCTAssertEqual(example.learnedSeparator, " · ")

        let result = await generator.synthesizeTitle(
            from: signals,
            originalExtension: "png",
            style: .titleCase,
            learnedExamples: [example],
            useAppleIntelligence: false
        )
        XCTAssertEqual(result.formattedFileName, "Trip LIS · hotel check in confirmation.png")
        XCTAssertFalse(result.usedAppleIntelligence)
    }

    // MARK: - Rename Service, Timestamps, Tidy Up & Undo

    func testRenamePreservesOriginalDatesAndUndoRestoresFilenameAndDates() async throws {
        let root = try TestFixtures.makeTemporaryDirectory(named: "RenameUndo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteStore(databaseURL: root.appendingPathComponent("test.sqlite"))
        let service = ScreenshotRenameService(store: store)

        let originalURL = root.appendingPathComponent("Screenshot 2026-11-11 at 7.12.33 PM.png")
        try makeSamplePNG(text: "Lisbon Flight Booking", at: originalURL)

        let originalDate = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes(
            [.creationDate: originalDate, .modificationDate: originalDate],
            ofItemAtPath: originalURL.path
        )

        let record = try await service.renameFile(
            at: originalURL,
            toFileName: "Lisbon Flight Booking.png",
            style: .titleCase,
            source: .autoWatch
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: originalURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.currentURL.path))
        XCTAssertEqual(record.newFileName, "Lisbon Flight Booking.png")

        let attrsAfterRename = try FileManager.default.attributesOfItem(atPath: record.currentURL.path)
        let modAfterRename = try XCTUnwrap(attrsAfterRename[.modificationDate] as? Date)
        XCTAssertLessThan(abs(modAfterRename.timeIntervalSince(originalDate)), 1.0)

        let reverted = try await service.undo(record: record)
        XCTAssertEqual(reverted.status, .reverted)
        XCTAssertTrue(FileManager.default.fileExists(atPath: originalURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.currentURL.path))

        let attrsAfterUndo = try FileManager.default.attributesOfItem(atPath: originalURL.path)
        let modAfterUndo = try XCTUnwrap(attrsAfterUndo[.modificationDate] as? Date)
        XCTAssertLessThan(abs(modAfterUndo.timeIntervalSince(originalDate)), 1.0)
    }

    func testTidyUpSkipsGoodNamesAndBatchUndoRevertsAll() async throws {
        let root = try TestFixtures.makeTemporaryDirectory(named: "TidyUpBatch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteStore(databaseURL: root.appendingPathComponent("test.sqlite"))
        let service = ScreenshotRenameService(store: store)

        let vague1 = root.appendingPathComponent("IMG_4471.png")
        let vague2 = root.appendingPathComponent("Untitled-3.png")
        let wellNamed = root.appendingPathComponent("Architecture Diagram.png")
        try makeSamplePNG(text: "Coffee Shop Receipt", at: vague1)
        try makeSamplePNG(text: "Weekly Sprint Notes", at: vague2)
        try makeSamplePNG(text: "System Diagram", at: wellNamed)

        let summary = await service.scanFolderForTidyUp(
            at: root,
            style: .titleCase,
            useAppleIntelligence: false
        )
        XCTAssertEqual(summary.candidates.count, 2)
        XCTAssertEqual(summary.skippedWellNamedCount, 1)

        let applied = try await service.applyTidyUpCandidates(summary.candidates, style: .titleCase)
        XCTAssertEqual(applied.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: wellNamed.path))
        let batchID = try XCTUnwrap(applied.first?.batchID)

        let reverted = try await service.undoBatch(batchID: batchID)
        XCTAssertEqual(reverted.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: vague1.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: vague2.path))
    }

    // MARK: - Watcher & Finder Style Learning

    func testWatcherAutoRenamesNewVagueImageAndLearnsFromManualFinderRename() async throws {
        let root = try TestFixtures.makeTemporaryDirectory(named: "Watcher-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteStore(databaseURL: root.appendingPathComponent("test.sqlite"))
        let service = ScreenshotRenameService(store: store)
        let watcher = ScreenshotWatcherService(
            store: store,
            renameService: service,
            settleDelayNanoseconds: 50_000_000
        )

        let collector = WatchEventCollector()
        await watcher.start(folders: [root], style: .titleCase, useAppleIntelligence: false) { event in
            await collector.append(event)
        }

        let shotURL = root.appendingPathComponent("Screenshot 2026-11-11 at 9.41.00 AM.png")
        try makeSamplePNG(text: "Flight Booking Confirmation", at: shotURL)
        await watcher.processFolderChange(at: root)

        let eventsAfterRename = await collector.snapshot()
        let renamedRecord: ScreenshotRenameRecord? = eventsAfterRename.compactMap {
            if case .renamed(let record) = $0 { return record }
            return nil
        }.first
        let record = try XCTUnwrap(renamedRecord)
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.currentURL.path))

        // Simulate user manually renaming the file in Finder.
        let manualURL = root.appendingPathComponent("Trip LIS · flight out.png")
        try FileManager.default.moveItem(at: record.currentURL, to: manualURL)
        await watcher.processFolderChange(at: root)
        await watcher.stop()

        let examples = try await store.loadStyleExamples(limit: 10)
        XCTAssertEqual(examples.count, 1)
        XCTAssertEqual(examples.first?.userChosenTitle, "Trip LIS · flight out")
        XCTAssertEqual(examples.first?.learnedPrefix, "Trip LIS")
        XCTAssertEqual(examples.first?.learnedSeparator, " · ")

        let history = try await store.loadScreenshotRenames(limit: 10)
        XCTAssertEqual(history.first?.status, .userOverridden)
    }

    // MARK: - SQLite v8 & Model Integration

    func testSQLiteStorePersistsAndClearsScreenshotTables() async throws {
        let store = try SQLiteStore.inMemory()
        let record = ScreenshotRenameRecord(
            originalURL: URL(fileURLWithPath: "/tmp/Screenshot 1.png"),
            currentURL: URL(fileURLWithPath: "/tmp/Lisbon Flight.png"),
            originalFileName: "Screenshot 1.png",
            newFileName: "Lisbon Flight.png",
            namingStyle: .titleCase,
            source: .tidyUp
        )
        let example = StyleLearningExample(
            suggestedTitle: "Lisbon Flight",
            userChosenTitle: "Trip LIS · flight out",
            learnedPrefix: "Trip LIS",
            learnedSeparator: " · "
        )
        try await store.saveScreenshotRename(record)
        try await store.saveStyleExample(example)

        let loadedRenames = try await store.loadScreenshotRenames(limit: 10)
        let loadedExamples = try await store.loadStyleExamples(limit: 10)
        XCTAssertEqual(loadedRenames.count, 1)
        XCTAssertEqual(loadedExamples.count, 1)

        try await store.deleteStyleExample(id: example.id)
        let afterDelete = try await store.loadStyleExamples(limit: 10)
        XCTAssertTrue(afterDelete.isEmpty)

        try await store.deleteAllData()
        let afterClear = try await store.loadScreenshotRenames(limit: 10)
        XCTAssertTrue(afterClear.isEmpty)
    }

    // MARK: - Helpers

    private func makeSamplePNG(text: String, at url: URL) throws {
        let size = NSSize(width: 480, height: 180)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 28),
            .foregroundColor: NSColor.black
        ]
        (text as NSString).draw(at: NSPoint(x: 24, y: 70), withAttributes: attrs)
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw XCTSkip("Could not render sample PNG")
        }
        try png.write(to: url)
    }
}

private actor WatchEventCollector {
    private var events: [ScreenshotWatchEvent] = []
    func append(_ event: ScreenshotWatchEvent) { events.append(event) }
    func snapshot() -> [ScreenshotWatchEvent] { events }
}
