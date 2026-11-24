import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import DriveCore

/// Simulates Google's resumable upload session endpoint.
final class FakeUploadServer: @unchecked Sendable {
    static let sessionURL = "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&upload_id=SECRET-SESSION"

    let total: Int64
    private let lock = NSLock()
    private var receivedData = Data()
    private var chunkPuts = 0
    /// 1-based chunk PUT numbers that fail with a network error (after the server stored `storeBeforeFailure` bytes).
    var failChunkPuts: Set<Int> = []
    var storeBeforeFailure: Int = 0
    /// 1-based chunk PUT number → bytes the server keeps (Google may persist less than sent).
    var partialAccept: [Int: Int] = [:]
    /// 1-based chunk PUT numbers answered with 503.
    var serverErrorPuts: Set<Int> = []
    private(set) var violations: [String] = []

    init(total: Int64) { self.total = total }

    var received: Data { lock.withLock { receivedData } }

    private func rangeHeaders() -> [String: String] {
        receivedData.isEmpty ? [:] : ["Range": "bytes=0-\(receivedData.count - 1)"]
    }

    func handle(_ r: URLRequest) throws -> Reply {
        try lock.withLock {
            guard r.httpMethod == "PUT", let cr = r.value(forHTTPHeaderField: "Content-Range") else {
                violations.append("bad request \(r.httpMethod ?? "-")")
                return .status(400)
            }
            if cr == "bytes */\(total)" && total > 0 {
                if (r.httpBody ?? Data()).count != 0 { violations.append("status query with body") }
                return .status(308, headers: rangeHeaders())
            }
            chunkPuts += 1
            let n = chunkPuts
            let body = r.httpBody ?? Data()
            if total > 0 {
                let expected = "bytes \(receivedData.count)-\(receivedData.count + body.count - 1)/\(total)"
                if cr != expected { violations.append("PUT \(n): Content-Range \(cr), expected \(expected)") }
            }
            if r.value(forHTTPHeaderField: "Content-Length") != String(body.count) {
                violations.append("PUT \(n): Content-Length mismatch")
            }
            if failChunkPuts.contains(n) {
                receivedData.append(body.prefix(storeBeforeFailure))
                throw URLError(.networkConnectionLost)
            }
            if serverErrorPuts.contains(n) {
                return .googleError(503)
            }
            receivedData.append(body.prefix(partialAccept[n] ?? body.count))
            if Int64(receivedData.count) == total {
                return .json(200, fileJSON(id: "up1", name: "uploaded", parents: ["parent"], extra: "\"size\":\"\(total)\""))
            }
            return .status(308, headers: rangeHeaders())
        }
    }
}

final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int64] = []
    var sent: [Int64] { lock.withLock { values } }
    func record(_ s: Int64, _ total: Int64) { lock.withLock { values.append(s) } }
}

