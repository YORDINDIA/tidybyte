import AppKit
import Foundation
import Quartz

/// Shared macOS Quick Look panel coordinator across Files, Space Explorer,
/// Why Panel, Duplicates, and Action Stack. Preserves key window focus so
/// Space toggles preview cleanly and arrow keys keep navigating lists.
@MainActor
final class QuickLookCoordinator: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookCoordinator()

    private var items: [URL] = []

    override private init() {
        super.init()
    }

    func preview(_ url: URL) {
        preview([url])
    }

    func preview(_ urls: [URL]) {
        let resolved = normalizedExistingURLs(from: urls)
        guard !resolved.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        let previousKeyWindow = NSApp.keyWindow
        items = resolved
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        if !panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
            previousKeyWindow?.makeKey()
        } else {
            panel.orderFront(nil)
        }
    }

    func togglePreview(_ urls: [URL]) {
        let resolved = normalizedExistingURLs(from: urls)
        guard !resolved.isEmpty else { return }
        if QLPreviewPanel.sharedPreviewPanelExists(),
           let panel = QLPreviewPanel.shared(),
           panel.isVisible,
           items == resolved {
            panel.orderOut(nil)
            return
        }
        preview(resolved)
    }

    func updateSelectionIfVisible(_ urls: [URL]) {
        guard QLPreviewPanel.sharedPreviewPanelExists(),
              let panel = QLPreviewPanel.shared(),
              panel.isVisible else { return }
        let resolved = normalizedExistingURLs(from: urls)
        guard !resolved.isEmpty else { return }
        items = resolved
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
    }

    func closeIfVisible() {
        guard QLPreviewPanel.sharedPreviewPanelExists(),
              let panel = QLPreviewPanel.shared(),
              panel.isVisible else { return }
        panel.orderOut(nil)
    }

    private func normalizedExistingURLs(from urls: [URL]) -> [URL] {
        var seen = Set<URL>()
        var result: [URL] = []
        for url in urls {
            let standardized = url.standardizedFileURL
            guard FileManager.default.fileExists(atPath: standardized.path),
                  seen.insert(standardized).inserted else { continue }
            result.append(standardized)
        }
        return result
    }

    // MARK: - QLPreviewPanelDataSource

    // QLPreviewPanelDataSource exposes Objective-C implicitly unwrapped signatures.
    // swiftlint:disable implicitly_unwrapped_optional
    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { items.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        let url: URL? = MainActor.assumeIsolated {
            guard items.indices.contains(index) else { return nil }
            return items[index]
        }
        return url as NSURL?
    }
    // swiftlint:enable implicitly_unwrapped_optional
}
