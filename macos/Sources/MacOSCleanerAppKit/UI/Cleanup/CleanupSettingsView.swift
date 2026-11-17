import AppKit
import MacOSCleanerCore
import SwiftUI

struct CleanupSettingsView: View {
    @Bindable var model: CleanupModel
    @State private var confirmsReset = false
    @State private var showsPhotosDeniedAlert = false

    var body: some View {
        Form {
            photosPermissionsSection
            analysisSection
            compressionSection
            reminderSection
            historySection
        }
        .formStyle(.grouped)
        .onAppear { model.refreshPhotoAuthorizationState() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshPhotoAuthorizationState()
        }
        .onChange(of: model.settings.defaultFilter) {
            model.filter = model.settings.defaultFilter
        }
        .alert(String(localized: "Photos Access Denied"), isPresented: $showsPhotosDeniedAlert) {
            Button(String(localized: "Cancel"), role: .cancel) {}
            Button(String(localized: "Open Photos Settings…")) { PermissionLinks.openPhotos() }
        } message: {
            Text(
                String(
                    localized: """
                        Tidybyte cannot read or clean your Photos library while Photos permission is denied. \
                        Open System Settings › Privacy & Security › Photos to allow access.
                        """
                )
            )
        }
        .confirmationDialog(
            String(
                localized: """
                    Reset review history and discard saved review drafts? Activity and \
                    recovery records will remain.
                    """
            ), isPresented: $confirmsReset
        ) {
            Button(String(localized: "Reset Review History"), role: .destructive) {
                Task { await model.resetHistory() }
            }
        }
    }

    private var photosPermissionsSection: some View {
        Section(String(localized: "Photos Library Access")) {
            LabeledContent(String(localized: "Permission Status")) {
                HStack(spacing: Spacing.elementTight) {
                    Text(permissionStatusTitle)
                        .foregroundStyle(permissionStatusColor)
                    switch model.photoAuthorizationState {
                    case .denied:
                        Button(String(localized: "Open Photos Settings…")) {
                            showsPhotosDeniedAlert = true
                        }
                    case .limited:
                        Button(String(localized: "Select More Photos…")) {
                            PermissionLinks.openPhotos()
                        }
                    case .notDetermined:
                        Button(String(localized: "Open Photos Settings…")) {
                            PermissionLinks.openPhotos()
                        }
                    case .authorized:
                        EmptyView()
                    }
                }
            }
            if model.photoAuthorizationState == .limited {
                Text(
                    String(
                        localized: """
                            Limited Access only shows selected photos. Choose Select More Photos… to grant \
                            Full Access in System Settings.
                            """
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var analysisSection: some View {
        Section(String(localized: "Analysis")) {
            Slider(value: $model.settings.similarSeconds, in: 1...60, step: 1) {
                Text(String(localized: "Similar files: \(Int(model.settings.similarSeconds)) seconds"))
                    .monospacedDigit()
            }
            Picker(String(localized: "Blur sensitivity"), selection: $model.settings.blurSensitivity) {
                Text(String(localized: "Low")).tag(0)
                Text(String(localized: "Medium")).tag(1)
                Text(String(localized: "High")).tag(2)
            }
            Picker(String(localized: "Category sensitivity"), selection: $model.settings.categorySensitivity) {
                Text(String(localized: "Strict")).tag(0)
                Text(String(localized: "Balanced")).tag(1)
                Text(String(localized: "Broad")).tag(2)
            }
            Slider(value: $model.settings.largeMegabytes, in: 5...500, step: 5) {
                Text(String(localized: "Large files: \(Int(model.settings.largeMegabytes)) MB"))
                    .monospacedDigit()
            }
            Picker(String(localized: "Default swipe filter"), selection: $model.settings.defaultFilter) {
                ForEach(ReviewFilter.allCases, id: \.self) { Text($0.title).tag($0) }
            }
        }
    }

    private var compressionSection: some View {
        Section(String(localized: "Compression")) {
            Picker(String(localized: "Photo sort order"), selection: $model.settings.photoCompressionSortOrder) {
                ForEach(PhotoCompressionSortOrder.allCases) { order in
                    Text(order.title).tag(order)
                }
            }
            Picker(String(localized: "Target max photo size"), selection: $model.settings.photoMaxSizeMB) {
                Text(String(localized: "Quality preset")).tag(Optional<Double>.none)
                ForEach(CleanupSettings.photoMaxSizeChoicesMB, id: \.self) { sizeMB in
                    Text(CompressionControlsView.formatMegabytes(sizeMB)).tag(Optional(sizeMB))
                }
            }
            Picker(String(localized: "Image quality"), selection: $model.settings.imageQuality) {
                Text(String(localized: "High")).tag(ImageQuality.high)
                Text(String(localized: "Balanced")).tag(ImageQuality.balanced)
                Text(String(localized: "Small")).tag(ImageQuality.small)
            }
            .disabled(model.settings.photoMaxSizeMB != nil)

            Picker(String(localized: "Max photo dimension"), selection: $model.settings.photoMaxDimension) {
                ForEach(CleanupSettings.photoMaxDimensionChoices, id: \.self) { dim in
                    Text(dim.map { String(localized: "\($0) px") } ?? String(localized: "Original"))
                        .tag(dim)
                }
            }
            Toggle(String(localized: "Convert photos to HEIC"), isOn: $model.settings.photoConvertToHEIC)
            Toggle(
                String(localized: "Replace and trash originals after compression"),
                isOn: $model.settings.deleteOriginalsAfterCompression
            )
            Picker(String(localized: "Video resolution"), selection: $model.settings.videoHeight) {
                Text("1080p").tag(1080)
                Text("720p").tag(720)
                Text("480p").tag(480)
            }
            Toggle(String(localized: "Use HEVC (H.265) for video"), isOn: $model.settings.videoUseHEVC)
        }
    }

    private var reminderSection: some View {
        Section(String(localized: "Reminder")) {
            Toggle(String(localized: "Weekly cleanup reminder"), isOn: $model.settings.reminderEnabled)
            Picker(String(localized: "Day at 09:00"), selection: $model.settings.reminderWeekday) {
                ForEach(1...7, id: \.self) { day in Text(Calendar.current.weekdaySymbols[day - 1]).tag(day) }
            }.disabled(!model.settings.reminderEnabled)

            if let result = model.result, result.isFresh {
                let breakdown = model.reminderCategoryBreakdown(for: result)
                if !breakdown.isEmpty {
                    ForEach(breakdown, id: \.tool) { entry in
                        LabeledContent(entry.tool.title) {
                            let countLabel = entry.count == 1
                                ? String(localized: "1 item")
                                : String(localized: "\(entry.count) items")
                            Text("\(countLabel) · \(entry.bytes.formattedByteCount)")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Text(model.multiCategoryReminderSummary(for: result))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(String(localized: "Reminders quote the date and multi-category counts from the last scan."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var historySection: some View {
        Section(String(localized: "History")) {
            Button(String(localized: "Reset Review History…"), role: .destructive) { confirmsReset = true }
                .disabled(model.isBusy)
        }
    }

    private var permissionStatusTitle: String {
        switch model.photoAuthorizationState {
        case .authorized: String(localized: "Full Access")
        case .limited: String(localized: "Limited Access")
        case .denied: String(localized: "Denied")
        case .notDetermined: String(localized: "Not Requested")
        }
    }

    private var permissionStatusColor: Color {
        switch model.photoAuthorizationState {
        case .authorized: SemanticScale.success
        case .limited: SemanticScale.warning
        case .denied: SemanticScale.error
        case .notDetermined: .secondary
        }
    }
}
