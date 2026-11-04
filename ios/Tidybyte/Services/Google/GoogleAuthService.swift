import AuthenticationServices
import CryptoKit
import Foundation
import Security
import UIKit

/// Sign in with Google for the optional Google Photos source.
///
/// OAuth 2.0 authorization code flow with PKCE for an installed (iOS) app.
/// No Google SDK: `ASWebAuthenticationSession` shows Google's own sign-in page,
/// and tokens live only in this device's Keychain. There is no TidyByte server.
/// Setup for the maintainer: `ios/docs/google-photos-oauth-setup.md`.
@MainActor
final class GoogleAuthService: NSObject {
    static let shared = GoogleAuthService()

    /// Read-only access to items the user picks, plus the account storage quota.
    static let scopes = [
        "https://www.googleapis.com/auth/photospicker.mediaitems.readonly",
        "https://www.googleapis.com/auth/drive.file"
    ]

    /// `GoogleClientID` in Info.plist, set from the `GOOGLE_IOS_CLIENT_ID`
    /// build setting. Empty means the Google source is not configured.
    nonisolated static var clientID: String {
        let value = (Bundle.main.object(forInfoDictionaryKey: "GoogleClientID") as? String ?? "")
            .trimmingCharacters(in: .whitespaces)
        return value.hasSuffix(".apps.googleusercontent.com") ? value : ""
    }

    nonisolated static var isConfigured: Bool { !clientID.isEmpty }

    /// "123-abc.apps.googleusercontent.com" → "com.googleusercontent.apps.123-abc".
    nonisolated static func redirectScheme(for clientID: String) -> String {
        let id = clientID.replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
        return "com.googleusercontent.apps.\(id)"
    }

    struct Tokens: Codable, Equatable {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date
    }

    private(set) var tokens: Tokens? = GoogleKeychain.load()
    var isSignedIn: Bool { tokens?.refreshToken != nil || (tokens.map { $0.expiresAt > .now } ?? false) }

    private var session: ASWebAuthenticationSession?

    // MARK: - Sign in

    func signIn() async throws {
        guard Self.isConfigured else { throw GoogleAuthError.notConfigured }
        let clientID = Self.clientID
        let scheme = Self.redirectScheme(for: clientID)
        let redirectURI = "\(scheme):/oauth2redirect"
        let verifier = PKCE.makeVerifier()
        let state = PKCE.makeVerifier()

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: PKCE.challenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state)
        ]

        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: components.url!, callbackURLScheme: scheme) { url, error in
                if let url { continuation.resume(returning: url) } else {
                    let cancelled = (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
                    continuation.resume(throwing: cancelled ? GoogleAuthError.cancelled : GoogleAuthError.failed(error?.localizedDescription ?? ""))
                }
            }
            session.presentationContextProvider = self
            self.session = session
            if !session.start() { continuation.resume(throwing: GoogleAuthError.failed("Could not open the sign-in page.")) }
        }
        session = nil

        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard items.first(where: { $0.name == "state" })?.value == state,
              let code = items.first(where: { $0.name == "code" })?.value else {
            throw GoogleAuthError.failed(items.first(where: { $0.name == "error" })?.value ?? "No authorization code.")
        }
        let response = try await tokenRequest([
            "code": code,
            "client_id": clientID,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code",
            "code_verifier": verifier
        ])
        store(response, keepingRefreshToken: nil)
    }

    /// A valid access token, refreshed when it is about to expire.
    func accessToken() async throws -> String {
        guard let tokens else { throw GoogleAuthError.signedOut }
        if tokens.expiresAt > Date().addingTimeInterval(60) { return tokens.accessToken }
        guard let refresh = tokens.refreshToken else { throw GoogleAuthError.signedOut }
        do {
            let response = try await tokenRequest([
                "refresh_token": refresh,
                "client_id": Self.clientID,
                "grant_type": "refresh_token"
            ])
            store(response, keepingRefreshToken: refresh)
            return self.tokens?.accessToken ?? ""
        } catch GoogleAuthError.http(400), GoogleAuthError.http(401) {
            // Revoked or expired grant: the user must sign in again.
            clearTokens()
            throw GoogleAuthError.signedOut
        }
    }

    /// Revokes the grant at Google and deletes the tokens on this device.
    func signOut() async {
        if let token = tokens?.refreshToken ?? tokens?.accessToken {
            var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.formBody(["token": token])
            _ = try? await URLSession.shared.data(for: request)
        }
        clearTokens()
    }

    // MARK: - Helpers

    private struct TokenResponse: Decodable {
        let access_token: String
        let expires_in: Double
        let refresh_token: String?
    }

    private func tokenRequest(_ fields: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formBody(fields)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw GoogleAuthError.http(status) }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    private func store(_ response: TokenResponse, keepingRefreshToken previous: String?) {
        let tokens = Tokens(
            accessToken: response.access_token,
            refreshToken: response.refresh_token ?? previous,
            expiresAt: Date().addingTimeInterval(response.expires_in)
        )
        self.tokens = tokens
        GoogleKeychain.save(tokens)
    }

    private func clearTokens() {
        tokens = nil
        GoogleKeychain.delete()
    }

    nonisolated static func formBody(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8) ?? Data()
    }
}

extension GoogleAuthService: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.keyWindow }
                .first ?? ASPresentationAnchor()
        }
    }
}

enum GoogleAuthError: LocalizedError, Equatable {
    case notConfigured
    case cancelled
    case signedOut
    case http(Int)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: L10n.string("Google Photos is not set up in this build.")
        case .cancelled: L10n.string("Sign-in cancelled.")
        case .signedOut: L10n.string("Your Google session ended. Sign in again.")
        case .http(let code): L10n.format("Google returned an error (%lld).", code)
        case .failed(let message): message
        }
    }
}

/// RFC 7636 helpers.
enum PKCE {
    static func makeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// One generic-password item holding the token JSON. This-device-only, so
/// tokens never sync to iCloud Keychain or move to a restored device.
enum GoogleKeychain {
    private static let query: [CFString: Any] = [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: "com.sakshammittal.tidybyte.google",
        kSecAttrAccount: "oauth"
    ]

    static func save(_ tokens: GoogleAuthService.Tokens) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData] = data
        item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    static func load() -> GoogleAuthService.Tokens? {
        var lookup = query
        lookup[kSecReturnData] = true
        lookup[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(GoogleAuthService.Tokens.self, from: data)
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }
}
