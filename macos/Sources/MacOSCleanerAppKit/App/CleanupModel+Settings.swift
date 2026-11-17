import Foundation
import MacOSCleanerCore
import UserNotifications

// Settings persistence and weekly reminder scheduling for Photos & Media.
// Lives beside the model to keep CleanupModel.swift within its length budget.

extension CleanupModel {
    /// Saves the latest settings cleanly without queuing a backlog of intermediate
    /// writes during rapid slider or picker updates.
    func scheduleSettingsSave() {
        settingsSaveEpoch += 1
        let epoch = settingsSaveEpoch
        let previous = settingsSaveTask
        previous?.cancel()
        settingsSaveTask = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled, epoch == self.settingsSaveEpoch else { return }
            await self.saveSettings()
        }
    }

    /// Cancels the latest pending save and waits for the chain to finish.
    func cancelPendingSettingsSave() async {
        settingsSaveEpoch += 1
        let pending = settingsSaveTask
        settingsSaveTask = nil
        pending?.cancel()
        await pending?.value
    }

    func saveSettings() async {
        do {
            try await store.saveCleanupState(settings, key: "settings")
            if result?.settingsVersion != settings.analysisVersion {
                result?.isFresh = false
            } else {
                result?.settings = settings
            }
        } catch {
            self.error = error.localizedDescription
            return
        }
        await refreshReminder()
    }

    struct ReminderCategoryEntry {
        let tool: CleanupTool
        let count: Int
        let bytes: Int64
    }

    func reminderCategoryBreakdown(for result: AnalysisResult) -> [ReminderCategoryEntry] {
        let tools: [CleanupTool] = [
            .duplicates, .similar, .blurry, .screenshots, .screenRecordings, .large, .livePhotos
        ]
        return tools.compactMap { tool in
            let matches = MediaAnalysisService.candidates(tool, in: result)
            guard !matches.isEmpty else { return nil }
            let bytes: Int64 = tool == .livePhotos
                ? matches.reduce(0) { $0 + livePhotoRecoverableBytes(for: $1) }
                : matches.reduce(0) { $0 + $1.bytes }
            return ReminderCategoryEntry(tool: tool, count: matches.count, bytes: bytes)
        }
    }

    func multiCategoryReminderSummary(for result: AnalysisResult) -> String {
        let breakdown = reminderCategoryBreakdown(for: result)
        let dateText = result.completedAt.formatted(date: .abbreviated, time: .omitted)
        guard !breakdown.isEmpty else {
            return String(localized: "Last scan \(dateText): No cleanup items waiting.")
        }
        let summaryParts = breakdown.prefix(4).map { entry in
            entry.count == 1
                ? String(localized: "\(entry.tool.title): 1 item")
                : String(localized: "\(entry.tool.title): \(entry.count) items")
        }
        let uniqueBytes = Set(
            breakdown.flatMap { entry in
                MediaAnalysisService.candidates(entry.tool, in: result)
            }
        ).reduce(Int64(0)) { $0 + $1.bytes }
        let partsText = summaryParts.joined(separator: " · ")
        return String(
            localized: "Last scan \(dateText): \(partsText) (\(uniqueBytes.formattedByteCount) total to review).")
    }

    // Internal, not private: Clear All Data refreshes it in CleanupModel+Clear.swift.
    func updateReminder() async throws {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["cleanup-weekly"])
        guard settings.reminderEnabled, let result else { return }
        guard try await center.requestAuthorization(options: [.alert, .sound]) else {
            throw CleanupError.message(String(localized: "Notifications are disabled in System Settings."))
        }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Weekly cleanup")
        content.body = multiCategoryReminderSummary(for: result)
        content.userInfo = ["route": "cleanup"]
        let trigger = UNCalendarNotificationTrigger(
            dateMatching: DateComponents(
                hour: 9, minute: 0,
                weekday: settings.reminderWeekday),
            repeats: true)
        try await center.add(
            UNNotificationRequest(identifier: "cleanup-weekly", content: content, trigger: trigger))
    }
}
