import Foundation

/// SHA-256 in plain Swift (FIPS 180-4).
///
/// Why hand-written: the dedupe key (FR-001-15) needs a stable content hash, and the architecture lint only lets
/// Payload import Foundation and FlotsamBase, which rules out CryptoKit and CommonCrypto. The key is a dedupe
/// identity, not a security boundary, so a small checked implementation is enough; the tests pin it to published
/// vectors. Swapping in CryptoKit is a one-function change if the lint allow-list ever admits it.
enum SHA256 {
    private static let roundConstants: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    /// Lowercase hexadecimal digest of `data`.
    static func hex(of data: Data) -> String {
        var state: [UInt32] = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
        ]
        var schedule = [UInt32](repeating: 0, count: 64)

        // Whole 64-byte blocks straight from the input; the remainder plus padding is hashed from a small copy.
        let wholeBlocks = data.count / 64
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            for block in 0..<wholeBlocks {
                compress(&state, &schedule, base.advanced(by: block * 64).assumingMemoryBound(to: UInt8.self))
            }
        }
        var tail = [UInt8](data.suffix(data.count - wholeBlocks * 64))
        tail.append(0x80)
        while tail.count % 64 != 56 { tail.append(0) }
        let bitLength = UInt64(data.count) &* 8
        for shift in stride(from: 56, through: 0, by: -8) { tail.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift))) }
        tail.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            for block in 0..<(buffer.count / 64) { compress(&state, &schedule, base.advanced(by: block * 64)) }
        }

        return state.map { word in
            let digits = String(word, radix: 16)
            return String(repeating: "0", count: 8 - digits.count) + digits
        }.joined()
    }

    private static func compress(_ state: inout [UInt32], _ w: inout [UInt32], _ block: UnsafePointer<UInt8>) {
        for t in 0..<16 {
            let i = t * 4
            w[t] = UInt32(block[i]) << 24 | UInt32(block[i + 1]) << 16 | UInt32(block[i + 2]) << 8 | UInt32(block[i + 3])
        }
        for t in 16..<64 {
            let s0 = rotr(w[t - 15], 7) ^ rotr(w[t - 15], 18) ^ (w[t - 15] >> 3)
            let s1 = rotr(w[t - 2], 17) ^ rotr(w[t - 2], 19) ^ (w[t - 2] >> 10)
            w[t] = w[t - 16] &+ s0 &+ w[t - 7] &+ s1
        }
        var a = state[0], b = state[1], c = state[2], d = state[3]
        var e = state[4], f = state[5], g = state[6], h = state[7]
        for t in 0..<64 {
            let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
            let choice = (e & f) ^ (~e & g)
            let temp1 = h &+ s1 &+ choice &+ roundConstants[t] &+ w[t]
            let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
            let majority = (a & b) ^ (a & c) ^ (b & c)
            let temp2 = s0 &+ majority
            h = g; g = f; f = e; e = d &+ temp1
            d = c; c = b; b = a; a = temp1 &+ temp2
        }
        state[0] = state[0] &+ a; state[1] = state[1] &+ b; state[2] = state[2] &+ c; state[3] = state[3] &+ d
        state[4] = state[4] &+ e; state[5] = state[5] &+ f; state[6] = state[6] &+ g; state[7] = state[7] &+ h
    }

    private static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
}
