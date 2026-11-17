import MacOSCleanerCore
import SwiftUI

/// First-run sheet: welcome, Full Disk Access, Photos, then the first scan.
/// The step is saved, so onboarding resumes after System Settings asks to
/// quit and reopen Tidybyte.
struct OnboardingView: View {
    static let stepKey = "onboardingStep"
    static let explicitCompletionKey = "onboardingCompletedExplicitly"
    static let doneStep = 4

    @Bindable var model: AppViewModel
    @AppStorage(OnboardingView.stepKey) private var step = 0
    @AppStorage(AppDelegate.menuBarExtraKey) private var showsMenuBarExtra = false
    @State private var hasFullDiskAccess = FullDiskAccess.isGranted()
    @State private var isAuthorizingPhotos = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let override = model.languageStore.activeOverride
        VStack(spacing: Spacing.elementSection) {
            switch step {
            case 0: welcome(override: override)
            case 1: fullDiskAccess(override: override)
            case 2: photos(override: override)
            default: ready(override: override)
            }
        }
        .padding(Spacing.sectionGap + 8)
        .frame(width: 520)
        .animation(reduceMotion ? nil : .appSelection, value: step)
        .task(id: step) { await waitForFullDiskAccess() }
    }

    // MARK: Steps

    private func welcome(override: AppLanguage?) -> some View {
        VStack(spacing: Spacing.elementNormal) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 96, height: 96)
                .accessibilityHidden(true)
            Text(L10n.string("Welcome to Tidybyte", language: override)).font(.largeTitle.bold())
            VStack(alignment: .leading, spacing: Spacing.elementNormal) {
                point("magnifyingglass", L10n.string("Finds caches, leftovers, duplicates, and large files.", language: override))
                point("hand.raised", L10n.string("Nothing changes until you approve it.", language: override))
                point("arrow.uturn.backward", L10n.string("Files go to the Trash, and History can restore them.", language: override))
            }
            .padding(.vertical, Spacing.elementTight)
            Button(L10n.string("Continue", language: override)) {
                step = DistributionChannel.supportsAdvanced ? 1 : 2
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
    }

    private func fullDiskAccess(override: AppLanguage?) -> some View {
        VStack(spacing: Spacing.elementNormal) {
            Image(systemName: hasFullDiskAccess ? "checkmark.shield.fill" : "lock.shield")
                .font(.system(.largeTitle))
                .foregroundStyle(hasFullDiskAccess ? AnyShapeStyle(SemanticScale.success) : AnyShapeStyle(.tint))
                .accessibilityHidden(true)
            Text(L10n.string("Allow Full Disk Access", language: override)).font(.title.bold())
            // Full localization key exceeds 140 chars in Localizable.xcstrings.
            // swiftlint:disable:next line_length
            Text(L10n.string("macOS hides Mail, Safari, and other apps' data until you allow it. Turn on Tidybyte in Privacy & Security › Full Disk Access. You can also drag the icon below into that list.", language: override))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 56, height: 56)
                .onDrag { NSItemProvider(object: Bundle.main.bundleURL as NSURL) }
                .help(L10n.string("Drag into the Full Disk Access list", language: override))
                .accessibilityLabel(L10n.string("Tidybyte app icon", language: override))
            HStack {
                Button(L10n.string("Skip for Now", language: override)) { step = 2 }
                Button(L10n.string("Open Privacy & Security", language: override)) {
                    PermissionLinks.openFullDiskAccess()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            Text(L10n.string("Tidybyte continues on its own once access is on.", language: override))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func photos(override: AppLanguage?) -> some View {
        let photosPrompt = L10n.string(
            // swiftlint:disable:next line_length
            "Tidybyte can find similar shots, blurry photos, and large videos in Photos. Anything you remove goes to Recently Deleted in Photos.",
            language: override
        )
        return VStack(spacing: Spacing.elementNormal) {
            Image(systemName: "photo.on.rectangle").font(.system(.largeTitle)).foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(L10n.string("Include your Photos library?", language: override)).font(.title.bold())
            Text(photosPrompt)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            HStack {
                Button(L10n.string("Not Now", language: override)) {
                    model.cleanup.scope.includesPhotos = false
                    step = 3
                }
                Button(L10n.string("Allow Photos Access", language: override)) {
                    guard !isAuthorizingPhotos else { return }
                    isAuthorizingPhotos = true
                    Task {
                        let granted = (try? await PhotoLibraryService().authorize()) != nil
                        model.cleanup.scope.includesPhotos = granted
                        isAuthorizingPhotos = false
                        step = 3
                    }
                }
                .disabled(isAuthorizingPhotos)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
    }

    private func ready(override: AppLanguage?) -> some View {
        VStack(spacing: Spacing.elementNormal) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(.largeTitle))
                .foregroundStyle(SemanticScale.success)
                .accessibilityHidden(true)
            Text(L10n.string("You're all set", language: override)).font(.title.bold())
            Toggle(L10n.string("Show free space in the menu bar", language: override), isOn: $showsMenuBarExtra)
                .toggleStyle(.switch)
            Button(L10n.string("Scan My Mac", language: override)) {
                model.completeOnboardingExplicitly()
                step = Self.doneStep
                model.scanAll()
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .keyboardShortcut(.defaultAction)
            Button(L10n.string("I'll scan later", language: override)) {
                model.completeOnboardingExplicitly()
                step = Self.doneStep
            }
            .buttonStyle(.bordered)
        }
    }

    private func point(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.tint)
        }
    }

    private func waitForFullDiskAccess() async {
        guard step == 1 else { return }
        while !Task.isCancelled {
            hasFullDiskAccess = FullDiskAccess.isGranted()
            if hasFullDiskAccess {
                try? await Task.sleep(for: .seconds(1))
                step = 2
                return
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }
}
