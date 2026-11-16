import Foundation
import StorageCore
import XCTest

final class SHA256Tests: XCTestCase {
    func testNISTVectors() {
        XCTAssertEqual(SHA256Digest.hex(Array("".utf8)),
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(SHA256Digest.hex(Array("abc".utf8)),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(SHA256Digest.hex(Array("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)),
                       "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        XCTAssertEqual(SHA256Digest.hex(Array(
            "abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu".utf8)),
                       "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1")
    }

    func testMillionAs() {
        var hasher = SHA256Digest.Hasher()
        let chunk = [UInt8](repeating: UInt8(ascii: "a"), count: 1000)
        for _ in 0..<1000 { hasher.update(chunk) }
        XCTAssertEqual(SHA256Digest.hexString(hasher.finalize()),
                       "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
        // One-shot over the same bytes.
        XCTAssertEqual(SHA256Digest.hex([UInt8](repeating: UInt8(ascii: "a"), count: 1_000_000)),
                       "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    func testStreamingSplitsMatchOneShot() {
        var rng = SystemRandomNumberGenerator()
        for length in [0, 1, 55, 56, 57, 63, 64, 65, 119, 120, 128, 1000] {
            let bytes = (0..<length).map { _ in UInt8.random(in: 0...255, using: &rng) }
            let oneShot = SHA256Digest.hex(bytes)
            var hasher = SHA256Digest.Hasher()
            var i = 0
            while i < bytes.count {
                let n = Int.random(in: 1...70, using: &rng)
                let end = min(bytes.count, i + n)
                if n % 2 == 0 { hasher.update(Data(bytes[i..<end])) } else { hasher.update(bytes[i..<end]) }
                i = end
            }
            XCTAssertEqual(SHA256Digest.hexString(hasher.finalize()), oneShot, "length \(length)")
        }
        // Non-contiguous sequence path.
        XCTAssertEqual(SHA256Digest.hex("abc".utf8.lazy.map { $0 }),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(SHA256Digest.hash(Array("abc".utf8)).count, 32)
    }
}
