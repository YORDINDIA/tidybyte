import AppKit
import MacOSCleanerCore
import ServiceManagement
import SwiftUI

enum SettingsSection: Hashable { case general, monitoring, scanning, media, privacy, data }

struct SettingsView: View {
    @Bindable var model: AppViewModel
    @State private var showClearConfirmation = false
    @State private var launchAtLogin = false
    @State private var apiBaseURLText = ""
    @State private var settingsError: String?
    @State private var cliStatusMessage: String?
    @State private var cliInstallError: String?
    @State private var cliInstalled = false
    @State private var copiedCLICommand = false
    @FocusState private var apiBaseURLFocused: Bool
    @AppStorage(AppDelegate.menuBarExtraKey) private var showsMenuBarExtra = false
    @AppStorage(AppDelegate.removalWatchKey) private var watchesAppRemovals = true

    var body: some View {
        let override = model.languageStore.activeOverride
        TabView(selection: $model.settingsSection) {
            Tab(L10n.string("General", language: override), systemImage: "gearshape", value: .general) {
                general(override: override)
            }
            if DistributionChannel.supportsAdvanced {
                Tab(L10n.string("Monitoring", language: override), systemImage: "waveform.path.ecg", value: .monitoring) {
                    MonitoringSettingsView()
                }
                Tab(L10n.string("Scanning", language: override), systemImage: "magnifyingglass", value: .scanning) {
                    scanning(override: override)
                }
            }
            Tab(L10n.string("Photos & Media", language: override), systemImage: "photo.on.rectangle", value: .media) {
                CleanupSettingsView(model: model.cleanup)
            }
            if DistributionChannel.supportsAdvanced {
                Tab(L10n.string("AI & Privacy", language: override), systemImage: "lock.shield", value: .privacy) {
                    provider(override: override)
                }
                Tab(L10n.string("Data", language: override), systemImage: "externaldrive", value: .data) {
                    data(override: override)
                }
            }
        }
        .frame(minWidth: 540, idealWidth: 600, minHeight: 460, idealHeight: 560)
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            apiBaseURLText = model.providerSettings.apiBaseURL.absoluteString
            #if !APP_STORE
            refreshCLIStatus()
            #endif
        }
        .alert(L10n.string("Clear all data?", language: override), isPresented: $showClearConfirmation) {
            Button(L10n.string("Cancel", language: override), role: .cancel) {}
            Button(L10n.string("Clear All Data", language: override), role: .destructive) {
                Task { await model.clearAllData() }
            }
        } message: {
            Text(L10n.string(
                "This deletes scan data, restore records, rules, and preferences. It cannot be undone.",
                language: override
            ))
        }
    }
}

