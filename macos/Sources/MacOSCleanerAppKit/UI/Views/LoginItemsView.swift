import MacOSCleanerCore
import SwiftUI

/// Apps › Login Items: launch agents and daemons that start with the Mac.
struct LoginItemsView: View {
    @Bindable var model: AppViewModel
    @State private var items: [LaunchItem] = []
    @State private var isLoading = true
    @State private var selection: LaunchItem.ID?
    @State private var pendingRemoval: LaunchItem?

    var body: some View {
        let override = model.languageStore.activeOverride
        Group {
            if isLoading {
                VStack(spacing: 0) {
                    ForEach(0..<6, id: \.self) { _ in
                        HStack(spacing: Spacing.elementNormal) {
                            SkeletonBlock(height: 20, width: 20)
                            SkeletonBlock(height: 14)
                            SkeletonBlock(height: 14, width: 110)
                            SkeletonBlock(height: 14, width: 110)
                        }
                        .padding(.vertical, Spacing.elementTight)
                    }
                }
                .padding(.horizontal, Spacing.screenEdge)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .accessibilityLabel(Text(L10n.string("Listing login items…", language: override)))
            } else if items.isEmpty {
                ContentUnavailableView(
                    L10n.string("No login items", language: override),
                    systemImage: "power",
                    description: Text(L10n.string(
                        "No third-party agents or daemons start with this Mac.",
                        language: override
                    ))
                )
            } else {
                table(override: override)
            }
        }
        .task {
            let loaded = await Task.detached(priority: .utility) {
                LaunchItems.list()
            }.value
            items = loaded
            isLoading = false
        }
        .confirmationDialog(
            L10n.format("Add %@ to Leftovers?", language: override, pendingRemoval?.label ?? ""),
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible
        ) {
            Button(L10n.string("Add to Leftovers", language: override)) {
                guard let item = pendingRemoval else { return }
                Task {
                    if await model.stageRemoval(of: item), let id = model.selectedActionID {
                        model.showReviewAction(id: id)
                    }
                }
            }
        } message: {
            Text(L10n.string("Nothing changes until you approve it in Leftovers and confirm.", language: override))
        }
    }

    private func table(override: AppLanguage?) -> some View {
        Table(items, selection: $selection) {
            TableColumn(L10n.string("Name", language: override)) { item in
                Label {
                    Text(item.appBundle?.deletingPathExtension().lastPathComponent ?? item.label)
                } icon: {
                    if let bundle = item.appBundle, FileManager.default.fileExists(atPath: bundle.path) {
                        AppIconView(url: bundle, size: 16)
                    } else {
                        Image(systemName: "gearshape.2")
                    }
                }
                .help(item.label)
            }
            TableColumn(L10n.string("Kind", language: override)) { item in Text(item.domain.displayName) }
                .width(min: 110, ideal: 130)
            TableColumn(L10n.string("Status", language: override)) { item in status(item, override: override) }
                .width(min: 100, ideal: 130)
            TableColumn(L10n.string("Program", language: override)) { item in
                Text(item.program ?? "—").font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
        .contextMenu(forSelectionType: LaunchItem.ID.self) { ids in
            if let item = items.first(where: { ids.contains($0.id) }) {
                Button(L10n.string("Show in Finder", language: override)) {
                    NSWorkspace.shared.activateFileViewerSelecting([item.url])
                }
                Button(L10n.string("Remove…", language: override)) { pendingRemoval = item }
                    .disabled(!item.canRemove)
            }
        }
    }

    @ViewBuilder
    private func status(_ item: LaunchItem, override: AppLanguage?) -> some View {
        if item.isProgramMissing {
            Label(L10n.string("Program missing", language: override), systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(SemanticScale.warning)
        } else if let enabled = item.isEnabled {
            Text(enabled ? L10n.string("Allowed", language: override) : L10n.string("Turned off", language: override))
        } else {
            Text(L10n.string("Not listed", language: override)).foregroundStyle(.secondary)
        }
    }
}
