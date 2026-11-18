import AppKit
import MacOSCleanerCore
import SwiftUI
import UniformTypeIdentifiers

struct SwipeReviewView: View {
    @Bindable var model: CleanupModel
    @State private var offset = CGSize.zero
    @State private var showsMovePicker = false
    @State private var showsSubfolderPicker = false
    @State private var albumPickerItem: ReviewItem?
    @State private var albumNotice: String?
    @State private var confirms = false
    @State private var confirmsDiscard = false
    @FocusState private var cardFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        VStack(spacing: Spacing.elementNormal) {
            if let session = model.session {
                sessionHeader(session)
                if let item = session.current {
                    card(item).id(item.id)
                } else {
                    ReviewBatchSummary(decisions: session.decisions, model: model)
                    Button(String(localized: "Confirm session")) { confirms = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isBusy || model.isSaving)
                }
            } else if let completed = model.completedSession {
                completedView(completed)
            } else {
                setup
            }
        }
        .padding(Spacing.cardPadding)
        .skeletonLoading(model.isBusy || model.isSaving)
        .navigationTitle(CleanupTool.swipe.title)
        .sheet(item: $albumPickerItem) { item in
            SwipeAlbumPickerSheet(item: item, model: model) { albumTitle in
                albumNotice = String(localized: "Added to “\(albumTitle)”")
            }
        }
        .sheet(isPresented: $confirms) { confirmSessionSheet }
        .confirmationDialog(
            String(localized: "Discard pending decisions? Completed changes stay in Activity."),
            isPresented: $confirmsDiscard
        ) {
            Button(String(localized: "Discard draft"), role: .destructive) { Task { await model.discardSession() } }
        }
        .fileImporter(isPresented: $showsMovePicker, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { choose(.move, destination: url) }
        }
        .fileImporter(isPresented: $showsSubfolderPicker, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { model.filterFolder = url }
        }
    }

    @ViewBuilder private func sessionHeader(_ session: ReviewSession) -> some View {
        if !model.sessionResults.isEmpty {
            let processed = model.sessionResults.count
            let successful = model.sessionResults.filter { $0.state == .complete }.count
            let remaining = max(0, session.pendingChanges.count - processed)
            Text(
                String(
                    localized: """
                        \(successful) successful · \(processed - successful) failed \
                        · \(remaining) unprocessed
                        """))
        }
        HStack {
            Text(String(localized: "\(session.decisions.count) of \(session.items.count) reviewed"))
                .monospacedDigit()
            if let albumNotice {
                Label(albumNotice, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(SemanticScale.success)
            }
            Spacer()
            Button(String(localized: "Undo last decision")) { Task { await model.undoDecision() } }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(
                    session.decisions.isEmpty || session.applicationStartedAt != nil || model.isBusy
                        || model.isSaving
                )
                .help(String(localized: "⌘Z or Edit ▸ Undo reverts the last decision."))
            Button(
                session.applicationStartedAt == nil
                    ? String(localized: "Discard draft") : String(localized: "Close session")
            ) {
                confirmsDiscard = true
            }
            .disabled(model.isBusy || model.isSaving)
        }
    }

    private var confirmSessionSheet: some View {
        VStack {
            if let session = model.session { ReviewBatchSummary(decisions: session.decisions, model: model) }
            HStack {
                Button(String(localized: "Cancel")) { confirms = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(String(localized: "Apply these changes"), role: .destructive) {
                    confirms = false
                    Task { await model.commitSession() }
                }
            }
        }
        .padding(Spacing.cardPadding)
        .frame(minWidth: 600, minHeight: 480)
        .presentationSizing(.form)
    }

    private var setup: some View {
        VStack(spacing: Spacing.elementSection) {
            Image(systemName: "rectangle.stack").font(.largeTitle)
            Text(String(localized: "Review one file at a time")).font(.title2)
            Picker(String(localized: "Session filter"), selection: $model.filter) {
                ForEach(ReviewFilter.allCases, id: \.self) { Text($0.title).tag($0) }
            }.frame(maxWidth: 360)
            if model.filter == .beforeDate {
                DatePicker(
                    String(localized: "Modified on or before"), selection: $model.filterDate, displayedComponents: .date
                )
            }
            if model.filter == .subfolder {
                Button(model.filterFolder?.lastPathComponent ?? String(localized: "Choose nested folder…")) {
                    showsSubfolderPicker = true
                }
            }
            let count = model.filteredItems().count
            Text(
                count == 1
                    ? String(localized: "1 file matches this session")
                    : String(localized: "\(count) files match this session")
            )
            .monospacedDigit()
            Button(String(localized: "Start session")) { Task { await model.startSession() } }
                .buttonStyle(.borderedProminent)
                .disabled(model.result?.isFresh != true || model.filteredItems().isEmpty)
            if model.result?.isFresh != true { Text(String(localized: "Run a scan to start reviewing.")) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func card(_ item: ReviewItem) -> some View {
        VStack(spacing: Spacing.elementTight) {
            Text(item.name).font(.title2).lineLimit(2)
            Text("\(ReviewItemLabeling.compactContext(for: item)) · \(item.sourceName)")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            ZStack {
                ReviewPreview(item: item, model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                SwipeStampOverlay(offset: offset, canDelete: item.canDelete, canMove: item.canEditLocally)
            }
            cardButtons(item)
            Text(String(localized: "Swipe left/right, use arrow keys, or press Delete. Changes wait for confirmation."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(Spacing.cardPadding)
        .background(.background, in: RoundedRectangle(cornerRadius: Radius.card))
        .background {
            TrackpadSwipeMonitor(
                isEnabled: !confirms && !showsMovePicker && albumPickerItem == nil && !model.isBusy && !model.isSaving,
                onChanged: { delta in offset = delta },
                onEnded: { finalOffset in finishSwipe(finalOffset, item: item) }
            )
        }
        .offset(offset)
        .rotationEffect(.degrees(reduceMotion ? 0 : Double(offset.width / 24)))
        .focusable().focused($cardFocused)
        .onAppear {
            cardFocused = true
            albumNotice = nil
        }
        .onKeyPress(keys: [.delete, .deleteForward, .leftArrow, .rightArrow, .upArrow, .space]) { key in
            handleKey(key, item: item)
        }
        .gesture(
            DragGesture(minimumDistance: 25)
                .onChanged { offset = $0.translation }
                .onEnded { finishSwipe($0.translation, item: item) }
        )
        .disabled(model.isBusy || model.isSaving)
        .accessibilityLabel(String(localized: "Review card for \(item.name), \(item.bytes.formattedByteCount)"))
    }

    private func cardButtons(_ item: ReviewItem) -> some View {
        GlassEffectContainer {
            HStack(spacing: Spacing.elementNormal) {
                Button(String(localized: "Move to Trash"), systemImage: "trash", role: .destructive) {
                    choose(.trash)
                }
                .disabled(!item.canDelete)
                .help(String(localized: "Left Arrow or Delete key"))

                Button(String(localized: "Keep"), systemImage: "checkmark") { choose(.keep) }
                    .help(String(localized: "Right Arrow key"))

                Button(String(localized: "Move…"), systemImage: "folder") { showsMovePicker = true }
                    .disabled(!item.canEditLocally)
                    .help(String(localized: "Up Arrow key"))

                if item.photoID != nil {
                    Button(String(localized: "Add to Album…"), systemImage: "rectangle.stack.badge.plus") {
                        albumPickerItem = item
                    }
                    .help(String(localized: "Add to a Photos album without removing from library"))
                }

                Button(String(localized: "Skip"), systemImage: "forward.end") { choose(.skip) }
                    .help(String(localized: "Space bar"))
            }
            .buttonStyle(.glass)
            .controlSize(.large)
        }
    }

    private func finishSwipe(_ translation: CGSize, item: ReviewItem) {
        if translation.height < -100, abs(translation.height) > abs(translation.width), item.canEditLocally {
            showsMovePicker = true
        } else if translation.width < -100, abs(translation.width) >= abs(translation.height), item.canDelete {
            choose(.trash)
        } else if translation.width > 100, abs(translation.width) >= abs(translation.height) {
            choose(.keep)
        }
        let animation: Animation? = reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.78)
        withAnimation(animation) { offset = .zero }
    }

    private func handleKey(_ key: KeyPress, item: ReviewItem) -> KeyPress.Result {
        guard cardFocused, !model.isBusy, !model.isSaving else { return .ignored }
        switch key.key {
        case .delete, .deleteForward, .leftArrow:
            if item.canDelete { choose(.trash) }
        case .rightArrow:
            choose(.keep)
        case .upArrow:
            if item.canEditLocally { showsMovePicker = true }
        case .space:
            choose(.skip)
        default:
            return .ignored
        }
        return .handled
    }

    /// Records the decision and registers it with Edit ▸ Undo.
    private func choose(_ choice: ReviewChoice, destination: URL? = nil) {
        Task {
            guard await model.decide(choice, destination: destination) else { return }
            undoManager?.registerUndo(withTarget: model) { target in
                Task { @MainActor in await target.undoDecision() }
            }
            undoManager?.setActionName(String(localized: "Swipe Decision"))
        }
    }

    @ViewBuilder private func completedView(_ completed: ReviewSession) -> some View {
        Image(systemName: "checklist").font(.largeTitle)
        Text(String(localized: "Session results")).font(.title2)
        let decisions = completed.decisions
        let trashed = model.sessionResults.filter { $0.action == "trash" && $0.state == .complete }
        Text(
            String(
                localized: "\(trashed.count) removed · \(decisions.filter { $0.choice == .keep }.count) kept"))
        let moved = decisions.filter { $0.choice == .move }.count
        let skipped = decisions.filter { $0.choice == .skip }.count
        Text(String(localized: "\(moved) moved · \(skipped) skipped"))
        let removedBytes = trashed.reduce(0) { $0 + $1.bytes }.formattedByteCount
        Text(String(localized: "\(removedBytes) sent to Trash or Recently Deleted"))
            .monospacedDigit()
        HStack {
            Button(String(localized: "Start Another Session")) {
                model.sessionResults = []
                model.completedSession = nil
                model.scan()
            }
            Button(String(localized: "Go to Cleanup Tools")) { model.selectedTool = nil }
        }
    }
}

private struct SwipeStampOverlay: View {
    let offset: CGSize
    let canDelete: Bool
    let canMove: Bool

    var body: some View {
        ZStack {
            if offset.width > 24 {
                stamp(
                    title: String(localized: "KEEP"),
                    symbol: "checkmark.circle.fill",
                    color: SemanticScale.success,
                    opacity: min(1, Double((offset.width - 24) / 80))
                )
                .rotationEffect(.degrees(-12))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if offset.width < -24 {
                stamp(
                    title: canDelete ? String(localized: "DELETE") : String(localized: "READ ONLY"),
                    symbol: canDelete ? "trash.fill" : "lock.fill",
                    color: canDelete ? SemanticScale.error : SemanticScale.warning,
                    opacity: min(1, Double((-offset.width - 24) / 80))
                )
                .rotationEffect(.degrees(12))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            } else if offset.height < -24, abs(offset.height) > abs(offset.width), canMove {
                stamp(
                    title: String(localized: "MOVE"),
                    symbol: "folder.fill",
                    color: .accentColor,
                    opacity: min(1, Double((-offset.height - 24) / 80))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .padding(Spacing.cardPadding)
        .allowsHitTesting(false)
    }

    private func stamp(title: String, symbol: String, color: Color, opacity: Double) -> some View {
        Label(title, systemImage: symbol)
            .font(.title3.weight(.bold))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundStyle(color)
            .background(color.opacity(0.16), in: RoundedRectangle(cornerRadius: Radius.cardCompact))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.cardCompact)
                    .strokeBorder(color, lineWidth: 2)
            }
            .opacity(opacity)
    }
}

/// Translates horizontal two-finger trackpad scroll gestures into swipe offsets.
private struct TrackpadSwipeMonitor: NSViewRepresentable {
    let isEnabled: Bool
    let onChanged: (CGSize) -> Void
    let onEnded: (CGSize) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onChanged: onChanged, onEnded: onEnded) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.hostView = view
        context.coordinator.installMonitor()
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.hostView = view
        context.coordinator.isEnabled = isEnabled
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    @MainActor final class Coordinator {
        weak var hostView: NSView?
        var isEnabled = true
        var onChanged: (CGSize) -> Void
        var onEnded: (CGSize) -> Void
        private var monitor: Any?
        private var accumulated = CGSize.zero
        private var trackingHorizontal = false

        init(onChanged: @escaping (CGSize) -> Void, onEnded: @escaping (CGSize) -> Void) {
            self.onChanged = onChanged
            self.onEnded = onEnded
        }

        func installMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handle(event) ?? event
            }
        }

        func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard isEnabled, let hostView, event.window === hostView.window,
                event.momentumPhase == []
            else { return event }
            let location = hostView.convert(event.locationInWindow, from: nil)
            guard hostView.bounds.contains(location) || trackingHorizontal else { return event }

            if event.phase == .began {
                accumulated = .zero
                trackingHorizontal = false
            }
            if event.phase == .changed || event.phase == .began {
                accumulated.width += event.scrollingDeltaX * 1.4
                accumulated.height += event.scrollingDeltaY
                if !trackingHorizontal, abs(accumulated.width) > max(12, abs(accumulated.height) * 1.2) {
                    trackingHorizontal = true
                }
                if trackingHorizontal {
                    onChanged(CGSize(width: accumulated.width, height: 0))
                    return nil
                }
            } else if event.phase == .ended || event.phase == .cancelled, trackingHorizontal {
                let finalOffset = CGSize(width: accumulated.width, height: 0)
                accumulated = .zero
                trackingHorizontal = false
                onEnded(finalOffset)
                return nil
            }
            return event
        }
    }
}

struct ReviewBatchSummary: View {
    let decisions: [ReviewDecision]
    let model: CleanupModel
    var retained: [ReviewItem] = []

    var body: some View {
        let trashBytes = decisions.filter { $0.choice == .trash }.reduce(0) { $0 + $1.item.bytes }.formattedByteCount
        return VStack(alignment: .leading, spacing: Spacing.elementNormal) {
            Text(String(localized: "Review these changes")).font(.title2)
            Text(
                String(
                    localized: """
                        \(count(.trash)) Trash · \(count(.keep)) kept · \(count(.move)) moved \
                        · \(count(.skip)) skipped
                        """
                ))
            Text(String(localized: "\(trashBytes) selected for removal")).monospacedDigit()
            List {
                ForEach(decisions, id: \.item.id) { decision in
                    HStack {
                        ReviewPreview(item: decision.item, model: model, thumbnail: true).frame(width: 64, height: 48)
                        VStack(alignment: .leading) {
                            Text(decision.item.name)
                            Text(ReviewItemLabeling.compactContext(for: decision.item))
                                .font(.caption2).foregroundStyle(.secondary)
                            Text(decision.destination?.path ?? decision.choice.title)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(decision.item.bytes.formattedByteCount).monospacedDigit()
                    }
                }
                if !retained.isEmpty {
                    Section(String(localized: "Retained components")) {
                        ForEach(retained) { item in
                            Label(item.name, systemImage: "checkmark.circle")
                        }
                    }
                }
            }
            if !retained.isEmpty {
                Text(
                    String(
                        localized: """
                            Removed RAW components contain editing data. Removed paired videos contain motion. \
                            These capabilities will not be preserved in the retained components.
                            """)
                ).font(.caption)
            }
            Text(
                String(
                    localized: """
                        Files move to Trash. Photos assets move to Recently Deleted and deletion \
                        can sync to iCloud. Photos moves first export and verify every original \
                        resource. No Trash or Recently Deleted items are permanently deleted \
                        by Cleanup. Photos recovery is normally available for 30 days.
                        """
                )
            )
            .font(.caption)
        }
    }

    private func count(_ choice: ReviewChoice) -> Int { decisions.filter { $0.choice == choice }.count }
}
