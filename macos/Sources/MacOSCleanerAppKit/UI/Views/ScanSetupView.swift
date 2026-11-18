import MacOSCleanerCore
import SwiftUI
import UniformTypeIdentifiers

struct ScanSetupView: View {
    @Bindable var model: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    @State private var draftMode: ScanMode
    @State private var draftFolders: [URL]
    @State private var draftPosture: CleanupPosture
    @State private var draftIncludeAI: Bool
    @State private var showsFolderPicker = false
    @State private var folderError: String?
    @State private var isDropTargeted = false

    init(model: AppViewModel) {
        self.model = model
        _draftMode = State(initialValue: model.selectedMode)
        _draftFolders = State(initialValue: model.selectedFolders)
        _draftPosture = State(initialValue: model.cleanupPosture)
        _draftIncludeAI = State(initialValue: model.includeAI)
    }

    var body: some View {
        let override = model.languageStore.activeOverride
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker(L10n.string("Scan", language: override), selection: $draftMode) {
                        ForEach(ScanMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    if draftMode == .selectedFolders {
                        folders(override: override)
                    }
                } header: {
                    Text(L10n.string("Choose what to scan", language: override))
                } footer: {
                    Text(L10n.string(
                        "Scanning does not change your files. Review proposed actions before applying them.",
                        language: override
                    ))
                }
                Section(L10n.string("Options", language: override)) {
                    Picker(L10n.string("Cleanup posture", language: override), selection: $draftPosture) {
                        Text(L10n.string("Conservative", language: override)).tag(CleanupPosture.conservative)
                        Text(L10n.string("Balanced", language: override)).tag(CleanupPosture.balanced)
                        Text(L10n.string("Aggressive", language: override)).tag(CleanupPosture.aggressive)
                    }
                    Toggle(L10n.string("Use configured AI provider", language: override), isOn: $draftIncludeAI)
                        .disabled(model.providerSettings.privacyMode == .localOnly)
                    Text(
                        draftIncludeAI
                            ? L10n.string(
                                "The AI & Privacy settings control which data is sent to your provider.",
                                language: override)
                            : L10n.string(
                                "This scan uses local rules. File data is not sent to an AI provider.",
                                language: override)
                    )
                    .font(.caption).foregroundStyle(.secondary)
                    Button(L10n.string("AI & Privacy Settings…", language: override)) {
                        model.settingsSection = .privacy
                        openSettings()
                    }
                }
            }
            .formStyle(.grouped)
            .dropDestination(for: URL.self) { urls, _ in
                handleDroppedFolders(urls, override: override)
            } isTargeted: { targeted in
                isDropTargeted = targeted
            }
            if let folderError {
                Label(folderError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(SemanticScale.error)
                    .padding(Spacing.cardPadding)
            }
            Divider()
            HStack {
                Button(L10n.string("Cancel", language: override)) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(L10n.string("Start Scan", language: override)) {
                    commitAndScan()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canScan)
            }
            .padding(Spacing.cardPadding)
        }
        .frame(minWidth: 520, minHeight: 460)
        .presentationSizing(.form)
        .fileImporter(
            isPresented: $showsFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                addDraftFolders(urls)
                folderError = nil
            case .failure(let error):
                folderError = error.localizedDescription
            }
        }
    }

    private func folders(override: AppLanguage?) -> some View {
        VStack(alignment: .leading, spacing: Spacing.elementNormal) {
            ForEach(draftFolders, id: \.path) { url in
                folderRow(for: url, override: override)
            }
            dropTargetArea(override: override)
            folderButtons(override: override)
        }
    }

    private func folderRow(for url: URL, override: AppLanguage?) -> some View {
        HStack {
            Label(url.lastPathComponent, systemImage: "folder")
                .help(url.path)
            Spacer()
            Text(url.deletingLastPathComponent().path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Button {
                let normalized = url.standardizedFileURL
                draftFolders.removeAll { $0.standardizedFileURL == normalized }
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(L10n.format("Remove %@", language: override, url.lastPathComponent))
        }
    }

    private func dropTargetArea(override: AppLanguage?) -> some View {
        VStack(spacing: Spacing.elementTight) {
            Label(
                L10n.string("Drop folders here to add them", language: override),
                systemImage: "folder.badge.plus"
            )
            .font(.caption)
            .foregroundStyle(isDropTargeted ? Primary.primary : .secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.elementNormal)
        .background(
            isDropTargeted ? Primary.selection : Color.primary.opacity(0.03),
            in: RoundedRectangle(cornerRadius: Radius.cardCompact, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.cardCompact, style: .continuous)
                .strokeBorder(
                    isDropTargeted ? Color.accentColor : SemanticScale.subtleBorder,
                    style: StrokeStyle(lineWidth: isDropTargeted ? 2 : 1, dash: [5, 4])
                )
        )
    }

    private func folderButtons(override: AppLanguage?) -> some View {
        HStack {
            Button(L10n.string("Choose Folders…", language: override)) { showsFolderPicker = true }
            Button(L10n.string("Add Downloads", language: override)) {
                if let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
                    addDraftFolders([downloads])
                    folderError = nil
                } else {
                    folderError = L10n.string("Could not resolve Downloads folder.", language: override)
                }
            }
            if !draftFolders.isEmpty {
                Spacer()
                Button(L10n.string("Clear", language: override)) { draftFolders.removeAll() }
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var canScan: Bool {
        !model.isScanning && !model.isExecuting && !model.isPlanning
            && (draftMode != .selectedFolders || !draftFolders.isEmpty)
    }

    private func addDraftFolders(_ urls: [URL]) {
        for url in urls {
            let normalized = url.standardizedFileURL
            guard FileManager.default.fileExists(atPath: normalized.path),
                  !draftFolders.contains(where: { $0.standardizedFileURL == normalized }) else { continue }
            draftFolders.append(normalized)
        }
    }

    private func handleDroppedFolders(_ urls: [URL], override: AppLanguage?) -> Bool {
        let validFolders = urls.filter { AppViewModel.isLocalFolder($0) }
        guard !validFolders.isEmpty else {
            folderError = L10n.string("Only local folders can be added to a scan.", language: override)
            return false
        }
        addDraftFolders(validFolders)
        draftMode = .selectedFolders
        folderError = nil
        return true
    }

    private func commitAndScan() {
        model.selectedMode = draftMode
        model.selectedFolders = draftFolders
        model.cleanupPosture = draftPosture
        model.includeAI = draftIncludeAI
        model.saveSettings()
        model.destination = .overview
        model.runScan()
        dismiss()
    }
}
