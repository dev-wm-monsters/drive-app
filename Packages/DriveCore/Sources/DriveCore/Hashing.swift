import Foundation

/// Pure-Swift hashes (no CryptoKit / CommonCrypto so the package builds and tests on Linux).
/// MD5 is used only to compare against Drive's `md5Checksum`; it is not a security primitive here.
public enum Hashing {
    public static let md5ReadChunkSize = 1 << 20 // 1 MiB

    /// Lower-case hex MD5 of a file, streamed in 1 MiB chunks.
    public static func md5Hex(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var md5 = MD5()
        while let chunk = try handle.read(upToCount: md5ReadChunkSize), !chunk.isEmpty {
            md5.update(chunk)
        }
        return hex(md5.finalize())
    }

    public static func md5Hex(_ data: Data) -> String {
        var md5 = MD5()
        md5.update(data)
        return hex(md5.finalize())
    }

    /// SHA-256 digest bytes.
    public static func sha256(_ data: Data) -> [UInt8] {
        var s = SHA256()
        s.update(data)
        return s.finalize()
    }

    public static func sha256Hex(_ data: Data) -> String {
        hex(sha256(data))
    }

    /// base64url (RFC 4648 §5) without padding of SHA-256(d). PKCE S256 challenge = this of the ASCII verifier.
    public static func sha256Base64URL(_ d: Data) -> String {
        base64URL(Data(sha256(d)))
    }

    public static func base64URL(_ d: Data) -> String {
        d.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64URLDecode(_ s: String) -> Data? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        return Data(base64Encoded: b)
    }

    static func hex(_ bytes: [UInt8]) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        out.reserveCapacity(bytes.count * 2)
        for b in bytes {
            out.append(digits[Int(b >> 4)])
            out.append(digits[Int(b & 0x0f)])
        }
        return String(decoding: out, as: UTF8.self)
    }
}

// MARK: - Shared Merkle–Damgård block buffering

private struct BlockBuffer {
    var bytes = [UInt8]()
    var totalLength: UInt64 = 0

    init() { bytes.reserveCapacity(64) }

    /// Feeds `raw`, calling `process` for each complete 64-byte block.
    mutating func feed(_ raw: UnsafeRawBufferPointer, _ process: (UnsafeRawBufferPointer) -> Void) {
        totalLength &+= UInt64(raw.count)
        var index = 0
        if !bytes.isEmpty {
            let take = min(64 - bytes.count, raw.count)
            bytes.append(contentsOf: raw[0..<take])
            index = take
            if bytes.count == 64 {
                bytes.withUnsafeBytes { process($0) }
                bytes.removeAll(keepingCapacity: true)
            }
        }
        while raw.count - index >= 64 {
            process(UnsafeRawBufferPointer(rebasing: raw[index..<(index + 64)]))
            index += 64
        }
        if index < raw.count {
            bytes.append(contentsOf: raw[index..<raw.count])
        }
    }

    /// Padding: 0x80, zeros, 64-bit bit length (little- or big-endian).
    func padding(bigEndianLength: Bool) -> [UInt8] {
        var pad: [UInt8] = [0x80]
        let used = (bytes.count + 1) % 64
        let zeros = used <= 56 ? 56 - used : 120 - used
        pad.append(contentsOf: repeatElement(0, count: zeros))
        let bits = totalLength &* 8
        for i in 0..<8 {
            let shift = bigEndianLength ? UInt64(56 - 8 * i) : UInt64(8 * i)
            pad.append(UInt8(truncatingIfNeeded: bits >> shift))
        }
        return pad
    }
}

// MARK: - MD5 (RFC 1321)

struct MD5 {
    private var state: (UInt32, UInt32, UInt32, UInt32) = (0x6745_2301, 0xefcd_ab89, 0x98ba_dcfe, 0x1032_5476)
    private var buffer = BlockBuffer()

    private static let s: [UInt32] = [
        7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
        5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
        4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
        6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
    ]

    private static let k: [UInt32] = [
        0xd76a_a478, 0xe8c7_b756, 0x2420_70db, 0xc1bd_ceee, 0xf57c_0faf, 0x4787_c62a, 0xa830_4613, 0xfd46_9501,
        0x6980_98d8, 0x8b44_f7af, 0xffff_5bb1, 0x895c_d7be, 0x6b90_1122, 0xfd98_7193, 0xa679_438e, 0x49b4_0821,
        0xf61e_2562, 0xc040_b340, 0x265e_5a51, 0xe9b6_c7aa, 0xd62f_105d, 0x0244_1453, 0xd8a1_e681, 0xe7d3_fbc8,
        0x21e1_cde6, 0xc337_07d6, 0xf4d5_0d87, 0x455a_14ed, 0xa9e3_e905, 0xfcef_a3f8, 0x676f_02d9, 0x8d2a_4c8a,
        0xfffa_3942, 0x8771_f681, 0x6d9d_6122, 0xfde5_380c, 0xa4be_ea44, 0x4bde_cfa9, 0xf6bb_4b60, 0xbebf_bc70,
        0x289b_7ec6, 0xeaa1_27fa, 0xd4ef_3085, 0x0488_1d05, 0xd9d4_d039, 0xe6db_99e5, 0x1fa2_7cf8, 0xc4ac_5665,
        0xf429_2244, 0x432a_ff97, 0xab94_23a7, 0xfc93_a039, 0x655b_59c3, 0x8f0c_cc92, 0xffef_f47d, 0x8584_5dd1,
        0x6fa8_7e4f, 0xfe2c_e6e0, 0xa301_4314, 0x4e08_11a1, 0xf753_7e82, 0xbd3a_f235, 0x2ad7_d2bb, 0xeb86_d391,
    ]

