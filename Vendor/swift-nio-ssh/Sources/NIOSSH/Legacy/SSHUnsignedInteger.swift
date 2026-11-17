//===----------------------------------------------------------------------===//
//
// Netdeck patch to SwiftNIO SSH (see PATCHES.md).
// Licensed under Apache License v2.0, like the rest of this package.
//
//===----------------------------------------------------------------------===//

/// A non-negative integer of arbitrary size, with just the operations finite-field Diffie-Hellman and RSA
/// signature checks need. Little-endian 64-bit limbs without trailing zero limbs (zero has no limbs).
///
/// Not constant time. It only handles ephemeral Diffie-Hellman values and public RSA data.
struct SSHUnsignedInteger: Hashable, Sendable {
    private(set) var limbs: [UInt64]

    init(limbs: [UInt64]) {
        self.limbs = limbs
        while self.limbs.last == 0 { self.limbs.removeLast() }
    }

    init(_ value: UInt64) {
        self.init(limbs: [value])
    }

    /// From big-endian magnitude bytes (an mpint's body, a hex constant). Leading zero bytes are fine.
    init<Bytes: Sequence>(bigEndianBytes bytes: Bytes) where Bytes.Element == UInt8 {
        let bytes = Array(bytes)
        var limbs = [UInt64]()
        limbs.reserveCapacity(bytes.count / 8 + 1)
        var current: UInt64 = 0
        var shift: UInt64 = 0
        for byte in bytes.reversed() {
            current |= UInt64(byte) << shift
            shift += 8
            if shift == 64 {
                limbs.append(current)
                current = 0
                shift = 0
            }
        }
        if shift > 0 { limbs.append(current) }
        self.init(limbs: limbs)
    }

    /// From a hexadecimal string (whitespace ignored).
    init?(hex: String) {
        var bytes = [UInt8]()
        var high: UInt8?
        for scalar in hex.unicodeScalars where !scalar.properties.isWhitespace {
            guard let nibble = UInt8(String(scalar), radix: 16) else { return nil }
            if let h = high {
                bytes.append(h << 4 | nibble)
                high = nil
            } else {
                high = nibble
            }
        }
        if let h = high { bytes.insert(h, at: 0) }  // odd length: a leading nibble
        self.init(bigEndianBytes: bytes)
    }

    var isZero: Bool { self.limbs.isEmpty }

    var bitWidth: Int {
        guard let top = self.limbs.last else { return 0 }
        return self.limbs.count * 64 - top.leadingZeroBitCount
    }

    func bit(_ index: Int) -> Bool {
        let limb = index / 64
        guard limb < self.limbs.count else { return false }
        return (self.limbs[limb] >> UInt64(index % 64)) & 1 == 1
    }

    /// Big-endian magnitude without leading zeros (empty for zero).
    var bigEndianBytes: [UInt8] {
        var bytes = [UInt8]()
        bytes.reserveCapacity(self.limbs.count * 8)
        for limb in self.limbs.reversed() {
            for shift in stride(from: 56, through: 0, by: -8) {
                bytes.append(UInt8(truncatingIfNeeded: limb >> UInt64(shift)))
            }
        }
        return Array(bytes.drop(while: { $0 == 0 }))
    }

    /// Big-endian bytes left-padded with zeros to `width`; nil when the value doesn't fit.
    func bigEndianBytes(width: Int) -> [UInt8]? {
        let bytes = self.bigEndianBytes
        guard bytes.count <= width else { return nil }
        return [UInt8](repeating: 0, count: width - bytes.count) + bytes
    }

    /// `self - other`; `other` must not be larger.
    func subtracting(_ other: SSHUnsignedInteger) -> SSHUnsignedInteger {
        precondition(other <= self, "SSHUnsignedInteger subtraction underflow")
        var result = self.limbs
        var borrow = false
        for i in 0..<result.count {
            let rhs = i < other.limbs.count ? other.limbs[i] : 0
            let (d1, o1) = result[i].subtractingReportingOverflow(rhs)
            let (d2, o2) = d1.subtractingReportingOverflow(borrow ? 1 : 0)
            result[i] = d2
            borrow = o1 || o2
        }
        return SSHUnsignedInteger(limbs: result)
    }
}

