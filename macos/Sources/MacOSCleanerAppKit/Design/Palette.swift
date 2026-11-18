import MacOSCleanerCore
import SwiftUI

public struct CategoricalPalette {
    public let soft: Color
    public let mid: Color
    public let ink: Color
    public let border: Color

    private init(_ color: Color, darkInk: Bool = false) {
        soft = color.opacity(0.14)
        mid = color
        ink = darkInk ? Color.black.opacity(0.9) : .white
        border = color.opacity(0.32)
    }
}

public extension CategoricalPalette {
    static var blue: Self { Self(Color(nsColor: .systemBlue)) }
    static var purple: Self { Self(Color(nsColor: .systemPurple)) }
    static var green: Self { Self(Color(nsColor: .systemGreen), darkInk: true) }
    static var yellow: Self { Self(Color(nsColor: .systemYellow), darkInk: true) }
    static var orange: Self { Self(Color(nsColor: .systemOrange), darkInk: true) }
    static var teal: Self { Self(Color(nsColor: .systemTeal), darkInk: true) }
    static var pink: Self { Self(Color(nsColor: .systemPink)) }
    static var coral: Self { Self(Color(nsColor: .systemRed)) }
    static var protected: Self { Self(Color(nsColor: .systemPurple)) }
}

public enum FolderPastel {
    private static var colors: [CategoricalPalette] {
        [.blue, .teal, .green, .orange, .purple, .pink, .coral, .yellow, .blue, .teal]
    }
    public static func palette(forFolderName name: String) -> CategoricalPalette {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in name.lowercased().utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return colors[Int(hash % UInt64(colors.count))]
    }
    public static var count: Int { colors.count }
}

public extension MediaKind {
    /// Categorical color for the Overview storage breakdown, matching the
    /// FindingCategory hues already used across the app.
    var palette: CategoricalPalette {
        switch self {
        case .image: .pink
        case .video: .purple
        case .pdf: .coral
        case .audio: .teal
        case .document: .blue
        case .archive: .orange
        case .other: .yellow
        }
    }
}

extension AppDestination {
    /// Segment colors for the Overview "You Could Free" hero.
    var palette: CategoricalPalette {
        switch self {
        case .systemJunk: .green
        case .developer: .orange
        case .largeFiles: .coral
        case .duplicates: .blue
        case .media: .pink
        case .leftovers: .teal
        default: .blue
        }
    }
}

public extension FindingCategory {
    /// Returns the categorical color palette associated with this finding type.
    var palette: CategoricalPalette {
        switch self {
        case .largeFile, .iosDeviceBackup, .timeMachineBackup, .largeFileReview:
            return .coral
        case .duplicate, .dockerCleanup, .systemDeep, .macOSSystemCache, .cloudStorageCache, .vmToolCache:
            return .blue
        case .cache, .packageManagerCleanup, .userEssentials, .developerToolCache, .applicationSupportCache:
            return .green
        case .log, .screenshot:
            return .yellow
        case .developerArtifact, .codingAgentArtifact, .officeAppCache, .developmentAppCache:
            return .orange
        case .appLeftover, .finderMetadata, .sandboxedAppCache, .uninstalledAppData:
            return .teal
        case .oldDownload, .oldInstaller, .browserCache, .appleSiliconUpdate:
            return .purple
        case .organization:
            return .pink
        case .protected:
            return .protected
        }
    }
}