    mutating func update(_ data: Data) {
        data.withUnsafeBytes { raw in
            var st = state
            buffer.feed(raw) { MD5.compress(&st, $0) }
            state = st
        }
    }

    mutating func finalize() -> [UInt8] {
        let pad = buffer.padding(bigEndianLength: false)
        update(Data(pad))
        var out = [UInt8]()
        for word in [state.0, state.1, state.2, state.3] {
            for i in 0..<4 { out.append(UInt8(truncatingIfNeeded: word >> UInt32(8 * i))) }
        }
        return out
    }

    private static func compress(_ st: inout (UInt32, UInt32, UInt32, UInt32), _ block: UnsafeRawBufferPointer) {
        var a = st.0, b = st.1, c = st.2, d = st.3
        for i in 0..<64 {
            var f: UInt32
            let g: Int
            switch i {
            case 0..<16:
                f = (b & c) | (~b & d); g = i
            case 16..<32:
                f = (d & b) | (~d & c); g = (5 * i + 1) % 16
            case 32..<48:
                f = b ^ c ^ d; g = (3 * i + 5) % 16
            default:
                f = c ^ (b | ~d); g = (7 * i) % 16
            }
            let m = UInt32(littleEndian: block.loadUnaligned(fromByteOffset: 4 * g, as: UInt32.self))
            f = f &+ a &+ k[i] &+ m
            a = d; d = c; c = b
            b = b &+ ((f << s[i]) | (f >> (32 - s[i])))
        }
        st.0 &+= a; st.1 &+= b; st.2 &+= c; st.3 &+= d
    }
}

// MARK: - SHA-256 (FIPS 180-4)

struct SHA256 {
    private var h: [UInt32] = [
        0x6a09_e667, 0xbb67_ae85, 0x3c6e_f372, 0xa54f_f53a, 0x510e_527f, 0x9b05_688c, 0x1f83_d9ab, 0x5be0_cd19,
    ]
    private var buffer = BlockBuffer()

    private static let k: [UInt32] = [
        0x428a_2f98, 0x7137_4491, 0xb5c0_fbcf, 0xe9b5_dba5, 0x3956_c25b, 0x59f1_11f1, 0x923f_82a4, 0xab1c_5ed5,
        0xd807_aa98, 0x1283_5b01, 0x2431_85be, 0x550c_7dc3, 0x72be_5d74, 0x80de_b1fe, 0x9bdc_06a7, 0xc19b_f174,
        0xe49b_69c1, 0xefbe_4786, 0x0fc1_9dc6, 0x240c_a1cc, 0x2de9_2c6f, 0x4a74_84aa, 0x5cb0_a9dc, 0x76f9_88da,
        0x983e_5152, 0xa831_c66d, 0xb003_27c8, 0xbf59_7fc7, 0xc6e0_0bf3, 0xd5a7_9147, 0x06ca_6351, 0x1429_2967,
        0x27b7_0a85, 0x2e1b_2138, 0x4d2c_6dfc, 0x5338_0d13, 0x650a_7354, 0x766a_0abb, 0x81c2_c92e, 0x9272_2c85,
        0xa2bf_e8a1, 0xa81a_664b, 0xc24b_8b70, 0xc76c_51a3, 0xd192_e819, 0xd699_0624, 0xf40e_3585, 0x106a_a070,
        0x19a4_c116, 0x1e37_6c08, 0x2748_774c, 0x34b0_bcb5, 0x391c_0cb3, 0x4ed8_aa4a, 0x5b9c_ca4f, 0x682e_6ff3,
        0x748f_82ee, 0x78a5_636f, 0x84c8_7814, 0x8cc7_0208, 0x90be_fffa, 0xa450_6ceb, 0xbef9_a3f7, 0xc671_78f2,
    ]

    mutating func update(_ data: Data) {
        data.withUnsafeBytes { raw in
            var hh = h
            buffer.feed(raw) { SHA256.compress(&hh, $0) }
            h = hh
        }
    }

    mutating func finalize() -> [UInt8] {
        let pad = buffer.padding(bigEndianLength: true)
        update(Data(pad))
        var out = [UInt8]()
        for word in h {
            for i in (0..<4).reversed() { out.append(UInt8(truncatingIfNeeded: word >> UInt32(8 * i))) }
        }
        return out
    }

    @inline(__always) private static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }

    private static func compress(_ h: inout [UInt32], _ block: UnsafeRawBufferPointer) {
        var w = [UInt32](repeating: 0, count: 64)
        for i in 0..<16 {
            w[i] = UInt32(bigEndian: block.loadUnaligned(fromByteOffset: 4 * i, as: UInt32.self))
        }
        for i in 16..<64 {
            let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
            let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
            w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
        }
        var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
        for i in 0..<64 {
            let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
            let ch = (e & f) ^ (~e & g)
            let t1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
            let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
            let maj = (a & b) ^ (a & c) ^ (b & c)
            let t2 = s0 &+ maj
            hh = g; g = f; f = e; e = d &+ t1
            d = c; c = b; b = a; a = t1 &+ t2
        }
        h[0] &+= a; h[1] &+= b; h[2] &+= c; h[3] &+= d
        h[4] &+= e; h[5] &+= f; h[6] &+= g; h[7] &+= hh
    }
}