extension SSHUnsignedInteger: Comparable {
    static func < (lhs: SSHUnsignedInteger, rhs: SSHUnsignedInteger) -> Bool {
        if lhs.limbs.count != rhs.limbs.count { return lhs.limbs.count < rhs.limbs.count }
        for i in stride(from: lhs.limbs.count - 1, through: 0, by: -1) where lhs.limbs[i] != rhs.limbs[i] {
            return lhs.limbs[i] < rhs.limbs[i]
        }
        return false
    }
}

/// Modular exponentiation by Montgomery multiplication (CIOS, Koç et al. 1996) for an odd modulus.
struct SSHMontgomeryModulus: Sendable {
    let modulus: SSHUnsignedInteger
    private let m: [UInt64]
    private let count: Int
    /// -m⁻¹ mod 2⁶⁴.
    private let mInverse: UInt64
    /// R mod m and R² mod m, with R = 2^(64·count).
    private let rModM: [UInt64]
    private let rSquared: [UInt64]

    /// Nil unless the modulus is odd and larger than one.
    init?(_ modulus: SSHUnsignedInteger) {
        guard let low = modulus.limbs.first, low & 1 == 1, modulus.bitWidth > 1 else { return nil }
        self.modulus = modulus
        self.m = modulus.limbs
        self.count = modulus.limbs.count

        // Newton's iteration doubles the correct low bits each step: 1, 2, 4, ..., 64.
        var inverse: UInt64 = 1
        for _ in 0..<6 { inverse = inverse &* (2 &- low &* inverse) }
        self.mInverse = 0 &- inverse

        // Doubling 1 modulo m, 64·count times gives R mod m; as many again gives R² mod m.
        var x = [UInt64](repeating: 0, count: self.count)
        x[0] = 1
        var r = x
        for step in 0..<(2 * 64 * self.count) {
            Self.doubleModulo(&x, self.m)
            if step == 64 * self.count - 1 { r = x }
        }
        self.rModM = r
        self.rSquared = x
    }

    /// base^exponent mod m. `base` must be smaller than the modulus.
    func power(_ base: SSHUnsignedInteger, _ exponent: SSHUnsignedInteger) -> SSHUnsignedInteger {
        precondition(base < self.modulus, "SSHMontgomeryModulus base must be reduced")
        let n = self.count
        // Raw buffers: this runs hundreds of multiplications per key exchange, and debug builds pay heavily
        // for array bounds and uniqueness checks.
        var buffers = [UInt64](repeating: 0, count: 5 * n + 2)
        buffers.withUnsafeMutableBufferPointer { all in
            let baseM = all.baseAddress!
            let result = baseM + n
            let operand = result + n
            let product = operand + n
            let scratch = product + n  // n + 2 limbs
            self.m.withUnsafeBufferPointer { m in
                let m = m.baseAddress!
                // operand = base, padded; baseM = base·R mod m.
                for i in 0..<base.limbs.count { operand[i] = base.limbs[i] }
                self.rSquared.withUnsafeBufferPointer { r2 in
                    Self.multiply(operand, r2.baseAddress!, into: baseM, m, self.mInverse, n, scratch)
                }
                for i in 0..<n { result[i] = self.rModM[i] }
                var i = exponent.bitWidth - 1
                while i >= 0 {
                    Self.multiply(result, result, into: product, m, self.mInverse, n, scratch)
                    if exponent.bit(i) {
                        Self.multiply(product, baseM, into: result, m, self.mInverse, n, scratch)
                    } else {
                        result.update(from: product, count: n)
                    }
                    i -= 1
                }
                // Out of Montgomery form: multiply by 1.
                operand.update(repeating: 0, count: n)
                operand[0] = 1
                Self.multiply(result, operand, into: product, m, self.mInverse, n, scratch)
            }
        }
        return SSHUnsignedInteger(limbs: Array(buffers[(3 * n)..<(4 * n)]))
    }

