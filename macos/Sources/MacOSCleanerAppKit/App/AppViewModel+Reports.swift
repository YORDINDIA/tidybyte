import Foundation
import AppKit
import MacOSCleanerCore

// Report and database export actions, kept out of AppViewModel.swift to stay within its length budget.

@MainActor
extension AppViewModel {
    func openLatestReport() {
        guard let reportURL = generatedReportURL else {
            errorMessage = String(localized: "No report generated yet.")
            return
        }
        NSWorkspace.shared.open(reportURL)
        statusMessage = String(localized: "Opened last report.")
    }

    func generateReport(to directory: URL? = nil) async {
        guard let outcome, let currentPlan = plan else {
            statusMessage = String(localized: "Run a scan first to generate a report.")
            return
        }
        guard !isScanning, !isExecuting else {
            errorMessage = String(localized: "Wait until the current scan or cleanup finishes.")
            return
        }
        do {
            // The destination is injectable so callers (and tests) can direct the PDF
            // anywhere; the default keeps the historical ~/Tidybyte Reports location.
            let reportDirectory = directory ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(AppIdentity.reportsFolderName, isDirectory: true)
            generatedReportURL = try await reportGenerator.generateCleanupReport(
                outcome: outcome, plan: currentPlan, destination: reportDirectory)
            statusMessage = String(localized: "Local PDF report generated.")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func exportDatabase() async {
        guard !isScanning, !isExecuting else {
            errorMessage = String(localized: "Cannot export while a scan or execution is in progress.")
            return
        }
        do {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "MacOSCleaner-\(Date().formatted(date: .numeric, time: .omitted)).sqlite"
            panel.allowedContentTypes = [.data]
            guard let window = NSApp.mainWindow ?? NSApp.windows.first(where: \.isVisible) else {
                errorMessage = String(localized: "The database could not be exported: no window is available to attach the save panel to.")
                return
            }
            let response = await panel.beginSheetModal(for: window)
            guard response == .OK, let destination = panel.url else { return }
            guard !isScanning, !isExecuting else {
                errorMessage = String(localized: "Cannot export while a scan or execution is in progress.")
                return
            }
            // exportCopy checkpoints the WAL and runs a sqlite3 backup, so the exported
            // file contains committed WAL content that a plain FileManager copy would miss.
            try await store.exportCopy(to: destination)
            statusMessage = String(localized: "Database exported successfully.")
        } catch {
            errorMessage = String(localized: "Failed to export database: \(error.localizedDescription)")
        }
    }
}
