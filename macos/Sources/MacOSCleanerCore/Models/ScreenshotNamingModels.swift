import Foundation

/// Naming styles supported by Snaptitle-style screenshot renaming.
public enum ScreenshotNamingStyle: String, CaseIterable, Codable, Identifiable, Sendable {
    case titleCase
    case sentenceCase
    case lowercaseDashes
    case dateFirst

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .titleCase:
            String(localized: "Title Case", comment: "Screenshot naming style: Title Case")
        case .sentenceCase:
            String(localized: "Sentence case", comment: "Screenshot naming style: Sentence case")
        case .lowercaseDashes:
            String(localized: "lowercase-dashes", comment: "Screenshot naming style: lowercase-dashes")
        case .dateFirst:
            String(localized: "Date first", comment: "Screenshot naming style: Date first")
        }
    }

    public var exampleFilename: String {
        switch self {
        case .titleCase: "Lisbon Flight Booking.png"
        case .sentenceCase: "Lisbon flight booking.png"
        case .lowercaseDashes: "lisbon-flight-booking.png"
        case .dateFirst: "2026-11-11 Lisbon Flight Booking.png"
        }
    }
}

public struct ScreenshotWatchFolder: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var url: URL
    public var bookmarkData: Data?
    public var isEnabled: Bool
    public var isSystemDetected: Bool

    public init(
        id: String = UUID().uuidString,
        url: URL,
        bookmarkData: Data? = nil,
        isEnabled: Bool = true,
        isSystemDetected: Bool = false
    ) {
        self.id = id
        self.url = url.standardizedFileURL
        self.bookmarkData = bookmarkData
        self.isEnabled = isEnabled
        self.isSystemDetected = isSystemDetected
    }
}

public enum ScreenshotRenameSource: String, Codable, Sendable {
    case autoWatch
    case tidyUp
    case dragDrop
    case manualInApp
}

public enum ScreenshotRenameStatus: String, Codable, Sendable {
    case applied
    case reverted
    case userOverridden
}

public struct ScreenshotRenameRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var batchID: String?
    public var originalURL: URL
    public var currentURL: URL
    public var originalFileName: String
    public var newFileName: String
    public var deviceID: UInt64?
    public var inodeID: UInt64?
    public var namingStyle: ScreenshotNamingStyle
    public var source: ScreenshotRenameSource
    public var status: ScreenshotRenameStatus
    public var ocrSnippet: String?
    public var visionLabels: [String]
    public var usedAppleIntelligence: Bool
    public var originalCreationDate: Date?
    public var originalModificationDate: Date?
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        batchID: String? = nil,
        originalURL: URL,
        currentURL: URL,
        originalFileName: String,
        newFileName: String,
        deviceID: UInt64? = nil,
        inodeID: UInt64? = nil,
        namingStyle: ScreenshotNamingStyle,
        source: ScreenshotRenameSource,
        status: ScreenshotRenameStatus = .applied,
        ocrSnippet: String? = nil,
        visionLabels: [String] = [],
        usedAppleIntelligence: Bool = false,
        originalCreationDate: Date? = nil,
        originalModificationDate: Date? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.batchID = batchID
        self.originalURL = originalURL.standardizedFileURL
        self.currentURL = currentURL.standardizedFileURL
        self.originalFileName = originalFileName
        self.newFileName = newFileName
        self.deviceID = deviceID
        self.inodeID = inodeID
        self.namingStyle = namingStyle
        self.source = source
        self.status = status
        self.ocrSnippet = ocrSnippet
        self.visionLabels = visionLabels
        self.usedAppleIntelligence = usedAppleIntelligence
        self.originalCreationDate = originalCreationDate
        self.originalModificationDate = originalModificationDate
        self.createdAt = createdAt
    }
}

public struct StyleLearningExample: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var suggestedTitle: String
    public var userChosenTitle: String
    public var learnedPrefix: String?
    public var learnedSeparator: String?
    public var prefersLowercaseBody: Bool
    public var ocrKeywords: [String]
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        suggestedTitle: String,
        userChosenTitle: String,
        learnedPrefix: String? = nil,
        learnedSeparator: String? = nil,
        prefersLowercaseBody: Bool = false,
        ocrKeywords: [String] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.suggestedTitle = suggestedTitle
        self.userChosenTitle = userChosenTitle
        self.learnedPrefix = learnedPrefix
        self.learnedSeparator = learnedSeparator
        self.prefersLowercaseBody = prefersLowercaseBody
        self.ocrKeywords = ocrKeywords
        self.createdAt = createdAt
    }
}

public struct TidyUpCandidate: Equatable, Identifiable, Sendable {
    public var id: String
    public var url: URL
    public var currentFileName: String
    public var proposedTitle: String
    public var proposedFileName: String
    public var isSelected: Bool
    public var creationDate: Date?
    public var modificationDate: Date?
    public var sizeBytes: Int64
    public var ocrSnippet: String?
    public var visionLabels: [String]
    public var usedAppleIntelligence: Bool

    public init(
        id: String = UUID().uuidString,
        url: URL,
        currentFileName: String,
        proposedTitle: String,
        proposedFileName: String,
        isSelected: Bool = true,
        creationDate: Date? = nil,
        modificationDate: Date? = nil,
        sizeBytes: Int64 = 0,
        ocrSnippet: String? = nil,
        visionLabels: [String] = [],
        usedAppleIntelligence: Bool = false
    ) {
        self.id = id
        self.url = url.standardizedFileURL
        self.currentFileName = currentFileName
        self.proposedTitle = proposedTitle
        self.proposedFileName = proposedFileName
        self.isSelected = isSelected
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.sizeBytes = sizeBytes
        self.ocrSnippet = ocrSnippet
        self.visionLabels = visionLabels
        self.usedAppleIntelligence = usedAppleIntelligence
    }
}

public struct TidyUpScanSummary: Equatable, Sendable {
    public var folderURL: URL
    public var candidates: [TidyUpCandidate]
    public var skippedWellNamedCount: Int

    public init(folderURL: URL, candidates: [TidyUpCandidate], skippedWellNamedCount: Int) {
        self.folderURL = folderURL.standardizedFileURL
        self.candidates = candidates
        self.skippedWellNamedCount = skippedWellNamedCount
    }
}

public enum ScreenshotWatchEvent: Sendable {
    case renamed(ScreenshotRenameRecord)
    case learnedStyle(StyleLearningExample)
    case skipped(url: URL, reason: String)
    case failed(url: URL, error: String)
}