    /// out = a·b·R⁻¹ mod m for a, b < m. `t` holds n + 2 limbs of scratch; `out` may not alias a or b.
    private static func multiply(
        _ a: UnsafePointer<UInt64>, _ b: UnsafePointer<UInt64>, into out: UnsafeMutablePointer<UInt64>,
        _ m: UnsafePointer<UInt64>, _ mInverse: UInt64, _ n: Int, _ t: UnsafeMutablePointer<UInt64>
    ) {
        t.update(repeating: 0, count: n + 2)
        for i in 0..<n {
            let bi = b[i]
            var carry: UInt64 = 0
            for j in 0..<n {
                let (hi, lo) = a[j].multipliedFullWidth(by: bi)
                let (s1, o1) = t[j].addingReportingOverflow(lo)
                let (s2, o2) = s1.addingReportingOverflow(carry)
                t[j] = s2
                carry = hi &+ (o1 ? 1 : 0) &+ (o2 ? 1 : 0)
            }
            var (s, o) = t[n].addingReportingOverflow(carry)
            t[n] = s
            t[n + 1] = o ? 1 : 0

            let factor = t[0] &* mInverse
            carry = 0
            for j in 0..<n {
                let (hi, lo) = factor.multipliedFullWidth(by: m[j])
                let (s1, o1) = t[j].addingReportingOverflow(lo)
                let (s2, o2) = s1.addingReportingOverflow(carry)
                t[j] = s2
                carry = hi &+ (o1 ? 1 : 0) &+ (o2 ? 1 : 0)
            }
            (s, o) = t[n].addingReportingOverflow(carry)
            t[n] = s
            t[n + 1] &+= o ? 1 : 0
            // t[0] is zero now: shift one limb down.
            for j in 0...n { t[j] = t[j + 1] }
            t[n + 1] = 0
        }
        // The result is below 2m: subtract m once if it is at least m.
        var atLeastM = t[n] != 0
        if !atLeastM {
            atLeastM = true
            var j = n - 1
            while j >= 0 {
                if t[j] != m[j] {
                    atLeastM = t[j] > m[j]
                    break
                }
                j -= 1
            }
        }
        if atLeastM {
            var borrow = false
            for j in 0..<n {
                let (d1, o1) = t[j].subtractingReportingOverflow(m[j])
                let (d2, o2) = d1.subtractingReportingOverflow(borrow ? 1 : 0)
                out[j] = d2
                borrow = o1 || o2
            }
        } else {
            out.update(from: t, count: n)
        }
    }

    private static func isLess(_ a: [UInt64], _ b: [UInt64]) -> Bool {
        for i in stride(from: a.count - 1, through: 0, by: -1) where a[i] != b[i] {
            return a[i] < b[i]
        }
        return false
    }

    /// a -= b, wrapping (callers know the true result is non-negative).
    private static func subtract(_ a: inout [UInt64], _ b: [UInt64]) {
        var borrow = false
        for i in 0..<a.count {
            let (d1, o1) = a[i].subtractingReportingOverflow(b[i])
            let (d2, o2) = d1.subtractingReportingOverflow(borrow ? 1 : 0)
            a[i] = d2
            borrow = o1 || o2
        }
    }

    /// x = 2x mod m for x < m.
    private static func doubleModulo(_ x: inout [UInt64], _ m: [UInt64]) {
        var carry: UInt64 = 0
        for i in 0..<x.count {
            let next = x[i] >> 63
            x[i] = x[i] << 1 | carry
            carry = next
        }
        if carry != 0 || !isLess(x, m) { subtract(&x, m) }
    }
}
