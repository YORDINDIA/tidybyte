import Foundation

/// URLs used by widget taps and parsed by the app.
enum WidgetLinks {
    static let storage = URL(string: "tidybyte://storage")!
    static let screenshots = URL(string: "tidybyte://cleanup/screenshots")!
    static let largeFiles = URL(string: "tidybyte://cleanup/largeFiles")!
}
