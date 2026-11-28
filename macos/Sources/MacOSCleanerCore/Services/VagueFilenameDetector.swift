import Darwin
import Foundation

/// Identifies vague or machine-generated image and screenshot filenames while
/// leaving already descriptive user-named files and protected files untouched.
public enum VagueFilenameDetector {
    public static let supportedImageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "tiff", "tif", "webp", "gif"
    ]

    public static var localizedScreenshotPrefixes: [String] {
        CleanerRuleEngine.localizedScreenshotPrefixes
    }

    private static let vagueCapturePrefixes: [String] = [
        "cleanshot ", "cleanshot_", "shottr ", "snagit ",
        "img_", "img-", "dsc_", "dscn", "pxl_", "mvimg_", "rpreplay_",
        "photo_", "photo-", "image (", "image-", "image_",
        "untitled", "capture_", "capture-", "pic_",
        "whatsapp image ", "telegram ", "signal-"
    ]

    private static let numericGuardedPrefixes: [String] = [
        "photo ", "capture "
    ]

    private static let exactVagueStems: Set<String> = [
        "image", "screenshot", "screen shot", "photo", "picture", "pic", "untitled", "capture", "paste", "pasted"
    ]

    private static let partialDownloadExtensions: Set<String> = [
        "tmp", "temp", "part", "download", "crdownload", "opdownload"
    ]

    private static let protectedRenameFlags: Set<RiskFlag> = [
        .sipProtectedSystemPath, .protectedDirectory, .protectedFile,
        .secretOrCertificate, .projectManifest, .sourceOrConfig,
        .codingAgentMemoryOrConfig, .insideTrash
    ]

    public static func hasScreenCaptureXattr(at url: URL) -> Bool {
        CleanerRuleEngine.hasScreenCaptureXattr(at: url)
    }

    /// True if `url` is a local, non-protected image with a vague or default capture name.
    public static func isEligibleVagueImage(
        at url: URL,
        policy: PathSafetyPolicy = PathSafetyPolicy(),
        fileManager: FileManager = .default
    ) -> Bool {
        let name = url.lastPathComponent
        guard !name.isEmpty, !name.hasPrefix(".") else { return false }
        let ext = url.pathExtension.lowercased()
        guard supportedImageExtensions.contains(ext), !partialDownloadExtensions.contains(ext) else {
            return false
        }
        guard isSafeRenameTarget(url: url, policy: policy, fileManager: fileManager) else {
            return false
        }
        return isVagueStem(url.deletingPathExtension().lastPathComponent, fullFileName: name)
    }

    /// Safety gate for renaming: refuses symlinks, directories, cloud placeholders,
    /// credential-like paths, and protected system/developer/secret paths.
    /// Allows user files even when Desktop/Documents sync with iCloud, as long
    /// as the local file is downloaded.
    public static func isSafeRenameTarget(
        url: URL,
        policy: PathSafetyPolicy = PathSafetyPolicy(),
        fileManager: FileManager = .default
    ) -> Bool {
        if (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil {
            return false
        }
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
            return false
        }
        if isCloudPlaceholder(url: url) {
            return false
        }
        if ContentExtractor.isCredentialLike(url) {
            return false
        }
        let flags = policy.riskFlags(for: url, isDirectory: false)
        return flags.isDisjoint(with: protectedRenameFlags)
    }

    public static func isCloudPlaceholder(url: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        guard let values = try? url.resourceValues(forKeys: keys),
              values.isUbiquitousItem == true else {
            return false
        }
        return values.ubiquitousItemDownloadingStatus != .current
    }

    public static func isVagueStem(_ stem: String, fullFileName: String? = nil) -> Bool {
        let trimmed = stem.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let lowered = trimmed.lowercased()
        let fullLowered = (fullFileName ?? stem).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if exactVagueStems.contains(lowered) {
            return true
        }
        let matchesLocalized = localizedScreenshotPrefixes.contains { prefix in
            fullLowered.hasPrefix(prefix) || lowered.hasPrefix(prefix.trimmingCharacters(in: .whitespaces))
        }
        if matchesLocalized {
            return isDefaultPrefixedPattern(lowered)
        }
        if vagueCapturePrefixes.contains(where: { lowered.hasPrefix($0) }) {
            return true
        }
        if numericGuardedPrefixes.contains(where: { lowered.hasPrefix($0) }) {
            return isDefaultPrefixedPattern(lowered)
        }
        if matchesTrailingCopyNumber(lowered) {
            return true
        }
        if matchesNumericOrTimestampStem(lowered) || matchesHexOrUUIDStem(lowered) {
            return true
        }
        return false
    }

    private static func isDefaultPrefixedPattern(_ lowered: String) -> Bool {
        // Matches e.g. "Screenshot", "Screenshot 1", "Screenshot_2026...", "Photo on 11-11-26..."
        exactVagueStems.contains(lowered) || lowered.contains { $0.isNumber }
    }

    private static func matchesTrailingCopyNumber(_ lowered: String) -> Bool {
        // Matches generic numbered names like "image 2", "untitled 3", "photo (1)"
        let pattern = #"^(image|untitled|photo|picture|pic|capture|screenshot|screen shot|scan)[\s_-]*(\(\d+\)|\d+)$"#
        return lowered.range(of: pattern, options: .regularExpression) != nil
    }

    private static func matchesNumericOrTimestampStem(_ lowered: String) -> Bool {
        // Pure digits, dates/timestamps like "2026-11-11 at 7.12.33 pm" or "20261111_191233"
        let stripped = lowered.replacingOccurrences(of: #"[\s._:/-]"#, with: "", options: .regularExpression)
        if !stripped.isEmpty, stripped.allSatisfy(\.isNumber) {
            return true
        }
        let dateTimePattern = #"^\d{4}[-_.]\d{2}[-_.]\d{2}(?:[\s_t@]+(?:at[\s_]+)?)?\d{1,2}[:.]\d{2}(?:[:.]\d{2})?(?:\s*(?:am|pm))?$"#
        return lowered.range(of: dateTimePattern, options: .regularExpression) != nil
    }

    private static func matchesHexOrUUIDStem(_ lowered: String) -> Bool {
        let uuidPattern = #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#
        if lowered.range(of: uuidPattern, options: .regularExpression) != nil {
            return true
        }
        return lowered.count >= 16 && lowered.allSatisfy(\.isHexDigit)
    }
}
