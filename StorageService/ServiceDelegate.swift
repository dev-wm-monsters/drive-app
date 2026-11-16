// ServiceDelegate.swift
// DriveAppStorageService: per-connection admission and the exported XPC object.
//
// Docs relied on:
// - https://developer.apple.com/documentation/foundation/nsxpclistenerdelegate/listener(_:shouldacceptnewconnection:)
// - https://developer.apple.com/documentation/foundation/nsxpcconnection/setcodesigningrequirement(_:)  (macOS 13+)
// - https://developer.apple.com/documentation/foundation/nsxpcconnection/effectiveuseridentifier
// - https://developer.apple.com/documentation/os/logger  (privacy: item names are .private, bytes never logged)
//
// Defence in depth: the listener already enforces `setConnectionCodeSigningRequirement` (main.swift).
// Here every accepted connection additionally gets the same requirement on the connection itself
// (XPC evaluates it against the peer's audit token and invalidates the connection on mismatch) and
// must belong to the same user.
// G0-VERIFY: NSXPCConnection exposes no public audit-token API (`auditToken` is SPI), so there is
// no separate SecCode check here; a PID-based SecCodeCopyGuestWithAttributes check would be racy
// (PID reuse) and is deliberately not used. Validate with a differently-signed test client that
// both the listener-level and connection-level requirements reject it.

import Foundation
import os
import StorageCore

final class ServiceDelegate: NSObject, NSXPCListenerDelegate, Sendable {
    private let engine: SpikeEngine
    private let peerRequirement: String?
    private let logger: Logger

    init(engine: SpikeEngine, peerRequirement: String?, logger: Logger) {
        self.engine = engine
        self.peerRequirement = peerRequirement
        self.logger = logger
        super.init()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let pid = connection.processIdentifier
        guard connection.effectiveUserIdentifier == getuid() else {
            logger.error("Rejected XPC client pid \(pid, privacy: .public): different user")
            return false
        }
        if let peerRequirement {
            connection.setCodeSigningRequirement(peerRequirement)
        }
        connection.exportedInterface = NSXPCInterface(with: StorageServiceXPC.self)
        connection.exportedObject = ServiceEndpoint(engine: engine, logger: logger, peerPID: pid)
        let logger = self.logger
        connection.interruptionHandler = {
            logger.info("XPC client pid \(pid, privacy: .public) interrupted")
        }
        connection.invalidationHandler = {
            logger.info("XPC client pid \(pid, privacy: .public) invalidated")
        }
        connection.resume()
        logger.info("Accepted XPC client pid \(pid, privacy: .public)")
        return true
    }
}

/// Exported object: Data → IPCCodec.decodeRequest → SpikeEngine.handle → encoded reply.
/// Every message gets exactly one reply, including malformed ones (encoded `.failure`).
final class ServiceEndpoint: NSObject, StorageServiceXPC, Sendable {
    private let engine: SpikeEngine
    private let logger: Logger
    private let peerPID: Int32

    init(engine: SpikeEngine, logger: Logger, peerPID: Int32) {
        self.engine = engine
        self.logger = logger
        self.peerPID = peerPID
        super.init()
    }

    func send(_ request: Data, withReply reply: @escaping @Sendable (Data) -> Void) {
        let decoded: IPCRequest
        do throws(StorageError) {
            decoded = try IPCCodec.decodeRequest(request)
        } catch {
            logger.error("pid \(self.peerPID, privacy: .public): rejected request (\(request.count, privacy: .public) bytes): \(error.description, privacy: .public)")
            reply(Self.encode(.failure(error)))
            return
        }
        log(decoded)
        let engine = self.engine
        let logger = self.logger
        Task {
            let response = await engine.handle(decoded)
            if case .failure(let error) = response {
                logger.info("Request failed: \(error.description, privacy: .public)")
            }
            reply(Self.encode(response))
        }
    }

    /// Never fails: an unencodable response becomes an encoded `.failure`; if even that fails the
    /// reply is empty Data, which the client decodes as `.invalidArgument` (EINVAL).
    private static func encode(_ response: IPCResponse) -> Data {
        do throws(StorageError) {
            return try IPCCodec.encode(response)
        } catch {
            return (try? IPCCodec.encode(IPCResponse.failure(error))) ?? Data()
        }
    }

    /// Request metadata only; never byte contents. Names are private.
    private func log(_ request: IPCRequest) {
        switch request {
        case .status:
            logger.debug("pid \(self.peerPID, privacy: .public): status")
        case let .listItems(parent, _, limit):
            logger.debug("pid \(self.peerPID, privacy: .public): listItems parent=\(parent.rawValue, privacy: .public) limit=\(limit, privacy: .public)")
        case let .stat(id):
            logger.debug("pid \(self.peerPID, privacy: .public): stat id=\(id.rawValue, privacy: .public)")
        case let .lookup(parent, name):
            logger.debug("pid \(self.peerPID, privacy: .public): lookup parent=\(parent.rawValue, privacy: .public) name=\(name, privacy: .private)")
        case let .readRange(requestID, item, _, offset, length):
            logger.debug("pid \(self.peerPID, privacy: .public): readRange req=\(requestID, privacy: .public) id=\(item.rawValue, privacy: .public) offset=\(offset, privacy: .public) length=\(length, privacy: .public)")
        case let .cancel(requestID):
            logger.info("pid \(self.peerPID, privacy: .public): cancel req=\(requestID, privacy: .public)")
        }
    }
}
