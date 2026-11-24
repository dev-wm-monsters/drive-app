import Foundation
import XCTest
@testable import DriveCore

final class HashingTests: XCTestCase {
    func testMD5RFC1321Vectors() {
        let vectors: [(String, String)] = [
            ("", "d41d8cd98f00b204e9800998ecf8427e"),
            ("a", "0cc175b9c0f1b6a831c399e269772661"),
            ("abc", "900150983cd24fb0d6963f7d28e17f72"),
            ("message digest", "f96b697d7cb7938d525a2f31aaf161d0"),
            ("abcdefghijklmnopqrstuvwxyz", "c3fcd3d76192e4007dfb496cca67e13b"),
            ("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789", "d174ab98d277d9f5a5611c2c9f419d9f"),
            (String(repeating: "1234567890", count: 8), "57edf4a22be3c955ac49da2e2107b67a"),
        ]
        for (input, expected) in vectors {
            XCTAssertEqual(Hashing.md5Hex(Data(input.utf8)), expected, input)
        }
        XCTAssertEqual(Hashing.md5Hex(Data(repeating: UInt8(ascii: "a"), count: 1_000_000)), "7707d6ae4e027c70eea2a935c2296f21")
    }

    func testSHA256NISTVectors() {
        XCTAssertEqual(Hashing.sha256Hex(Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(Hashing.sha256Hex(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(
            Hashing.sha256Hex(Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        )
        XCTAssertEqual(
            Hashing.sha256Hex(Data(repeating: UInt8(ascii: "a"), count: 1_000_000)),
            "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"
        )
    }

    func testPaddingBoundaries() {
        // Lengths around the 55/56/64-byte padding boundaries must agree with chunked feeding.
        for n in [54, 55, 56, 57, 63, 64, 65, 119, 120, 128] {
            let data = Data((0..<n).map { UInt8(truncatingIfNeeded: $0 &* 31) })
            var md5 = MD5()
            var sha = SHA256()
            for b in data {
                md5.update(Data([b]))
                sha.update(Data([b]))
            }
            XCTAssertEqual(Hashing.hex(md5.finalize()), Hashing.md5Hex(data), "md5 n=\(n)")
            XCTAssertEqual(Hashing.hex(sha.finalize()), Hashing.sha256Hex(data), "sha n=\(n)")
        }
        // Known values for the 55/56-byte edge (python hashlib).
        XCTAssertEqual(Hashing.md5Hex(Data(repeating: 0x61, count: 55)), "ef1772b6dff9a122358552954ad0df65")
        XCTAssertEqual(Hashing.md5Hex(Data(repeating: 0x61, count: 56)), "3b0c8ac703f828b04c6c197006d17218")
    }

    func testMD5OfFileStreamsAcrossChunks() throws {
        let n = 3 * 1024 * 1024 + 7
        let data = Data((0..<n).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) })
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("blob.bin")
        try data.write(to: url)
        XCTAssertEqual(try Hashing.md5Hex(of: url), "c326d73a47bbece36dfee0838beccfa6")
        XCTAssertEqual(Hashing.sha256Hex(data), "ae97a234a40c6485ec45d3a98121fa5ffe71520d9e30a50f3e65dfbdc4e7fd9a")
    }

    func testPKCERFC7636AppendixB() {
        let p = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        XCTAssertEqual(p.challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testPKCEGenerate() {
        let p = PKCE.generate()
        XCTAssertEqual(p.verifier.count, 64)
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        XCTAssertTrue(p.verifier.allSatisfy(allowed.contains))
        XCTAssertEqual(p.challenge, Hashing.sha256Base64URL(Data(p.verifier.utf8)))
        XCTAssertEqual(p.challenge.count, 43)
        XCTAssertFalse(p.challenge.contains("="))
        XCTAssertFalse(p.challenge.contains("+"))
        XCTAssertFalse(p.challenge.contains("/"))
        XCTAssertNotEqual(PKCE.generate().verifier, p.verifier)
    }
}
