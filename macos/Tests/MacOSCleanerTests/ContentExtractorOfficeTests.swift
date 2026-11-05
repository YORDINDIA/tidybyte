import Foundation
import XCTest
@testable import MacOSCleanerCore

/// SP-13: Office content extraction. Production decodes docx through
/// `/usr/bin/textutil` (`ContentExtractor.readOfficePreview`). These tests
/// exercise that path on a REAL docx (built by the same converter) and pin
/// the honest fallback for Office files textutil cannot decode (pptx/xlsx):
/// the summary keeps its office/extension labels and file metadata but no
/// extracted text.
final class ContentExtractorOfficeTests: XCTestCase {
    private var root = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        root = try TestFixtures.makeTemporaryDirectory(named: "OfficeExtract-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Converts `source` to a real Office file with the same converter
    /// production uses, so the fixture exercises the actual decode path.
    private func makeOfficeFixture(at destination: URL, from source: URL, format: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        process.arguments = ["-convert", format, source.path, "-output", destination.path]
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(domain: "OfficeFixture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "textutil -convert \(format) failed: \(message)"])
        }
    }

    func testOfficeDocxPreviewExtractsText() async throws {
        let probe = "Tidybyte office extraction probe: quarterly report"
        let source = root.appendingPathComponent("probe-source.txt", isDirectory: false)
        try Data(probe.utf8).write(to: source)
        let docx = root.appendingPathComponent("report.docx", isDirectory: false)
        try makeOfficeFixture(at: docx, from: source, format: "docx")

        let crawler = FileCrawler()
        let crawlOutcome26 = await crawler.crawl(rootURLs: [root], sessionID: "scan")
        let (records, _) = (crawlOutcome26.files, crawlOutcome26.errors)
        let docxRecord = try XCTUnwrap(records.first { $0.fileName == "report.docx" })
        let extractor = ContentExtractor()
        let summaries = await extractor.summarize(files: records, privacyMode: .snippetsAI)
        let summary = try XCTUnwrap(
            summaries.first { $0.fileID == docxRecord.id },
            "The docx should produce a content summary")
        XCTAssertTrue(summary.textPreview?.contains(probe) == true,
                      "docx text should be extracted into the summary preview, got: \(summary.textPreview ?? "nil")")
    }

    func testOfficeFileTextutilCannotDecodeStillYieldsLabeledSummary() async throws {
        // textutil has no pptx/xlsx reader (its formats are txt, rtf, rtfd,
        // html, doc, docx, odt, wordml, webarchive), so a structurally valid
        // pptx — a zip of XML parts, like PowerPoint writes — fails to decode.
        // The extractor must not lose the file: the summary keeps its
        // office/extension labels and metadata line, with no extracted text.
        let staging = root.appendingPathComponent("deck-parts/ppt", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("<presentation/>".utf8).write(to: staging.appendingPathComponent("presentation.xml", isDirectory: false))
        let pptx = root.appendingPathComponent("deck.pptx", isDirectory: false)
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.arguments = ["-q", "-r", pptx.path, "ppt"]
        zip.currentDirectoryURL = root.appendingPathComponent("deck-parts", isDirectory: true)
        try zip.run()
        zip.waitUntilExit()
        guard zip.terminationStatus == 0, FileManager.default.fileExists(atPath: pptx.path) else {
            throw XCTSkip("/usr/bin/zip unavailable; cannot build a pptx-shaped fixture")
        }

        let crawler = FileCrawler()
        let crawlOutcome27 = await crawler.crawl(rootURLs: [root], sessionID: "scan")
        let (records, _) = (crawlOutcome27.files, crawlOutcome27.errors)
        let pptxRecord = try XCTUnwrap(records.first { $0.fileName == "deck.pptx" })
        let extractor = ContentExtractor()
        let summaries = await extractor.summarize(files: records, privacyMode: .snippetsAI)
        let summary = try XCTUnwrap(
            summaries.first { $0.fileID == pptxRecord.id },
            "A pptx textutil cannot decode must still produce a summary")
        let preview = try XCTUnwrap(summary.textPreview, "The metadata-only summary must not be empty")
        XCTAssertTrue(preview.contains("office"), "Summary should keep the office label, got: \(preview)")
        XCTAssertTrue(preview.contains("pptx"), "Summary should keep the extension label, got: \(preview)")
        XCTAssertTrue(preview.contains("size:"), "Summary should keep the size metadata, got: \(preview)")
    }
}
