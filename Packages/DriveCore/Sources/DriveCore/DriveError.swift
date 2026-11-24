import Foundation

/// Every DriveCore failure. Associated strings never contain tokens, auth codes or upload session URLs.
public enum DriveError: Error, Sendable, Hashable {
    /// No usable tokens (never signed in, signed out, refresh token revoked / `invalid_grant`, or 401 after a refresh).
    case needsLogin
    /// The OAuth client itself was rejected (`invalid_client`, `unauthorized_client`).
    case unauthorized
    /// 429 or a rate-limit 403 that survived all retries.
    case rateLimited(retryAfter: Duration?)
    case notFound
    /// `resolveRoot`: no shared drive with this name, or the folder ID does not exist / is not a folder.
    case rootNotFound(String)
    /// `resolveRoot`: more than one shared drive has the configured name. Payload: the drive IDs.
    case rootAmbiguous([String])
    case quotaExceeded
    /// 403 that is neither a rate limit nor a quota error. Payload: Google's `reason` (or `status`).
    case forbidden(String)
    case checksumMismatch
    /// Transport failure. Payload is a short code such as `URLError -1005`, never a URL.
    case network(String)
    case server(Int)
    case invalidResponse(String)
    case cancelled
    /// A required configuration value is missing. Payload: the key name.
    case notConfigured(String)
}

extension DriveError {
    /// Whether the retry policy should try again (429, 5xx, rate-limit 403, transport failures).
    var isRetryable: Bool {
        switch self {
        case .rateLimited, .server, .network: return true
        default: return false
        }
    }

    var retryAfter: Duration? {
        if case .rateLimited(let d) = self { return d }
        return nil
    }
}

extension DriveError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .needsLogin: return "Sign-in required"
        case .unauthorized: return "OAuth client rejected"
        case .rateLimited(let d): return "Rate limited" + (d.map { " (retry after \($0))" } ?? "")
        case .notFound: return "Not found"
        case .rootNotFound(let s): return "Drive root not found: \(s)"
        case .rootAmbiguous(let ids): return "Drive root ambiguous: \(ids.count) shared drives match"
        case .quotaExceeded: return "Storage quota exceeded"
        case .forbidden(let r): return "Forbidden: \(r)"
        case .checksumMismatch: return "Checksum mismatch"
        case .network(let s): return "Network error: \(s)"
        case .server(let c): return "Server error \(c)"
        case .invalidResponse(let s): return "Invalid response: \(s)"
        case .cancelled: return "Cancelled"
        case .notConfigured(let k): return "Not configured: \(k)"
        }
    }
}

/// Maps an arbitrary error thrown by a transport / Task into a `DriveError`.
func mapTransportError(_ error: any Error) -> DriveError {
    if let e = error as? DriveError { return e }
    if error is CancellationError { return .cancelled }
    if let u = error as? URLError {
        if u.code == .cancelled { return .cancelled }
        // Deliberately only the code: URLError's description can contain the request URL
        // (which, for uploads, is the secret session URL).
        return .network("URLError \(u.code.rawValue)")
    }
    let ns = error as NSError
    return .network("\(ns.domain) \(ns.code)")
}
