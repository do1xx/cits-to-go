import Foundation

/// Consistent Overhead Byte Stuffing, identical to the firmware / Android implementation.
enum Cobs {
    struct MalformedRecord: Error {}

    static func encode(_ input: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: input.count + input.count / 254 + 1)
        var write = 1
        var codeIndex = 0
        var code: UInt8 = 1

        for value in input {
            if value == 0 {
                out[codeIndex] = code
                codeIndex = write
                write += 1
                code = 1
            } else {
                out[write] = value
                write += 1
                code += 1
                if code == 0xff {
                    out[codeIndex] = code
                    codeIndex = write
                    write += 1
                    code = 1
                }
            }
        }
        out[codeIndex] = code
        return Array(out[0..<write])
    }

    static func decode<C: RandomAccessCollection>(_ input: C) throws -> [UInt8] where C.Element == UInt8, C.Index == Int {
        var out = [UInt8]()
        out.reserveCapacity(input.count)
        var read = input.startIndex
        let end = input.endIndex

        while read < end {
            let code = Int(input[read])
            read += 1
            if code == 0 || read + code - 1 > end { throw MalformedRecord() }
            for _ in 0..<(code - 1) {
                out.append(input[read])
                read += 1
            }
            if code < 0xff && read < end { out.append(0) }
        }
        return out
    }
}

/// IEEE 802.3 CRC-32 (same polynomial as java.util.zip.CRC32).
enum Crc32 {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum<C: Collection>(_ bytes: C) -> UInt32 where C.Element == UInt8 {
        var crc: UInt32 = 0xffff_ffff
        for b in bytes { crc = table[Int((crc ^ UInt32(b)) & 0xff)] ^ (crc >> 8) }
        return crc ^ 0xffff_ffff
    }
}

extension Array where Element == UInt8 {
    func u16le(_ o: Int) -> UInt16 { UInt16(self[o]) | UInt16(self[o + 1]) << 8 }
    func u32le(_ o: Int) -> UInt32 { UInt32(u16le(o)) | UInt32(u16le(o + 2)) << 16 }
    func u64le(_ o: Int) -> UInt64 { UInt64(u32le(o)) | UInt64(u32le(o + 4)) << 32 }
    func u16be(_ o: Int) -> UInt16 { UInt16(self[o]) << 8 | UInt16(self[o + 1]) }
    func u32be(_ o: Int) -> UInt32 { UInt32(u16be(o)) << 16 | UInt32(u16be(o + 2)) }

    mutating func putU16le(_ v: UInt16, at o: Int) {
        self[o] = UInt8(v & 0xff); self[o + 1] = UInt8(v >> 8)
    }
    mutating func putU32le(_ v: UInt32, at o: Int) {
        for i in 0..<4 { self[o + i] = UInt8((v >> (8 * UInt32(i))) & 0xff) }
    }

    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
