import XCTest
@testable import Tidybyte

// MARK: - Keychain write failure (fake backend)

@MainActor
final class GoogleKeychainTests: XCTestCase {

    /// In-memory stand-in for the Keychain. `refuseAdds` makes `SecItemAdd` fail, and
    /// `updateStatus` makes `SecItemUpdate` fail, the way a locked or full Keychain does.
    private final class FakeKeychain: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Data?
        private let refuseAdds: Bool
        var updateStatus: OSStatus?
        private(set) var addCount = 0

        init(refuseAdds: Bool, updateStatus: OSStatus? = nil) {
            self.refuseAdds = refuseAdds
            self.updateStatus = updateStatus
        }

        var backend: GoogleKeychainBackend {
            GoogleKeychainBackend(
                add: { [self] query in
                    lock.withLock {
                        addCount += 1
                        if refuseAdds { return errSecInteractionNotAllowed }
                        stored = (query as NSDictionary)[kSecValueData] as? Data
                        return errSecSuccess
                    }
                },
                delete: { [self] _ in
                    lock.withLock {
                        stored = nil
                        return errSecSuccess
                    }
                },
                copyMatching: { [self] _ in
                    lock.withLock { stored }
                },
                update: { [self] _, attributes in
                    lock.withLock {
                        if let updateStatus { return updateStatus }
                        guard stored != nil else { return errSecItemNotFound }
                        stored = (attributes as NSDictionary)[kSecValueData] as? Data
                        return errSecSuccess
                    }
                }
            )
        }
    }

    override func tearDown() {
        GoogleKeychain.backend = .system
        super.tearDown()
    }

    private func sampleTokens() -> GoogleAuthService.Tokens {
        GoogleAuthService.Tokens(
            accessToken: "access", refreshToken: "refresh",
            expiresAt: Date(timeIntervalSince1970: 2_000_000_000)
        )
    }

    private func sampleResponse() throws -> GoogleAuthService.TokenResponse {
        try JSONDecoder().decode(
            GoogleAuthService.TokenResponse.self,
            from: Data(#"{"access_token":"access","expires_in":3600,"refresh_token":"refresh"}"#.utf8)
        )
    }

    func testSaveReportsFailureWhenTheKeychainRefusesTheWrite() {
        let fake = FakeKeychain(refuseAdds: true)
        GoogleKeychain.backend = fake.backend
        XCTAssertFalse(GoogleKeychain.save(sampleTokens()))
        XCTAssertEqual(fake.addCount, 1)
    }

    func testSaveRoundTripsThroughTheKeychain() {
        let fake = FakeKeychain(refuseAdds: false)
        GoogleKeychain.backend = fake.backend
        XCTAssertTrue(GoogleKeychain.save(sampleTokens()))
        XCTAssertEqual(GoogleKeychain.load(), sampleTokens())
    }

    /// The user must not be left looking signed in when the write failed: the
    /// error is thrown, and the app holds no tokens.
    func testStoreThrowsAndHoldsNoTokensWhenTheKeychainRefuses() throws {
        let fake = FakeKeychain(refuseAdds: true)
        GoogleKeychain.backend = fake.backend
        let auth = GoogleAuthService()
        XCTAssertNil(auth.tokens)

        XCTAssertThrowsError(try auth.store(try sampleResponse(), keepingRefreshToken: nil)) { error in
            XCTAssertEqual(error as? GoogleAuthError, .keychainWriteFailed)
        }
        XCTAssertNil(auth.tokens)
        XCTAssertFalse(auth.isSignedIn)
    }

    /// A failed in-place update must leave the previous token in place. The old
    /// code deleted it first, so a failed add lost the last usable credential.
    func testFailedUpdateKeepsThePreviousToken() {
        let fake = FakeKeychain(refuseAdds: false)
        GoogleKeychain.backend = fake.backend
        XCTAssertTrue(GoogleKeychain.save(sampleTokens()))
        fake.updateStatus = errSecIO
        let next = GoogleAuthService.Tokens(
            accessToken: "next", refreshToken: "refresh",
            expiresAt: Date(timeIntervalSince1970: 2_000_000_000)
        )
        XCTAssertFalse(GoogleKeychain.save(next))
        XCTAssertEqual(GoogleKeychain.load(), sampleTokens())
    }

    func testStoreKeepsTokensWhenTheKeychainAccepts() throws {
        let fake = FakeKeychain(refuseAdds: false)
        GoogleKeychain.backend = fake.backend
        let auth = GoogleAuthService()

        try auth.store(try sampleResponse(), keepingRefreshToken: nil)
        XCTAssertEqual(auth.tokens?.accessToken, "access")
        XCTAssertEqual(auth.tokens?.refreshToken, "refresh")
        XCTAssertTrue(auth.isSignedIn)
        XCTAssertEqual(GoogleKeychain.load()?.accessToken, "access")
    }
}

// MARK: - Google pagination

final class GooglePhotosPaginationTests: XCTestCase {

    func testLastPageEndsTheListing() throws {
        var seen = Set<String>()
        XCTAssertNil(try GooglePhotosAPI.pageStep(returned: nil, seen: &seen))
        XCTAssertNil(try GooglePhotosAPI.pageStep(returned: "", seen: &seen))
    }

    func testNewTokensAreFollowed() throws {
        var seen = Set<String>()
        XCTAssertEqual(try GooglePhotosAPI.pageStep(returned: "a", seen: &seen), "a")
        XCTAssertEqual(try GooglePhotosAPI.pageStep(returned: "b", seen: &seen), "b")
    }

    /// A token that returns after a longer cycle must throw. It must not loop, and
    /// it must not end the listing quietly with a shorter result.
    func testRepeatedTokenThrowsInsteadOfEndingQuietly() throws {
        var seen = Set<String>()
        _ = try GooglePhotosAPI.pageStep(returned: "a", seen: &seen)
        _ = try GooglePhotosAPI.pageStep(returned: "b", seen: &seen)
        XCTAssertThrowsError(try GooglePhotosAPI.pageStep(returned: "a", seen: &seen)) { error in
            guard case GoogleAuthError.failed = error else {
                return XCTFail("expected a failed error, got \(error)")
            }
        }
    }
}

// MARK: - Google auth error text

@MainActor
final class GoogleAuthErrorTextTests: XCTestCase {

    /// An empty failure message left the sign-in banner blank.
    func testFailedAndKeychainErrorsAlwaysHaveText() {
        XCTAssertFalse((GoogleAuthError.failed("").errorDescription ?? "").isEmpty)
        XCTAssertFalse((GoogleAuthError.keychainWriteFailed.errorDescription ?? "").isEmpty)
        XCTAssertEqual(GoogleAuthError.failed("Boom").errorDescription, "Boom")
    }

    /// Storage failed and the revoke also failed: the user is told Google still
    /// holds the access. Storage failed and the revoke worked: the storage error.
    func testStorageFailureReportsWhetherGoogleStillHoldsTheAccess() {
        let storage = GoogleAuthError.keychainWriteFailed
        XCTAssertEqual(
            GoogleAuthService.signInStorageFailure(storage, revoked: true) as? GoogleAuthError,
            .keychainWriteFailed
        )
        XCTAssertEqual(
            GoogleAuthService.signInStorageFailure(storage, revoked: false) as? GoogleAuthError,
            .grantNotRevoked
        )
        XCTAssertFalse((GoogleAuthError.grantNotRevoked.errorDescription ?? "").isEmpty)
    }
}
