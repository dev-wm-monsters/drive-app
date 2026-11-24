import Foundation

/// Hands out valid access tokens. Refreshes when fewer than 60 s remain and coalesces concurrent refreshes into a
/// single in-flight request. Tokens are persisted through the `TokenStore` (shared Keychain between the app and the
/// File Provider extension), so before refreshing it re-reads the store in case the other process already did.
public actor AuthSession {
    public static let refreshMargin: TimeInterval = 60

    private let client: OAuthClient
    private let store: any TokenStore
    private let now: @Sendable () -> Date
    private var tokens: OAuthTokens?
    private var refreshTask: Task<OAuthTokens, any Error>?
    /// Bumped by sign-in / sign-out so a refresh that finishes afterwards cannot resurrect old tokens.
    private var generation = 0

    public init(client: OAuthClient, store: any TokenStore, now: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client
        self.store = store
        self.now = now
    }

    public var isSignedIn: Bool {
        currentTokens() != nil
    }

    /// The signed-in account's email (from the id_token), if known.
    public var email: String? {
        currentTokens()?.email
    }

    /// Stores freshly exchanged tokens (after `OAuthClient.exchange`).
    public func signIn(_ newTokens: OAuthTokens) throws(DriveError) {
        generation += 1
        refreshTask?.cancel()
        refreshTask = nil
        tokens = newTokens
        do {
            try store.save(newTokens)
        } catch {
            throw .notConfigured("TokenStore")
        }
    }

    public func accessToken() async throws(DriveError) -> String {
        guard let t = currentTokens() else { throw .needsLogin }
        if isFresh(t) { return t.accessToken }
        return try await refreshed(force: false).accessToken
    }

    /// Called after a 401: refreshes unless the rejected token has already been replaced (by a concurrent refresh).
    public func forceRefresh(rejecting rejected: String?) async throws(DriveError) -> String {
        guard let t = currentTokens() else { throw .needsLogin }
        if let rejected, t.accessToken != rejected, isFresh(t) { return t.accessToken }
        return try await refreshed(force: true).accessToken
    }

    public func signOut() async {
        generation += 1
        refreshTask?.cancel()
        refreshTask = nil
        tokens = nil
        try? store.clear()
    }

    // MARK: - Private

    private func isFresh(_ t: OAuthTokens) -> Bool {
        t.expiresAt.timeIntervalSince(now()) > Self.refreshMargin
    }

    private func currentTokens() -> OAuthTokens? {
        if let tokens { return tokens }
        // Not cached: (re)load, so tokens saved by the sign-in flow or the other process are picked up.
        tokens = (try? store.load()) ?? nil
        return tokens
    }

    private func refreshed(force: Bool) async throws(DriveError) -> OAuthTokens {
        if let task = refreshTask {
            return try await Self.value(of: task)
        }
        if !force, let stored = (try? store.load()) ?? nil, isFresh(stored) {
            tokens = stored
            return stored
        }
        guard let current = tokens else { throw .needsLogin }
        let client = self.client
        let task = Task { () async throws -> OAuthTokens in
            try await client.refresh(current)
        }
        refreshTask = task
        let gen = generation
        do {
            let new = try await Self.value(of: task)
            if refreshTask == task { refreshTask = nil }
            guard gen == generation else { throw DriveError.needsLogin }
            tokens = new
            try? store.save(new)
            return new
        } catch {
            let e = mapTransportError(error)
            if refreshTask == task { refreshTask = nil }
            if e == .needsLogin, gen == generation {
                tokens = nil
                try? store.clear()
            }
            throw e
        }
    }

    private static func value(of task: Task<OAuthTokens, any Error>) async throws(DriveError) -> OAuthTokens {
        do {
            return try await task.value
        } catch {
            throw mapTransportError(error)
        }
    }
}
