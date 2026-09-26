import Foundation

/// One captured over-the-air frame as reported by the ESP32-C5 firmware.
struct CitsPacket: Sendable {
    static let flagBroadcast: UInt16 = 0x0001
    static let flagTruncated: UInt16 = 0x0002

    let sequence: UInt32
    let timestampUs: UInt64
    let frequencyMhz: UInt16
    let rssiDbm: Int8
    let wifiType: UInt8
    let rxState: UInt8
    let flags: UInt16
    let originalLength: UInt16
    let payload: [UInt8]

    var truncated: Bool { flags & Self.flagTruncated != 0 }
    var broadcast: Bool { flags & Self.flagBroadcast != 0 }
}

struct FirmwareStatistics: Sendable {
    static let flagUsbConnected: UInt32 = 1 << 0
    static let flagBleConnected: UInt32 = 1 << 1
    static let flagBleNotifyEnabled: UInt32 = 1 << 2
    static let flagBleSecured: UInt32 = 1 << 3

    var uptimeMs: UInt32
    var wifiRxPacketsPerSecond: UInt32
    var capturedPacketsPerSecond: UInt32
    var bleCapturePacketsPerSecond: UInt32
    var bleBytesPerSecond: UInt32
    var rxNoBufferTotal: UInt32
    var rxTooLargeTotal: UInt32
    var bleOutputDropsTotal: UInt32
    var bleNotifyFailuresTotal: UInt32
    var wifiRxPacketsTotal: UInt32
    var capturedPacketsTotal: UInt32
    var bleCapturePacketsTotal: UInt32
    var flags: UInt32
    var bleQueueDepth: UInt16
    var bleQueueCapacity: UInt16
    var bleMtu: UInt16
    var bleConnectionIntervalUnits: UInt16

    var usbConnected: Bool { flags & Self.flagUsbConnected != 0 }
    var bleSecured: Bool { flags & Self.flagBleSecured != 0 }
    var bleConnectionIntervalMs: Double? { bleConnectionIntervalUnits > 0 ? Double(bleConnectionIntervalUnits) * 1.25 : nil }
}

enum CtgInboundFrame: Sendable {
    case capture(CitsPacket)
    case txResult(requestId: UInt32, status: UInt32, packetLength: UInt16)
    case bluetoothEnrollmentResult(status: UInt32, armed: Bool)
    case pinResult(status: UInt32, pin: UInt32)
    case statistics(FirmwareStatistics)
}

struct CtgProtocolError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

/// CTG1 record format shared by USB and BLE transports (see firmware/src/protocol.rs).
enum CtgProtocol {
    static let typeCapture: UInt8 = 1
    static let typeTxRequest: UInt8 = 2
    static let typeTxResult: UInt8 = 3
    static let typeBleEnrollRequest: UInt8 = 4
    static let typeBleEnrollResult: UInt8 = 5
    static let typeStatistics: UInt8 = 6
    static let typeSetPin: UInt8 = 7
    static let typePinResult: UInt8 = 8

    static let captureHeaderLen = 32
    static let txRequestHeaderLen = 16
    static let txResultHeaderLen = 20
    static let bleEnrollRequestHeaderLen = 12
    static let bleEnrollResultHeaderLen = 16
    static let statisticsHeaderLen = 112
    static let minHeaderLen = 8
    static let crcLen = 4
    static let maxPacketBytes = 2352
    static let flagEnSysSeq: UInt16 = 0x0001

    // MARK: Decoding

    static func decode<C: RandomAccessCollection>(encoded: C) throws -> CtgInboundFrame where C.Element == UInt8, C.Index == Int {
        let d: [UInt8]
        do { d = try Cobs.decode(encoded) } catch { throw CtgProtocolError("Malformed COBS record") }
        guard d.count >= minHeaderLen + crcLen else { throw CtgProtocolError("Frame too short") }
        guard d[0] == 0x43, d[1] == 0x54, d[2] == 0x47, d[3] == 0x31 else { throw CtgProtocolError("Bad CTG1 magic") }
        let version = d[4], type = d[5]
        let headerLen = Int(d.u16le(6))
        guard version == 1 else { throw CtgProtocolError("Unsupported CTG version \(version)") }
        guard headerLen >= minHeaderLen, d.count >= headerLen + crcLen else {
            throw CtgProtocolError("Invalid CTG header length \(headerLen)")
        }
        let expected = d.u32le(d.count - crcLen)
        guard Crc32.checksum(d[0..<(d.count - crcLen)]) == expected else { throw CtgProtocolError("CRC mismatch") }

        switch type {
        case typeCapture:
            guard headerLen == captureHeaderLen else { throw CtgProtocolError("Unexpected capture header length \(headerLen)") }
            let capturedLen = Int(d.u16le(26))
            guard d.count == headerLen + capturedLen + crcLen else {
                throw CtgProtocolError("Frame length \(d.count) does not match captured length \(capturedLen)")
            }
            return .capture(CitsPacket(
                sequence: d.u32le(10),
                timestampUs: d.u64le(14),
                frequencyMhz: d.u16le(22),
                rssiDbm: Int8(bitPattern: d[28]),
                wifiType: d[29],
                rxState: d[30],
                flags: d.u16le(8),
                originalLength: d.u16le(24),
                payload: Array(d[headerLen..<(headerLen + capturedLen)])
            ))
        case typeTxResult:
            guard headerLen == txResultHeaderLen else { throw CtgProtocolError("Malformed TX result") }
            return .txResult(requestId: d.u32le(8), status: d.u32le(12), packetLength: d.u16le(16))
        case typeBleEnrollResult:
            guard headerLen == bleEnrollResultHeaderLen, d.count == headerLen + crcLen else {
                throw CtgProtocolError("Malformed Bluetooth enrollment result")
            }
            return .bluetoothEnrollmentResult(status: d.u32le(8), armed: d[12] != 0)
        case typePinResult:
            guard headerLen == 16, d.count == headerLen + crcLen else { throw CtgProtocolError("Malformed PIN result") }
            return .pinResult(status: d.u32le(8), pin: d.u32le(12))
        case typeStatistics:
            guard headerLen == statisticsHeaderLen, d.count == headerLen + crcLen else {
                throw CtgProtocolError("Malformed statistics record")
            }
            return .statistics(FirmwareStatistics(
                uptimeMs: d.u32le(8),
                wifiRxPacketsPerSecond: d.u32le(16),
                capturedPacketsPerSecond: d.u32le(20),
                bleCapturePacketsPerSecond: d.u32le(28),
                bleBytesPerSecond: d.u32le(36),
                rxNoBufferTotal: d.u32le(44),
                rxTooLargeTotal: d.u32le(48),
                bleOutputDropsTotal: d.u32le(60),
                bleNotifyFailuresTotal: d.u32le(68),
                wifiRxPacketsTotal: d.u32le(72),
                capturedPacketsTotal: d.u32le(76),
                bleCapturePacketsTotal: d.u32le(84),
                flags: d.u32le(88),
                bleQueueDepth: d.u16le(96),
                bleQueueCapacity: d.u16le(98),
                bleMtu: d.u16le(100),
                bleConnectionIntervalUnits: d.u16le(102)
            ))
        default:
            throw CtgProtocolError("Unsupported CTG frame type \(type)")
        }
    }

