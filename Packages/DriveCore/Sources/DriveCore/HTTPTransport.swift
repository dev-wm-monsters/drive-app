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
        #if canImport(FoundationNetworking)
        // swift-corelibs-foundation: no async download API; buffer in memory (Linux is test-only).
        let (data, http) = try await data(for: r)
        try data.write(to: file, options: .atomic)
        return http
        #else
        let (tmp, response) = try await session.download(for: r)
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        let fm = FileManager.default
        if fm.fileExists(atPath: file.path) { try fm.removeItem(at: file) }
        try fm.moveItem(at: tmp, to: file)
        return http
        #endif
    }
}

extension HTTPURLResponse {
    func header(_ name: String) -> String? {
        value(forHTTPHeaderField: name)
    }
}
