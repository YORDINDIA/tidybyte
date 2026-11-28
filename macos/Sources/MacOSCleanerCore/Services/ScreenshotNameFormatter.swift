import Foundation

/// Formats generated screenshot titles into a chosen `ScreenshotNamingStyle`,
/// sanitizes filesystem characters, and resolves name collisions safely.
public enum ScreenshotNameFormatter {
    private static let maxStemLength = 72
    private static let smallTitleWords: Set<String> = [
        "a", "an", "and", "as", "at", "but", "by", "for", "from", "in", "into",
        "nor", "of", "on", "or", "over", "per", "the", "to", "via", "with"
    ]

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    public static func formatTitle(
        _ rawTitle: String,
        style: ScreenshotNamingStyle,
        date: Date? = nil,
        learnedPrefix: String? = nil,
        learnedSeparator: String? = nil,
        prefersLowercaseBody: Bool = false
    ) -> String {
        let cleaned = sanitizeRawTitle(rawTitle)
        let baseTitle = cleaned.isEmpty ? L10n.string("Captured Screenshot") : cleaned

        // Preserve user's explicit learned prefix + separator (e.g., "Trip LIS · flight out")
        if let prefix = learnedPrefix?.trimmingCharacters(in: .whitespacesAndNewlines),
           !prefix.isEmpty {
            let separator = learnedSeparator ?? " · "
            let body = stripLeadingPrefix(baseTitle, prefix: prefix)
            let formattedBody: String
            if prefersLowercaseBody && style != .lowercaseDashes {
                formattedBody = body.lowercased()
            } else {
                formattedBody = formatBody(body, style: style == .dateFirst ? .titleCase : style)
            }
            let combined = "\(prefix)\(separator)\(formattedBody)"
            if style == .dateFirst, let date {
                return truncate("\(dateFormatter.string(from: date)) \(combined)", style: style)
            }
            return truncate(combined, style: style)
        }

        let formattedBody = formatBody(baseTitle, style: style)
        switch style {
        case .titleCase, .sentenceCase, .lowercaseDashes:
            return truncate(formattedBody, style: style)
        case .dateFirst:
            let stamp = dateFormatter.string(from: date ?? Date())
            return truncate("\(stamp) \(formattedBody)", style: style)
        }
    }

    public static func fileName(
        fromFormattedTitle title: String,
        originalExtension ext: String
    ) -> String {
        let sanitized = sanitizeFileSystemCharacters(title)
        let stem = sanitized.isEmpty ? L10n.string("Captured Screenshot") : sanitized
        let cleanExt = ext.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return cleanExt.isEmpty ? stem : "\(stem).\(cleanExt)"
    }

    public static func collisionFreeURL(
        forFileName fileName: String,
        in directory: URL,
        excluding sourceURL: URL? = nil,
        style: ScreenshotNamingStyle = .titleCase,
        fileManager: FileManager = .default
    ) -> URL {
        let standardizedSource = sourceURL?.standardizedFileURL.path.lowercased()
        let initial = directory.appendingPathComponent(fileName, isDirectory: false)
        if !existsOtherThanSource(at: initial, excludedLowerPath: standardizedSource, fileManager: fileManager) {
            return initial
        }

        let stem = initial.deletingPathExtension().lastPathComponent
        let ext = initial.pathExtension
        let joiner = style == .lowercaseDashes ? "-" : " "
        for counter in 2...999 {
            let candidateName = ext.isEmpty
                ? "\(stem)\(joiner)\(counter)"
                : "\(stem)\(joiner)\(counter).\(ext)"
            let candidate = directory.appendingPathComponent(candidateName, isDirectory: false)
            if !existsOtherThanSource(at: candidate, excludedLowerPath: standardizedSource, fileManager: fileManager) {
                return candidate
            }
        }
        let fallbackSuffix = UUID().uuidString.prefix(6)
        let fallbackName = ext.isEmpty ? "\(stem)-\(fallbackSuffix)" : "\(stem)-\(fallbackSuffix).\(ext)"
        return directory.appendingPathComponent(fallbackName, isDirectory: false)
    }

