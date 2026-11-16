import Foundation

/// Deterministic, random-access byte generator: the byte at offset `i` is a pure function of
/// `(seed, i)`.
///
/// Algorithm (stable; changing it changes every fixture hash): for 8-byte block index
/// `k = i / 8`, `block = splitmix64(seed ^ k)` stored little-endian, and byte `i` is
/// `block[i % 8]`. The default seed is FNV-1a 64 of the UTF-8 name.
public struct FixtureFile: Sendable, Hashable {
    public let name: String
    public let size: UInt64
    public let seed: UInt64

    public init(name: String, size: UInt64, seed: UInt64) {
        self.name = name
        self.size = size
        self.seed = seed
    }

    /// Seed derived from the name (FNV-1a 64 of its UTF-8 bytes).
    public init(name: String, size: UInt64) {
        self.init(name: name, size: size, seed: FixtureFile.fnv1a64(name))
    }

    /// The bytes in `range`, clamped to `[0, size)`. A range at/after EOF yields `[]`.
    public func bytes(in range: ByteRange) -> [UInt8] {
        let r = clamped(range)
        guard r.length > 0 else { return [] }
        return [UInt8](unsafeUninitializedCapacity: Int(r.length)) { buffer, count in
            fill(UnsafeMutableRawBufferPointer(buffer), from: r.offset)
            count = Int(r.length)
        }
    }

    /// Same as `bytes(in:)`, generated directly into a `Data`.
    public func data(in range: ByteRange) -> Data {
        let r = clamped(range)
        guard r.length > 0 else { return Data() }
        var data = Data(count: Int(r.length))
        data.withUnsafeMutableBytes { fill($0, from: r.offset) }
        return data
    }

    /// The byte at `offset` (not bounds-checked against `size`).
    public func byte(at offset: UInt64) -> UInt8 {
        let block = FixtureFile.splitmix64(seed ^ (offset / 8))
        return UInt8(truncatingIfNeeded: block >> ((offset % 8) * 8))
    }

    /// Fills `buffer` with the generator output starting at absolute `offset`
    /// (ignores `size`; callers clamp).
    public func fill(_ buffer: UnsafeMutableRawBufferPointer, from offset: UInt64) {
        let count = buffer.count
        guard count > 0, let base = buffer.baseAddress else { return }
        var i = 0
        var pos = offset
        // Leading partial block.
        while i < count, pos % 8 != 0 {
            base.storeBytes(of: byte(at: pos), toByteOffset: i, as: UInt8.self)
            i += 1
            pos += 1
        }
        // Whole blocks.
        var k = pos / 8
        while count - i >= 8 {
            let v = FixtureFile.splitmix64(seed ^ k).littleEndian
            (base + i).storeBytes(of: v, as: UInt64.self)
            i += 8
            k &+= 1
        }
        // Trailing partial block.
        pos = k * 8
        while i < count {
            base.storeBytes(of: byte(at: pos), toByteOffset: i, as: UInt8.self)
            i += 1
            pos += 1
        }
    }

    private func clamped(_ range: ByteRange) -> ByteRange {
        guard range.offset < size else { return ByteRange(offset: range.offset, length: 0) }
        return ByteRange(offset: range.offset, length: min(range.length, size - range.offset))
    }

    public static func splitmix64(_ x: UInt64) -> UInt64 {
        var z = x &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    public static func fnv1a64(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01B3
        }
        return hash
    }
}

/// An immutable, in-memory catalog of directories and generated files.
public struct FixtureCatalog: Sendable {
    /// One item plus its path relative to the catalog root (`/`-separated, no leading slash).
    public struct Entry: Sendable, Hashable {
        public let path: String
        public let attributes: ItemAttributes
        /// Generator for files; `nil` for directories.
        public let fixture: FixtureFile?
    }

    /// Catalog name reported in `ServiceStatus.catalog`.
    public let name: String
    private let items: [ItemID: Entry]
    /// Children of each directory, sorted by UTF-8 byte order of the name.
    private let children: [ItemID: [ItemID]]

    /// The B01 spike layout (docs/05-test-plan.md fixture sizes):
    ///
    /// ```
    /// /                      id 1
    /// ├── empty.bin          id 2   0 B
    /// ├── one.bin            id 3   1 B
    /// ├── 64k.bin            id 4   65 536 B
    /// ├── seg-minus-1.bin    id 5   4 MiB − 1
    /// ├── seg.bin            id 6   4 MiB
    /// ├── seg-plus-1.bin     id 7   4 MiB + 1
    /// ├── Ünïcødé name.bin   id 8   12 345 B   (NFC)
    /// └── nested/            id 9
    ///     └── deep.bin       id 10  100 000 B
    /// ```
    /// Every item has revision `"r1"`.
    public static let spike: FixtureCatalog = {
        let mib: UInt64 = 1024 * 1024
        return FixtureCatalog(name: "spike", revision: "r1", layout: [
            .file("empty.bin", 0),
            .file("one.bin", 1),
            .file("64k.bin", 65_536),
            .file("seg-minus-1.bin", 4 * mib - 1),
            .file("seg.bin", 4 * mib),
            .file("seg-plus-1.bin", 4 * mib + 1),
            .file("\u{00DC}n\u{00EF}c\u{00F8}d\u{00E9} name.bin", 12_345),
            .directory("nested", [
                .file("deep.bin", 100_000),
            ]),
        ])
    }()

