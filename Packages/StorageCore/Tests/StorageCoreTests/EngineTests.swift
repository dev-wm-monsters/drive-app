import Foundation
import StorageCore
import XCTest

/// One-shot latch used to pause a read inside the engine's test hooks.
actor Latch {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var arrivals = 0

    func wait() async {
        arrivals += 1
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

final class CancellationRegistryTests: XCTestCase {
    func testLifecycle() async throws {
        let r = CancellationRegistry()
        try await r.begin(1)
        var cancelled = await r.isCancelled(1)
        XCTAssertFalse(cancelled)
        await r.cancel(1)
        cancelled = await r.isCancelled(1)
        XCTAssertTrue(cancelled)
        await r.end(1)
        await r.end(1)   // idempotent
        let inFlight = await r.inFlightCount
        let tombstones = await r.tombstoneCount
        XCTAssertEqual(inFlight, 0)
        XCTAssertEqual(tombstones, 0, "cancel of an in-flight id leaves no tombstone")
    }

    func testDuplicateInFlightRejected() async throws {
        let r = CancellationRegistry()
        try await r.begin(5)
        do {
            try await r.begin(5)
            XCTFail("expected duplicate rejection")
        } catch {
            guard case .invalidArgument = error else { return XCTFail("got \(error)") }
        }
        await r.end(5)
        try await r.begin(5)   // reusable once ended
        await r.end(5)
    }

    func testCancelBeforeBeginConsumesTombstone() async throws {
        let r = CancellationRegistry()
        await r.cancel(9)
        await r.cancel(9)   // repeated cancel is harmless
        var count = await r.tombstoneCount
        XCTAssertEqual(count, 1)
        try await r.begin(9)
        let cancelled = await r.isCancelled(9)
        XCTAssertTrue(cancelled)
        count = await r.tombstoneCount
        XCTAssertEqual(count, 0)
        await r.end(9)
        let after = await r.isCancelled(9)
        XCTAssertFalse(after)
    }

    func testTombstoneCap() async throws {
        let small = CancellationRegistry(maxTombstones: 4)
        for id: RequestID in 1...10 { await small.cancel(id) }
        let count = await small.tombstoneCount
        XCTAssertEqual(count, 4)
        let oldest = await small.isCancelled(1)
        let newest = await small.isCancelled(10)
        XCTAssertFalse(oldest)
        XCTAssertTrue(newest)

        let r = CancellationRegistry()
        XCTAssertEqual(r.maxTombstones, 1024)
        for id: RequestID in 0..<10_000 { await r.cancel(id) }
        let bounded = await r.tombstoneCount
        XCTAssertEqual(bounded, 1024)
        let kept = await r.isCancelled(9_999)
        let evicted = await r.isCancelled(0)
        XCTAssertTrue(kept)
        XCTAssertFalse(evicted)
    }
}

final class SpikeEngineTests: XCTestCase {
    func testStatus() async {
        let engine = SpikeEngine(version: "0.1.0-test")
        guard case .status(let s) = await engine.handle(.status) else { return XCTFail() }
        XCTAssertEqual(s.version, "0.1.0-test")
        XCTAssertEqual(s.pid, ProcessInfo.processInfo.processIdentifier)
        XCTAssertEqual(s.catalog, "spike")
        XCTAssertLessThanOrEqual(s.startedAt, Date())
    }

    func testMetadataRequests() async {
        let engine = SpikeEngine(version: "t")
        guard case .page(let page) = await engine.handle(.listItems(parent: .root, cursor: nil, limit: 3)) else { return XCTFail() }
        XCTAssertEqual(page.items.count, 3)
        XCTAssertEqual(page.nextCursor, "3")
        let stat = await engine.handle(.stat(ItemID(rawValue: 6)))
        XCTAssertEqual(stat, .attributes(try FixtureCatalog.spike.stat(ItemID(rawValue: 6))))
        let lookup = await engine.handle(.lookup(parent: ItemID(rawValue: 9), name: "deep.bin"))
        guard case .attributes(let a) = lookup else { return XCTFail() }
        XCTAssertEqual(a.id.rawValue, 10)
        let badLimit = await engine.handle(.listItems(parent: .root, cursor: nil, limit: 0))
        guard case .failure(.invalidArgument) = badLimit else { return XCTFail("\(badLimit)") }
        let missing = await engine.handle(.stat(ItemID(rawValue: 1234)))
        XCTAssertEqual(missing, .failure(.unknownItem))
    }

    func testReadRange() async {
        let engine = SpikeEngine(version: "t")
        let fixture = FixtureCatalog.spike.fixture(for: ItemID(rawValue: 7))!
        let response = await engine.handle(.readRange(requestID: 1, item: ItemID(rawValue: 7), revision: "r1",
                                                      offset: Int64(Limits.maxReadReply) - 1, length: 10))
        XCTAssertEqual(response, .bytes(fixture.data(in: ByteRange(offset: Limits.maxReadReply - 1, length: 2))))
        let stale = await engine.handle(.readRange(requestID: 2, item: ItemID(rawValue: 7), revision: "r0", offset: 0, length: 1))
        XCTAssertEqual(stale, .failure(.revisionChanged(expected: "r0", actual: "r1")))
        let negative = await engine.handle(.readRange(requestID: 3, item: ItemID(rawValue: 7), revision: "r1", offset: -1, length: 1))
        guard case .failure(.invalidArgument) = negative else { return XCTFail() }
        let dir = await engine.handle(.readRange(requestID: 4, item: .root, revision: "r1", offset: 0, length: 1))
        XCTAssertEqual(dir, .failure(.isDirectory))
        let eof = await engine.handle(.readRange(requestID: 5, item: ItemID(rawValue: 3), revision: "r1", offset: 1, length: 1))
        XCTAssertEqual(eof, .bytes(Data()))
        let inFlight = await engine.registry.inFlightCount
        XCTAssertEqual(inFlight, 0, "every read ends its registration, including failures")
        // An ID can be reused after its read completed.
        let again = await engine.handle(.readRange(requestID: 1, item: ItemID(rawValue: 3), revision: "r1", offset: 0, length: 1))
        guard case .bytes(let one) = again else { return XCTFail() }
        XCTAssertEqual(one.count, 1)
    }

    func testCancelBeforeRead() async {
        let engine = SpikeEngine(version: "t")
        let ack = await engine.handle(.cancel(77))
        XCTAssertEqual(ack, .cancelled(77))
        let read = await engine.handle(.readRange(requestID: 77, item: ItemID(rawValue: 6), revision: "r1", offset: 0, length: 10))
        XCTAssertEqual(read, .failure(.cancelled))
        let tombstones = await engine.registry.tombstoneCount
        let inFlight = await engine.registry.inFlightCount
        XCTAssertEqual(tombstones, 0)
        XCTAssertEqual(inFlight, 0)
        // Unknown-id cancel is a no-op for other requests.
        let other = await engine.handle(.readRange(requestID: 78, item: ItemID(rawValue: 3), revision: "r1", offset: 0, length: 1))
        guard case .bytes = other else { return XCTFail("\(other)") }
    }

    func testCancelAfterBeginViaHook() async {
        let registry = CancellationRegistry()
        let engine = SpikeEngine(catalog: .spike, version: "t", registry: registry,
                                 afterBegin: { id in await registry.cancel(id) }, afterProduce: nil)
        let r = await engine.handle(.readRange(requestID: 1, item: ItemID(rawValue: 6), revision: "r1", offset: 0, length: 100))
        XCTAssertEqual(r, .failure(.cancelled))
    }

    func testCancelAfterProduceViaHook() async {
        let registry = CancellationRegistry()
        let engine = SpikeEngine(catalog: .spike, version: "t", registry: registry,
                                 afterBegin: nil, afterProduce: { id in await registry.cancel(id) })
        let r = await engine.handle(.readRange(requestID: 1, item: ItemID(rawValue: 6), revision: "r1", offset: 0, length: 100))
        XCTAssertEqual(r, .failure(.cancelled))
        let inFlight = await registry.inFlightCount
        XCTAssertEqual(inFlight, 0)
    }

    /// A real race: the read is parked mid-flight while a concurrent `.cancel` arrives through
    /// `handle`, proving cancel is not queued behind the read.
    func testCancelDuringReadFromAnotherTask() async {
        let latch = Latch()
        let registry = CancellationRegistry()
        let engine = SpikeEngine(catalog: .spike, version: "t", registry: registry,
                                 afterBegin: { _ in await latch.wait() }, afterProduce: nil)
        let read = Task {
            await engine.handle(.readRange(requestID: 500, item: ItemID(rawValue: 6), revision: "r1", offset: 0, length: 4 << 20))
        }
        await waitUntil { await latch.arrivals == 1 }
        let ack = await engine.handle(.cancel(500))
        XCTAssertEqual(ack, .cancelled(500))
        await latch.open()
        let result = await read.value
        XCTAssertEqual(result, .failure(.cancelled))
        let tombstones = await registry.tombstoneCount
        XCTAssertEqual(tombstones, 0, "cancel of an in-flight read leaves no tombstone")
    }

    func testDuplicateInFlightIDRejected() async {
        let latch = Latch()
        let registry = CancellationRegistry()
        let engine = SpikeEngine(catalog: .spike, version: "t", registry: registry,
                                 afterBegin: { _ in await latch.wait() }, afterProduce: nil)
        let first = Task {
            await engine.handle(.readRange(requestID: 9, item: ItemID(rawValue: 3), revision: "r1", offset: 0, length: 1))
        }
        await waitUntil { await latch.arrivals == 1 }
        let dup = await engine.handle(.readRange(requestID: 9, item: ItemID(rawValue: 3), revision: "r1", offset: 0, length: 1))
        guard case .failure(.invalidArgument) = dup else { return XCTFail("\(dup)") }
        await latch.open()
        let firstResult = await first.value
        guard case .bytes(let d) = firstResult else { return XCTFail("\(firstResult)") }
        XCTAssertEqual(d.count, 1, "the original read is unaffected by the rejected duplicate")
    }

    func testSwiftTaskCancellationCancelsRead() async {
        let latch = Latch()
        let engine = SpikeEngine(catalog: .spike, version: "t", registry: CancellationRegistry(),
                                 afterBegin: { _ in await latch.wait() }, afterProduce: nil)
        let read = Task {
            await engine.handle(.readRange(requestID: 1, item: ItemID(rawValue: 4), revision: "r1", offset: 0, length: 10))
        }
        await waitUntil { await latch.arrivals == 1 }
        read.cancel()
        await latch.open()
        let result = await read.value
        XCTAssertEqual(result, .failure(.cancelled))
    }

    func testConcurrentReadsMatchFixture() async {
        let engine = SpikeEngine(version: "t")
        let catalog = FixtureCatalog.spike
        let files = catalog.entries.compactMap { $0.fixture == nil ? nil : $0.attributes }
        let ok = await withTaskGroup(of: Bool.self) { group in
            for i in 0..<64 {
                let a = files[i % files.count]
                let offset = Int64((UInt64(i) &* 2_654_435_761) % (a.size + 2))
                let length = Int64(i * 70_001)
                group.addTask {
                    let r = await engine.handle(.readRange(requestID: RequestID(i), item: a.id, revision: "r1", offset: offset, length: length))
                    let expected = try? catalog.read(a.id, revision: "r1", offset: offset, length: length)
                    return r == .bytes(expected ?? Data([1]))
                }
            }
            var all = true
            for await r in group { all = all && r }
            return all
        }
        XCTAssertTrue(ok)
        let inFlight = await engine.registry.inFlightCount
        XCTAssertEqual(inFlight, 0)
    }

    func testResponsesEncodeWithinLimits() async throws {
        let engine = SpikeEngine(version: "t")
        let r = await engine.handle(.readRange(requestID: 1, item: ItemID(rawValue: 7), revision: "r1", offset: 0, length: Int64.max))
        guard case .bytes(let d) = r else { return XCTFail() }
        XCTAssertEqual(d.count, Int(Limits.maxReadReply))
        let encoded = try IPCCodec.encode(r)
        XCTAssertEqual(try IPCCodec.decodeResponse(encoded), r)
    }

    private func waitUntil(_ condition: @Sendable () async -> Bool) async {
        for _ in 0..<10_000 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("condition never became true")
    }
}

final class ServiceHealthTests: XCTestCase {
    func testTransitions() throws {
        var h = ServiceHealth()
        XCTAssertEqual(h.state, .unknown)
        XCTAssertNoThrow(try h.gate())
        XCTAssertFalse(h.needsReconnect)

        let table: [(ServiceConnectionEvent, ServiceHealth.State)] = [
            (.connected, .healthy), (.replyReceived, .healthy), (.interrupted, .unavailable),
            (.replyReceived, .healthy), (.invalidated, .unavailable), (.connected, .healthy),
            (.replyTimedOut, .unavailable), (.replyTimedOut, .unavailable), (.connected, .healthy),
        ]
        for (event, expected) in table {
            h.record(event)
            XCTAssertEqual(h.state, expected, "after \(event)")
            XCTAssertEqual(h.lastEvent, event)
            if expected == .unavailable {
                XCTAssertTrue(h.needsReconnect)
                XCTAssertThrowsError(try h.gate()) { XCTAssertEqual($0 as? StorageError, .serviceUnavailable) }
            } else {
                XCTAssertNoThrow(try h.gate())
            }
        }
    }

    func testFailureMappingAndDeadline() {
        XCTAssertEqual(ServiceHealth.failure(for: .interrupted), .serviceUnavailable)
        XCTAssertEqual(ServiceHealth.failure(for: .invalidated), .serviceUnavailable)
        XCTAssertEqual(ServiceHealth.failure(for: .replyTimedOut), .timedOut)
        XCTAssertNil(ServiceHealth.failure(for: .connected))
        XCTAssertNil(ServiceHealth.failure(for: .replyReceived))
        XCTAssertEqual(ServiceHealth.foregroundDeadline, .seconds(30))
        XCTAssertEqual(StorageError.serviceUnavailable.posixErrorCode, ENOTCONN)
    }
}

final class POSIXMappingTests: XCTestCase {
    func testMapping() {
        let table: [(StorageError, Int32)] = [
            (.invalidArgument("x"), EINVAL), (.unknownItem, ENOENT), (.unknownAccount, ENOENT),
            (.notDirectory, ENOTDIR), (.isDirectory, EISDIR), (.revisionChanged(expected: "a", actual: "b"), ESTALE),
            (.cancelled, ECANCELED), (.serviceUnavailable, ENOTCONN), (.timedOut, ETIMEDOUT),
            (.readOnly, EROFS), (.messageTooLarge(limit: 1, actual: 2), EMSGSIZE),
        ]
        XCTAssertEqual(table.count, IPCCodecTests.allErrors.count, "every case mapped")
        for (error, code) in table {
            XCTAssertEqual(error.posixErrorCode, code, "\(error)")
            XCTAssertNotEqual(code, 0)
        }
        XCTAssertFalse(StorageError.cancelled.description.isEmpty)
    }
}
