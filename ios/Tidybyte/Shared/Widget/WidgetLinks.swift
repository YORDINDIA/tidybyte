import Foundation

/// URLs used by widget taps and parsed by the app.
enum WidgetLinks {
    static let scheme = "tidybyte"
    static let storageHost = "storage"
    static let cleanupHost = "cleanup"

    static let storage = URL(string: "\(scheme)://\(storageHost)")!
    static let screenshots = URL(string: "\(scheme)://\(cleanupHost)/screenshots")!
    static let largeFiles = URL(string: "\(scheme)://\(cleanupHost)/largeFiles")!
}
