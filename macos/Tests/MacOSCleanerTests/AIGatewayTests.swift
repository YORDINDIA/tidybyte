import Foundation
@testable import MacOSCleanerCore
import XCTest

/// Mock URL protocol for testing AIGateway HTTP requests
final class MockURLProtocol: URLProtocol {
    // Use nonisolated(unsafe) for test-only mutable state
    nonisolated(unsafe) static var mockResponse: ((URLRequest) -> (Data, HTTPURLResponse))?
    /// Counts requests observed by the protocol, so retry tests can assert the
    /// exact attempt count (AI-06). Attempts are sequential per classify() call.
    nonisolated(unsafe) static var requestCount = 0

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let mockResponse = Self.mockResponse else {
            let error = NSError(domain: "MockURLProtocol", code: -1, userInfo: [NSLocalizedDescriptionKey: "No mock response configured"])
            client?.urlProtocol(self, didFailWithError: error)
            return
        }

        let (data, response) = mockResponse(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Test configuration for AIGateway
final class AIGatewayTests: XCTestCase {
    private var session: URLSession!
    private var keychain: KeychainStore!
    private var gateway: AIGateway!

    override func setUp() async throws {
        try await super.setUp()

        // Create mock URL session configuration
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: config)

        // Create in-memory keychain for testing. The tests exercise the REAL
        // macOS keychain (KeychainStore has no protocol seam), so make each run
        // hermetic by removing keys from both the legacy and provider-keyed
        // accounts — a leftover dev key would otherwise let the gateway reach
        // the HTTP layer and surface a 401 instead of missingAPIKey.
        let keychain = KeychainStore(inMemory: true)
        try? await keychain.deleteAPIKey()
        try? await keychain.deleteAPIKey(account: "OpenAI-compatible")
        self.keychain = keychain

        // Create gateway with the mock session — without it the gateway falls
        // back to URLSession.shared and HTTP-level tests hit the real network.
        gateway = AIGateway(keychain: keychain, session: session)
    }

    override func tearDown() async throws {
        MockURLProtocol.mockResponse = nil
        try await super.tearDown()
    }

    func testAIGatewayReturnsLocalOnlyError() async throws {
        let settings = ProviderSettings(privacyMode: .localOnly)
        let findings: [Finding] = []

        do {
            _ = try await gateway.classify(findings: findings, filesByID: [:], settings: settings)
            XCTFail("Expected localOnly error")
        } catch let error as AIGatewayError {
            guard case .localOnly = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        }
    }

    func testAIGatewayReturnsMissingAPIKeyError() async throws {
        let settings = ProviderSettings(privacyMode: .metadataOnlyAI)
        let findings: [Finding] = []

        do {
            _ = try await gateway.classify(findings: findings, filesByID: [:], settings: settings)
            XCTFail("Expected missingAPIKey error")
        } catch let error as AIGatewayError {
            guard case .missingAPIKey = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        }
    }

    func testAIGatewaySupportsSnippetsAIMode() async throws {
        // This test verifies that snippetsAI mode is accepted (not rejected)
        let settings = ProviderSettings(privacyMode: .snippetsAI)
        let findings: [Finding] = []

        // The gateway should not throw unsupportedPrivacyMode for snippetsAI
        // It will throw missingAPIKey since we haven't set an API key
        do {
            _ = try await gateway.classify(findings: findings, filesByID: [:], settings: settings)
            XCTFail("Expected missingAPIKey error")
        } catch let error as AIGatewayError {
            // This is expected - snippetsAI is now supported, but we need an API key
            guard case .missingAPIKey = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        }
    }

    func testAIGatewaySupportsVisionAIMode() async throws {
        // This test verifies that visionAI mode is accepted (not rejected)
        let settings = ProviderSettings(privacyMode: .visionAI)
        let findings: [Finding] = []

        // The gateway should not throw unsupportedPrivacyMode for visionAI
        // It will throw missingAPIKey since we haven't set an API key
        do {
            _ = try await gateway.classify(findings: findings, filesByID: [:], settings: settings)
            XCTFail("Expected missingAPIKey error")
        } catch let error as AIGatewayError {
            // This is expected - visionAI is now supported, but we need an API key
            guard case .missingAPIKey = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        }
    }

    func testAIGatewayRejectsUnsupportedPrivacyModes() async throws {
        // Every privacy mode is supported; each non-localOnly mode must fail
        // with missingAPIKey (no key in the test environment) and never a
        // mode-rejection error.
        let modes: [PrivacyMode] = [.metadataOnlyAI, .snippetsAI, .visionAI, .fullDocumentAI]

        for mode in modes {
            let settings = ProviderSettings(privacyMode: mode)
            do {
                _ = try await gateway.classify(findings: [], filesByID: [:], settings: settings)
            } catch let error as AIGatewayError {
                guard case .missingAPIKey = error else {
                    XCTFail("Mode \(mode.rawValue) should surface missingAPIKey, got \(error)")
                    return
                }
            }
        }
    }

    // MARK: - AI-06: retry with backoff

    /// A valid chat-completions envelope whose content is an empty
    /// recommendations JSON object, as the gateway expects from providers.
    private static let chatEnvelopeData = Data(
        #"""
        {"choices":[{"message":{"content":"{\"recommendations\":[]}"}}]}
        """#.utf8
    )

    private static func httpBody(status: Int, body: Data) -> (Data, HTTPURLResponse) {
        let url = URL(string: "https://api.openai.com/v1/chat/completions")
            ?? URL(fileURLWithPath: "/chat/completions")
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)
            ?? HTTPURLResponse()
        return (body, response)
    }

    /// Stores a key in the provider account the gateway reads first, so the
    /// HTTP layer (and with it the retry loop) is actually exercised.
    private func saveTestAPIKey() async throws {
        try await keychain.saveAPIKey("sk-tidybyte-test", account: "OpenAI-compatible")
    }

    func testAIGatewayRetriesTransientServerErrorThenSucceeds() async throws {
        try await saveTestAPIKey()
        let settings = ProviderSettings(privacyMode: .metadataOnlyAI)
        MockURLProtocol.requestCount = 0
        MockURLProtocol.mockResponse = { _ in
            MockURLProtocol.requestCount += 1
            if MockURLProtocol.requestCount == 1 {
                return Self.httpBody(status: 500, body: Data("server exploded".utf8))
            }
            return Self.httpBody(status: 200, body: Self.chatEnvelopeData)
        }

        let recommendations = try await gateway.classify(findings: [], filesByID: [:], settings: settings)

        XCTAssertTrue(recommendations.isEmpty)
        XCTAssertEqual(MockURLProtocol.requestCount, 2, "A single transient 500 must be retried, not fatal")
    }

    func testAIGatewayThrowsRetryLimitExhaustedAfterThreeAttempts() async throws {
        try await saveTestAPIKey()
        let settings = ProviderSettings(privacyMode: .metadataOnlyAI)
        MockURLProtocol.requestCount = 0
        MockURLProtocol.mockResponse = { _ in
            MockURLProtocol.requestCount += 1
            return Self.httpBody(status: 500, body: Data("still down".utf8))
        }

        do {
            _ = try await gateway.classify(findings: [], filesByID: [:], settings: settings)
            XCTFail("Expected retryLimitExhausted")
        } catch let error as AIGatewayError {
            guard case .retryLimitExhausted = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        }
        XCTAssertEqual(MockURLProtocol.requestCount, 3, "Exactly maxRetries attempts before giving up")
    }

    func testAIGatewayDoesNotRetryPermanentClientErrors() async throws {
        try await saveTestAPIKey()
        let settings = ProviderSettings(privacyMode: .metadataOnlyAI)
        MockURLProtocol.requestCount = 0
        MockURLProtocol.mockResponse = { _ in
            MockURLProtocol.requestCount += 1
            return Self.httpBody(status: 404, body: Data("no such model".utf8))
        }

        do {
            _ = try await gateway.classify(findings: [], filesByID: [:], settings: settings)
            XCTFail("Expected invalidResponse for HTTP 404")
        } catch let error as AIGatewayError {
            guard case .invalidResponse(let statusCode, _) = error, statusCode == 404 else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        }
        XCTAssertEqual(MockURLProtocol.requestCount, 1, "4xx (except 429) is permanent: one attempt, no retries")
    }

    func testAIGatewayDoesNotRetryMalformedResponses() async throws {
        try await saveTestAPIKey()
        let settings = ProviderSettings(privacyMode: .metadataOnlyAI)
        MockURLProtocol.requestCount = 0
        MockURLProtocol.mockResponse = { _ in
            MockURLProtocol.requestCount += 1
            return Self.httpBody(status: 200, body: Data("Here is my prose answer.".utf8))
        }

        do {
            _ = try await gateway.classify(findings: [], filesByID: [:], settings: settings)
            XCTFail("Expected malformedResponse for non-JSON content")
        } catch let error as AIGatewayError {
            guard case .malformedResponse = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        }
        XCTAssertEqual(MockURLProtocol.requestCount, 1, "Deterministic malformed output must not burn retry attempts")
    }
}
