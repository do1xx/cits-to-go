import Foundation

/// Classic libpcap writer, LINKTYPE_IEEE802_11 (105), as produced by the Android app.
/// Device timestamps (u32 µs wrap on the firmware side) are anchored to wall clock at the first packet.
final class PcapWriter {
    let url: URL
    private let handle: FileHandle
    private var buffer = Data()
    private var lastFlush = Date()
    private var epochUs: UInt64?
    private var baseDeviceUs: UInt64?
    private var previousDeviceUs: UInt64?
    private var wrapOffsetUs: UInt64 = 0
    private(set) var packetCount = 0

    private static let deviceRange: UInt64 = 1 << 32

    static var capturesDirectory: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("captures", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    convenience init() throws {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        try self.init(url: Self.capturesDirectory.appendingPathComponent("cits-\(f.string(from: Date())).pcap"))
    }

    init(url: URL) throws {
        self.url = url
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        var h = [UInt8]()
        h.le32(0xA1B2_C3D4); h.le16(2); h.le16(4); h.le32(0); h.le32(0); h.le32(65_535); h.le32(105)
        buffer.append(contentsOf: h)
        flush()
    }

    func write(_ packet: CitsPacket) {
        let ts = unixMicros(packet.timestampUs)
        var rec = [UInt8]()
        rec.reserveCapacity(16 + packet.payload.count)
        rec.le32(UInt32(ts / 1_000_000)); rec.le32(UInt32(ts % 1_000_000))
        rec.le32(UInt32(packet.payload.count)); rec.le32(UInt32(max(Int(packet.originalLength), packet.payload.count)))
        rec += packet.payload
        buffer.append(contentsOf: rec)
        packetCount += 1
        if buffer.count > 64 * 1024 || Date().timeIntervalSince(lastFlush) > 2 { flush() }
    }

    func flush() {
        guard !buffer.isEmpty else { return }
        try? handle.write(contentsOf: buffer)
        buffer.removeAll(keepingCapacity: true)
        lastFlush = Date()
    }

    func close() {
        flush()
        try? handle.close()
    }

    private func unixMicros(_ timestampUs: UInt64) -> UInt64 {
        let raw = timestampUs & (Self.deviceRange - 1)
        if let prev = previousDeviceUs, raw < prev {
            if prev - raw > Self.deviceRange / 2 {
                wrapOffsetUs += Self.deviceRange
            } else {
                epochUs = nil; baseDeviceUs = nil; wrapOffsetUs = 0
            }
        }
        previousDeviceUs = raw
        let extended = raw + wrapOffsetUs
        if baseDeviceUs == nil {
            baseDeviceUs = extended
            epochUs = UInt64(Date().timeIntervalSince1970 * 1_000_000)
        }
        return epochUs! + extended - baseDeviceUs!
    }
}

private extension Array where Element == UInt8 {
    mutating func le16(_ v: UInt16) { append(UInt8(v & 0xff)); append(UInt8(v >> 8)) }
    mutating func le32(_ v: UInt32) { for i in 0..<4 { append(UInt8((v >> (8 * UInt32(i))) & 0xff)) } }
}
