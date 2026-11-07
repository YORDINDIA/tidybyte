public extension ScanMode {
    var isSystemCleanSection: Bool { systemCleanSection != nil }

    var systemCleanSection: MoCleanScanner.SystemCleanSection? {
        switch self {
        case .selectedFolders, .homeFolder, .developerCleanup: nil
        case .deepSystem: .deepSystem
        case .userEssentials: .userEssentials
        case .finderMetadata: .finderMetadata
        case .macOSSystemCaches: .macOSSystemCaches
        case .sandboxedAppCaches: .sandboxedAppCaches
        case .browsers: .browsers
        case .cloudStorage: .cloudStorage
        case .officeApps: .officeApps
        case .developerTools: .developerTools
        case .devApplications: .devApplications
        case .vmTools: .vmTools
        case .applicationSupport: .applicationSupport
        case .uninstalledAppData: .uninstalledAppData
        case .appleSiliconUpdates: .appleSiliconUpdates
        case .iosBackups: .iosBackups
        case .timeMachineBackups: .timeMachineBackups
        case .largeFiles: .largeFiles
        }
    }
}
