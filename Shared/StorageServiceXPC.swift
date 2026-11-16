// StorageServiceXPC.swift
// Shared XPC glue for B01. Compiled into three targets: DriveApp (host app),
// DriveAppFS (FSKit extension) and DriveAppStorageService (LaunchAgent).
// macOS only. Payloads are opaque `Data`; StorageCore's IPCCodec owns encoding,
// validation and size limits (TRD "Local IPC contract").
//
// Docs relied on:
// - https://developer.apple.com/documentation/foundation/nsxpcconnection/init(machservicename:options:)
// - https://developer.apple.com/documentation/foundation/nsxpcconnection/setcodesigningrequirement(_:)  (macOS 13+;
//   a malformed requirement is a fatal error in Swift, so requirement strings are built only from validated parts)
// - https://developer.apple.com/documentation/foundation/nsxpcconnection/remoteobjectproxywitherrorhandler(_:)
// - https://developer.apple.com/documentation/foundation/nsxpcconnection/interruptionhandler
// - https://developer.apple.com/documentation/foundation/nsxpcconnection/invalidationhandler
// - https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements
//
// NSXPCConnection is NOT Sendable in the macOS 26.5 SDK: NSXPCConnection.h sits inside
// NS_HEADER_AUDIT_BEGIN(nullability, sendability) without NS_SWIFT_SENDABLE, and the Foundation
// overlay adds no conformance. It may be stored in and returned from `Mutex` state, but it must not
// be passed into a `withLock` closure (that merges it into the `inout sending` region: Swift 6 error).
// G0-VERIFY: checked only against a non-Sendable stand-in with Swift 6.2 on Linux (`-emit-sil`);
// confirm on the first Xcode build.

import Foundation
import os
import StorageCore
import Synchronization

// MARK: - XPC surface

/// The only XPC method. `request` is an `IPCCodec`-encoded `IPCRequest`; the reply is an
/// `IPCCodec`-encoded `IPCResponse`. The service always replies, even to malformed input.
@objc public protocol StorageServiceXPC {
    func send(_ request: Data, withReply reply: @escaping @Sendable (Data) -> Void)
}

// MARK: - Configuration read from Info.plist (never hard-coded)

enum InfoPlistValue {
    /// A non-empty string value. An unexpanded `$(VAR)` means the build setting was missing.
    static func string(_ key: String, in bundle: Bundle) -> String? {
        guard let raw = bundle.object(forInfoDictionaryKey: key) as? String else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains("$(") else { return nil }
        return value
    }
}

/// Reads the StorageService Mach service name that every target's Info.plist carries as
/// `DriveAppStorageMachService` = `$(DEVELOPMENT_TEAM).$(APP_BUNDLE_ID).storage`.
public enum MachServiceName {
    public static let infoPlistKey = "DriveAppStorageMachService"

    public static func resolve(in bundle: Bundle = .main) -> String? {
        InfoPlistValue.string(infoPlistKey, in: bundle)
    }
}

/// Signing identity of the DriveApp family, from Info.plist keys
/// `DriveAppTeamID` = `$(DEVELOPMENT_TEAM)` and `DriveAppBaseBundleID` = `$(APP_BUNDLE_ID)`.
public struct ServiceIdentity: Sendable, Equatable {
    /// `nil` for an ad-hoc / no-team build.
    public let teamID: String?
    public let baseBundleID: String

    public var appBundleID: String { baseBundleID }
    public var extensionBundleID: String { baseBundleID + ".fsext" }
    public var serviceBundleID: String { baseBundleID + ".storageservice" }

    public static func resolve(in bundle: Bundle = .main) -> ServiceIdentity? {
        guard let base = InfoPlistValue.string("DriveAppBaseBundleID", in: bundle),
              isValidBundleID(base) else { return nil }
        let team = InfoPlistValue.string("DriveAppTeamID", in: bundle).flatMap { isValidTeamID($0) ? $0 : nil }
        return ServiceIdentity(teamID: team, baseBundleID: base)
    }

    /// Requirement: Apple-issued certificate (Apple Development / Developer ID) of our team, and
    /// one of `identifiers`. `nil` when there is no team or an identifier is malformed.
    public func requirement(forPeers identifiers: [String]) -> String? {
        guard let teamID, !identifiers.isEmpty, identifiers.allSatisfy(Self.isValidBundleID) else { return nil }
        let ids = identifiers.map { "identifier \"\($0)\"" }.joined(separator: " or ")
        return "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\" and (\(ids))"
    }

    /// Team IDs are 10 upper-case alphanumerics.
    static func isValidTeamID(_ value: String) -> Bool {
        value.utf8.count == 10 && value.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) }
    }

    /// Reverse-DNS characters only, so the value cannot break out of a quoted requirement string.
    static func isValidBundleID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 255 && value.utf8.allSatisfy { byte in
            (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
                || byte == 0x2E || byte == 0x2D
        }
    }
}

