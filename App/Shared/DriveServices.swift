// Builds the DriveCore object graph used by both the app and the extension.

import DriveCore
import Foundation

struct DriveServices: Sendable {
    let config: AppConfig
    let store: KeychainTokenStore
    let transport: URLSessionTransport
    let oauth: OAuthClient
    let auth: AuthSession
    let client: DriveClient
    let shared: SharedState

    init(config: AppConfig) {
        self.config = config
        self.store = KeychainTokenStore(config: config)
        self.transport = URLSessionTransport(session: .shared)
        self.oauth = OAuthClient(config: config.drive, transport: transport)
        self.auth = AuthSession(client: oauth, store: store)
        self.client = DriveClient(config: config.drive, auth: auth, transport: transport)
        self.shared = SharedState(config: config)
    }

    /// Returns the cached root, or resolves it on Drive and caches it.
    func root(forceRefresh: Bool = false) async throws(DriveError) -> DriveRoot {
        if !forceRefresh, let cached = shared.root { return cached }
        let root = try await client.resolveRoot()
        shared.setRoot(root)
        return root
    }
}

extension DriveError {
    /// Converts any error thrown around DriveCore calls into a DriveError.
    static func from(_ error: any Error) -> DriveError {
        if let e = error as? DriveError { return e }
        if error is CancellationError { return .cancelled }
        if let e = error as? KeychainError { return .notConfigured(e.description) }
        if let e = error as? URLError {
            return e.code == .cancelled ? .cancelled : .network(e.localizedDescription)
        }
        // Not String(describing:): Cocoa errors carry paths/URLs in userInfo,
        // and this text is logged at public level.
        let ns = error as NSError
        return .invalidResponse("\(ns.domain) \(ns.code)")
    }

    /// Short user-facing explanation, with guidance for root problems.
    var userMessage: String {
        switch self {
        case .needsLogin, .unauthorized:
            return "Sign-in expired. Choose \u{201C}Sign in with Google\u{201D} again."
        case .rootNotFound(let name):
            return "No shared drive named \u{201C}\(name)\u{201D} is visible to this account. Ask an admin to add you to it, or sign in with your work account."
        case .rootAmbiguous(let ids):
            return "\(ids.count) shared drives have this name. Set DRIVE_ROOT_FOLDER_ID (one of: \(ids.joined(separator: ", "))) and rebuild."
        case .rateLimited:
            return "Google Drive is rate-limiting requests. Retrying shortly."
        case .notFound:
            return "The item no longer exists on Google Drive."
        case .quotaExceeded:
            return "The shared drive is out of storage."
        case .forbidden(let reason):
            return "Google Drive refused the request (\(reason))."
        case .checksumMismatch:
            return "A download was corrupted (checksum mismatch). It will be retried."
        case .network(let message):
            return "Network problem: \(message)"
        case .server(let code):
            return "Google Drive server error (\(code)). Retrying shortly."
        case .invalidResponse:
            return "Unexpected response from Google Drive."
        case .cancelled:
            return "Cancelled."
        case .notConfigured(let what):
            return "Not configured: \(what)"
        }
    }
}
