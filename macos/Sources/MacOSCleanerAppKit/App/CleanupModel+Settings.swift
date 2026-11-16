import Foundation
import MacOSCleanerCore

// Settings persistence for Photos & Media. Lives beside the model to keep CleanupModel.swift within its length budget.

extension CleanupModel {
    /// Saves after any earlier save finishes, so writes keep their order.
    func scheduleSettingsSave() {
        let previous = settingsSaveTask
        settingsSaveTask = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled else { return }
            await self?.saveSettings()
        }
    }

    /// Cancels the latest pending save and waits for the chain to finish.
    func cancelPendingSettingsSave() async {
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
}
