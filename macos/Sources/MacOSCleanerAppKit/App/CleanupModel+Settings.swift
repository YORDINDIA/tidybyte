import Foundation
import MacOSCleanerCore

// Settings persistence for Photos & Media. Lives beside the model to keep CleanupModel.swift within its length budget.

extension CleanupModel {
    func saveSettings() async {
        do {
            try await store.saveCleanupState(settings, key: "settings")
            if result?.settingsVersion != settings.analysisVersion {
                result?.isFresh = false
            } else {
                result?.settings = settings
            }
            try await updateReminder()
        } catch { self.error = error.localizedDescription }
    }
}
