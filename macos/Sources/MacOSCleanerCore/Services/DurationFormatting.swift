import Foundation

/// Presentation helper for durations, kept beside ByteFormatting so the
/// monitor CLI and the Monitor UI render one shared "2d 3h" shape.
public extension TimeInterval {
    /// Compact duration with the two most significant units, e.g. "2d 3h"
    /// or "5h 30m".
    var formattedDuration: String {
        let total = Int(self)
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        return days > 0 ? "\(days)d \(hours)h" : "\(hours)h \(minutes)m"
    }
}
