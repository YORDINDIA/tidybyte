import Foundation

/// Shared safe-JSON pipeline for the surfaces that serialize readings (the
/// MCP server and the `tidybyte monitor` CLI).
///
/// JSONSerialization raises Objective-C exceptions for invalid payloads —
/// NaN or infinity doubles, non-property-list values — and `try?` cannot
/// catch those: one non-finite monitor reading aborted the whole server
/// (see the crash reports). Sanitize first, then validate before serializing.
public enum JSONSanitizing {
    /// Replaces anything JSON cannot represent: non-finite doubles become 0
    /// (a dropped reading, not a crash), unknown values become descriptions.
    public static func sanitized(_ value: Any) -> Any {
        switch value {
        case let bool as Bool: return bool
        case let int as Int: return int
        case let int64 as Int64: return int64
        case let double as Double: return double.isFinite ? double : 0
        case let string as String: return string
        case let array as [Any]: return array.map { sanitized($0) }
        case let dictionary as [String: Any]: return dictionary.mapValues { sanitized($0) }
        default: return String(describing: value)
        }
    }

    /// Sanitizes, validates, then serializes. Returns nil when the payload
    /// still is not valid JSON.
    public static func data(_ value: Any, options: JSONSerialization.WritingOptions = []) -> Data? {
        let safe = sanitized(value)
        guard JSONSerialization.isValidJSONObject(safe) else {
            return nil
        }
        return try? JSONSerialization.data(withJSONObject: safe, options: options)
    }
}
