import Foundation

/// Generic unaligned-PER building blocks shared by the CAM/DENM and MAPEM/SPATEM decoders.
extension UperBitReader {
    /// X.691 §11.9 general length determinant (unconstrained), incl. 16K fragments.
    mutating func lengthDeterminant() throws -> Int {
        if !(try bit()) { return Int(try bits(7)) }
        if !(try bit()) { return Int(try bits(14)) }
        let fragments = Int(try bits(6))
        guard (1...4).contains(fragments) else { throw IntersectionDecodeError("Unsupported length determinant") }
        return fragments * 16_384 + (try lengthDeterminant())
    }

    /// Skips an open type (length-prefixed octets): used for extension additions and regional extensions.
    mutating func skipOpenType() throws {
        var remaining = try lengthDeterminant()
        while remaining >= 16_384 { try skip(16_384 * 8); remaining -= 16_384 }
        try skip(remaining * 8)
    }

    /// X.691 §11.6 normally small non-negative whole number (CHOICE / ENUMERATED extension indices).
    mutating func normallySmallNumber() throws -> Int {
        if !(try bit()) { return Int(try bits(6)) }
        return try lengthDeterminant()
    }

    /// Skips the extension additions of a SEQUENCE whose extension bit was set.
    /// Call after all root components have been read.
    mutating func skipSequenceExtensions() throws {
        let count: Int
        if !(try bit()) { count = Int(try bits(6)) + 1 } else { count = try lengthDeterminant() }
        var present = 0
        for _ in 0..<count { if try bit() { present += 1 } }
        for _ in 0..<present { try skipOpenType() }
    }

    /// Reads a CHOICE index; for an extension alternative returns nil after skipping its value.
    mutating func choice(rootCount: Int, extensible: Bool) throws -> Int? {
        if extensible, try bit() {
            _ = try normallySmallNumber()
            try skipOpenType()
            return nil
        }
        let width = rootCount <= 1 ? 0 : Int.bitWidth - (rootCount - 1).leadingZeroBitCount
        return Int(try bits(width))
    }

    /// Reads an ENUMERATED value; extension values come back as rootCount + index.
    mutating func enumerated(rootCount: Int, extensible: Bool) throws -> Int {
        if extensible, try bit() { return rootCount + (try normallySmallNumber()) }
        let width = rootCount <= 1 ? 0 : Int.bitWidth - (rootCount - 1).leadingZeroBitCount
        return Int(try bits(width))
    }

    /// Skips SEQUENCE (SIZE(1..4)) OF RegionalExtension.
    mutating func skipRegionalExtensions() throws {
        for _ in 0..<(try int(1, 4)) {
            _ = try constrained(0, 255)
            try skipOpenType()
        }
    }
}
