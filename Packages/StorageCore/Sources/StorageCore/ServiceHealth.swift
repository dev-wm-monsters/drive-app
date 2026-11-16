/// Events the client (FSKit extension / app) observes on its connection to StorageService.
public enum ServiceConnectionEvent: Sendable, Hashable {
    /// A connection was (re)created and resumed.
    case connected
    /// The service process exited or the connection was interrupted (XPC interruption handler).
    case interrupted
    /// The connection is permanently invalid (XPC invalidation handler).
    case invalidated
    /// A well-formed reply arrived.
    case replyReceived
    /// No reply within `ServiceHealth.foregroundDeadline`.
    case replyTimedOut
}

/// Client-side health and failure policy for the service connection (FR03, NFR06).
///
/// State machine:
/// - `.unknown` (initial) — requests may be attempted.
/// - `.connected`, `.replyReceived` → `.healthy`.
/// - `.interrupted`, `.invalidated`, `.replyTimedOut` → `.unavailable`.
///
/// Policy:
/// - Reads in flight when the connection is interrupted/invalidated fail immediately with
///   `StorageError.serviceUnavailable` (ENOTCONN); a reply timeout fails with `.timedOut`
///   (ETIMEDOUT). See `failure(for:)`. Nothing returns stale success.
/// - The next request reconnects: when `needsReconnect` is true the client creates (or, after
///   an interruption, reuses) its connection and records `.connected`, then calls `gate()`
///   immediately before sending. If reconnection was not possible, `gate()` throws
///   `.serviceUnavailable` so the request fails fast instead of hanging.
/// - Every foreground request carries `foregroundDeadline` (30 s, NFR06) as its reply deadline.
public struct ServiceHealth: Sendable, Hashable {
    public enum State: Sendable, Hashable {
        case unknown
        case healthy
        case unavailable
    }

    public static let foregroundDeadline: Duration = .seconds(30)

    public private(set) var state: State = .unknown
    public private(set) var lastEvent: ServiceConnectionEvent?

    public init() {}

    public mutating func record(_ event: ServiceConnectionEvent) {
        lastEvent = event
        switch event {
        case .connected, .replyReceived:
            state = .healthy
        case .interrupted, .invalidated, .replyTimedOut:
            state = .unavailable
        }
    }

    /// True after a failure event: the client should reconnect before the next request.
    public var needsReconnect: Bool { state == .unavailable }

    /// Throws `.serviceUnavailable` when the state is `.unavailable`; `.unknown` and
    /// `.healthy` allow the attempt.
    public func gate() throws(StorageError) {
        if state == .unavailable { throw .serviceUnavailable }
    }

    /// The error to fail in-flight requests with when `event` happens, or `nil` for
    /// non-failure events.
    public static func failure(for event: ServiceConnectionEvent) -> StorageError? {
        switch event {
        case .interrupted, .invalidated: return .serviceUnavailable
        case .replyTimedOut: return .timedOut
        case .connected, .replyReceived: return nil
        }
    }
}
