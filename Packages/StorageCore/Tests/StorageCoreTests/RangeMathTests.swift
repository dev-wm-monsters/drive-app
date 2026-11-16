import StorageCore
import XCTest

final class RangeMathTests: XCTestCase {
    private let mib: UInt64 = 1024 * 1024

    func testClampTable() throws {
        // (offset, length, fileSize) -> expected (offset, length)
        let cases: [(Int64, Int64, UInt64, UInt64, UInt64, UInt)] = [
            (0, 0, 0, 0, 0, #line),
            (0, 1, 0, 0, 0, #line),           // empty file
            (0, 10, 100, 0, 10, #line),
            (90, 10, 100, 90, 10, #line),     // exactly to EOF
            (90, 11, 100, 90, 10, #line),     // clamp final range
            (99, 1, 100, 99, 1, #line),       // last byte
            (99, 1000, 100, 99, 1, #line),
            (100, 1, 100, 100, 0, #line),     // at EOF -> empty, no error
            (100, 0, 100, 100, 0, #line),
            (101, 5, 100, 101, 0, #line),     // past EOF -> empty at offset
            (5, 0, 100, 5, 0, #line),         // zero length -> empty
            (Int64.max, 0, 100, UInt64(Int64.max), 0, #line),
            (0, Int64.max, 100, 0, 100, #line),
            (Int64.max - 1, 1, UInt64.max, UInt64(Int64.max - 1), 1, #line),
            (Int64(4 * 1024 * 1024 - 1), 2, 4 * 1024 * 1024, 4 * 1024 * 1024 - 1, 1, #line),
        ]
        for (offset, length, size, expOffset, expLength, line) in cases {
            let r = try RangeMath.clamp(offset: offset, length: length, fileSize: size)
            XCTAssertEqual(r, ByteRange(offset: expOffset, length: expLength), "clamp(\(offset), \(length), \(size))", line: line)
        }
    }

    func testClampRejectsInvalid() {
        let cases: [(Int64, Int64, UInt)] = [
            (-1, 0, #line),
            (0, -1, #line),
            (-1, -1, #line),
            (Int64.min, 1, #line),
            (Int64.max, 1, #line),         // overflow
            (1, Int64.max, #line),         // overflow
            (Int64.max / 2 + 1, Int64.max / 2 + 1, #line),
        ]
        for (offset, length, line) in cases {
            XCTAssertThrowsError(try RangeMath.clamp(offset: offset, length: length, fileSize: .max), line: line) { error in
                guard case StorageError.invalidArgument = error else {
                    return XCTFail("expected invalidArgument, got \(error)", line: line)
                }
            }
        }
    }

    func testByteRangeEnd() {
        XCTAssertEqual(ByteRange(offset: 10, length: 5).end, 15)
        XCTAssertEqual(ByteRange(offset: .max, length: 5).end, .max)   // saturates
        XCTAssertTrue(ByteRange(offset: 3, length: 0).isEmpty)
    }

    func testSegmentIndexes() {
        let s = mib * 4
        let cases: [(UInt64, UInt64, ClosedRange<UInt64>?, UInt)] = [
            (0, 0, nil, #line),
            (s, 0, nil, #line),
            (0, 1, 0...0, #line),
            (0, s, 0...0, #line),
            (0, s + 1, 0...1, #line),
            (s - 1, 1, 0...0, #line),
            (s - 1, 2, 0...1, #line),
            (s, 1, 1...1, #line),
            (s, s, 1...1, #line),
            (s + 1, s, 1...2, #line),
            (3 * s - 1, 2 * s + 2, 2...5, #line),     // end = 5s + 1
            (3 * s - 1, 2 * s + 1, 2...4, #line),     // end = 5s
            (.max - 1, 1, (UInt64.max - 1) / s ... (UInt64.max - 1) / s, #line),
        ]
        for (offset, length, expected, line) in cases {
            XCTAssertEqual(RangeMath.segmentIndexes(for: ByteRange(offset: offset, length: length)), expected,
                           "\(offset)+\(length)", line: line)
        }
        XCTAssertEqual(RangeMath.segmentIndexes(for: ByteRange(offset: 10, length: 20), segmentSize: 8), 1...3)
        XCTAssertNil(RangeMath.segmentIndexes(for: ByteRange(offset: 10, length: 20), segmentSize: 0))
    }

    func testSplit() {
        let c = Limits.maxReadReply
        XCTAssertEqual(RangeMath.split(ByteRange(offset: 5, length: 0)), [])
        XCTAssertEqual(RangeMath.split(ByteRange(offset: 0, length: c)), [ByteRange(offset: 0, length: c)])
        XCTAssertEqual(RangeMath.split(ByteRange(offset: 0, length: c + 1)),
                       [ByteRange(offset: 0, length: c), ByteRange(offset: c, length: 1)])
        XCTAssertEqual(RangeMath.split(ByteRange(offset: c - 1, length: 2)),
                       [ByteRange(offset: c - 1, length: 1), ByteRange(offset: c, length: 1)])
        XCTAssertEqual(RangeMath.split(ByteRange(offset: 1, length: 2 * c)),
                       [ByteRange(offset: 1, length: c - 1), ByteRange(offset: c, length: c), ByteRange(offset: 2 * c, length: 1)])
        XCTAssertEqual(RangeMath.split(ByteRange(offset: 7, length: 20), maxChunk: 8),
                       [ByteRange(offset: 7, length: 1), ByteRange(offset: 8, length: 8),
                        ByteRange(offset: 16, length: 8), ByteRange(offset: 24, length: 3)])
        XCTAssertEqual(RangeMath.split(ByteRange(offset: 7, length: 20), maxChunk: 0), [ByteRange(offset: 7, length: 20)])
        // Near UInt64.max: no trap, contiguous coverage.
        let top = RangeMath.split(ByteRange(offset: .max - 10, length: 10), maxChunk: 4)
        XCTAssertEqual(top.first?.offset, .max - 10)
        XCTAssertEqual(top.reduce(0) { $0 + $1.length }, 10)
    }

    func testSplitPropertiesRandomized() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<2000 {
            let chunk = UInt64.random(in: 1...64, using: &rng)
            let range = ByteRange(offset: UInt64.random(in: 0...1000, using: &rng), length: UInt64.random(in: 0...500, using: &rng))
            let parts = RangeMath.split(range, maxChunk: chunk)
            XCTAssertEqual(parts.reduce(0) { $0 + $1.length }, range.length)
            var cursor = range.offset
            for (i, p) in parts.enumerated() {
                XCTAssertEqual(p.offset, cursor)
                XCTAssertGreaterThan(p.length, 0)
                XCTAssertLessThanOrEqual(p.length, chunk)
                if i > 0 { XCTAssertEqual(p.offset % chunk, 0, "aligned chunk starts") }
                XCTAssertEqual(RangeMath.segmentIndexes(for: p, segmentSize: chunk)?.count, 1)
                cursor = p.end
            }
            XCTAssertEqual(parts.count, RangeMath.segmentIndexes(for: range, segmentSize: chunk)?.count ?? 0)
        }
    }
}
