import Foundation

/// Structured natural-language intent: what the user wants done, to which
/// scope, in which location. Produced by `IntentParser` (pure, testable) and
/// consumed by `PlannerAgent.makePlan(intent:...)`. Replaces the previous
/// keyword `contains/regex` OR-filter stack, whose overlapping predicates
/// (`large` vs `large files`, `downloads` vs `old downloads`) produced
/// order-dependent, untestable plans.
public struct PlanIntent: Sendable, Equatable {
    public enum Action: String, Sendable {
        case review
        case delete
        case archive
        case organize
    }

    public enum Scope: Sendable, Equatable {
        case all
        case restoreAll
        case duplicates
        case caches
        case logs
        case downloads
        case oldDownloads(days: Int)
        case oldInstallers(days: Int)
        case olderThan(days: Int)
        case largerThan(bytes: Int64)
        case pythonCaches
        case nodeModules
        case docker
        case homebrew
        case developerArtifacts
        case safeOnly
    }

    public var action: Action
    public var scopes: [Scope]
    public var excludedScopes: [Scope]

    public init(action: Action = .review, scopes: [Scope] = [.all], excludedScopes: [Scope] = []) {
        self.action = action
        self.scopes = scopes
        self.excludedScopes = excludedScopes
    }
}

/// Pure rules-based grammar for plan commands. No LLM, no regex soup:
/// one tokenizer pass, then deterministic action + scope extraction.
public enum IntentParser {
    private static let negationSeparators = [
        "but don't ", "but dont ", "but do not ", "but never ", "but keep ",
        "except for ", "except ", "without ", "excluding ", "exclude ", "unless ", "skip "
    ]

    public static func parse(_ command: String) -> PlanIntent {
        let lowered = command.lowercased()
        let (positiveText, negatedTexts) = splitNegations(in: lowered)
        let positiveWords = tokenizedWords(positiveText)

        var action: PlanIntent.Action = .review
        if !startsWithLeadingNegation(positiveText) {
            if positiveWords.contains("archive") {
                action = .archive
            } else if !positiveWords.isDisjoint(with: ["delete", "trash", "remove"]) {
                action = .delete
            } else if !positiveWords.isDisjoint(with: ["organize", "sort"]) {
                action = .organize
            }
        }

        var scopes: [PlanIntent.Scope] = []
        let wantsRestore = action == .review
            && (positiveWords.contains("everything")
                || positiveText.contains("all actions")
                || positiveText.contains("show all")
                || positiveText.contains("restore all")
                || !positiveWords.isDisjoint(with: ["undo", "reset"])
                || (positiveWords.contains("full") && !positiveWords.isDisjoint(with: ["show", "restore", "reset"])))
        if wantsRestore {
            scopes.append(.restoreAll)
        }

        if startsWithLeadingNegation(positiveText) {
            let excluded = extractScopes(from: positiveText)
            let extraExcluded = negatedTexts.flatMap { extractScopes(from: $0) }
            return PlanIntent(
                action: action,
                scopes: scopes.isEmpty ? [.all] : scopes,
                excludedScopes: deduplicatedScopes(excluded + extraExcluded)
            )
        }

        scopes.append(contentsOf: extractScopes(from: positiveText))
        let excludedScopes = deduplicatedScopes(negatedTexts.flatMap { extractScopes(from: $0) })
        if scopes.isEmpty {
            scopes = [.all]
        }
        return PlanIntent(action: action, scopes: scopes, excludedScopes: excludedScopes)
    }

    private static func startsWithLeadingNegation(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = ["don't ", "dont ", "do not ", "never ", "keep ", "skip ", "exclude ", "excluding "]
        return prefixes.contains { trimmed.hasPrefix($0) }
    }

    private static func splitNegations(in text: String) -> (positive: String, negated: [String]) {
        var remaining = text
        var positiveParts: [String] = []
        var negatedParts: [String] = []

        while !remaining.isEmpty {
            var earliest: (range: Range<String.Index>, marker: String)?
            for sep in negationSeparators {
                if let found = remaining.range(of: sep),
                   earliest.map({ found.lowerBound < $0.range.lowerBound }) ?? true {
                    earliest = (found, sep)
                }
            }
            guard let match = earliest else {
                positiveParts.append(remaining)
                break
            }
            let prefix = String(remaining[..<match.range.lowerBound])
            if !prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                positiveParts.append(prefix)
            }
            remaining = String(remaining[match.range.upperBound...])
            if let comma = remaining.firstIndex(where: { $0 == "," || $0 == ";" }) {
                negatedParts.append(String(remaining[..<comma]))
                remaining = String(remaining[remaining.index(after: comma)...])
            } else {
                negatedParts.append(remaining)
                break
            }
        }
        return (positiveParts.joined(separator: " "), negatedParts)
    }

    private static func tokenizedWords(_ text: String) -> Set<String> {
        Set(text.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
    }

    private static func extractScopes(from text: String) -> [PlanIntent.Scope] {
        let words = tokenizedWords(text)
        var scopes: [PlanIntent.Scope] = []
        if words.contains("duplicate") || words.contains("duplicates") {
            scopes.append(.duplicates)
        }
        if words.contains("python") || words.contains("pycache") {
            scopes.append(.pythonCaches)
        }
        if words.contains("node") || words.contains("npm") || text.contains("node_modules") {
            scopes.append(.nodeModules)
        }
        if words.contains("docker") {
            scopes.append(.docker)
        }
        if words.contains("brew") || words.contains("homebrew") {
            scopes.append(.homebrew)
        }
        if words.contains("cache") || words.contains("caches") || words.contains("temporary") || words.contains("temp") {
            scopes.append(.caches)
        }
        if words.contains("log") || words.contains("logs") {
            scopes.append(.logs)
        }
        if let days = olderThanDays(in: text) {
            scopes.append(.olderThan(days: days))
        } else if words.contains("old") {
            if words.contains("download") || words.contains("downloads") {
                scopes.append(.oldDownloads(days: 30))
            }
            if words.contains("installer") || words.contains("installers") {
                scopes.append(.oldInstallers(days: 30))
            }
        }
        if !words.isDisjoint(with: ["download", "downloads"]),
           !scopes.contains(where: { if case .oldDownloads = $0 { return true }; return false }) {
            scopes.append(.downloads)
        }
        if words.contains("big") || words.contains("large") {
            scopes.append(.largerThan(bytes: text.contains("file") || text.contains("files") ? 1_000_000_000 : 100_000_000))
        }
        if !words.isDisjoint(with: ["project", "projects", "developer", "dev"]) {
            scopes.append(.developerArtifacts)
        }
        if words.contains("safe") || words.contains("conservative") {
            scopes.append(.safeOnly)
        }
        return scopes
    }

    private static func deduplicatedScopes(_ scopes: [PlanIntent.Scope]) -> [PlanIntent.Scope] {
        var unique: [PlanIntent.Scope] = []
        for scope in scopes where !unique.contains(scope) {
            unique.append(scope)
        }
        return unique
    }

    private static func olderThanDays(in lowered: String) -> Int? {
        guard lowered.contains("older than") || lowered.contains("old files") || lowered.contains("older") else {
            return nil
        }
        if let range = lowered.range(of: #"(\d+)\s*days?"#, options: .regularExpression),
           let days = Int(lowered[range].filter(\.isNumber)) {
            return days
        }
        return lowered.contains("older than") || lowered.contains("old files") ? 30 : nil
    }
}
