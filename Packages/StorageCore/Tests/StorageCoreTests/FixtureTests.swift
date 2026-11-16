import Foundation
import StorageCore
import XCTest

final class FixtureFileTests: XCTestCase {
    func testFNV1aVectors() {
        XCTAssertEqual(FixtureFile.fnv1a64(""), 0xCBF2_9CE4_8422_2325)
        XCTAssertEqual(FixtureFile.fnv1a64("a"), 0xAF63_DC4C_8601_EC8C)
        XCTAssertEqual(FixtureFile.fnv1a64("foobar"), 0x8594_4171_F739_67E8)
    }

    func testDeterministicAndNameSeeded() {
        let a = FixtureFile(name: "x.bin", size: 1000)
        let b = FixtureFile(name: "x.bin", size: 1000)
        let c = FixtureFile(name: "y.bin", size: 1000)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.seed, FixtureFile.fnv1a64("x.bin"))
        XCTAssertEqual(a.bytes(in: ByteRange(offset: 0, length: 1000)), b.bytes(in: ByteRange(offset: 0, length: 1000)))
        XCTAssertNotEqual(a.bytes(in: ByteRange(offset: 0, length: 1000)), c.bytes(in: ByteRange(offset: 0, length: 1000)))
        // Pinned first bytes so an accidental algorithm change is caught.
        let first = FixtureFile(name: "x", size: 16, seed: 0).bytes(in: ByteRange(offset: 0, length: 8))
        let v = FixtureFile.splitmix64(0)
        XCTAssertEqual(first, (0..<8).map { UInt8(truncatingIfNeeded: v >> ($0 * 8)) })
        XCTAssertEqual(FixtureFile.splitmix64(0), 0xE220_A839_7B1D_CDAF)
    }

    func testRandomAccessEquivalence() {
        let size: UInt64 = 100_003
        let f = FixtureFile(name: "equiv.bin", size: size)
        let full = f.bytes(in: ByteRange(offset: 0, length: size))
        XCTAssertEqual(full.count, Int(size))
        XCTAssertEqual(Data(full), f.data(in: ByteRange(offset: 0, length: size)))
        var rng = SystemRandomNumberGenerator()
        var pairs: [(UInt64, UInt64)] = [(0, 0), (0, 1), (1, 7), (7, 9), (8, 16), (3, 3), (size - 1, size), (size - 9, size)]
        for _ in 0..<500 {
            let a = UInt64.random(in: 0...size, using: &rng)
            let b = UInt64.random(in: a...size, using: &rng)
            pairs.append((a, b))
        }
        for (a, b) in pairs {
            let r = ByteRange(offset: a, length: b - a)
            let expected = Array(full[Int(a)..<Int(b)])
            XCTAssertEqual(f.bytes(in: r), expected, "\(a)..<\(b)")
            XCTAssertEqual(f.data(in: r), Data(expected), "\(a)..<\(b)")
        }
        for i in [0, 1, 7, 8, 9, 50_000, Int(size) - 1] {
            XCTAssertEqual(f.byte(at: UInt64(i)), full[i])
        }
    }

    func testClampsAtSize() {
        let f = FixtureFile(name: "c.bin", size: 10)
        XCTAssertEqual(f.bytes(in: ByteRange(offset: 5, length: 100)).count, 5)
        XCTAssertEqual(f.bytes(in: ByteRange(offset: 10, length: 1)), [])
        XCTAssertEqual(f.bytes(in: ByteRange(offset: 50, length: 1)), [])
        XCTAssertEqual(f.data(in: ByteRange(offset: 11, length: 1)), Data())
        XCTAssertEqual(FixtureFile(name: "e", size: 0).bytes(in: ByteRange(offset: 0, length: 10)), [])
    }

    func testFourMiBSliceIsFast() {
        let f = FixtureFile(name: "seg.bin", size: 8 * 1024 * 1024)
        let clock = ContinuousClock()
        var bytes: [UInt8] = []
        let elapsed = clock.measure {
            bytes = f.bytes(in: ByteRange(offset: 3, length: 4 * 1024 * 1024))
        }
        XCTAssertEqual(bytes.count, 4 * 1024 * 1024)
        print("[timing] 4 MiB unaligned slice generated in \(elapsed)")
        XCTAssertLessThan(elapsed, .seconds(2))
    }
}

final class FixtureCatalogTests: XCTestCase {
    let catalog = FixtureCatalog.spike
    let mib: UInt64 = 1024 * 1024
    let unicodeName = "\u{00DC}n\u{00EF}c\u{00F8}d\u{00E9} name.bin"

