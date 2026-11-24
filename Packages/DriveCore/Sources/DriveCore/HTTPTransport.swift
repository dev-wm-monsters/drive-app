import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The only network seam. Tests inject a fake; production uses `URLSessionTransport`.
///
/// Implementations return non-2xx responses normally (they do not throw for HTTP status codes) and
/// throw only for transport failures / cancellation.
public protocol HTTPTransport: Sendable {
    func data(for r: URLRequest) async throws -> (Data, HTTPURLResponse)
    /// Streams the response body into `file` (replacing it) and returns the response.
    /// For non-2xx responses the (error) body is written to `file` too.
    func download(for r: URLRequest, to file: URL) async throws -> HTTPURLResponse
    /// Same as `download(for:to:)`, reporting `(bytesReceived, expectedTotal or nil)` while the body streams in.
    /// The default implementation reports nothing.
    func download(for r: URLRequest, to file: URL, progress: (@Sendable (Int64, Int64?) -> Void)?) async throws -> HTTPURLResponse
}

extension HTTPTransport {
    public func download(for r: URLRequest, to file: URL, progress: (@Sendable (Int64, Int64?) -> Void)?) async throws -> HTTPURLResponse {
        try await download(for: r, to: file)
    }
}

public struct URLSessionTransport: HTTPTransport {
    public let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(for r: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: r)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    public func download(for r: URLRequest, to file: URL) async throws -> HTTPURLResponse {
        try await download(for: r, to: file, progress: nil)
    }

    public func download(for r: URLRequest, to file: URL, progress: (@Sendable (Int64, Int64?) -> Void)?) async throws -> HTTPURLResponse {
        #if canImport(FoundationNetworking)
        // swift-corelibs-foundation: no async download API; buffer in memory (Linux is test-only).
        let (data, http) = try await data(for: r)
        try data.write(to: file, options: .atomic)
        return http
        #else
        let observer = progress.map { DownloadProgressObserver($0) }
        defer { observer?.stop() }
        let (tmp, response) = try await session.download(for: r, delegate: observer)
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        let fm = FileManager.default
        if fm.fileExists(atPath: file.path) { try fm.removeItem(at: file) }
        try fm.moveItem(at: tmp, to: file)
        return http
        #endif
    }
}

#if !canImport(FoundationNetworking)
/// Polls the download task's byte counters (the async `download(for:delegate:)` API has no progress callback).
/// `urlSession(_:didCreateTask:)` (macOS 13+) hands over the task the async API creates.
/// VERIFY-ON-MAC: the task-specific delegate receives didCreateTask, so Finder shows a progress bar.
final class DownloadProgressObserver: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let report: @Sendable (Int64, Int64?) -> Void
    private var poller: Task<Void, Never>?
    private var stopped = false

    init(_ report: @escaping @Sendable (Int64, Int64?) -> Void) {
        self.report = report
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        let box = TaskBox(task: task)
        let report = self.report
        lock.lock()
        defer { lock.unlock() }
        guard !stopped, poller == nil else { return }
        poller = Task.detached {
            var last: Int64 = -1
            while !Task.isCancelled {
                let received = box.task.countOfBytesReceived
                let expected = box.task.countOfBytesExpectedToReceive
                if received != last {
                    last = received
                    report(received, expected > 0 ? expected : nil)
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    func stop() {
        lock.lock()
        stopped = true
        let p = poller
        poller = nil
        lock.unlock()
        p?.cancel()
    }

    private struct TaskBox: @unchecked Sendable { let task: URLSessionTask }
}
#endif

extension HTTPURLResponse {
    func header(_ name: String) -> String? {
        value(forHTTPHeaderField: name)
    }
}
