import Foundation

/// Pure-Swift SHA-256 (FIPS 180-4). Used for fixture manifests and NFR01 integrity checks
/// on platforms without CryptoKit. Not intended for secrets or constant-time use.
public enum SHA256Digest {
    /// Lowercase hex digest of `bytes`.
    public static func hex(_ bytes: some Sequence<UInt8>) -> String {
        var hasher = Hasher()
        hasher.update(bytes)
        return hexString(hasher.finalize())
    }

    /// Raw 32-byte digest of `bytes`.
    public static func hash(_ bytes: some Sequence<UInt8>) -> [UInt8] {
        var hasher = Hasher()
        hasher.update(bytes)
        return hasher.finalize()
    }

    public static func hexString(_ digest: [UInt8]) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        out.reserveCapacity(digest.count * 2)
        for b in digest {
            out.append(digits[Int(b >> 4)])
            out.append(digits[Int(b & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Streaming hasher: call `update` any number of times, then `finalize` once.
    public struct Hasher: Sendable {
        private var h0: UInt32 = 0x6A09_E667, h1: UInt32 = 0xBB67_AE85
        private var h2: UInt32 = 0x3C6E_F372, h3: UInt32 = 0xA54F_F53A
        private var h4: UInt32 = 0x510E_527F, h5: UInt32 = 0x9B05_688C
        private var h6: UInt32 = 0x1F83_D9AB, h7: UInt32 = 0x5BE0_CD19
        private var buffer: [UInt8] = []
        private var totalBytes: UInt64 = 0

        public init() {
            buffer.reserveCapacity(64)
        }

        public mutating func update(_ bytes: some Sequence<UInt8>) {
            let handled: Void? = bytes.withContiguousStorageIfAvailable { buf in
                update(UnsafeRawBufferPointer(buf))
            }
            if handled == nil {
                let array = Array(bytes)
                array.withUnsafeBytes { update($0) }
            }
        }

        public mutating func update(_ data: Data) {
            data.withUnsafeBytes { update($0) }
        }

        public mutating func update(_ raw: UnsafeRawBufferPointer) {
            guard raw.count > 0, let base = raw.baseAddress else { return }
            totalBytes &+= UInt64(raw.count)
            var index = 0
            if !buffer.isEmpty {
                let take = min(64 - buffer.count, raw.count)
                buffer.append(contentsOf: UnsafeRawBufferPointer(start: base, count: take))
                index = take
                if buffer.count == 64 {
                    let block = buffer
                    block.withUnsafeBytes { compress($0.baseAddress!) }
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            while raw.count - index >= 64 {
                compress(base + index)
                index += 64
            }
            if index < raw.count {
                buffer.append(contentsOf: UnsafeRawBufferPointer(start: base + index, count: raw.count - index))
            }
        }

        /// Pads and returns the 32-byte digest. The hasher should not be reused afterwards.
        public mutating func finalize() -> [UInt8] {
            let bitLength = totalBytes &* 8
            var tail: [UInt8] = buffer
            tail.append(0x80)
            while tail.count % 64 != 56 { tail.append(0) }
            for shift in stride(from: 56, through: 0, by: -8) {
                tail.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift)))
            }
            tail.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    compress(raw.baseAddress! + offset)
                    offset += 64
                }
            }
            buffer.removeAll()
            var out = [UInt8]()
            out.reserveCapacity(32)
            for word in [h0, h1, h2, h3, h4, h5, h6, h7] {
                out.append(UInt8(truncatingIfNeeded: word >> 24))
                out.append(UInt8(truncatingIfNeeded: word >> 16))
                out.append(UInt8(truncatingIfNeeded: word >> 8))
                out.append(UInt8(truncatingIfNeeded: word))
            }
            return out
        }

        @inline(__always)
        private static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }

        private mutating func compress(_ block: UnsafeRawPointer) {
            withUnsafeTemporaryAllocation(of: UInt32.self, capacity: 64) { w in
                for t in 0..<16 {
                    let p = block + t * 4
                    w[t] = UInt32(p.load(as: UInt8.self)) << 24
                        | UInt32(p.load(fromByteOffset: 1, as: UInt8.self)) << 16
                        | UInt32(p.load(fromByteOffset: 2, as: UInt8.self)) << 8
                        | UInt32(p.load(fromByteOffset: 3, as: UInt8.self))
                }
                for t in 16..<64 {
                    let s0 = Hasher.rotr(w[t - 15], 7) ^ Hasher.rotr(w[t - 15], 18) ^ (w[t - 15] >> 3)
                    let s1 = Hasher.rotr(w[t - 2], 17) ^ Hasher.rotr(w[t - 2], 19) ^ (w[t - 2] >> 10)
                    w[t] = w[t - 16] &+ s0 &+ w[t - 7] &+ s1
                }
                var a = h0, b = h1, c = h2, d = h3, e = h4, f = h5, g = h6, h = h7
                for t in 0..<64 {
                    let s1 = Hasher.rotr(e, 6) ^ Hasher.rotr(e, 11) ^ Hasher.rotr(e, 25)
                    let ch = (e & f) ^ (~e & g)
                    let t1 = h &+ s1 &+ ch &+ Hasher.k[t] &+ w[t]
                    let s0 = Hasher.rotr(a, 2) ^ Hasher.rotr(a, 13) ^ Hasher.rotr(a, 22)
                    let maj = (a & b) ^ (a & c) ^ (b & c)
                    let t2 = s0 &+ maj
                    h = g; g = f; f = e; e = d &+ t1
                    d = c; c = b; b = a; a = t1 &+ t2
                }
                h0 &+= a; h1 &+= b; h2 &+= c; h3 &+= d
                h4 &+= e; h5 &+= f; h6 &+= g; h7 &+= h
            }
        }

        private static let k: [UInt32] = [
            0x428A_2F98, 0x7137_4491, 0xB5C0_FBCF, 0xE9B5_DBA5, 0x3956_C25B, 0x59F1_11F1, 0x923F_82A4, 0xAB1C_5ED5,
            0xD807_AA98, 0x1283_5B01, 0x2431_85BE, 0x550C_7DC3, 0x72BE_5D74, 0x80DE_B1FE, 0x9BDC_06A7, 0xC19B_F174,
            0xE49B_69C1, 0xEFBE_4786, 0x0FC1_9DC6, 0x240C_A1CC, 0x2DE9_2C6F, 0x4A74_84AA, 0x5CB0_A9DC, 0x76F9_88DA,
            0x983E_5152, 0xA831_C66D, 0xB003_27C8, 0xBF59_7FC7, 0xC6E0_0BF3, 0xD5A7_9147, 0x06CA_6351, 0x1429_2967,
            0x27B7_0A85, 0x2E1B_2138, 0x4D2C_6DFC, 0x5338_0D13, 0x650A_7354, 0x766A_0ABB, 0x81C2_C92E, 0x9272_2C85,
            0xA2BF_E8A1, 0xA81A_664B, 0xC24B_8B70, 0xC76C_51A3, 0xD192_E819, 0xD699_0624, 0xF40E_3585, 0x106A_A070,
            0x19A4_C116, 0x1E37_6C08, 0x2748_774C, 0x34B0_BCB5, 0x391C_0CB3, 0x4ED8_AA4A, 0x5B9C_CA4F, 0x682E_6FF3,
            0x748F_82EE, 0x78A5_636F, 0x84C8_7814, 0x8CC7_0208, 0x90BE_FFFA, 0xA450_6CEB, 0xBEF9_A3F7, 0xC671_78F2,
        ]
    }
}