extension SettingsView {
    private func general(override: AppLanguage?) -> some View {
        Form {
            languageSection(override: override)
            Section(L10n.string("Startup", language: override)) {
                Toggle(L10n.string("Launch at login", language: override), isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled, override: override) }
                if let settingsError { Text(settingsError).foregroundStyle(SemanticScale.error) }
            }
            Section {
                Toggle(L10n.string("Show in menu bar", language: override), isOn: $showsMenuBarExtra)
            } footer: {
                Text(L10n.string(
                    "Shows free space and quick actions. Tidybyte keeps running when its window closes.",
                    language: override
                ))
            }
            if DistributionChannel.supportsAdvanced {
                Section {
                    Toggle(
                        L10n.string("Offer to clean up after I delete an app", language: override),
                        isOn: $watchesAppRemovals
                    )
                    .onChange(of: watchesAppRemovals) { _, enabled in model.setRemovalWatching(enabled) }
                } footer: {
                    Text(L10n.string(
                        "Tidybyte notices apps removed from Applications while it runs.",
                        language: override
                    ))
                }
                #if !APP_STORE
                cliToolSection(override: override)
                #endif
            }
            aboutSection(override: override)
        }
        .formStyle(.grouped)
    }

    private func languageSection(override: AppLanguage?) -> some View {
        let store = model.languageStore
        let selection = Binding(
            get: { store.selectedLanguage },
            set: { store.setLanguage($0) }
        )
        return Section {
            Picker(L10n.string("Language", language: override), selection: selection) {
                Text(L10n.string("Automatic", language: override)).tag(AppLanguage.system)
                Divider()
                ForEach(AppLanguage.concreteLanguages) { language in
                    Text(languageLabel(language)).tag(language)
                }
            }
            if model.languageStore.systemLanguageIsUnsupported {
                Text(L10n.string(
                    "Your macOS language is not translated yet, so Tidybyte is using English. Pick a language above to override.",
                    language: override
                ))
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        } header: {
            Text(L10n.string("Language", language: override))
        } footer: {
            Text(L10n.string(
                "Automatic follows macOS. Tidybyte updates immediately; system dialogs follow on next launch.",
                language: override
            ))
        }
    }

    private func languageLabel(_ language: AppLanguage) -> String {
        language.englishName == language.endonym
            ? language.endonym
            : "\(language.endonym) — \(language.englishName)"
    }

    #if !APP_STORE
    private func cliToolSection(override: AppLanguage?) -> some View {
        let executablePath = Bundle.main.executableURL?.path ?? "/Applications/Tidybyte.app/Contents/MacOS/Tidybyte"
        let installCommand = "ln -sf \"\(executablePath)\" /usr/local/bin/tidybyte"
        return Section {
            LabeledContent(L10n.string("Status", language: override)) {
                Text(cliInstalled
                    ? L10n.string("Installed", language: override)
                    : L10n.string("Not installed", language: override))
                .foregroundStyle(cliInstalled ? SemanticScale.success : .secondary)
            }
            HStack {
                Button(L10n.string("Install CLI (tidybyte)…", language: override)) {
                    installCLISymlink(targetExecutable: executablePath, override: override)
                }
                Spacer()
                Button(copiedCLICommand
                    ? L10n.string("Copied", language: override)
                    : L10n.string("Copy Command", language: override)) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(installCommand, forType: .string)
                    copiedCLICommand = true
                }
            }
            Text(verbatim: installCommand)
                .appFont(.filePath)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let cliStatusMessage {
                Text(cliStatusMessage)
                    .font(.caption)
                    .foregroundStyle(SemanticScale.success)
            }
            if let cliInstallError {
                Text(cliInstallError)
                    .font(.caption)
                    .foregroundStyle(SemanticScale.error)
            }
        } header: {
            Text(L10n.string("Command Line Tool", language: override))
        } footer: {
            Text(L10n.string(
                "Installs a symlink at ~/.local/bin/tidybyte or lets you link /usr/local/bin/tidybyte manually.",
                language: override
            ))
        }
    }

    private func refreshCLIStatus() {
        let fm = FileManager.default
        let userBin = fm.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/tidybyte").path
        let systemBin = "/usr/local/bin/tidybyte"
        cliInstalled = fm.fileExists(atPath: userBin) || fm.fileExists(atPath: systemBin)
    }

    private func installCLISymlink(targetExecutable: String, override: AppLanguage?) {
        cliInstallError = nil
        cliStatusMessage = nil
        let fm = FileManager.default
        let dir = fm.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin", isDirectory: true)
        let linkURL = dir.appendingPathComponent("tidybyte", isDirectory: false)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            if fm.fileExists(atPath: linkURL.path) || (try? fm.attributesOfItem(atPath: linkURL.path)) != nil {
                try fm.removeItem(at: linkURL)
            }
            try fm.createSymbolicLink(atPath: linkURL.path, withDestinationPath: targetExecutable)
            cliInstalled = true
            cliStatusMessage = L10n.format("Installed symlink at %@.", language: override, linkURL.path)
        } catch {
            cliInstallError = error.localizedDescription
        }
    }
    #endif

    private func aboutSection(override: AppLanguage?) -> some View {
        let devFallback = L10n.string("Development", language: override)
        return Section {
            LabeledContent(
                L10n.string("Version", language: override),
                value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? devFallback
            )
            LabeledContent(
                L10n.string("Build", language: override),
                value: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? devFallback
            )
        } header: {
            Text(L10n.string("About", language: override))
        } footer: {
            VStack(alignment: .leading, spacing: Spacing.elementTight) {
                Text(L10n.string("All processing happens on this device.", language: override))
                if DistributionChannel.supportsAdvanced {
                    Text(L10n.string(
                        "Optional AI features are off by default and send data only to the provider you configure.",
                        language: override
                    ))
                }
            }
        }
    }

    private func scanning(override: AppLanguage?) -> some View {
        Form {
            scanningDefaultsSection(override: override)
            maintenanceSection(override: override)
            preferencesSection(override: override)
        }
        .formStyle(.grouped)
        .disabled(model.isScanning || model.isExecuting)
    }

    private func scanningDefaultsSection(override: AppLanguage?) -> some View {
        Section(L10n.string("Defaults", language: override)) {
            Picker(L10n.string("Scan mode", language: override), selection: $model.selectedMode) {
                ForEach(ScanMode.allCases, id: \.self) { mode in Text(mode.displayName).tag(mode) }
            }.onChange(of: model.selectedMode) { model.saveSettings() }
            Picker(L10n.string("Cleanup posture", language: override), selection: $model.cleanupPosture) {
                Text(L10n.string("Conservative", language: override)).tag(CleanupPosture.conservative)
                Text(L10n.string("Balanced", language: override)).tag(CleanupPosture.balanced)
                Text(L10n.string("Aggressive", language: override)).tag(CleanupPosture.aggressive)
            }.onChange(of: model.cleanupPosture) { model.saveSettings() }
            Picker(L10n.string("Duplicate resolution", language: override), selection: $model.duplicateStrategy) {
                Text(L10n.string("Fold into APFS clone (nothing deleted)", language: override))
                    .tag(DuplicateStrategy.apfsClone)
                Text(L10n.string("Move duplicates to Trash", language: override))
                    .tag(DuplicateStrategy.moveToTrash)
            }.onChange(of: model.duplicateStrategy) { model.saveSettings() }
        }
    }

    private func maintenanceSection(override: AppLanguage?) -> some View {
        Section(L10n.string("Automatic maintenance", language: override)) {
            Toggle(isOn: $model.autoscanEnabled) {
                VStack(alignment: .leading, spacing: Spacing.elementTight) {
                    Text(L10n.string("Run daily when idle", language: override))
                    // swiftlint:disable:next line_length
                    Text(L10n.string("Waits for idle time and power (or ≥50% battery). Folds duplicate files only. Nothing is ever deleted unattended, and every fold can be undone.", language: override))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .onChange(of: model.autoscanEnabled) { model.saveSettings() }
            if !model.autoscanEnabled, !LaunchAgentInstaller.canInstall() {
                Text(L10n.string(
                    "Install the app in /Applications to enable automatic maintenance.",
                    language: override
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if let lastRun = model.lastAutoScanDate {
                LabeledContent(L10n.string("Last automatic run", language: override)) {
                    Text(lastRun.formatted(date: .abbreviated, time: .shortened))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func preferencesSection(override: AppLanguage?) -> some View {
        Section(L10n.string("Recommendation preferences", language: override)) {
            calibration(
                L10n.string("Review source code carefully", language: override),
                ruleType: .never,
                rule: L10n.string(
                    "Never suggest deleting source code files without manual review.",
                    language: override
                )
            )
            calibration(
                L10n.string("Find more old downloads", language: override),
                ruleType: .always,
                rule: L10n.string(
                    "Be more willing to suggest cleanup for old downloads and installers.",
                    language: override
                )
            )
            calibration(
                L10n.string("Protect design source files", language: override),
                ruleType: .never,
                rule: L10n.string(
                    "Never suggest deleting design source files (.psd, .sketch, .fig) without review.",
                    language: override
                )
            )
            calibration(
                L10n.string("Prefer archiving", language: override),
                ruleType: .preferArchive,
                rule: L10n.string(
                    "Prefer archiving files instead of moving to trash.",
                    language: override
                )
            )
            calibration(
                L10n.string("Review cloud files carefully", language: override),
                ruleType: .never,
                rule: L10n.string(
                    "Never suggest actions on cloud-synced files without explicit review.",
                    language: override
                )
            )
        }
    }

    private func provider(override: AppLanguage?) -> some View {
        Form {
            privacySection(override: override)
            providerFieldsSection(override: override)
            modelOptionsSection(override: override)
        }
        .formStyle(.grouped)
        .disabled(model.isScanning || model.isExecuting)
    }

    private func privacySection(override: AppLanguage?) -> some View {
        Section(L10n.string("Privacy", language: override)) {
            Picker(L10n.string("Allowed data", language: override), selection: $model.providerSettings.privacyMode) {
                Text(L10n.string("Local Only", language: override)).tag(PrivacyMode.localOnly)
                Text(L10n.string("Metadata Only AI", language: override)).tag(PrivacyMode.metadataOnlyAI)
                Text(L10n.string("Snippets AI", language: override)).tag(PrivacyMode.snippetsAI)
                Text(L10n.string("Vision AI", language: override)).tag(PrivacyMode.visionAI)
                Text(L10n.string("Full Document AI", language: override)).tag(PrivacyMode.fullDocumentAI)
            }.onChange(of: model.providerSettings.privacyMode) { model.saveSettings() }
            Toggle(L10n.string("Enable AI during scans", language: override), isOn: $model.includeAI)
                .disabled(model.providerSettings.privacyMode == .localOnly)
                .onChange(of: model.includeAI) { model.saveSettings() }
            Text(L10n.string(
                "Local Only sends no data. Other modes send allowed data to your provider.",
                language: override
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func providerFieldsSection(override: AppLanguage?) -> some View {
        Section(L10n.string("Provider", language: override)) {
            TextField(L10n.string("Provider name", language: override), text: $model.providerSettings.providerName)
                .onChange(of: model.providerSettings.providerName) { model.saveSettings() }
            TextField(L10n.string("API base URL", language: override), text: $apiBaseURLText)
                .focused($apiBaseURLFocused).onSubmit { commitAPIBaseURL() }
                .onChange(of: apiBaseURLFocused) { if !apiBaseURLFocused { commitAPIBaseURL() } }
            if let message = apiBaseURLValidationMessage(override: override) {
                Text(message).foregroundStyle(SemanticScale.error)
            }
            TextField(L10n.string("Text model", language: override), text: $model.providerSettings.textModel)
                .onChange(of: model.providerSettings.textModel) { model.saveSettings() }
            SecureField(L10n.string("API key", language: override), text: $model.apiKeyInput)
            Button(L10n.string("Save API Key", language: override)) {
                Task {
                    await model.saveAPIKey()
                    settingsError = model.errorMessage
                }
            }.disabled(model.apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if let settingsError { Text(settingsError).foregroundStyle(SemanticScale.error) }
        }
    }

    private func modelOptionsSection(override: AppLanguage?) -> some View {
        Section(L10n.string("Model options", language: override)) {
            Stepper(
                L10n.format("Maximum tokens: %lld", language: override, model.providerSettings.maxTokens),
                value: $model.providerSettings.maxTokens, in: 200...8000, step: 100
            )
            .onChange(of: model.providerSettings.maxTokens) { model.saveSettings() }
            LabeledContent(L10n.string("Temperature", language: override)) {
                HStack(spacing: Spacing.elementNormal) {
                    Slider(value: $model.providerSettings.temperature, in: 0...1)
                        .onChange(of: model.providerSettings.temperature) { model.saveSettings() }
                    Text(model.providerSettings.temperature, format: .number.precision(.fractionLength(2)))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func data(override: AppLanguage?) -> some View {
        Form {
            Section(L10n.string("Local storage", language: override)) {
                Button(L10n.string("Export Database…", language: override)) {
                    Task { await model.exportDatabase() }
                }
                Button(L10n.string("Clear All Data…", language: override), role: .destructive) {
                    showClearConfirmation = true
                }
                Text(L10n.string(
                    "Clearing local data removes the records needed to restore previous changes.",
                    language: override
                ))
                .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).disabled(model.isScanning || model.isExecuting)
    }

    private func calibration(_ title: String, ruleType: MemoryRuleType, rule: String) -> some View {
        Button(title) { Task { await model.applyCalibrationPreset(rule, ruleType: ruleType) } }
    }

    private func setLaunchAtLogin(_ enabled: Bool, override: AppLanguage?) {
        guard enabled != (SMAppService.mainApp.status == .enabled) else { return }
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            settingsError = nil
        } catch {
            settingsError = L10n.format(
                "Could not update launch at login: %@",
                language: override,
                error.localizedDescription
            )
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func commitAPIBaseURL() {
        guard apiBaseURLValidationMessage(override: model.languageStore.activeOverride) == nil,
              let url = URL(string: apiBaseURLText.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return }
        model.providerSettings.apiBaseURL = url
        model.saveSettings()
    }

    private func apiBaseURLValidationMessage(override: AppLanguage?) -> String? {
        let text = apiBaseURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), url.scheme?.lowercased() == "https",
              url.host?.isEmpty == false
        else {
            return L10n.string(
                "Enter an https provider URL such as https://api.example.com/v1.",
                language: override
            )
        }
        return nil
    }
}