    private func expectError(_ expected: StorageError, line: UInt = #line, _ body: () throws -> Void) {
        do {
            try body()
            XCTFail("expected \(expected)", line: line)
        } catch {
            XCTAssertEqual(error as? StorageError, expected, line: line)
        }
    }

    private func expectInvalidArgument(line: UInt = #line, _ body: () throws -> Void) {
        do {
            try body()
            XCTFail("expected invalidArgument", line: line)
        } catch {
            guard case .invalidArgument? = error as? StorageError else { return XCTFail("got \(error)", line: line) }
        }
    }

    func testLayoutAndStableIDs() throws {
        XCTAssertEqual(catalog.name, "spike")
        let expected: [(UInt64, String, ItemKind, UInt64, UInt64)] = [
            (2, "empty.bin", .file, 0, 1),
            (3, "one.bin", .file, 1, 1),
            (4, "64k.bin", .file, 65_536, 1),
            (5, "seg-minus-1.bin", .file, 4 * mib - 1, 1),
            (6, "seg.bin", .file, 4 * mib, 1),
            (7, "seg-plus-1.bin", .file, 4 * mib + 1, 1),
            (8, unicodeName, .file, 12_345, 1),
            (9, "nested", .directory, 0, 1),
            (10, "deep.bin", .file, 100_000, 9),
        ]
        for (raw, name, kind, size, parent) in expected {
            let a = try catalog.stat(ItemID(rawValue: raw))
            XCTAssertEqual(a.name, name)
            XCTAssertEqual(a.kind, kind)
            XCTAssertEqual(a.size, size)
            XCTAssertEqual(a.parent.rawValue, parent)
            XCTAssertEqual(a.revision, "r1")
        }
        let root = try catalog.stat(.root)
        XCTAssertEqual(root.kind, .directory)
        XCTAssertEqual(root.parent, .root)
        XCTAssertEqual(catalog.entries.count, 9)
        // Depth-first in listing order: a directory's children follow it directly.
        let paths = catalog.entries.map(\.path)
        XCTAssertEqual(paths, ["64k.bin", "empty.bin", "nested", "nested/deep.bin", "one.bin", "seg-minus-1.bin",
                               "seg-plus-1.bin", "seg.bin", unicodeName])
        XCTAssertTrue(unicodeName.unicodeScalars.count == 16, "name is NFC")
    }

    func testListSortedAndPaging() throws {
        let all = try catalog.list(parent: .root, cursor: nil, limit: Limits.maxListLimit)
        XCTAssertNil(all.nextCursor)
        XCTAssertEqual(all.items.map(\.name), ["64k.bin", "empty.bin", "nested", "one.bin", "seg-minus-1.bin",
                                               "seg-plus-1.bin", "seg.bin", unicodeName])
        for limit in 1...9 {
            var names: [String] = []
            var cursor: String?
            var pages = 0
            repeat {
                let page = try catalog.list(parent: .root, cursor: cursor, limit: limit)
                XCTAssertLessThanOrEqual(page.items.count, limit)
                names += page.items.map(\.name)
                cursor = page.nextCursor
                pages += 1
            } while cursor != nil && pages < 100
            XCTAssertEqual(names, all.items.map(\.name), "limit \(limit)")
            XCTAssertEqual(pages, (8 + limit - 1) / limit)
        }
        let end = try catalog.list(parent: .root, cursor: "8", limit: 5)
        XCTAssertEqual(end.items, [])
        XCTAssertNil(end.nextCursor)
        let nested = try catalog.list(parent: ItemID(rawValue: 9), cursor: nil, limit: 10)
        XCTAssertEqual(nested.items.map(\.name), ["deep.bin"])
        XCTAssertEqual(try catalog.list(parent: ItemID(rawValue: 9), cursor: nil, limit: 1).nextCursor, nil)
    }

    func testListErrors() {
        for cursor in ["abc", "-1", "", " 1", "1 ", "1.5", "9", "99999999999999999999", "+1", "0x1", "١"] {
            expectInvalidArgument { _ = try catalog.list(parent: .root, cursor: cursor, limit: 10) }
        }
        for limit in [0, -1, Limits.maxListLimit + 1, Int.min, Int.max] {
            expectInvalidArgument { _ = try catalog.list(parent: .root, cursor: nil, limit: limit) }
        }
        expectError(.notDirectory) { _ = try catalog.list(parent: ItemID(rawValue: 3), cursor: nil, limit: 10) }
        expectError(.unknownItem) { _ = try catalog.list(parent: ItemID(rawValue: 999), cursor: nil, limit: 10) }
        expectError(.unknownItem) { _ = try catalog.list(parent: ItemID(rawValue: 0), cursor: nil, limit: 10) }
    }