    // MARK: Encoding

    static func txRequest(requestId: UInt32, packet: [UInt8], flags: UInt16 = flagEnSysSeq) -> [UInt8] {
        precondition(!packet.isEmpty && packet.count <= maxPacketBytes)
        var d = header(type: typeTxRequest, headerLen: txRequestHeaderLen, bodyLen: packet.count)
        d.putU32le(requestId, at: 8)
        d.putU16le(UInt16(packet.count), at: 12)
        d.putU16le(flags, at: 14)
        d.replaceSubrange(txRequestHeaderLen..<(txRequestHeaderLen + packet.count), with: packet)
        return seal(d)
    }

    static func bluetoothEnrollmentRequest() -> [UInt8] {
        var d = header(type: typeBleEnrollRequest, headerLen: bleEnrollRequestHeaderLen, bodyLen: 0)
        d[8] = 1 // replace existing owner and arm exactly one pairing attempt
        return seal(d)
    }

    /// Changes the Bluetooth pairing PIN (0…999999); only accepted over an already paired link.
    static func setPinRequest(_ pin: UInt32) -> [UInt8] {
        precondition(pin <= 999_999)
        var d = header(type: typeSetPin, headerLen: 12, bodyLen: 0)
        d.putU32le(pin, at: 8)
        return seal(d)
    }

    private static func header(type: UInt8, headerLen: Int, bodyLen: Int) -> [UInt8] {
        var d = [UInt8](repeating: 0, count: headerLen + bodyLen + crcLen)
        d[0] = 0x43; d[1] = 0x54; d[2] = 0x47; d[3] = 0x31
        d[4] = 1
        d[5] = type
        d.putU16le(UInt16(headerLen), at: 6)
        return d
    }

    private static func seal(_ decoded: [UInt8]) -> [UInt8] {
        var d = decoded
        d.putU32le(Crc32.checksum(d[0..<(d.count - crcLen)]), at: d.count - crcLen)
        return Cobs.encode(d) + [0]
    }
}

/// Splits a byte stream (BLE notifications are arbitrary chunks) into 0x00-delimited CTG records.
struct CtgStreamReader {
    static let maxEncodedRecord = 8192

    private var record: [UInt8] = []
    private var discarding = false

    init() { record.reserveCapacity(Self.maxEncodedRecord) }

    mutating func reset() {
        record.removeAll(keepingCapacity: true)
        discarding = false
    }

    /// Feeds raw bytes and returns every complete frame (or decode error) found.
    mutating func accept<S: Sequence>(_ bytes: S) -> [Result<CtgInboundFrame, CtgProtocolError>] where S.Element == UInt8 {
        var results: [Result<CtgInboundFrame, CtgProtocolError>] = []
        for b in bytes {
            if b == 0 {
                if !discarding && !record.isEmpty {
                    do { results.append(.success(try CtgProtocol.decode(encoded: record))) }
                    catch let e as CtgProtocolError { results.append(.failure(e)) }
                    catch { results.append(.failure(CtgProtocolError("\(error)"))) }
                }
                record.removeAll(keepingCapacity: true)
                discarding = false
            } else if !discarding {
                if record.count < Self.maxEncodedRecord {
                    record.append(b)
                } else {
                    record.removeAll(keepingCapacity: true)
                    discarding = true
                    results.append(.failure(CtgProtocolError("Record exceeded \(Self.maxEncodedRecord) bytes; resynchronizing")))
                }
            }
        }
        return results
    }
}

/// Counts missing capture sequence numbers, including across u32 wrap-around.
struct CaptureSequenceTracker {
    private var previous: UInt32?

    mutating func reset() { previous = nil }

    mutating func observe(_ sequence: UInt32) -> UInt32 {
        defer { previous = sequence }
        guard let last = previous else { return 0 }
        let delta = sequence &- last
        return (2...0x7fff_ffff).contains(delta) ? delta - 1 : 0
    }
}