    /// Tree description used to build a catalog. IDs are assigned depth-first in declaration
    /// order starting at 2 (root is 1), so they are stable for a given layout.
    public indirect enum Node: Sendable {
        case file(String, UInt64)
        case directory(String, [Node])
    }

    public init(name: String, revision: String, layout: [Node]) {
        var items: [ItemID: Entry] = [:]
        var children: [ItemID: [ItemID]] = [:]
        var nextID: UInt64 = 2
        items[.root] = Entry(
            path: "",
            attributes: ItemAttributes(id: .root, parent: .root, name: "", kind: .directory, size: 0, revision: revision),
            fixture: nil)

        func add(_ nodes: [Node], parent: ItemID, parentPath: String) {
            var ids: [ItemID] = []
            for node in nodes {
                let id = ItemID(rawValue: nextID)
                nextID += 1
                ids.append(id)
                switch node {
                case let .file(fileName, size):
                    let path = parentPath.isEmpty ? fileName : parentPath + "/" + fileName
                    items[id] = Entry(
                        path: path,
                        attributes: ItemAttributes(id: id, parent: parent, name: fileName, kind: .file, size: size, revision: revision),
                        fixture: FixtureFile(name: fileName, size: size))
                case let .directory(dirName, nested):
                    let path = parentPath.isEmpty ? dirName : parentPath + "/" + dirName
                    items[id] = Entry(
                        path: path,
                        attributes: ItemAttributes(id: id, parent: parent, name: dirName, kind: .directory, size: 0, revision: revision),
                        fixture: nil)
                    add(nested, parent: id, parentPath: path)
                }
            }
            children[parent] = ids.sorted { a, b in
                items[a]!.attributes.name.utf8.lexicographicallyPrecedes(items[b]!.attributes.name.utf8)
            }
        }
        add(layout, parent: .root, parentPath: "")
        self.name = name
        self.items = items
        self.children = children
    }

    /// All items except the root, depth-first, children in listing order.
    public var entries: [Entry] {
        var result: [Entry] = []
        func walk(_ id: ItemID) {
            for child in children[id] ?? [] {
                guard let entry = items[child] else { continue }
                result.append(entry)
                if entry.attributes.kind == .directory { walk(child) }
            }
        }
        walk(.root)
        return result
    }

    /// The generator for a file item, or `nil` for directories / unknown IDs.
    public func fixture(for id: ItemID) -> FixtureFile? { items[id]?.fixture }

    public func stat(_ id: ItemID) throws(StorageError) -> ItemAttributes {
        guard let entry = items[id] else { throw .unknownItem }
        return entry.attributes
    }

    /// Pages through a directory. `cursor` is opaque (currently a base-10 index); pass the
    /// previous page's `nextCursor`. `limit` must be in `1...Limits.maxListLimit`.
    public func list(parent: ItemID, cursor: String?, limit: Int) throws(StorageError) -> ListPage {
        let dir = try stat(parent)
        guard dir.kind == .directory else { throw .notDirectory }
        guard (1...Limits.maxListLimit).contains(limit) else {
            throw .invalidArgument("limit \(limit) outside 1...\(Limits.maxListLimit)")
        }
        let ids = children[parent] ?? []
        var start = 0
        if let cursor {
            guard cursor.utf8.count <= 19, !cursor.isEmpty, cursor.utf8.allSatisfy({ (0x30...0x39).contains($0) }),
                  let index = Int(cursor), index <= ids.count
            else { throw .invalidArgument("bad cursor") }
            start = index
        }
        let end = min(ids.count, start + limit)
        let page = ids[start..<end].compactMap { items[$0]?.attributes }
        return ListPage(items: page, nextCursor: end < ids.count ? String(end) : nil)
    }

    /// Finds a child by name. Names compare with Swift `String` equality (Unicode canonical
    /// equivalence), so an NFD spelling of an NFC name matches.
    public func lookup(parent: ItemID, name: String) throws(StorageError) -> ItemAttributes {
        let dir = try stat(parent)
        guard dir.kind == .directory else { throw .notDirectory }
        for id in children[parent] ?? [] {
            if let entry = items[id], entry.attributes.name == name { return entry.attributes }
        }
        throw .unknownItem
    }

    /// Reads bytes of a file at a pinned revision.
    ///
    /// Order of checks: item exists, is a file, revision matches, then offset/length are
    /// validated and clamped at EOF (`RangeMath.clamp`). The reply is capped at
    /// `Limits.maxReadReply` bytes: callers must loop (or `RangeMath.split`) for larger reads.
    public func read(_ id: ItemID, revision: String, offset: Int64, length: Int64) throws(StorageError) -> Data {
        guard let entry = items[id] else { throw .unknownItem }
        guard entry.attributes.kind == .file, let fixture = entry.fixture else { throw .isDirectory }
        guard entry.attributes.revision == revision else {
            throw .revisionChanged(expected: revision, actual: entry.attributes.revision)
        }
        var range = try RangeMath.clamp(offset: offset, length: length, fileSize: entry.attributes.size)
        range.length = min(range.length, Limits.maxReadReply)
        return fixture.data(in: range)
    }
}
