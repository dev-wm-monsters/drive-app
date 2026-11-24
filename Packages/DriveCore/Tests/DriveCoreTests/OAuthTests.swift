import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import DriveCore

final class OAuthTests: XCTestCase {
    static func idToken(email: String) -> String {
        let header = Hashing.base64URL(Data(#"{"alg":"RS256","typ":"JWT"}"#.utf8))
        let payload = Hashing.base64URL(Data(#"{"iss":"https://accounts.google.com","email":"\#(email)","email_verified":true}"#.utf8))
        return "\(header).\(payload).signature"
    }

    func makeOAuth(secret: String? = nil, transport: FakeTransport, clock: TestClock = TestClock()) -> OAuthClient {
        let config = DriveConfig(
            clientID: "cid.apps.googleusercontent.com",
            clientSecret: secret,
            redirectURI: URL(string: "com.googleusercontent.apps.cid:/oauth2redirect")!,
            root: .sharedDriveNamed("WakeupMonster")
        )
        return OAuthClient(config: config, transport: transport, now: { clock.now })
    }

    func testAuthorizationURL() throws {
        let oauth = makeOAuth(transport: FakeTransport())
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        let url = oauth.authorizationURL(pkce: pkce, state: "st/ate+1")
        let c = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(c.scheme, "https")
        XCTAssertEqual(c.host, "accounts.google.com")
        XCTAssertEqual(c.path, "/o/oauth2/v2/auth")
        var q: [String: String] = [:]
        for item in c.queryItems ?? [] { q[item.name] = item.value }
        XCTAssertEqual(q, [
            "client_id": "cid.apps.googleusercontent.com",
            "redirect_uri": "com.googleusercontent.apps.cid:/oauth2redirect",
            "response_type": "code",
            "scope": "https://www.googleapis.com/auth/drive openid email",
            "state": "st/ate+1",
            "code_challenge": "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
            "code_challenge_method": "S256",
            "access_type": "offline",
            "prompt": "consent",
        ])
        // Strict encoding: '+', '/', ':' and spaces are percent-encoded.
        XCTAssertTrue(url.absoluteString.contains("state=st%2Fate%2B1"))
        XCTAssertTrue(url.absoluteString.contains("scope=https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fdrive%20openid%20email"))
    }

    func testExchangeWithoutSecret() async throws {
        let t = FakeTransport()
        let clock = TestClock()
        t.on(isToken, .json(200, """
        {"access_token":"at","expires_in":3599,"refresh_token":"rt","id_token":"\(Self.idToken(email: "a@wakeupmonster.com"))","token_type":"Bearer"}
        """))
        let oauth = makeOAuth(transport: t, clock: clock)
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        let tokens = try await oauth.exchange(code: "4/code+x", pkce: pkce)
        XCTAssertEqual(tokens, OAuthTokens(accessToken: "at", refreshToken: "rt", expiresAt: clock.now.addingTimeInterval(3599), email: "a@wakeupmonster.com"))
        let r = try XCTUnwrap(t.requests.first)
        XCTAssertEqual(r.url?.absoluteString, "https://oauth2.googleapis.com/token")
        XCTAssertEqual(r.httpMethod, "POST")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        XCTAssertEqual(formBody(r), [
            "grant_type": "authorization_code",
            "code": "4/code+x",
            "redirect_uri": "com.googleusercontent.apps.cid:/oauth2redirect",
            "client_id": "cid.apps.googleusercontent.com",
            "code_verifier": "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk",
        ])
    }

    func testExchangeWithSecret() async throws {
        let t = FakeTransport()
        t.on(isToken, .json(200, #"{"access_token":"at","expires_in":3599,"refresh_token":"rt"}"#))
        let oauth = makeOAuth(secret: "desktop-secret", transport: t)
        let tokens = try await oauth.exchange(code: "c", pkce: PKCE.generate())
        XCTAssertNil(tokens.email)
        XCTAssertEqual(formBody(t.requests[0])["client_secret"], "desktop-secret")
    }

    func testExchangeInvalidGrant() async {
        let t = FakeTransport()
        t.on(isToken, .json(400, #"{"error":"invalid_grant","error_description":"Bad Request"}"#))
        await expectError(.needsLogin) { try await self.makeOAuth(transport: t).exchange(code: "c", pkce: PKCE.generate()) }
    }

    func testTokenEndpointErrors() async {
        let t = FakeTransport()
        t.on(isToken,
             .json(401, #"{"error":"invalid_client"}"#),
             .status(503),
             .failure(URLError(.notConnectedToInternet)))
        let oauth = makeOAuth(transport: t)
        let tokens = OAuthTokens(accessToken: "a", refreshToken: "r", expiresAt: Date(), email: nil)
        await expectError(.unauthorized) { try await oauth.refresh(tokens) }
        await expectError(.server(503)) { try await oauth.refresh(tokens) }
        await expectError(.network("URLError \(URLError.Code.notConnectedToInternet.rawValue)")) { try await oauth.refresh(tokens) }
    }

    func testRefreshKeepsRefreshTokenAndEmailWhenOmitted() async throws {
        let t = FakeTransport()
        let clock = TestClock()
        t.on(isToken, .json(200, #"{"access_token":"new","expires_in":100}"#))
        let oauth = makeOAuth(transport: t, clock: clock)
        let old = OAuthTokens(accessToken: "old", refreshToken: "rt-keep", expiresAt: clock.now, email: "me@x.com")
        let new = try await oauth.refresh(old)
        XCTAssertEqual(new, OAuthTokens(accessToken: "new", refreshToken: "rt-keep", expiresAt: clock.now.addingTimeInterval(100), email: "me@x.com"))
        XCTAssertEqual(formBody(t.requests[0]), [
            "grant_type": "refresh_token",
            "refresh_token": "rt-keep",
            "client_id": "cid.apps.googleusercontent.com",
        ])
    }

    func testRefreshReplacesRotatedRefreshToken() async throws {
        let t = FakeTransport()
        t.on(isToken, .json(200, #"{"access_token":"new","expires_in":100,"refresh_token":"rt-new"}"#))
        let new = try await makeOAuth(transport: t).refresh(OAuthTokens(accessToken: "o", refreshToken: "rt-old", expiresAt: Date(), email: nil))
        XCTAssertEqual(new.refreshToken, "rt-new")
    }

    func testRefreshInvalidGrantAndMissingRefreshToken() async {
        let t = FakeTransport()
        t.on(isToken, .json(400, #"{"error":"invalid_grant"}"#))
        let oauth = makeOAuth(transport: t)
        await expectError(.needsLogin) { try await oauth.refresh(OAuthTokens(accessToken: "o", refreshToken: "r", expiresAt: Date(), email: nil)) }
        await expectError(.needsLogin) { try await oauth.refresh(OAuthTokens(accessToken: "o", refreshToken: nil, expiresAt: Date(), email: nil)) }
        XCTAssertEqual(t.requests.count, 1)
    }

    func testEmailFromIDToken() {
        XCTAssertEqual(OAuthClient.email(fromIDToken: Self.idToken(email: "x@y.z")), "x@y.z")
        XCTAssertNil(OAuthClient.email(fromIDToken: "garbage"))
        XCTAssertNil(OAuthClient.email(fromIDToken: "a.!!!.c"))
    }

    // MARK: - AuthSession

    func testAccessTokenFreshDoesNotRefresh() async throws {
        let h = Harness()
        let token = try await h.auth.accessToken()
        XCTAssertEqual(token, "at-1")
        XCTAssertTrue(h.transport.requests.isEmpty)
        let signedIn = await h.auth.isSignedIn
        XCTAssertTrue(signedIn)
    }

    func testAccessTokenRefreshesWithin60Seconds() async throws {
        let h = Harness()
        h.scriptRefreshes()
        h.clock.advance(3600 - 61)
        let t1 = try await h.auth.accessToken()
        XCTAssertEqual(t1, "at-1")
        XCTAssertEqual(h.transport.requests.count, 0)
        h.clock.advance(2) // 59 s left
        let t2 = try await h.auth.accessToken()
        XCTAssertEqual(t2, "at-2")
        XCTAssertEqual(h.transport.requests.count, 1)
        XCTAssertEqual(try h.store.load()?.accessToken, "at-2")
        XCTAssertEqual(try h.store.load()?.refreshToken, "rt-1")
    }

    func testConcurrentAccessTokenCoalescesIntoOneRefresh() async throws {
        let h = Harness()
        var reply = Reply.json(200, #"{"access_token":"at-2","expires_in":3599}"#)
        reply.delay = .milliseconds(100)
        h.transport.on(isToken, reply)
        h.clock.advance(3600)
        let auth = h.auth
        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<20 { group.addTask { try await auth.accessToken() } }
            var out: [String] = []
            for try await t in group { out.append(t) }
            return out
        }
        XCTAssertEqual(tokens.count, 20)
        XCTAssertTrue(tokens.allSatisfy { $0 == "at-2" })
        XCTAssertEqual(h.transport.requests(matching: isToken).count, 1)
    }

    func testRefreshInvalidGrantSignsOut() async throws {
        let h = Harness()
        h.transport.on(isToken, .json(400, #"{"error":"invalid_grant"}"#))
        h.clock.advance(3600)
        await expectError(.needsLogin) { try await h.auth.accessToken() }
        let signedIn = await h.auth.isSignedIn
        XCTAssertFalse(signedIn)
        XCTAssertNil(try h.store.load())
    }

    func testRefreshPicksUpTokensSavedByOtherProcess() async throws {
        let h = Harness()
        _ = try await h.auth.accessToken() // cache at-1
        h.clock.advance(3600)
        try h.store.save(OAuthTokens(accessToken: "at-other", refreshToken: "rt-1", expiresAt: h.clock.now.addingTimeInterval(3600), email: nil))
        let t = try await h.auth.accessToken()
        XCTAssertEqual(t, "at-other")
        XCTAssertTrue(h.transport.requests.isEmpty)
    }

    func testSignedOutNeedsLoginAndSignInFlow() async throws {
        let h = Harness(signedIn: false)
        await expectError(.needsLogin) { try await h.auth.accessToken() }
        try await h.auth.signIn(OAuthTokens(accessToken: "fresh", refreshToken: "r", expiresAt: h.clock.now.addingTimeInterval(3600), email: "e@x"))
        let token = try await h.auth.accessToken()
        XCTAssertEqual(token, "fresh")
        let email = await h.auth.email
        XCTAssertEqual(email, "e@x")
        await h.auth.signOut()
        let signedIn = await h.auth.isSignedIn
        XCTAssertFalse(signedIn)
        XCTAssertNil(try h.store.load())
    }

    // MARK: - Config

    func testConfigFromInfoDictionary() throws {
        let redirect = URL(string: "rev:/oauth2redirect")!
        let base: [String: Any] = [
            "GoogleClientID": "cid",
            "GoogleReversedClientID": "rev",
            "DriveRootSharedDriveName": "WakeupMonster",
            "DriveRootFolderID": "",
        ]
        let c = try DriveConfig.fromInfoDictionary(base, redirectURI: redirect)
        XCTAssertEqual(c.clientID, "cid")
        XCTAssertNil(c.clientSecret)
        XCTAssertEqual(c.root, .sharedDriveNamed("WakeupMonster"))
        XCTAssertEqual(c.scopes, ["https://www.googleapis.com/auth/drive", "openid", "email"])
        XCTAssertEqual(c.pollInterval, .seconds(30))
        XCTAssertEqual(c.redirectURI, redirect)

        var folder = base
        folder["DriveRootFolderID"] = " 1AbCfolder "
        XCTAssertEqual(try DriveConfig.fromInfoDictionary(folder, redirectURI: redirect).root, .folderID("1AbCfolder"))

        var noClient = base
        noClient["GoogleClientID"] = ""
        XCTAssertThrowsError(try DriveConfig.fromInfoDictionary(noClient, redirectURI: redirect)) {
            XCTAssertEqual($0 as? DriveError, .notConfigured("GoogleClientID"))
        }
        noClient["GoogleClientID"] = "$(GOOGLE_CLIENT_ID_MAC)"
        XCTAssertThrowsError(try DriveConfig.fromInfoDictionary(noClient, redirectURI: redirect)) {
            XCTAssertEqual($0 as? DriveError, .notConfigured("GoogleClientID"))
        }

        var noRoot = base
        noRoot["DriveRootSharedDriveName"] = ""
        XCTAssertThrowsError(try DriveConfig.fromInfoDictionary(noRoot, redirectURI: redirect)) {
            XCTAssertEqual($0 as? DriveError, .notConfigured("DriveRootSharedDriveName"))
        }

        XCTAssertEqual(DriveConfig.iOSClientRedirectURI(reversedClientID: "com.googleusercontent.apps.x")?.absoluteString,
                       "com.googleusercontent.apps.x:/oauth2redirect")
        XCTAssertNil(DriveConfig.iOSClientRedirectURI(reversedClientID: ""))
    }
}
