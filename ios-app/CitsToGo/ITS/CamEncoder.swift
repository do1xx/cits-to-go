import CoreLocation
import Foundation

/// Unaligned PER bit writer (port of the Android UperBitWriter).
struct UperBitWriter {
    private(set) var bytes: [UInt8] = []
    private var bitCount = 0

    mutating func bit(_ v: Bool) { bits(v ? 1 : 0, 1) }

    mutating func constrained(_ value: Int64, _ minimum: Int64, _ maximum: Int64) {
        precondition(value >= minimum && value <= maximum, "\(value) outside \(minimum)...\(maximum)")
        let range = maximum - minimum + 1
        bits(UInt64(value - minimum), range <= 1 ? 0 : 64 - (range - 1).leadingZeroBitCount)
    }

    mutating func bits(_ value: UInt64, _ width: Int) {
        for shift in stride(from: width - 1, through: 0, by: -1) {
            if bitCount % 8 == 0 { bytes.append(0) }
            if (value >> UInt64(shift)) & 1 == 1 { bytes[bitCount / 8] |= 1 << UInt8(7 - bitCount % 8) }
            bitCount += 1
        }
    }
}

/// Station ID and 802.11 source address used when transmitting.
struct CamIdentity: Equatable, Sendable {
    let stationId: UInt32
    let mac: [UInt8]

    /// Random station ID and a locally administered unicast MAC (like a pseudonym change).
    static func random() -> CamIdentity {
        var mac = (0..<6).map { _ in UInt8.random(in: 0...255) }
        mac[0] = (mac[0] & 0xFC) | 0x02
        return CamIdentity(stationId: UInt32.random(in: 1...0xFFFF_FFFE), mac: mac)
    }

    var macString: String { mac.map { String(format: "%02x", $0) }.joined(separator: ":") }
}

/// Position/kinematics in CAM units; "unavailable" values per ETSI TS 102 894-2.
struct CamPosition: Sendable {
    var latitude: Int = 900_000_001, longitude: Int = 1_800_000_001
    var semiMajorCm = 4_095, semiMinorCm = 4_095, semiMajorOrientation = 3_601
    var altitudeCm = 800_001, altitudeConfidence = 15
    var heading = 3_601, headingConfidence = 127
    var speedCms = 16_383, speedConfidence = 127
    var accurate = false

    init() {}

    init(location l: CLLocation) {
        latitude = Int((l.coordinate.latitude * 1e7).rounded()).clamped(-900_000_000, 900_000_000)
        longitude = Int((l.coordinate.longitude * 1e7).rounded()).clamped(-1_800_000_000, 1_800_000_000)
        if l.horizontalAccuracy >= 0 {
            let cm = max(1, Int((l.horizontalAccuracy * 100).rounded(.up)))
            semiMajorCm = cm <= 4_093 ? cm : 4_094
            semiMinorCm = semiMajorCm
            semiMajorOrientation = 0
            accurate = semiMajorCm <= 500
        }
        if l.verticalAccuracy >= 0 {
            altitudeCm = Int((l.altitude * 100).rounded()).clamped(-100_000, 800_000)
            altitudeConfidence = Self.altitudeConfidence(l.verticalAccuracy)
        }
        if l.course >= 0 {
            heading = Int((l.course.truncatingRemainder(dividingBy: 360) * 10).rounded()).clamped(0, 3_600)
            if l.courseAccuracy >= 0 { headingConfidence = max(1, Int((l.courseAccuracy * 10).rounded(.up))).clamped(1, 126) }
        }
        if l.speed >= 0 {
            speedCms = Int((l.speed * 100).rounded()).clamped(0, 16_382)
            if l.speedAccuracy >= 0 { speedConfidence = max(1, Int((l.speedAccuracy * 100).rounded(.up))).clamped(1, 126) }
        }
    }

    private static func altitudeConfidence(_ m: Double) -> Int {
        let steps: [Double] = [0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1, 2, 5, 10, 20, 50, 100, 200]
        return steps.firstIndex { m <= $0 } ?? 14
    }
}

private extension Int {
    func clamped(_ lo: Int, _ hi: Int) -> Int { Swift.min(Swift.max(self, lo), hi) }
}

/// CAM Release 1 (protocolVersion 2) encoder and GeoNetworking SHB / BTP-B framing,
/// ported from the Android app (CamUperEncoder / ItsG5FrameBuilder).
enum CamEncoder {
    static let itsEpochUnixMs: Int64 = 1_072_915_200_000
    static let leapMs: Int64 = 5_000   // TAI − UTC grew by 5 s since the ITS epoch

    static func timestampIts(_ now: Date) -> Int64 {
        Int64((now.timeIntervalSince1970 * 1000).rounded()) - itsEpochUnixMs + leapMs
    }

