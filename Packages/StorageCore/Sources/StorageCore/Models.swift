import Foundation

/// Identifies one in-flight read so it can be cancelled.
public typealias RequestID = UInt64

/// Stable identifier of an item in a catalog. `root` is always 1.
public struct ItemID: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }
    public static let root = ItemID(rawValue: 1)
    public var description: String { "item#\(rawValue)" }
}

public enum ItemKind: String, Codable, Sendable {
    case directory
    case file
}

public struct ItemAttributes: Codable, Hashable, Sendable {
    public var id: ItemID
    /// Parent directory. The root is its own parent.
    public var parent: ItemID
    public var name: String
    public var kind: ItemKind
    /// Byte size for files; 0 for directories.
    public var size: UInt64
    /// Opaque revision string; reads must name the revision they expect.
    public var revision: String

    public init(id: ItemID, parent: ItemID, name: String, kind: ItemKind, size: UInt64, revision: String) {
        self.id = id
        self.parent = parent
        self.name = name
        self.kind = kind
        self.size = size
        self.revision = revision
    }
}

public struct ListPage: Codable, Hashable, Sendable {
    public var items: [ItemAttributes]
    /// Opaque cursor for the next page; `nil` when the listing is complete.
    public var nextCursor: String?

    public init(items: [ItemAttributes], nextCursor: String?) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

/// A half-open byte range `[offset, offset + length)`.
public struct ByteRange: Codable, Hashable, Sendable, CustomStringConvertible {
    public var offset: UInt64
    public var length: UInt64

    public init(offset: UInt64, length: UInt64) {
        self.offset = offset
        self.length = length
    }

    /// Exclusive end. Saturates at `UInt64.max` instead of trapping for hand-built ranges;
    /// ranges produced by `RangeMath.clamp` never overflow.
    public var end: UInt64 {
        let (sum, overflow) = offset.addingReportingOverflow(length)
        return overflow ? .max : sum
    }

    public var isEmpty: Bool { length == 0 }

    public var description: String { "[\(offset), \(end))" }
}

/// Size budgets from docs/03-trd.md and docs/02-srd.md (NFR04).
public enum Limits {
    /// Largest byte payload in one read reply (TRD: "Cap read replies to 4 MiB").
    public static let maxReadReply: UInt64 = 4 * 1024 * 1024
    /// Largest encoded control message (anything that is not a `.bytes` reply).
    public static let maxControlMessage: Int = 1024 * 1024
    /// Encoding overhead allowed on top of `maxReadReply` for an encoded `.bytes` reply.
    public static let readReplyOverhead: Int = 64 * 1024
    /// Largest encoded `.bytes` response: `maxReadReply + readReplyOverhead`.
    public static let maxReadReplyMessage: Int = Int(maxReadReply) + readReplyOverhead
    /// Local cache segment unit.
    public static let segmentSize: UInt64 = 4 * 1024 * 1024
    /// Bound on outstanding network reads (NFR04).
    public static let maxConcurrentNetworkReads: Int = 8
    /// Largest `limit` accepted by `listItems`.
    public static let maxListLimit: Int = 1000
}
