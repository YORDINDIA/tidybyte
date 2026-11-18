import SwiftUI

extension Animation {
    /// Short state transition. Callers disable this when Reduce Motion is enabled.
    static var appSelection: Animation { .easeOut(duration: 0.15) }
    /// Smooth layout expand/collapse transition for inspector and drill-down views.
    static var appExpand: Animation { .easeInOut(duration: 0.2) }
}
