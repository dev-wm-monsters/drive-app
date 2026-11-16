import Foundation

/// Requests carried as opaque `Data` over the XPC connection. StorageCore owns encoding
/// and validation so that the XPC glue never interprets payloads itself.
public enum IPCRequest: Codable, Hashable, Sendable {
    case status
    case listItems(parent: ItemID, cursor: String?, limit: Int)
    case stat(ItemID)
    case lookup(parent: ItemID, name: String)
    case readRange(requestID: RequestID, item: ItemID, revision: String, offset: Int64, length: Int64)
    case cancel(RequestID)
}

public enum IPCResponse: Codable, Hashable, Sendable {
    case status(ServiceStatus)
    case page(ListPage)
    case attributes(ItemAttributes)
    /// At most `Limits.maxReadReply` bytes.
    case bytes(Data)
    /// Acknowledges a `.cancel(id)` request. A cancelled read itself answers `.failure(.cancelled)`.
    case cancelled(RequestID)
    case failure(StorageError)
}

public struct ServiceStatus: Codable, Hashable, Sendable {
    public var version: String
    public var pid: Int32
    public var startedAt: Date
    public var catalog: String

    public init(version: String, pid: Int32, startedAt: Date, catalog: String) {
        self.version = version
        self.pid = pid
        self.startedAt = startedAt
        self.catalog = catalog
    }
}

/// Binary property-list codec with size limits enforced on both encode and decode.
///
/// Wire format: a binary plist of `{"v": 1, "m": <message>}`. An unknown `v` is rejected.
/// - Requests: encoded size ≤ `Limits.maxControlMessage`.
/// - `.bytes` responses: ≤ `Limits.maxReadReplyMessage` (4 MiB + 64 KiB); the payload itself
///   must be ≤ `Limits.maxReadReply`.
/// - Every other response: ≤ `Limits.maxControlMessage`.
///
/// Decoding checks `Data.count` before parsing (→ `.messageTooLarge`) and maps any parse
/// failure to `.invalidArgument`; it never traps on hostile input.
public enum IPCCodec {
    public static let wireVersion = 1

    private struct Envelope<Message: Codable>: Codable {
        let v: Int
        let m: Message
    }

    public static func encode(_ request: IPCRequest) throws(StorageError) -> Data {
        let data = try encodeEnvelope(request)
        try check(data.count, limit: Limits.maxControlMessage)
        return data
    }

    public static func decodeRequest(_ data: Data) throws(StorageError) -> IPCRequest {
        try check(data.count, limit: Limits.maxControlMessage)
        return try decodeEnvelope(IPCRequest.self, from: data)
    }

    public static func encode(_ response: IPCResponse) throws(StorageError) -> Data {
        if case .bytes(let payload) = response, payload.count > Int(Limits.maxReadReply) {
            throw .messageTooLarge(limit: Int(Limits.maxReadReply), actual: payload.count)
        }
        let data = try encodeEnvelope(response)
        try check(data.count, limit: limit(for: response))
        return data
    }

    public static func decodeResponse(_ data: Data) throws(StorageError) -> IPCResponse {
        try check(data.count, limit: Limits.maxReadReplyMessage)
        let response = try decodeEnvelope(IPCResponse.self, from: data)
        try check(data.count, limit: limit(for: response))
        if case .bytes(let payload) = response, payload.count > Int(Limits.maxReadReply) {
            throw .messageTooLarge(limit: Int(Limits.maxReadReply), actual: payload.count)
        }
        return response
    }

    private static func limit(for response: IPCResponse) -> Int {
        if case .bytes = response { return Limits.maxReadReplyMessage }
        return Limits.maxControlMessage
    }

    private static func check(_ count: Int, limit: Int) throws(StorageError) {
        guard count <= limit else { throw .messageTooLarge(limit: limit, actual: count) }
    }

    private static func encodeEnvelope<M: Codable>(_ message: M) throws(StorageError) -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        do {
            return try encoder.encode(Envelope(v: wireVersion, m: message))
        } catch {
            throw .invalidArgument("encode failed: \(error)")
        }
    }

    private static func decodeEnvelope<M: Codable>(_ type: M.Type, from data: Data) throws(StorageError) -> M {
        let envelope: Envelope<M>
        do {
            envelope = try PropertyListDecoder().decode(Envelope<M>.self, from: data)
        } catch {
            throw .invalidArgument("malformed message")
        }
        guard envelope.v == wireVersion else {
            throw .invalidArgument("unsupported wire version \(envelope.v)")
        }
        return envelope.m
    }
}