/// Whether peer code signing is enforced. Skipping is possible ONLY in DEBUG builds.
public enum PeerRequirement: Sendable, Equatable {
    case enforce(String)
    /// DEBUG builds without a team (ad-hoc "Sign to Run Locally"): no peer check. Logged loudly.
    case skippedForDebugBuild
    /// Release build without a usable identity: refuse to communicate.
    case unavailable

    public static func make(identity: ServiceIdentity?, peers: (ServiceIdentity) -> [String]) -> PeerRequirement {
        if let identity, let requirement = identity.requirement(forPeers: peers(identity)) {
            return .enforce(requirement)
        }
        #if DEBUG
        return .skippedForDebugBuild
        #else
        return .unavailable
        #endif
    }
}

// MARK: - Response unwrapping

extension IPCResponse {
    public func expectAttributes() throws(StorageError) -> ItemAttributes {
        switch self {
        case .attributes(let value): return value
        case .failure(let error): throw error
        default: throw .invalidArgument("unexpected reply")
        }
    }

    public func expectPage() throws(StorageError) -> ListPage {
        switch self {
        case .page(let value): return value
        case .failure(let error): throw error
        default: throw .invalidArgument("unexpected reply")
        }
    }

    public func expectBytes() throws(StorageError) -> Data {
        switch self {
        case .bytes(let value): return value
        case .failure(let error): throw error
        default: throw .invalidArgument("unexpected reply")
        }
    }

    public func expectStatus() throws(StorageError) -> ServiceStatus {
        switch self {
        case .status(let value): return value
        case .failure(let error): throw error
        default: throw .invalidArgument("unexpected reply")
        }
    }
}

// MARK: - Client

/// Client used by the FSKit extension and the host app.
///
/// - Lazily creates `NSXPCConnection(machServiceName:options: [])` and requires the peer to be
///   `<base>.storageservice` signed by the same team.
/// - Interruption/invalidation feed `ServiceHealth`; in-flight calls fail with `.serviceUnavailable`
///   (XPC calls each pending error handler), never with stale success (FR03).
/// - Every call has a deadline (default 30 s, NFR06). On timeout or Swift task cancellation a
///   `.readRange` is followed by a best-effort `.cancel(requestID)`.
public final class StorageServiceClient: Sendable {
    private struct State {
        var connection: NSXPCConnection?
        var health = ServiceHealth()
        var serial: UInt64 = 0
    }

    private let machServiceName: String?
    private let requirement: PeerRequirement
    /// Random high 32 bits: request IDs from the app and the extension share the service's
    /// cancellation registry, so they must not collide.
    private let requestIDPrefix: UInt64
    private let state = Mutex(State())
    private let logger: Logger

    public init(bundle: Bundle = .main) {
        self.machServiceName = MachServiceName.resolve(in: bundle)
        self.requirement = PeerRequirement.make(identity: ServiceIdentity.resolve(in: bundle)) { [$0.serviceBundleID] }
        self.requestIDPrefix = UInt64(UInt32.random(in: 1...UInt32.max)) << 32
        self.logger = Logger(subsystem: bundle.bundleIdentifier ?? "DriveApp", category: "storage-client")
        if machServiceName == nil {
            logger.fault("Info.plist key \(MachServiceName.infoPlistKey, privacy: .public) is missing; every call will fail")
        }
        switch requirement {
        case .enforce:
            break
        case .skippedForDebugBuild:
            logger.fault("DEBUG BUILD WITHOUT TEAM ID: StorageService peer code signing is NOT checked")
        case .unavailable:
            logger.fault("No team ID / base bundle ID in Info.plist: refusing unauthenticated StorageService connections")
        }
    }

    /// Monotonic within this process (low 32 bits), unique across processes with high probability.
    public func nextRequestID() -> RequestID {
        let serial = state.withLock { state -> UInt64 in
            state.serial &+= 1
            return state.serial & 0xFFFF_FFFF
        }
        return requestIDPrefix | serial
    }

    public var health: ServiceHealth {
        state.withLock { $0.health }
    }

    /// Drops the connection (for example when the volume deactivates). The next call reconnects.
    public func invalidate() {
        let connection = state.withLock { state -> NSXPCConnection? in
            defer { state.connection = nil }
            return state.connection
        }
        connection?.invalidate()
    }