    func testLookupAndStat() throws {
        XCTAssertEqual(try catalog.lookup(parent: .root, name: "seg.bin").id.rawValue, 6)
        XCTAssertEqual(try catalog.lookup(parent: ItemID(rawValue: 9), name: "deep.bin").id.rawValue, 10)
        XCTAssertEqual(try catalog.lookup(parent: .root, name: unicodeName).id.rawValue, 8)
        // NFD spelling of the same name is canonically equivalent.
        let nfd = "U\u{0308}ni\u{0308}c\u{00F8}de\u{0301} name.bin"
        XCTAssertNotEqual(Array(nfd.utf8), Array(unicodeName.utf8))
        XCTAssertEqual(try catalog.lookup(parent: .root, name: nfd).id.rawValue, 8)
        expectError(.unknownItem) { _ = try catalog.lookup(parent: .root, name: "missing.bin") }
        expectError(.unknownItem) { _ = try catalog.lookup(parent: .root, name: "deep.bin") }
        expectError(.unknownItem) { _ = try catalog.lookup(parent: .root, name: "SEG.BIN") }
        expectError(.notDirectory) { _ = try catalog.lookup(parent: ItemID(rawValue: 6), name: "x") }
        expectError(.unknownItem) { _ = try catalog.lookup(parent: ItemID(rawValue: 77), name: "x") }
        expectError(.unknownItem) { _ = try catalog.stat(ItemID(rawValue: 0)) }
        expectError(.unknownItem) { _ = try catalog.stat(ItemID(rawValue: 11)) }
        expectError(.unknownItem) { _ = try catalog.stat(ItemID(rawValue: .max)) }
    }

    func testReadBoundariesForEveryFile() throws {
        let cap = Int64(Limits.maxReadReply)
        for entry in catalog.entries {
            guard let fixture = entry.fixture else { continue }
            let id = entry.attributes.id
            let size = Int64(fixture.size)
            let full = fixture.bytes(in: ByteRange(offset: 0, length: fixture.size))
            func check(_ offset: Int64, _ length: Int64, line: UInt = #line) throws {
                let got = try catalog.read(id, revision: "r1", offset: offset, length: length)
                let start = min(offset, size)
                let end = min(size, start + min(length, cap))
                XCTAssertEqual(got, Data(full[Int(start)..<Int(end)]),
                               "\(entry.path) read(\(offset), \(length))", line: line)
            }
            try check(0, 0)
            try check(0, 1)
            try check(1, 1)
            try check(0, size)
            try check(size, 1)                   // at EOF: empty
            try check(size, 0)
            try check(size + 1, 10)              // past EOF: empty
            try check(size + 1_000_000, 1)
            if size > 0 {
                try check(size - 1, 1)           // EOF-1
                try check(size - 1, 100)         // clamp
            }
            try check(Int64(4 * mib) - 1, 2)
            try check(Int64(4 * mib), 1)
            try check(0, cap + 1)                // > 4 MiB request capped
            try check(1, Int64.max - 1)
            // Zero length anywhere is empty.
            XCTAssertEqual(try catalog.read(id, revision: "r1", offset: size / 2, length: 0), Data())
        }
        let capped = try catalog.read(ItemID(rawValue: 7), revision: "r1", offset: 0, length: Int64(8 * mib))
        XCTAssertEqual(capped.count, Int(Limits.maxReadReply))
        let tail = try catalog.read(ItemID(rawValue: 7), revision: "r1", offset: Int64(4 * mib), length: Int64(8 * mib))
        XCTAssertEqual(tail.count, 1)
    }

    func testReadErrors() {
        expectError(.isDirectory) { _ = try catalog.read(.root, revision: "r1", offset: 0, length: 1) }
        expectError(.isDirectory) { _ = try catalog.read(ItemID(rawValue: 9), revision: "r1", offset: 0, length: 1) }
        expectError(.unknownItem) { _ = try catalog.read(ItemID(rawValue: 42), revision: "r1", offset: 0, length: 1) }
        expectError(.revisionChanged(expected: "r2", actual: "r1")) {
            _ = try catalog.read(ItemID(rawValue: 6), revision: "r2", offset: 0, length: 1)
        }
        expectError(.revisionChanged(expected: "", actual: "r1")) {
            _ = try catalog.read(ItemID(rawValue: 2), revision: "", offset: 0, length: 0)
        }
        expectInvalidArgument { _ = try catalog.read(ItemID(rawValue: 6), revision: "r1", offset: -1, length: 1) }
        expectInvalidArgument { _ = try catalog.read(ItemID(rawValue: 6), revision: "r1", offset: 0, length: -1) }
        expectInvalidArgument { _ = try catalog.read(ItemID(rawValue: 6), revision: "r1", offset: Int64.max, length: 1) }
    }
}
