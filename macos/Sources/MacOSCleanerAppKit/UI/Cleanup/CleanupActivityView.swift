import AppKit
import Charts
import MacOSCleanerCore
import SwiftUI

struct CleanupActivityView: View {
    @Bindable var model: CleanupModel

    private var completed: [ActivityEvent] {
        model.activity.filter { $0.state == .complete && !$0.restored }
    }

    private var recent30DayEvents: [ActivityEvent] {
        let cutoff = Date().addingTimeInterval(-30 * 86_400)
        return model.activity.filter { event in
            guard event.state == .complete else { return false }
            if event.date > cutoff { return true }
            if let restored = event.restoredAt, restored > cutoff { return true }
            return false
        }
    }

    private var interruptedEvents: [ActivityEvent] {
        model.activity.filter {
            $0.state == .prepared || $0.state == .outputReady || $0.state == .interrupted
                || ($0.restoreStartedAt != nil && !$0.restored)
        }
    }

    private func total(where matches: (ActivityEvent) -> Bool) -> String {
        completed.filter(matches).reduce(0) { $0 + $1.savings }.formattedByteCount
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.elementSection) {
                summarySection
                if !interruptedEvents.isEmpty { interruptedBanner }
                chartSection
                byToolSection
                recentEventsSection
            }
            .padding(Spacing.cardPadding)
            .skeletonLoading(model.isBusy)
        }
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: Spacing.elementTight) {
            Text(completed.reduce(0) { $0 + $1.savings }.formattedByteCount)
                .font(.largeTitle)
                .monospacedDigit()
            Text(
                completed.count == 1
                    ? String(localized: "1 item processed")
                    : String(localized: "\(completed.count) items processed")
            )
            .monospacedDigit()
            Text(
                String(
                    localized: """
                        Space returns when Trash or Recently Deleted is emptied. These totals \
                        record logical bytes removed or reduced, not measured free disk space.
                        """
                )
            )
            .foregroundStyle(.secondary)
            LabeledContent(
                String(localized: "Sent to Trash"),
                value: total { $0.action == "trash" && $0.item.url != nil }
            )
            .monospacedDigit()
            LabeledContent(
                String(localized: "Sent to Recently Deleted"),
                value: total { $0.action == "trash" && $0.item.photoID != nil }
            )
            .monospacedDigit()
            LabeledContent(
                String(localized: "Verified compression and format reductions"),
                value: total { $0.action == "compress" || $0.action == "keepComponent" }
            )
            .monospacedDigit()
        }
    }

    private var interruptedBanner: some View {
        GroupBox {
            HStack(alignment: .center, spacing: Spacing.elementNormal) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(
                            interruptedEvents.count == 1
                                ? String(localized: "1 interrupted operation")
                                : String(localized: "\(interruptedEvents.count) interrupted operations")
                        )
                        .font(.headline)
                        Text(
                            String(
                                localized: """
                                    An earlier operation stopped before finishing. Verify any output paths \
                                    below, then dismiss to reconcile Activity.
                                    """
                            )
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(SemanticScale.warning)
                }
                Spacer()
                Button(String(localized: "Reconcile & Dismiss")) {
                    Task { await model.dismissInterruptedOperations() }
                }
                .disabled(model.isBusy || model.isSaving)
            }
            .padding(4)
        }
    }

    @ViewBuilder private var chartSection: some View {
        if recent30DayEvents.isEmpty {
            ContentUnavailableView(
                String(localized: "No activity in the last 30 days"),
                systemImage: "chart.bar",
                description: Text(
                    String(localized: "Reviewed photos and media appear here once you clean them."))
            )
            .frame(height: 180)
        } else {
            let cutoff = Date().addingTimeInterval(-30 * 86_400)
            Chart {
                ForEach(recent30DayEvents) { event in
                    if event.date > cutoff {
                        BarMark(
                            x: .value(String(localized: "Date"), event.date, unit: .day),
                            y: .value(String(localized: "Bytes"), event.completedReduction))
                    }
                    if let restored = event.restoredAt, restored > cutoff {
                        BarMark(
                            x: .value(String(localized: "Date"), restored, unit: .day),
                            y: .value(String(localized: "Restore adjustment"), -event.completedReduction))
                    }
                }
            }
            .frame(height: 180)
            .accessibilityLabel(String(localized: "Logical bytes processed in the last 30 days"))
        }
    }

    private var byToolSection: some View {
        GroupBox(String(localized: "By tool")) {
            ForEach(CleanupTool.allCases) { tool in
                let values = completed.filter { $0.tool == tool }
                if !values.isEmpty {
                    LabeledContent(tool.title, value: values.reduce(0) { $0 + $1.savings }.formattedByteCount)
                        .monospacedDigit()
                }
            }
        }
    }

    private var recentEventsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.elementNormal) {
            Text(String(localized: "Recent 25 events")).font(.headline)
            if model.activity.isEmpty {
                ContentUnavailableView(
                    String(localized: "No activity yet"), systemImage: "clock",
                    description: Text(
                        String(localized: "Completed changes and interrupted operations appear here.")))
            }
            ForEach(Array(model.activity.prefix(25))) { event in
                eventRow(event)
            }
        }
    }

    private func eventRow(_ event: ActivityEvent) -> some View {
        GroupBox {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(event.item.name).font(.headline)
                    Text(
                        String(
                            localized: """
                                \(event.tool.title) · 1 item · \(event.bytes.formattedByteCount) · \
                                \(event.date.formatted())
                                """
                        )
                    )
                    .font(.caption)
                    .monospacedDigit()
                    Text(event.restored ? String(localized: "Restored") : event.state.title)
                    if let date = event.restoredAt {
                        Text(String(localized: "Restore adjustment: \(date.formatted())"))
                    } else if event.restoreStartedAt != nil {
                        Text(String(localized: "Restore interrupted. Check the original folder and Trash."))
                    }
                    if event.action == "compress" || event.action == "keepBoth" || event.action == "keepComponent" {
                        Text(String(localized: "After: \(event.outputBytes.formattedByteCount)")).monospacedDigit()
                    }
                    if let output = event.replacementURL ?? event.outputURL {
                        Text(output.path).font(.caption).textSelection(.enabled)
                    }
                    if let asset = event.replacementPhotoID {
                        Text(String(localized: "Replacement Photos asset: \(asset)"))
                            .font(.caption).textSelection(.enabled)
                    }
                    if let error = event.error { Text(error).foregroundStyle(SemanticScale.error) }
                }
                Spacer()
                if event.item.photoID != nil {
                    Text(String(localized: "Recover in Photos → Recently Deleted (normally 30 days)"))
                        .font(.caption)
                } else if event.state == .complete, !event.restored, event.restoreStartedAt == nil,
                    event.outputURL != nil {
                    Button(String(localized: "Restore")) { Task { await model.restore(event) } }
                        .disabled(model.isBusy)
                }
            }
        }
    }
}