    static func encodeCam(identity: CamIdentity, stationType: StationType, position p: CamPosition, now: Date) -> [UInt8] {
        var w = UperBitWriter()
        w.constrained(2, 0, 255)                                   // protocolVersion
        w.constrained(2, 0, 255)                                   // messageID cam
        w.constrained(Int64(identity.stationId), 0, 0xFFFF_FFFF)
        w.constrained(timestampIts(now) % 65_536, 0, 65_535)       // generationDeltaTime
        w.bit(false); w.bit(false); w.bit(false)                   // CamParameters: ext, lowFreq, special
        w.bit(false)                                               // BasicContainer ext
        w.constrained(Int64(stationType.rawValue), 0, 255)
        w.constrained(Int64(p.latitude), -900_000_000, 900_000_001)
        w.constrained(Int64(p.longitude), -1_800_000_000, 1_800_000_001)
        w.constrained(Int64(p.semiMajorCm), 0, 4_095)
        w.constrained(Int64(p.semiMinorCm), 0, 4_095)
        w.constrained(Int64(p.semiMajorOrientation), 0, 3_601)
        w.constrained(Int64(p.altitudeCm), -100_000, 800_001)
        w.constrained(Int64(p.altitudeConfidence), 0, 15)
        w.bit(false)                                               // HighFrequencyContainer: root choice
        let rsu = stationType == .roadSideUnit
        w.bit(rsu)
        if rsu {
            w.bit(false); w.bit(false)
        } else {
            for _ in 0..<7 { w.bit(false) }                        // optional vehicle fields absent
            w.constrained(Int64(p.heading), 0, 3_601)
            w.constrained(Int64(p.headingConfidence), 1, 127)
            w.constrained(Int64(p.speedCms), 0, 16_383)
            w.constrained(Int64(p.speedConfidence), 1, 127)
            w.constrained(p.speedCms == 16_383 ? 2 : 0, 0, 2)      // driveDirection
            w.constrained(1_023, 1, 1_023); w.constrained(4, 0, 4) // vehicleLength unavailable
            w.constrained(62, 1, 62)                               // vehicleWidth unavailable
            w.constrained(161, -160, 161); w.constrained(102, 0, 102) // longitudinalAcceleration
            w.constrained(1_023, -1_023, 1_023); w.constrained(7, 0, 7) // curvature
            w.bit(false); w.constrained(2, 0, 2)                   // curvatureCalculationMode unavailable
            w.constrained(32_767, -32_766, 32_767); w.constrained(8, 0, 8) // yawRate unavailable
        }
        return w.bytes
    }

    private static var wlanSequence: UInt16 = 0

    /// Complete IEEE 802.11 QoS-data broadcast frame: LLC/SNAP + GeoNetworking SHB + BTP-B 2001 + CAM.
    static func camFrame(identity: CamIdentity, stationType: StationType, position p: CamPosition, now: Date) -> [UInt8] {
        let cam = encodeCam(identity: identity, stationType: stationType, position: p, now: now)
        var btp: [UInt8] = [0x07, 0xD1, 0x00, 0x00] + cam          // destination port 2001, port info 0
        let geoAvailable = abs(p.latitude) <= 899_999_999 && abs(p.longitude) <= 1_799_999_999
        var gn: [UInt8] = [0x11, 0x00, 0x05, 0x01]                 // basic: v1, common, lifetime 1 s, 1 hop
        gn += [0x20, 0x50, 0x02, stationType == .roadSideUnit ? 0x00 : 0x80]  // common: BTP-B, SHB, TC 2, mobile
        gn += be16(UInt16(btp.count)) + [0x01, 0x00]               // payload length, max hop 1, reserved
        gn += [UInt8((stationType.rawValue & 0x1F) << 2), 0x00] + identity.mac   // GN address
        gn += be32(UInt32(truncatingIfNeeded: timestampIts(now)))
        gn += be32(UInt32(bitPattern: Int32(geoAvailable ? p.latitude : 0)))
        gn += be32(UInt32(bitPattern: Int32(geoAvailable ? p.longitude : 0)))
        gn += be16(UInt16(p.speedCms.clampedTo(0, 16_383)) | (p.accurate && geoAvailable ? 0x8000 : 0))
        gn += be16(UInt16(p.heading.clampedTo(0, 3_600)))
        gn += [0, 0, 0, 0]                                         // SHB reserved / DCC
        gn += btp
        btp = []
        wlanSequence &+= 1
        let seq = (wlanSequence & 0x0FFF) << 4
        var frame: [UInt8] = [0x88, 0x00, 0x00, 0x00]              // QoS data, duration 0
        frame += [UInt8](repeating: 0xFF, count: 6) + identity.mac + [UInt8](repeating: 0xFF, count: 6)
        frame += [UInt8(seq & 0xFF), UInt8(seq >> 8)]              // sequence control
        frame += [0x03, 0x00]                                      // QoS control: TID 3
        frame += [0xAA, 0xAA, 0x03, 0x00, 0x00, 0x00, 0x89, 0x47]  // LLC/SNAP, GeoNetworking
        return frame + gn
    }

    private static func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xFF)] }
    private static func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
}

private extension Int {
    func clampedTo(_ lo: Int, _ hi: Int) -> Int { Swift.min(Swift.max(self, lo), hi) }
}
