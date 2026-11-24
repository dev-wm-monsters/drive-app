import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct OAuthTokens: Sendable, Codable, Hashable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date
    public var email: String?

    public init(accessToken: String, refreshToken: String?, expiresAt: Date, email: String?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.email = email
    }
}

/// Persistent token storage (Keychain on Mac). Implementations must be thread-safe.
public protocol TokenStore: Sendable {
    func load() throws -> OAuthTokens?
    func save(_ t: OAuthTokens) throws
    func clear() throws
}

/// Process-local token store (tests, previews).
public final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: OAuthTokens?

    public init(_ tokens: OAuthTokens? = nil) {
        self.tokens = tokens
    }

    public func load() throws -> OAuthTokens? {
        lock.withLock { tokens }
    }

    public func save(_ t: OAuthTokens) throws {
        lock.withLock { tokens = t }
    }

    public func clear() throws {
        lock.withLock { tokens = nil }
    }
}

/// RFC 7636 PKCE pair, method S256.
public struct PKCE: Sendable {
    public let verifier: String
    public let challenge: String

    static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// Uses a caller-provided verifier (43–128 unreserved characters), e.g. for test vectors.
    public init(verifier: String) {
        self.verifier = verifier
        self.challenge = Hashing.sha256Base64URL(Data(verifier.utf8))
    }

    /// 64-character verifier from `SystemRandomNumberGenerator` (CSPRNG on Darwin and Linux).
    public static func generate() -> PKCE {
        PKCE(verifier: randomString(length: 64))
    }

    static func randomString(length: Int) -> String {
        var rng = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in alphabet[Int(rng.next(upperBound: UInt64(alphabet.count)))] })
    }
}

/// Google OAuth 2.0 for installed apps: authorization code + PKCE (S256) + state.
public struct OAuthClient: Sendable {
    public static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    public static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!

    public let config: DriveConfig
    let transport: any HTTPTransport
    let now: @Sendable () -> Date

    public init(config: DriveConfig, transport: any HTTPTransport) {
        self.init(config: config, transport: transport, now: { Date() })
    }

    /// `now` is injectable for tests (token expiry).
    public init(config: DriveConfig, transport: any HTTPTransport, now: @escaping @Sendable () -> Date) {
        self.config = config
        self.transport = transport
        self.now = now
    }

    /// Random `state` value for CSRF protection; compare it with the redirect's `state`.
    public static func makeState() -> String {
        PKCE.randomString(length: 32)
    }

    public func authorizationURL(pkce: PKCE, state: String) -> URL {
        let params: [(String, String)] = [
            ("client_id", config.clientID),
            ("redirect_uri", config.redirectURI.absoluteString),
            ("response_type", "code"),
            ("scope", config.scopes.joined(separator: " ")),
            ("state", state),
            ("code_challenge", pkce.challenge),
            ("code_challenge_method", "S256"),
            ("access_type", "offline"),
            ("prompt", "consent"),
        ]
        return URL(string: Self.authorizationEndpoint.absoluteString + "?" + FormEncoding.encode(params))!
    }

    public func exchange(code: String, pkce: PKCE) async throws(DriveError) -> OAuthTokens {
        var params: [(String, String)] = [
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", config.redirectURI.absoluteString),
            ("client_id", config.clientID),
            ("code_verifier", pkce.verifier),
        ]
        if let secret = config.clientSecret { params.append(("client_secret", secret)) }
        let r = try await tokenRequest(params)
        // With access_type=offline + prompt=consent Google always returns a refresh token; if it ever does not,
        // the session works until expiry and then reports .needsLogin.
        return OAuthTokens(
            accessToken: r.access_token,
            refreshToken: r.refresh_token,
            expiresAt: now().addingTimeInterval(TimeInterval(r.expires_in ?? 3600)),
            email: r.id_token.flatMap(Self.email(fromIDToken:))
        )
    }

    /// Keeps the old refresh token and email when the response omits them. `invalid_grant` → `.needsLogin`.
    public func refresh(_ t: OAuthTokens) async throws(DriveError) -> OAuthTokens {
        guard let refreshToken = t.refreshToken else { throw .needsLogin }
        var params: [(String, String)] = [
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
            ("client_id", config.clientID),
        ]
        if let secret = config.clientSecret { params.append(("client_secret", secret)) }
        let r = try await tokenRequest(params)
        return OAuthTokens(
            accessToken: r.access_token,
            refreshToken: r.refresh_token ?? refreshToken,
            expiresAt: now().addingTimeInterval(TimeInterval(r.expires_in ?? 3600)),
            email: r.id_token.flatMap(Self.email(fromIDToken:)) ?? t.email
        )
    }

    /// Reads `email` from the id_token payload WITHOUT verifying the signature. That is acceptable because the
    /// token was received directly from Google's token endpoint over TLS (OpenID Connect Core §3.1.3.7), and the
    /// email is used for display only, never for authorization.
    static func email(fromIDToken token: String) -> String? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, let payload = Hashing.base64URLDecode(String(parts[1])),
              let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
        else { return nil }
        return obj["email"] as? String
    }

    // MARK: - Token endpoint

    private struct TokenResponse: Decodable {
        var access_token: String
        var expires_in: Int?
        var refresh_token: String?
        var id_token: String?
    }

    private struct TokenError: Decodable {
        var error: String?
    }

    private func tokenRequest(_ params: [(String, String)]) async throws(DriveError) -> TokenResponse {
        var req = URLRequest(url: Self.tokenEndpoint)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = Data(FormEncoding.encode(params).utf8)
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.data(for: req)
        } catch {
            throw mapTransportError(error)
        }
        let status = response.statusCode
        guard (200..<300).contains(status) else {
            let code = (try? JSONDecoder().decode(TokenError.self, from: data))?.error ?? ""
            switch code {
            case "invalid_grant": throw .needsLogin
            case "invalid_client", "unauthorized_client": throw .unauthorized
            default: break
            }
            if status == 429 { throw .rateLimited(retryAfter: nil) }
            if status >= 500 { throw .server(status) }
            throw .invalidResponse("token endpoint HTTP \(status) \(code)")
        }
        do {
            return try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            throw .invalidResponse("token endpoint returned undecodable JSON")
        }
    }
}

/// `application/x-www-form-urlencoded` / query encoding; only RFC 3986 unreserved characters stay literal.
enum FormEncoding {
    static let unreserved: Set<UInt8> = Set(Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~".utf8))

    static func escape(_ s: String) -> String {
        var out = ""
        for b in s.utf8 {
            if unreserved.contains(b) {
                out.unicodeScalars.append(Unicode.Scalar(b))
            } else {
                out += String(format: "%%%02X", b)
            }
        }
        return out
    }

    static func encode(_ params: [(String, String)]) -> String {
        params.map { "\(escape($0.0))=\(escape($0.1))" }.joined(separator: "&")
    }
}
