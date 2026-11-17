import MacOSCleanerCore
import SwiftUI

struct ApplicationsView: View {
    @Bindable var model: AppViewModel

    private var applications: [InstalledApplication] {
        let query = model.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.installedApplications.filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
                || ($0.bundleIdentifier?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    var body: some View {
        let override = model.languageStore.activeOverride
        List(selection: $model.selectedApplicationID) {
            ForEach(applications) { app in
                HStack(spacing: Spacing.elementNormal) {
                    AppIconView(url: app.bundleURL, size: 32)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(app.name).font(.headline)
                        Text(app.bundleURL.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    if model.stagedUninstallAppIDs.contains(app.id) {
                        Label(L10n.string("Staged", language: override), systemImage: "checkmark.circle")
                            .font(.caption)
                    }
                    Text(app.bundleSizeBytes.formattedByteCount).monospacedDigit()
                }
                .padding(.vertical, Spacing.elementTight)
                .tag(app.id)
            }
        }
        .listStyle(.inset)
        .skeletonLoading(model.isLoadingApplications)
        .overlay {
            if model.isLoadingApplications {
                ProgressView(L10n.string("Loading applications…", language: override))
            } else if applications.isEmpty {
                if model.searchText.isEmpty {
                    ContentUnavailableView(
                        L10n.string("No applications found", language: override),
                        systemImage: "app",
                        description: Text(L10n.string(
                            "Tidybyte checks /Applications and ~/Applications.",
                            language: override
                        ))
                    )
                } else {
                    ContentUnavailableView.search(text: model.searchText)
                }
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first {
                Button(L10n.string("Show Details", language: override)) {
                    model.selectedApplicationID = id
                    model.showsInspector = true
                }
            }
        } primaryAction: { ids in
            model.selectedApplicationID = ids.first
            model.showsInspector = true
        }
        .task { if model.installedApplications.isEmpty { await model.loadInstalledApplications() } }
    }
}

struct ApplicationDetailsView: View {
    @Bindable var model: AppViewModel
    @State private var showsStagingConfirmation = false

    private var app: InstalledApplication? {
        model.installedApplications.first { $0.id == model.selectedApplicationID }
    }

    var body: some View {
        let override = model.languageStore.activeOverride
        Group {
            if let app {
                Form {
                    Section {
                        Label {
                            Text(app.name).font(.headline)
                        } icon: {
                            AppIconView(url: app.bundleURL, size: 20)
                        }
                        Text(app.bundleURL.path)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        LabeledContent(
                            L10n.string("Bundle size", language: override),
                            value: app.bundleSizeBytes.formattedByteCount
                        )
                        if let identifier = app.bundleIdentifier {
                            LabeledContent(L10n.string("Identifier", language: override), value: identifier)
                        }
                        Button(L10n.string("Show in Finder", language: override)) {
                            NSWorkspace.shared.activateFileViewerSelecting([app.bundleURL])
                        }
                    }
                    footprint(app, override: override)
                    Section(L10n.string("Uninstall", language: override)) {
                        Button(L10n.string("Uninstall…", language: override)) { showsStagingConfirmation = true }
                            .disabled(
                                model.footprintItemsByAppID[app.id] == nil
                                    || model.stagedUninstallAppIDs.contains(app.id)
                            )
                        Text(L10n.string(
                            "Adds the app and its sure matches to Leftovers. Nothing changes until you approve and confirm.",
                            language: override
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .disabled(model.isScanning || model.isExecuting || model.isPlanning)
                }
                .formStyle(.grouped)
                .confirmationDialog(
                    L10n.format("Stage uninstall for %@?", language: override, app.name),
                    isPresented: $showsStagingConfirmation,
                    titleVisibility: .visible
                ) {
                    Button(L10n.string("Add to Leftovers", language: override)) {
                        Task {
                            await model.stageUninstall(for: app)
                            if model.stagedUninstallAppIDs.contains(app.id), let id = model.selectedActionID {
                                model.showReviewAction(id: id)
                            }
                        }
                    }
                    Button(L10n.string("Cancel", language: override), role: .cancel) {}
                } message: {
                    Text(L10n.string(
                        "Add the app and its data to Review. Files change only after approval and confirmation.",
                        language: override
                    ))
                }
            } else {
                ContentUnavailableView(
                    L10n.string("No application selected", language: override),
                    systemImage: "app"
                )
            }
        }
        .task(id: model.selectedApplicationID) { if let app { await model.loadFootprint(for: app) } }
    }

    private func footprint(_ app: InstalledApplication, override: AppLanguage?) -> some View {
        Section(L10n.string("Associated data", language: override)) {
            if let items = model.footprintItemsByAppID[app.id] {
                if items.isEmpty {
                    Text(L10n.string("No associated data found.", language: override))
                        .foregroundStyle(.secondary)
                }
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        LabeledContent(item.location.displayName, value: item.sizeBytes.formattedByteCount)
                        Text(item.url.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Label {
                            Text("\(item.confidence.displayName) · \(item.reason)")
                        } icon: {
                            Image(systemName: item.confidence == .certain ? "checkmark.seal" : "questionmark.circle")
                                .foregroundStyle(
                                    item.confidence == .certain ? SemanticScale.success : SemanticScale.warning
                                )
                        }
                        .font(.caption)
                        if item.location.isSystemWide {
                            Label(
                                L10n.string("Shared system location", language: override),
                                systemImage: "exclamationmark.shield"
                            )
                            .font(.caption)
                            .foregroundStyle(SemanticScale.warning)
                        }
                    }
                }
            } else {
                ProgressView(L10n.string("Measuring associated data…", language: override))
            }
        }
    }
}

/// The app's own Finder icon, as Finder and System Settings show it.
struct AppIconView: View {
    let url: URL
    let size: CGFloat

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
            .resizable()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
