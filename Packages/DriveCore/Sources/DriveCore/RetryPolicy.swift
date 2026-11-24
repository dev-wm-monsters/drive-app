import Foundation

/// Exponential backoff with full jitter: delay(n) = random(0 ... min(maxDelay, baseDelay * 2^(n-1))),
/// where n is the number of failed attempts so far. A server `Retry-After` replaces the computed delay
/// (capped at `maxRetryAfter`). Retried: 429, 5xx, 403 rateLimitExceeded/userRateLimitExceeded, transport errors.
public struct RetryPolicy: Sendable {
    /// Total attempts including the first one.
    public var maxAttempts: Int
    public var baseDelay: Duration
    public var maxDelay: Duration
    /// Upper bound for an honoured `Retry-After`, so a hostile/buggy header cannot stall the app.
    public var maxRetryAfter: Duration
    /// Maps the capped exponential delay to the actual delay. Default: uniform in [0, d] (full jitter).
    public var jitter: @Sendable (Duration) -> Duration
    /// Injected so tests do not sleep. Default: `Task.sleep(for:)` (throws on cancellation).
    public var sleep: @Sendable (Duration) async throws -> Void

    public static let `default` = RetryPolicy()

    public init(
        maxAttempts: Int = 5,
        baseDelay: Duration = .seconds(1),
        maxDelay: Duration = .seconds(32),
        maxRetryAfter: Duration = .seconds(300),
        jitter: @escaping @Sendable (Duration) -> Duration = RetryPolicy.fullJitter,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.maxAttempts = max(1, maxAttempts)
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.maxRetryAfter = maxRetryAfter
        self.jitter = jitter
        self.sleep = sleep
    }

    @Sendable public static func fullJitter(_ d: Duration) -> Duration {
        let ms = max(Int64(0), Int64(d / .milliseconds(1)))
        return .milliseconds(Int64.random(in: 0...ms))
    }

    /// Delay before the next attempt after `failures` failed attempts (1-based).
    public func delay(afterFailures failures: Int, retryAfter: Duration?) -> Duration {
        if let retryAfter { return min(max(retryAfter, .zero), maxRetryAfter) }
        let exponent = min(max(failures - 1, 0), 30)
        let exp = baseDelay * (1 << exponent)
        return jitter(min(exp, maxDelay))
    }

    /// Parses `Retry-After` (delta-seconds or HTTP-date).
    public static func parseRetryAfter(_ value: String?, now: Date = Date()) -> Duration? {
        guard let v = value?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { return nil }
        if let secs = Int(v) { return .seconds(max(0, secs)) }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = f.date(from: v) else { return nil }
        return .seconds(max(0, Int(date.timeIntervalSince(now).rounded(.up))))
    }
}
