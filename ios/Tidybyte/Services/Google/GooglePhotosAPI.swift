import Foundation

/// One item the user picked in the Google Photos Picker.
struct CloudMediaItem: Identifiable, Sendable, Equatable {
    enum Kind: String, Sendable { case photo = "PHOTO", video = "VIDEO" }

    let id: String
    let kind: Kind
    let createTime: Date?
    let filename: String
    let mimeType: String
    let width: Int
    let height: Int
    /// Download base. Valid for about 60 minutes after the pick; needs the
    /// OAuth bearer token on every request.
    let baseUrl: String
    /// Bytes from a HEAD request; nil when Google did not report a length.
    var fileSize: Int64?

    /// A JPEG of at most `size` pixels on the longest edge.
    func thumbnailURL(size: Int) -> URL? { URL(string: "\(baseUrl)=w\(size)-h\(size)") }
    /// The original bytes (`=d` photo, `=dv` video).
    var originalURL: URL? { URL(string: baseUrl + (kind == .video ? "=dv" : "=d")) }
}

/// Google account storage. Google reports Drive usage on its own; Photos and
/// Gmail share the remainder, so they are shown together.
struct GoogleStorageQuota: Sendable, Equatable {
    /// nil for unlimited plans.
    let limit: Int64?
    let usage: Int64
    let usageInDrive: Int64
    let usageInDriveTrash: Int64

    var photosAndGmail: Int64 { max(0, usage - usageInDrive - usageInDriveTrash) }
    var fractionUsed: Double {
        guard let limit, limit > 0 else { return 0 }
        return min(1, Double(usage) / Double(limit))
    }
}

/// Photos Picker API (photospicker.googleapis.com) and Drive `about`.
/// Every call reads through the signed-in user's token; nothing goes to a
/// TidyByte server.
@MainActor
struct GooglePhotosAPI {
    var auth: GoogleAuthService = .shared
    var urlSession: URLSession = .shared

    struct PickerSession: Decodable, Sendable {
        struct Polling: Decodable, Sendable {
            let pollInterval: String?
            let timeoutIn: String?
        }
        let id: String
        let pickerUri: String?
        let pollingConfig: Polling?
        let mediaItemsSet: Bool?
    }

    func createSession() async throws -> PickerSession {
        try await decode(PickerSession.self, request("https://photospicker.googleapis.com/v1/sessions", method: "POST", body: Data("{}".utf8)))
    }

    func session(id: String) async throws -> PickerSession {
        try await decode(PickerSession.self, request("https://photospicker.googleapis.com/v1/sessions/\(id)"))
    }

    func deleteSession(id: String) async {
        _ = try? await send(request("https://photospicker.googleapis.com/v1/sessions/\(id)", method: "DELETE"))
    }

    /// All picked items, across pages.
    func mediaItems(sessionId: String) async throws -> [CloudMediaItem] {
        var items: [CloudMediaItem] = []
        var pageToken: String?
        repeat {
            var components = URLComponents(string: "https://photospicker.googleapis.com/v1/mediaItems")!
            components.queryItems = [URLQueryItem(name: "sessionId", value: sessionId), URLQueryItem(name: "pageSize", value: "100")]
                + (pageToken.map { [URLQueryItem(name: "pageToken", value: $0)] } ?? [])
            // `+` and `/` in page tokens must be escaped; URLComponents leaves `+` alone.
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
            let page = try await decode(MediaItemsPage.self, request(components.string ?? ""))
            items += page.mediaItems?.compactMap(\.cloudItem) ?? []
            pageToken = page.nextPageToken
        } while pageToken != nil
        return items
    }

    func storageQuota() async throws -> GoogleStorageQuota {
        let about = try await decode(About.self, request("https://www.googleapis.com/drive/v3/about?fields=storageQuota"))
        return about.storageQuota.quota
    }

    /// Size in bytes of the original file, from a HEAD request.
    func fileSize(of item: CloudMediaItem) async -> Int64? {
        guard let url = item.originalURL,
              var request = try? await authorized(URLRequest(url: url)) else { return nil }
        request.httpMethod = "HEAD"
        guard let (_, response) = try? await urlSession.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.expectedContentLength > 0 else { return nil }
        return http.expectedContentLength
    }

    func thumbnailData(of item: CloudMediaItem, size: Int) async throws -> Data {
        guard let url = item.thumbnailURL(size: size) else { throw GoogleAuthError.failed(L10n.string("Bad image URL.")) }
        return try await send(authorized(URLRequest(url: url)))
    }

    // MARK: - Transport

    private func request(_ url: String, method: String = "GET", body: Data? = nil) async throws -> URLRequest {
        guard let url = URL(string: url) else { throw GoogleAuthError.failed("Bad URL.") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return try await authorized(request)
    }

    private func authorized(_ request: URLRequest) async throws -> URLRequest {
        var request = request
        request.setValue("Bearer \(try await auth.accessToken())", forHTTPHeaderField: "Authorization")
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await urlSession.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw GoogleAuthError.http(status) }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, _ request: URLRequest) async throws -> T {
        try JSONDecoder().decode(T.self, from: await send(request))
    }
}

// MARK: - Wire formats (internal so tests can decode fixtures)

struct MediaItemsPage: Decodable {
    struct Item: Decodable {
        struct File: Decodable {
            struct Metadata: Decodable {
                let width: Int?
                let height: Int?
            }
            let baseUrl: String?
            let mimeType: String?
            let filename: String?
            let mediaFileMetadata: Metadata?
        }
        let id: String
        let createTime: String?
        let type: String?
        let mediaFile: File?

        var cloudItem: CloudMediaItem? {
            guard let file = mediaFile, let baseUrl = file.baseUrl else { return nil }
            return CloudMediaItem(
                id: id,
                kind: CloudMediaItem.Kind(rawValue: type ?? "") ?? .photo,
                createTime: createTime.flatMap(Self.parseDate),
                filename: file.filename ?? "",
                mimeType: file.mimeType ?? "",
                width: file.mediaFileMetadata?.width ?? 0,
                height: file.mediaFileMetadata?.height ?? 0,
                baseUrl: baseUrl,
                fileSize: nil
            )
        }

        static func parseDate(_ string: String) -> Date? {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: string) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: string)
        }
    }
    let mediaItems: [Item]?
    let nextPageToken: String?
}

struct About: Decodable {
    struct Quota: Decodable {
        let limit: String?
        let usage: String?
        let usageInDrive: String?
        let usageInDriveTrash: String?

        var quota: GoogleStorageQuota {
            GoogleStorageQuota(
                limit: limit.flatMap { Int64($0) },
                usage: usage.flatMap { Int64($0) } ?? 0,
                usageInDrive: usageInDrive.flatMap { Int64($0) } ?? 0,
                usageInDriveTrash: usageInDriveTrash.flatMap { Int64($0) } ?? 0
            )
        }
    }
    let storageQuota: Quota
}

extension GooglePhotosAPI.PickerSession {
    /// "5s" / "1.5s" → seconds. Google sends protobuf Duration strings.
    static func seconds(_ duration: String?) -> Double? {
        guard let duration, duration.hasSuffix("s") else { return nil }
        return Double(duration.dropLast())
    }
}
