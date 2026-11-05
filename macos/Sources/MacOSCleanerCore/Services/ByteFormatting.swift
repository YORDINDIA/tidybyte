import Foundation

/// Presentation helper for byte counts. Kept in the Core module because
/// findings, plans, and services all format sizes; lives in its own file so
/// the safety-policy source stays focused on path safety.
public extension Int64 {
    var formattedByteCount: String {
        // ByteCountFormatter renders 0 as "Zero KB", which is inconsistent with
        // the "31 bytes" style it uses for other small values. Render zero
        // explicitly so all sizes share the same format.
        if self == 0 {
            return String(localized: "0 bytes", comment: "Byte count for an empty file")
        }
        return ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }

    /// A byte count per second, e.g. "2.4 MB/s", as the monitor shows rates.
    /// Zero goes through the same explicit rendering as `formattedByteCount`
    /// so the menu bar never shows "Zero KB/s".
    var formattedByteRate: String {
        formattedByteCount + "/s"
    }
}

public extension Double {
    /// Rounds a bytes-per-second rate to a whole count, then formats it.
    var formattedByteRate: String {
        Int64(self).formattedByteRate
    }
}
