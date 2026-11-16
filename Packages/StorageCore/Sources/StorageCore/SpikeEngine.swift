import Foundation

/// Tracks in-flight read requests and cancellations.
///
/// `cancel` of an ID that is not in flight records a tombstone so a read that *starts after*
/// its cancel (the cancel overtook the read on the wire) is still cancelled. Tombstones are
/// consumed by `begin` and capped at `maxTombstones` (oldest evicted first) so memory stays
/// bounded even if a client cancels IDs that never arrive.
public actor CancellationRegistry {
    public nonisolated let maxTombstones: Int
    /// In-flight IDs → cancelled flag.
    private var inFlight: [RequestID: Bool] = [:]
    private var tombstones: Set<RequestID> = []
    private var tombstoneOrder: [RequestID] = []
    private var tombstoneHead = 0

    public init(maxTombstones: Int = 1024) {
        self.maxTombstones = max(1, maxTombstones)
    }

    /// Registers `id` as in flight. A duplicate in-flight ID → `.invalidArgument`.
    /// If a tombstone exists for `id`, it is consumed and the request starts cancelled.
    public func begin(_ id: RequestID) throws(StorageError) {
        guard inFlight[id] == nil else { throw .invalidArgument("duplicate in-flight request id \(id)") }
        let preCancelled = tombstones.remove(id) != nil
        inFlight[id] = preCancelled
    }

    /// Cancels `id`. Unknown IDs are a harmless no-op apart from recording a bounded tombstone.
    public func cancel(_ id: RequestID) {
        if inFlight[id] != nil {
            inFlight[id] = true
            return
        }
        guard tombstones.insert(id).inserted else { return }
        tombstoneOrder.append(id)
        while tombstones.count > maxTombstones, tombstoneHead < tombstoneOrder.count {
            let oldest = tombstoneOrder[tombstoneHead]
            tombstoneHead += 1
            tombstones.remove(oldest)
        }
        compactOrderIfNeeded()
    }

    public func isCancelled(_ id: RequestID) -> Bool {
        if let cancelled = inFlight[id] { return cancelled }
        return tombstones.contains(id)
    }

    /// Ends `id` (idempotent).
    public func end(_ id: RequestID) {
        inFlight[id] = nil
    }

    public var inFlightCount: Int { inFlight.count }
    public var tombstoneCount: Int { tombstones.count }

    private func compactOrderIfNeeded() {
        // Drop consumed/evicted entries from the FIFO so it stays O(maxTombstones).
        guard tombstoneOrder.count > 2 * maxTombstones else { return }
        tombstoneOrder = tombstoneOrder[tombstoneHead...].filter { tombstones.contains($0) }
        tombstoneHead = 0
    }
}

/// Server-side request handling for the B01 spike (pure and testable); StorageService wraps it
/// behind the XPC listener.
///
/// All engine state is immutable or owned by the `CancellationRegistry` actor, so `handle` is
/// `nonisolated`: concurrent reads run in parallel and a `.cancel` is never queued behind
/// byte generation.
///
/// Read cancellation: the registry is checked after `begin` and again after the bytes are
/// produced; either hit answers `.failure(.cancelled)` (ECANCELED). Swift task cancellation
/// of the handling task has the same effect.
public actor SpikeEngine {
    package typealias Hook = @Sendable (RequestID) async -> Void

    public nonisolated let catalog: FixtureCatalog
    public nonisolated let version: String
    public nonisolated let startedAt: Date
    public nonisolated let registry: CancellationRegistry
    private nonisolated let afterBegin: Hook?
    private nonisolated let afterProduce: Hook?

    public init(catalog: FixtureCatalog = .spike, version: String) {
        self.init(catalog: catalog, version: version, registry: CancellationRegistry(), afterBegin: nil, afterProduce: nil)
    }

    /// Test seam: hooks run after the request is registered and after bytes are produced.
    package init(catalog: FixtureCatalog, version: String, registry: CancellationRegistry,
                 afterBegin: Hook?, afterProduce: Hook?) {
        self.catalog = catalog
        self.version = version
        self.startedAt = Date()
        self.registry = registry
        self.afterBegin = afterBegin
        self.afterProduce = afterProduce
    }

    public nonisolated func status() -> ServiceStatus {
        ServiceStatus(version: version, pid: ProcessInfo.processInfo.processIdentifier,
                      startedAt: startedAt, catalog: catalog.name)
    }

    public nonisolated func handle(_ request: IPCRequest) async -> IPCResponse {
        do throws(StorageError) {
            switch request {
            case .status:
                return .status(status())
            case let .listItems(parent, cursor, limit):
                return .page(try catalog.list(parent: parent, cursor: cursor, limit: limit))
            case let .stat(id):
                return .attributes(try catalog.stat(id))
            case let .lookup(parent, name):
                return .attributes(try catalog.lookup(parent: parent, name: name))
            case let .readRange(requestID, item, revision, offset, length):
                return await read(requestID: requestID, item: item, revision: revision, offset: offset, length: length)
            case let .cancel(id):
                await registry.cancel(id)
                return .cancelled(id)
            }
        } catch {
            return .failure(error)
        }
    }

    private nonisolated func read(requestID: RequestID, item: ItemID, revision: String,
                                  offset: Int64, length: Int64) async -> IPCResponse {
        do {
            try await registry.begin(requestID)
        } catch {
            return .failure(error)
        }
        let response = await readRegistered(requestID: requestID, item: item, revision: revision,
                                            offset: offset, length: length)
        await registry.end(requestID)
        return response
    }

    private nonisolated func readRegistered(requestID: RequestID, item: ItemID, revision: String,
                                            offset: Int64, length: Int64) async -> IPCResponse {
        if let afterBegin { await afterBegin(requestID) }
        if await cancelled(requestID) { return .failure(.cancelled) }
        let data: Data
        do {
            data = try catalog.read(item, revision: revision, offset: offset, length: length)
        } catch {
            return .failure(error)
        }
        if let afterProduce { await afterProduce(requestID) }
        if await cancelled(requestID) { return .failure(.cancelled) }
        return .bytes(data)
    }

    private nonisolated func cancelled(_ id: RequestID) async -> Bool {
        if Task.isCancelled { return true }
        return await registry.isCancelled(id)
    }
}