    private static func existsOtherThanSource(
        at candidate: URL,
        excludedLowerPath: String?,
        fileManager: FileManager
    ) -> Bool {
        if let excludedLowerPath, candidate.standardizedFileURL.path.lowercased() == excludedLowerPath {
            return false
        }
        return fileManager.fileExists(atPath: candidate.path)
    }

    public static func sanitizeRawTitle(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
        for ext in VagueFilenameDetector.supportedImageExtensions {
            let suffix = ".\(ext)"
            if text.lowercased().hasSuffix(suffix) {
                text = String(text.dropLast(suffix.count))
                break
            }
        }
        text = sanitizeFileSystemCharacters(text)
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: ".-_ "))
        return text
    }

    private static func sanitizeFileSystemCharacters(_ text: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\\\0\n\r\t*?\"<>|")
        let parts = text.components(separatedBy: forbidden)
        return parts.joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripLeadingPrefix(_ title: String, prefix: String) -> String {
        let loweredTitle = title.lowercased()
        let loweredPrefix = prefix.lowercased()
        guard loweredTitle.hasPrefix(loweredPrefix) else { return title }
        let remainder = title.dropFirst(prefix.count)
            .trimmingCharacters(in: CharacterSet(charactersIn: " ·-—:/"))
        return remainder.isEmpty ? title : remainder
    }

    private static func formatBody(_ body: String, style: ScreenshotNamingStyle) -> String {
        let tokens = body.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return L10n.string("Captured Screenshot") }

        switch style {
        case .titleCase, .dateFirst:
            return tokens.enumerated().map { index, token in
                formatTitleToken(token, isEdgeWord: index == 0 || index == tokens.count - 1)
            }.joined(separator: " ")

        case .sentenceCase:
            return tokens.enumerated().map { index, token in
                if index == 0 {
                    return capitalizeFirstPreservingCamelCase(token)
                }
                return preservesUppercaseToken(token) ? token : token.lowercased()
            }.joined(separator: " ")

        case .lowercaseDashes:
            let joined = tokens.joined(separator: "-")
                .lowercased()
                .replacingOccurrences(of: #"[^a-z0-9\p{L}\p{N}-]+"#, with: "-", options: .regularExpression)
                .replacingOccurrences(of: #"-{2,}"#, with: "-", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            return joined.isEmpty ? "captured-screenshot" : joined
        }
    }

    private static func formatTitleToken(_ token: String, isEdgeWord: Bool) -> String {
        if preservesUppercaseToken(token) || hasInternalCamelCase(token) {
            return token
        }
        let lowered = token.lowercased()
        if !isEdgeWord, smallTitleWords.contains(lowered) {
            return lowered
        }
        return capitalizeFirstPreservingCamelCase(lowered)
    }

    private static func preservesUppercaseToken(_ token: String) -> Bool {
        let letters = token.filter(\.isLetter)
        return letters.count >= 2 && letters.count <= 5 && letters.allSatisfy(\.isUppercase)
    }

    private static func hasInternalCamelCase(_ token: String) -> Bool {
        guard token.count >= 3 else { return false }
        return token.dropFirst().contains(where: \.isUppercase) && token.contains(where: \.isLowercase)
    }

    private static func capitalizeFirstPreservingCamelCase(_ token: String) -> String {
        guard let first = token.first else { return token }
        return String(first).uppercased() + token.dropFirst()
    }

    private static func truncate(_ value: String, style: ScreenshotNamingStyle) -> String {
        guard value.count > maxStemLength else { return value }
        let prefix = String(value.prefix(maxStemLength))
        let separator: Character = style == .lowercaseDashes ? "-" : " "
        if let lastBoundary = prefix.lastIndex(of: separator),
           prefix.distance(from: prefix.startIndex, to: lastBoundary) > 20 {
            return String(prefix[..<lastBoundary])
        }
        return prefix.trimmingCharacters(in: CharacterSet(charactersIn: " -"))
    }
}