    public func call(_ request: IPCRequest,
                     timeout: Duration = ServiceHealth.foregroundDeadline) async throws(StorageError) -> IPCResponse {
        if Task.isCancelled { throw .cancelled }
        let payload = try IPCCodec.encode(request)
        let connection = try connectionForCall()
        let slot = ReplySlot()

        let timer = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            if slot.resume(.failure(.timedOut)) {
                self?.record(.replyTimedOut)
            }
        }
        defer { timer.cancel() }

        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Result<Data, StorageError>, Never>) in
                // Already cancelled or timed out: do not send a request nobody will wait for.
                guard slot.install(continuation) else { return }
                let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
                    // Interrupted/invalidated before a reply. The connection handlers record health.
                    slot.resume(.failure(.serviceUnavailable))
                }
                guard let service = proxy as? StorageServiceXPC else {
                    slot.resume(.failure(.serviceUnavailable))
                    return
                }
                service.send(payload) { reply in
                    slot.resume(.success(reply))
                }
            }
        } onCancel: {
            slot.resume(.failure(.cancelled))
        }

        switch result {
        case .success(let data):
            record(.replyReceived)
            return try IPCCodec.decodeResponse(data)
        case .failure(let error):
            if error == .timedOut || error == .cancelled, let id = Self.cancellableID(of: request) {
                sendCancel(id, on: connection)
            }
            throw error
        }
    }

    // MARK: Private

    private static func cancellableID(of request: IPCRequest) -> RequestID? {
        if case let .readRange(requestID, _, _, _, _) = request { return requestID }
        return nil
    }

    private func connectionForCall() throws(StorageError) -> NSXPCConnection {
        guard let machServiceName else { throw .serviceUnavailable }
        let requirementString: String?
        switch requirement {
        case .enforce(let value): requirementString = value
        case .skippedForDebugBuild: requirementString = nil
        case .unavailable: throw .serviceUnavailable
        }

        let outcome = state.withLock { state -> Result<NSXPCConnection, StorageError> in
            if let existing = state.connection {
                // After an interruption the same connection is reused; launchd relaunches the
                // agent on the next message.
                if state.health.needsReconnect { state.health.record(.connected) }
                do throws(StorageError) {
                    try state.health.gate()
                } catch {
                    return .failure(error)
                }
                return .success(existing)
            }
            let connection = makeConnection(machServiceName: machServiceName, requirement: requirementString)
            state.connection = connection
            state.health.record(.connected)
            return .success(connection)
        }
        switch outcome {
        case .success(let connection): return connection
        case .failure(let error): throw error
        }
    }

    private func makeConnection(machServiceName: String, requirement: String?) -> NSXPCConnection {
        let connection = NSXPCConnection(machServiceName: machServiceName, options: [])
        connection.remoteObjectInterface = NSXPCInterface(with: StorageServiceXPC.self)
        if let requirement {
            // Must be set before resume(); the peer is checked against its audit token by XPC.
            connection.setCodeSigningRequirement(requirement)
        }
        connection.interruptionHandler = { [weak self] in
            self?.logger.error("StorageService connection interrupted")
            self?.record(.interrupted)
        }
        connection.invalidationHandler = { [weak self, weak connection] in
            self?.logger.error("StorageService connection invalidated")
            self?.connectionInvalidated(connection)
        }
        connection.resume()
        return connection
    }

    private func connectionInvalidated(_ connection: NSXPCConnection?) {
        // Compare by ObjectIdentifier (Sendable): using the non-Sendable connection itself inside
        // withLock merges it into the `inout sending` state's region, which Swift 6 rejects.
        let invalidated = connection.map(ObjectIdentifier.init)
        state.withLock { state in
            if let invalidated, let current = state.connection, ObjectIdentifier(current) == invalidated {
                state.connection = nil
            }
            state.health.record(.invalidated)
        }
    }

    private func record(_ event: ServiceConnectionEvent) {
        state.withLock { $0.health.record(event) }
    }

    private func sendCancel(_ id: RequestID, on connection: NSXPCConnection) {
        guard let payload = try? IPCCodec.encode(IPCRequest.cancel(id)) else { return }
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in }
        (proxy as? StorageServiceXPC)?.send(payload) { _ in }
        logger.info("Sent cancel for request \(id, privacy: .public)")
    }
}

/// One reply, delivered exactly once, from whichever comes first: the XPC reply, the XPC error
/// handler, the deadline, or task cancellation (which may fire before the continuation exists).
private final class ReplySlot: Sendable {
    private struct Box {
        var continuation: CheckedContinuation<Result<Data, StorageError>, Never>?
        var early: Result<Data, StorageError>?
        var finished = false
    }

    private let box = Mutex(Box())

    /// Returns false if a result was already delivered (the continuation is resumed with it).
    func install(_ continuation: CheckedContinuation<Result<Data, StorageError>, Never>) -> Bool {
        let ready = box.withLock { box -> Result<Data, StorageError>? in
            if let early = box.early {
                box.early = nil
                box.finished = true
                return early
            }
            box.continuation = continuation
            return nil
        }
        guard let ready else { return true }
        continuation.resume(returning: ready)
        return false
    }

    /// Returns true if `result` is the one delivered.
    @discardableResult
    func resume(_ result: Result<Data, StorageError>) -> Bool {
        let (continuation, won) = box.withLock { box -> (CheckedContinuation<Result<Data, StorageError>, Never>?, Bool) in
            if box.finished || box.early != nil { return (nil, false) }
            if let continuation = box.continuation {
                box.continuation = nil
                box.finished = true
                return (continuation, true)
            }
            box.early = result
            return (nil, true)
        }
        continuation?.resume(returning: result)
        return won
    }
}
