import Foundation

/// Binary search helpers for sorted path arrays.
enum SortedPathSearch {
    /// Returns the index of the first element whose path is >= `prefix`.
    static func lowerBound(_ paths: [String], _ prefix: String) -> Int {
        var lo = 0
        var hi = paths.count
        while lo < hi {
            let mid = lo + (hi - lo) / 2
            if paths[mid] < prefix { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// Returns the index of the first element whose path is >= the character after `prefix`.
    /// Uses Swift String ordering, the same ordering the paths are sorted with.
    static func upperBound(_ paths: [String], _ prefix: String) -> Int {
        // Build the upper bound by incrementing the last Unicode scalar of the prefix.
        // This ensures correct ordering for all Unicode characters, not just ASCII.
        // The surrogate range U+D800...U+DFFF has no scalars, so it is skipped.
        // A prefix ending in U+10FFFF has no successor: every later path is >= prefix.
        let upperPrefix: String
        if let lastScalar = prefix.unicodeScalars.last {
            var next = lastScalar.value + 1
            if next == 0xD800 { next = 0xE000 }
            if let incremented = Unicode.Scalar(next) {
                upperPrefix = String(prefix.unicodeScalars.dropLast()) + String(incremented)
            } else {
                return paths.count
            }
        } else {
            upperPrefix = prefix
        }
        var lo = 0
        var hi = paths.count
        while lo < hi {
            let mid = lo + (hi - lo) / 2
            if paths[mid] < upperPrefix { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}