final class UploadTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = try tempDir()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func makeFile(size: Int) throws -> (URL, Data) {
        let data = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ ($0 >> 20)) })
        let url = dir.appendingPathComponent("local-\(size).bin")
        try data.write(to: url)
        return (url, data)
    }

    func script(_ h: Harness, siblings: String = "", server: FakeUploadServer) {
        h.transport.on(path("/drive/v3/files"), .json(200, "{\"files\":[\(siblings)]}"))
        h.transport.on({ $0.httpMethod == "POST" && $0.url?.path == "/upload/drive/v3/files" },
                       handler: { _ in .status(200, headers: ["Location": FakeUploadServer.sessionURL]) })
        h.transport.on({ $0.url?.query?.contains("upload_id=") == true }, handler: server.handle)
    }

    func puts(_ h: Harness) -> [URLRequest] {
        h.transport.requests(matching: { $0.httpMethod == "PUT" })
    }

    func testUploadPicksFreeNameAndStartsSession() async throws {
        let h = Harness()
        let (file, data) = try makeFile(size: 10)
        let server = FakeUploadServer(total: 10)
        script(h, siblings: [
            fileJSON(id: "s1", name: "clip.mp4", parents: ["parent"], created: "2026-01-01T00:00:00Z"),
            fileJSON(id: "s2", name: "CLIP.mp4", parents: ["parent"], created: "2026-01-02T00:00:00Z"),
            fileJSON(id: "s3", name: "clip (3).mp4", mimeType: "application/vnd.google-apps.document", parents: ["parent"]),
        ].joined(separator: ","), server: server)
        let progress = ProgressLog()
        let result = try await h.client.upload(file: file, desiredName: "clip.mp4", parentID: "parent", progress: progress.record)
        XCTAssertEqual(result.id, "up1")
        XCTAssertEqual(result.size, 10)
        XCTAssertEqual(server.received, data)
        XCTAssertEqual(server.violations, [])
        XCTAssertEqual(progress.sent.first, 0)
        XCTAssertEqual(progress.sent.last, 10)

        // Existing: "clip.mp4" + "CLIP.mp4" (displayed as "CLIP (2).mp4"); the hidden doc does not reserve "(3)".
        let list = try XCTUnwrap(h.transport.requests(matching: path("/drive/v3/files")).first)
        XCTAssertEqual(query(list)["q"], "'parent' in parents and trashed = false")
        XCTAssertEqual(query(list)["supportsAllDrives"], "true")

        let post = try XCTUnwrap(h.transport.requests(matching: { $0.httpMethod == "POST" }).first)
        XCTAssertEqual(post.url?.host, "www.googleapis.com")
        XCTAssertEqual(query(post), ["uploadType": "resumable", "supportsAllDrives": "true", "fields": DriveClient.fields])
        XCTAssertEqual(post.value(forHTTPHeaderField: "X-Upload-Content-Length"), "10")
        XCTAssertEqual(post.value(forHTTPHeaderField: "X-Upload-Content-Type"), "video/mp4")
        XCTAssertEqual(post.value(forHTTPHeaderField: "Content-Type"), "application/json; charset=UTF-8")
        XCTAssertEqual(bearer(post), "Bearer at-1")
        let meta = try XCTUnwrap(JSONSerialization.jsonObject(with: post.httpBody ?? Data()) as? [String: Any])
        XCTAssertEqual(meta["name"] as? String, "clip (3).mp4")
        XCTAssertEqual(meta["parents"] as? [String], ["parent"])
        XCTAssertEqual(meta.count, 2)

        let put = try XCTUnwrap(puts(h).first)
        XCTAssertEqual(put.value(forHTTPHeaderField: "Content-Range"), "bytes 0-9/10")
    }

    func testUploadNoCollisionKeepsSanitizedName() async throws {
        let h = Harness()
        let (file, _) = try makeFile(size: 3)
        let server = FakeUploadServer(total: 3)
        script(h, siblings: fileJSON(id: "s1", name: "other.mov", parents: ["parent"]), server: server)
        _ = try await h.client.upload(file: file, desiredName: "Q1: plan?.mov", parentID: "parent", progress: nil)
        let post = try XCTUnwrap(h.transport.requests(matching: { $0.httpMethod == "POST" }).first)
        let meta = try XCTUnwrap(JSONSerialization.jsonObject(with: post.httpBody ?? Data()) as? [String: Any])
        XCTAssertEqual(meta["name"] as? String, "Q1_ plan_.mov")
        XCTAssertEqual(post.value(forHTTPHeaderField: "X-Upload-Content-Type"), "video/quicktime")
    }

    func testUploadChunkBoundaries20MiBPlusOne() async throws {
        let h = Harness()
        let size = 20 * 1024 * 1024 + 1
        let (file, data) = try makeFile(size: size)
        let server = FakeUploadServer(total: Int64(size))
        script(h, server: server)
        let progress = ProgressLog()
        _ = try await h.client.upload(file: file, desiredName: "big.bin", parentID: "parent", progress: progress.record)
        XCTAssertEqual(server.violations, [])
        XCTAssertEqual(server.received, data)
        let ranges = puts(h).map { $0.value(forHTTPHeaderField: "Content-Range") ?? "" }
        XCTAssertEqual(ranges, [
            "bytes 0-8388607/20971521",
            "bytes 8388608-16777215/20971521",
            "bytes 16777216-20971520/20971521",
        ])
        XCTAssertEqual(puts(h).map { $0.httpBody?.count ?? -1 }, [8_388_608, 8_388_608, 4_194_305])
        XCTAssertEqual(progress.sent, [0, 8_388_608, 16_777_216, 20_971_521])
        XCTAssertEqual(DriveClient.uploadChunkSize % (256 * 1024), 0)
        let post = try XCTUnwrap(h.transport.requests(matching: { $0.httpMethod == "POST" }).first)
        XCTAssertEqual(post.value(forHTTPHeaderField: "X-Upload-Content-Type"), "application/octet-stream")
    }

    func testUpload308ResumesFromServerRange() async throws {
        let h = Harness()
        let size = 10 * 1024 * 1024
        let (file, data) = try makeFile(size: size)
        let server = FakeUploadServer(total: Int64(size))
        server.partialAccept = [1: 4 * 1024 * 1024] // server kept only 4 MiB of the first 8 MiB chunk
        script(h, server: server)
        _ = try await h.client.upload(file: file, desiredName: "a.bin", parentID: "parent", progress: nil)
        XCTAssertEqual(server.violations, [])
        XCTAssertEqual(server.received, data)
        XCTAssertEqual(puts(h).map { $0.value(forHTTPHeaderField: "Content-Range") ?? "" }, [
            "bytes 0-8388607/10485760",
            "bytes 4194304-10485759/10485760",
        ])
    }

    func testUploadInterruptedQueriesStatusAndResumes() async throws {
        let h = Harness()
        let size = 20 * 1024 * 1024 + 1
        let (file, data) = try makeFile(size: size)
        let server = FakeUploadServer(total: Int64(size))
        server.failChunkPuts = [2]
        server.storeBeforeFailure = 1024 * 1024 // 1 MiB of chunk 2 arrived before the connection dropped
        script(h, server: server)
        _ = try await h.client.upload(file: file, desiredName: "a.bin", parentID: "parent", progress: nil)
        XCTAssertEqual(server.violations, [])
        XCTAssertEqual(server.received, data)
        XCTAssertEqual(puts(h).map { $0.value(forHTTPHeaderField: "Content-Range") ?? "" }, [
            "bytes 0-8388607/20971521",
            "bytes 8388608-16777215/20971521", // fails
            "bytes */20971521", // status query
            "bytes 9437184-17825791/20971521", // resume at 9 MiB
            "bytes 17825792-20971520/20971521",
        ])
        XCTAssertEqual(puts(h)[2].httpBody?.count ?? 0, 0)
        XCTAssertEqual(h.sleeps.sleeps, [.seconds(1)])
    }

    func testUploadServerErrorQueriesStatusAndResumes() async throws {
        let h = Harness()
        let size = 9 * 1024 * 1024
        let (file, data) = try makeFile(size: size)
        let server = FakeUploadServer(total: Int64(size))
        server.serverErrorPuts = [2]
        script(h, server: server)
        _ = try await h.client.upload(file: file, desiredName: "a.bin", parentID: "parent", progress: nil)
        XCTAssertEqual(server.received, data)
        XCTAssertEqual(puts(h).map { $0.value(forHTTPHeaderField: "Content-Range") ?? "" }, [
            "bytes 0-8388607/9437184",
            "bytes 8388608-9437183/9437184",
            "bytes */9437184",
            "bytes 8388608-9437183/9437184",
        ])
    }

    func testUploadGivesUpAfterMaxAttempts() async throws {
        let h = Harness()
        let (file, _) = try makeFile(size: 100)
        h.transport.on(path("/drive/v3/files"), .json(200, #"{"files":[]}"#))
        h.transport.on({ $0.httpMethod == "POST" }, .status(200, headers: ["Location": FakeUploadServer.sessionURL]))
        h.transport.on({ $0.httpMethod == "PUT" }, handler: { _ in throw URLError(.timedOut) })
        await expectError(.network("URLError \(URLError.Code.timedOut.rawValue)")) {
            try await h.client.upload(file: file, desiredName: "a.bin", parentID: "parent", progress: nil)
        }
        XCTAssertEqual(puts(h).count, 5)
        XCTAssertEqual(h.sleeps.sleeps, [.seconds(1), .seconds(2), .seconds(4), .seconds(8)])
    }

    func testUploadZeroByteFile() async throws {
        let h = Harness()
        let (file, _) = try makeFile(size: 0)
        let server = FakeUploadServer(total: 0)
        script(h, server: server)
        let f = try await h.client.upload(file: file, desiredName: "empty.txt", parentID: "parent", progress: nil)
        XCTAssertEqual(f.id, "up1")
        let put = try XCTUnwrap(puts(h).first)
        XCTAssertEqual(put.value(forHTTPHeaderField: "Content-Range"), "bytes */0")
        XCTAssertEqual(put.value(forHTTPHeaderField: "Content-Length"), "0")
    }

    func testUploadExpiredSessionRestartsOnce() async throws {
        let h = Harness()
        let (file, data) = try makeFile(size: 50)
        h.transport.on(path("/drive/v3/files"), .json(200, #"{"files":[]}"#))
        h.transport.on({ $0.httpMethod == "POST" },
                       .status(200, headers: ["Location": FakeUploadServer.sessionURL + "-old"]),
                       .status(200, headers: ["Location": FakeUploadServer.sessionURL]))
        h.transport.on({ $0.url?.query?.hasSuffix("-old") == true }, .googleError(404, reason: "notFound"))
        let server = FakeUploadServer(total: 50)
        h.transport.on({ $0.url?.query?.contains("upload_id=") == true }, handler: server.handle)
        _ = try await h.client.upload(file: file, desiredName: "a.bin", parentID: "parent", progress: nil)
        XCTAssertEqual(server.received, data)
        XCTAssertEqual(h.transport.requests(matching: { $0.httpMethod == "POST" }).count, 2)
    }

    func testUploadMissingLocalFile() async {
        let h = Harness()
        await expectError(.invalidResponse("cannot read local file")) {
            try await h.client.upload(file: self.dir.appendingPathComponent("nope"), desiredName: "x", parentID: "p", progress: nil)
        }
        XCTAssertTrue(h.transport.requests.isEmpty)
    }
}
