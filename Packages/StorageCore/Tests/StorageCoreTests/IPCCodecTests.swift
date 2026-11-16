import Foundation
import StorageCore
import XCTest

final class IPCCodecTests: XCTestCase {
    static let allRequests: [IPCRequest] = [
        .status,
        .listItems(parent: .root, cursor: nil, limit: 10),
        .listItems(parent: ItemID(rawValue: 9), cursor: "3", limit: Limits.maxListLimit),
        .listItems(parent: .root, cursor: "", limit: -1),
        .stat(ItemID(rawValue: .max)),
        .lookup(parent: .root, name: "\u{00DC}n\u{00EF}c\u{00F8}d\u{00E9} name.bin"),
        .lookup(parent: .root, name: ""),
        .readRange(requestID: .max, item: ItemID(rawValue: 6), revision: "r1", offset: Int64.min, length: Int64.max),
        .readRange(requestID: 0, item: .root, revision: "", offset: 0, length: 0),
        .cancel(42),
        .cancel(.max),
    ]

    static let allErrors: [StorageError] = [
        .invalidArgument("why"), .unknownItem, .unknownAccount, .notDirectory, .isDirectory,
        .revisionChanged(expected: "r2", actual: "r1"), .cancelled, .serviceUnavailable, .timedOut,
        .readOnly, .messageTooLarge(limit: 1, actual: 2),
    ]

    static var allResponses: [IPCResponse] {
        let attrs = ItemAttributes(id: ItemID(rawValue: 6), parent: .root, name: "seg.bin", kind: .file, size: 4 << 20, revision: "r1")
        var responses: [IPCResponse] = [
            .status(ServiceStatus(version: "0.1.0 (1)", pid: 1234, startedAt: Date(timeIntervalSince1970: 1_763_251_200.25), catalog: "spike")),
            .page(ListPage(items: [attrs, attrs], nextCursor: "2")),
            .page(ListPage(items: [], nextCursor: nil)),
            .attributes(attrs),
            .bytes(Data()),
            .bytes(Data([0, 1, 2, 255])),
            .bytes(Data(count: Int(Limits.maxReadReply))),
            .cancelled(.max),
        ]
        responses += allErrors.map { .failure($0) }
        return responses
    }

    func testRequestRoundTrip() throws {
        for request in Self.allRequests {
            let data = try IPCCodec.encode(request)
            XCTAssertLessThanOrEqual(data.count, Limits.maxControlMessage)
            XCTAssertEqual(try IPCCodec.decodeRequest(data), request)
        }
    }

    func testResponseRoundTrip() throws {
        for response in Self.allResponses {
            let data = try IPCCodec.encode(response)
            XCTAssertEqual(try IPCCodec.decodeResponse(data), response)
        }
        let full = try IPCCodec.encode(IPCResponse.bytes(Data(count: Int(Limits.maxReadReply))))
        XCTAssertLessThanOrEqual(full.count, Limits.maxReadReplyMessage)
    }

    func testOversizeRejectedOnEncode() {
        let huge = String(repeating: "x", count: Limits.maxControlMessage)
        assertTooLarge { _ = try IPCCodec.encode(IPCRequest.lookup(parent: .root, name: huge)) }
        assertTooLarge { _ = try IPCCodec.encode(IPCResponse.bytes(Data(count: Int(Limits.maxReadReply) + 1))) }
        assertTooLarge { _ = try IPCCodec.encode(IPCResponse.failure(.invalidArgument(huge))) }
        // Distinct names: binary plists de-duplicate identical objects.
        let items = (0..<1000).map { i in
            ItemAttributes(id: ItemID(rawValue: UInt64(i)), parent: .root, name: "\(i)" + String(repeating: "n", count: 2000),
                           kind: .file, size: 0, revision: "r1")
        }
        assertTooLarge { _ = try IPCCodec.encode(IPCResponse.page(ListPage(items: items, nextCursor: nil))) }
    }

    func testOversizeRejectedOnDecodeBeforeParsing() {
        assertTooLarge { _ = try IPCCodec.decodeRequest(Data(count: Limits.maxControlMessage + 1)) }
        assertTooLarge { _ = try IPCCodec.decodeResponse(Data(count: Limits.maxReadReplyMessage + 1)) }
    }

    /// A control response that is well-formed but bigger than 1 MiB is rejected after parsing.
    func testOversizeControlResponseRejectedOnDecode() throws {
        struct Envelope: Encodable { let v: Int; let m: IPCResponse }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(Envelope(v: 1, m: .failure(.invalidArgument(String(repeating: "x", count: 2 << 20)))))
        XCTAssertGreaterThan(data.count, Limits.maxControlMessage)
        XCTAssertLessThanOrEqual(data.count, Limits.maxReadReplyMessage)
        assertTooLarge { _ = try IPCCodec.decodeResponse(data) }
        // Same envelope with a too-large .bytes payload.
        let bytes = try encoder.encode(Envelope(v: 1, m: .bytes(Data(count: Int(Limits.maxReadReply) + 10))))
        assertTooLarge { _ = try IPCCodec.decodeResponse(bytes) }
    }

    func testWrongWireVersionRejected() throws {
        struct Envelope: Encodable { let v: Int; let m: IPCRequest }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(Envelope(v: 2, m: .status))
        assertInvalid { _ = try IPCCodec.decodeRequest(data) }
    }

    func testGarbageRejectedWithoutCrashing() throws {
        var inputs: [Data] = [Data(), Data([0]), Data("bplist00".utf8), Data("{\"v\":1}".utf8),
                              Data("<?xml version=\"1.0\"?><plist><dict/></plist>".utf8)]
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<300 {
            let n = Int.random(in: 0..<200, using: &rng)
            let junk = Data((0..<n).map { _ in UInt8.random(in: 0...255, using: &rng) })
            inputs.append(junk)
            inputs.append(Data("bplist00".utf8) + junk)
        }
        let valid = try IPCCodec.encode(IPCRequest.readRange(requestID: 7, item: ItemID(rawValue: 6), revision: "r1", offset: 5, length: 9))
        for cut in 0..<valid.count { inputs.append(valid.prefix(cut)) }
        for _ in 0..<2000 {
            var mutated = valid
            for _ in 0..<Int.random(in: 1...4, using: &rng) {
                let i = Int.random(in: 0..<mutated.count, using: &rng)
                mutated[i] ^= UInt8.random(in: 1...255, using: &rng)
            }
            inputs.append(mutated)
        }
        var rejected = 0
        for input in inputs {
            do {
                _ = try IPCCodec.decodeRequest(input)
            } catch {
                guard case .invalidArgument = error else { return XCTFail("unexpected \(error)") }
                rejected += 1
            }
            do {
                _ = try IPCCodec.decodeResponse(input)
            } catch {
                guard case .invalidArgument = error else { return XCTFail("unexpected \(error)") }
            }
        }
        XCTAssertGreaterThan(rejected, inputs.count / 2)
        // A request is not a response.
        assertInvalid { _ = try IPCCodec.decodeResponse(valid) }
    }

    private func assertTooLarge(line: UInt = #line, _ body: () throws -> Void) {
        do {
            try body()
            XCTFail("expected messageTooLarge", line: line)
        } catch {
            guard case .messageTooLarge? = error as? StorageError else { return XCTFail("got \(error)", line: line) }
        }
    }

    private func assertInvalid(line: UInt = #line, _ body: () throws -> Void) {
        do {
            try body()
            XCTFail("expected invalidArgument", line: line)
        } catch {
            guard case .invalidArgument? = error as? StorageError else { return XCTFail("got \(error)", line: line) }
        }
    }
}
