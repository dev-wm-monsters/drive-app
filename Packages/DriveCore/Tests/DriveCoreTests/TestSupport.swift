import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import DriveCore

struct TestFailure: Error, CustomStringConvertible {
    var description: String
}

/// Scripted HTTP reply.
struct Reply: Sendable {
    var status: Int = 200
    var headers: [String: String] = [:]
    var body = Data()
    var error: (any Error & Sendable)?
    var delay: Duration?

    static func json(_ status: Int = 200, _ json: String, headers: [String: String] = [:]) -> Reply {
        var h = headers
        h["Content-Type"] = "application/json"
        return Reply(status: status, headers: h, body: Data(json.utf8))
    }

    static func status(_ status: Int, headers: [String: String] = [:], body: Data = Data()) -> Reply {
        Reply(status: status, headers: headers, body: body)
    }

    static func googleError(_ status: Int, reason: String? = nil, googleStatus: String? = nil, headers: [String: String] = [:]) -> Reply {
        let errors = reason.map { "[{\"domain\":\"usageLimits\",\"reason\":\"\($0)\",\"message\":\"m\"}]" } ?? "[]"
        let st = googleStatus.map { ",\"status\":\"\($0)\"" } ?? ""
        return .json(status, "{\"error\":{\"code\":\(status),\"message\":\"m\",\"errors\":\(errors)\(st)}}", headers: headers)
    }

    static func failure(_ error: any Error & Sendable) -> Reply {
        Reply(error: error)
    }
}

/// Records every request and answers from routes (first matching route with replies left wins).
final class FakeTransport: HTTPTransport, @unchecked Sendable {
    private struct Route {
        var match: @Sendable (URLRequest) -> Bool
        var replies: [Reply]
        var handler: (@Sendable (URLRequest) throws -> Reply)?
    }

    private let lock = NSLock()
    private var routes: [Route] = []
    private var recorded: [URLRequest] = []

    var requests: [URLRequest] { lock.withLock { recorded } }

    func requests(matching predicate: (URLRequest) -> Bool) -> [URLRequest] {
        requests.filter(predicate)
    }

    /// FIFO replies for matching requests.
    func on(_ match: @escaping @Sendable (URLRequest) -> Bool, _ replies: Reply...) {
        lock.withLock { routes.append(Route(match: match, replies: replies, handler: nil)) }
    }

    /// Dynamic replies for matching requests (never exhausted).
    func on(_ match: @escaping @Sendable (URLRequest) -> Bool, handler: @escaping @Sendable (URLRequest) throws -> Reply) {
        lock.withLock { routes.append(Route(match: match, replies: [], handler: handler)) }
    }

    private func next(for r: URLRequest) throws -> Reply {
        try lock.withLock {
            recorded.append(r)
            for i in routes.indices where routes[i].match(r) {
                if let h = routes[i].handler { return try h(r) }
                if !routes[i].replies.isEmpty { return routes[i].replies.removeFirst() }
            }
            throw TestFailure(description: "no scripted reply for \(r.httpMethod ?? "GET") \(r.url?.absoluteString ?? "-")")
        }
    }

    func data(for r: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let reply = try next(for: r)
        if let d = reply.delay { try await Task.sleep(for: d) }
        if let e = reply.error { throw e }
        let response = HTTPURLResponse(url: r.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        return (reply.body, response)
    }

    func download(for r: URLRequest, to file: URL) async throws -> HTTPURLResponse {
        let (data, response) = try await data(for: r)
        try data.write(to: file)
        return response
    }
}

// MARK: - Matchers

func isToken(_ r: URLRequest) -> Bool { r.url?.host == "oauth2.googleapis.com" }
func path(_ p: String) -> @Sendable (URLRequest) -> Bool {
    { r in r.url?.host == "www.googleapis.com" && r.url?.path == p }
}
func isAPI(_ r: URLRequest) -> Bool { r.url?.host == "www.googleapis.com" }

func query(_ r: URLRequest) -> [String: String] {
    var out: [String: String] = [:]
    for item in URLComponents(url: r.url!, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
        out[item.name] = item.value ?? ""
    }
    return out
}

func formBody(_ r: URLRequest) -> [String: String] {
    let s = String(decoding: r.httpBody ?? Data(), as: UTF8.self)
    var c = URLComponents()
    c.percentEncodedQuery = s
    var out: [String: String] = [:]
    for item in c.queryItems ?? [] { out[item.name] = item.value ?? "" }
    return out
}

final class SleepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Duration] = []
    var sleeps: [Duration] { lock.withLock { values } }
    func record(_ d: Duration) { lock.withLock { values.append(d) } }
}

/// Mutable clock for tests.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ d: Date = Date(timeIntervalSince1970: 1_800_000_000)) { value = d }
    var now: Date { lock.withLock { value } }
    func advance(_ s: TimeInterval) { lock.withLock { value = value.addingTimeInterval(s) } }
}

struct Harness {
    let transport = FakeTransport()
    let sleeps = SleepRecorder()
    let clock = TestClock()
    let store: InMemoryTokenStore
    let config: DriveConfig
    let auth: AuthSession
    let client: DriveClient

    init(root: RootSelector = .sharedDriveNamed("WakeupMonster"), signedIn: Bool = true, maxAttempts: Int = 5) {
        config = DriveConfig(
            clientID: "test-client.apps.googleusercontent.com",
            redirectURI: URL(string: "com.googleusercontent.apps.test-client:/oauth2redirect")!,
            root: root
        )
        let clock = self.clock
        store = InMemoryTokenStore(signedIn
            ? OAuthTokens(accessToken: "at-1", refreshToken: "rt-1", expiresAt: clock.now.addingTimeInterval(3600), email: "u@example.com")
            : nil)
        let oauth = OAuthClient(config: config, transport: transport, now: { clock.now })
        auth = AuthSession(client: oauth, store: store, now: { clock.now })
        let sleeps = self.sleeps
        let policy = RetryPolicy(maxAttempts: maxAttempts, jitter: { $0 }, sleep: { sleeps.record($0) })
        client = DriveClient(config: config, auth: auth, transport: transport, retry: policy)
    }

    /// Token endpoint answering refreshes with at-2, at-3, ...
    func scriptRefreshes(count: Int = 5) {
        let replies = (2..<(2 + count)).map { Reply.json(200, "{\"access_token\":\"at-\($0)\",\"expires_in\":3599,\"token_type\":\"Bearer\"}") }
        for r in replies { transport.on(isToken, r) }
    }
}

func expectError<T>(
    _ expected: DriveError,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ body: () async throws -> T
) async {
    do {
        _ = try await body()
        XCTFail("expected \(expected), got success", file: file, line: line)
    } catch {
        XCTAssertEqual(error as? DriveError, expected, file: file, line: line)
    }
}

func fileJSON(
    id: String,
    name: String,
    mimeType: String = "video/mp4",
    parents: [String] = ["root"],
    trashed: Bool = false,
    created: String = "2026-01-01T10:00:00.000Z",
    extra: String = ""
) -> String {
    let p = parents.map { "\"\($0)\"" }.joined(separator: ",")
    return """
    {"id":"\(id)","name":"\(name)","mimeType":"\(mimeType)","createdTime":"\(created)","modifiedTime":"\(created)",\
    "parents":[\(p)],"trashed":\(trashed)\(extra.isEmpty ? "" : "," + extra)}
    """
}

func tempDir() throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("DriveCoreTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

func bearer(_ r: URLRequest) -> String? { r.value(forHTTPHeaderField: "Authorization") }
