import Foundation

/// Shared safe-JSON pipeline for the surfaces that serialize readings (the
/// MCP server and the `tidybyte monitor` CLI).
///
/// JSONSerialization raises Objective-C exceptions for invalid payloads —
/// NaN or infinity doubles, non-property-list values — and `try?` cannot
/// catch those: one non-finite monitor reading aborted the whole server
/// (see the crash reports). Sanitize first, then validate before serializing.
public enum JSONSanitizing {
    /// Replaces anything JSON cannot represent. Non-finite numbers and nil become
    /// JSON null, so a missing reading stays visibly missing. Other unknown values
    /// become their description.
    public static func sanitized(_ value: Any) -> Any {
        if let number = sanitizedNumber(value) { return number }
        switch value {
        case let bool as Bool: return bool
        case let string as String: return string
        case is NSNull: return NSNull()
        case let array as [Any]: return array.map { sanitized($0) }
        case let dictionary as [String: Any]: return dictionary.mapValues { sanitized($0) }
        default: return isNil(value) ? NSNull() : String(describing: value)
        }
    }

    /// Integers pass through. Floating-point values pass through when finite.
    private static func sanitizedNumber(_ value: Any) -> Any? {
        switch value {
        case let int as Int: return int
        case let int64 as Int64: return int64
        case let int32 as Int32: return int32
        case let uint as UInt: return uint
        case let uint32 as UInt32: return uint32
        case let uint64 as UInt64: return uint64
        case let double as Double: return finite(double)
        case let float as Float: return finite(float)
        default: return nil
        }
    }

    private static func finite<T: BinaryFloatingPoint>(_ value: T) -> Any {
        value.isFinite ? value : NSNull()
    }

    /// True for an Optional that holds nil, whatever its wrapped type.
    private static func isNil(_ value: Any) -> Bool {
        if case Optional<Any>.none = value { return true }
        return false
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
