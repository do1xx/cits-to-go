import Foundation

/// C-ITS message classification by ETSI ITS PDU header messageID.
enum ItsMessageType: Int, CaseIterable, Sendable {
    case denm = 1, cam = 2, poi = 3, spatem = 4, mapem = 5, ivim = 6, srem = 9, ssem = 10, rtcmem = 13, cpm = 14, imzm = 15, vam = 16

    var name: String {
        switch self {
        case .denm: "DENM"
        case .cam: "CAM"
        case .poi: "POI"
        case .spatem: "SPATEM"
        case .mapem: "MAPEM"
        case .ivim: "IVIM"
        case .srem: "SREM"
        case .ssem: "SSEM"
        case .rtcmem: "RTCMEM"
        case .cpm: "CPM"
        case .imzm: "IMZM"
        case .vam: "VAM"
        }
    }

    var longName: String {
        switch self {
        case .denm: "Decentralized Environmental Notification"
        case .cam: "Cooperative Awareness"
        case .poi: "Point of Interest"
        case .spatem: "Signal Phase and Timing"
        case .mapem: "Intersection Topology (MAP)"
        case .ivim: "Infrastructure to Vehicle Information"
        case .srem: "Signal Request"
        case .ssem: "Signal Request Status"
        case .rtcmem: "GNSS Corrections (RTCM)"
        case .cpm: "Collective Perception"
        case .imzm: "Interference Management Zone"
        case .vam: "VRU Awareness"
        }
    }

    static func from(btpPort: Int) -> ItsMessageType? {
        switch btpPort {
        case 2001: .cam
        case 2002: .denm
        case 2003: .mapem
        case 2004: .spatem
        case 2006: .ivim
        case 2007: .srem
        case 2008: .ssem
        case 2009: .cpm
        case 2018: .vam
        default: nil
        }
    }
}

struct ItsPacketInfo: Sendable {
    let destinationPort: Int
    let protocolVersion: Int
    let messageId: Int
    let stationId: UInt32
    let payload: [UInt8]           // ITS PDU incl. 6-byte header
    let sourceLatitude: Double?    // degrees
    let sourceLongitude: Double?
    let secured: Bool

    var messageType: ItsMessageType? { ItsMessageType(rawValue: messageId) ?? ItsMessageType.from(btpPort: destinationPort) }
    var displayName: String { messageType?.name ?? "msg \(messageId)" }
}

enum ItsExtraction: Sendable {
    case success(ItsPacketInfo)
    case notGeoNetworking
    case unsupported(reason: String, secured: Bool)
}

/// Port of the Android GeoNetworkingFrameParser + ItsFrameExtractor.
/// Locates LLC/SNAP (EtherType 0x8947), walks Basic/Common/Extended headers
/// (also inside a secured envelope) and returns the BTP-B / ITS PDU.
enum ItsFrameExtractor {
    private static let snapGeoNetworking: [UInt8] = [0xaa, 0xaa, 0x03, 0x00, 0x00, 0x00, 0x89, 0x47]
    private static let basicHeaderLen = 4
    private static let commonHeaderLen = 8
    private static let btpHeaderLen = 4
    private static let itsPduHeaderLen = 6
    private static let headerTypeGBC = 0x40
    private static let headerTypeSHB = 0x50
    private static let maxSecuredPrefixBytes = 512

    static func extract(_ frame: [UInt8]) -> ItsExtraction {
        guard let snap = indexOf(snapGeoNetworking, in: frame) else { return .notGeoNetworking }
        let basic = snap + snapGeoNetworking.count
        guard frame.count >= basic + basicHeaderLen else {
            return .unsupported(reason: "Truncated GeoNetworking Basic Header", secured: false)
        }
        switch Int(frame[basic] & 0x0f) {
        case 1:
            guard let r = parseCommon(frame, basic + basicHeaderLen, secured: false) else {
                return .unsupported(reason: "Unsupported GeoNetworking Common/Extended Header", secured: false)
            }
            return .success(r)
        case 2:
            let start = basic + basicHeaderLen
            let endExclusive = min(frame.count - commonHeaderLen + 1, start + maxSecuredPrefixBytes)
            var candidate: ItsPacketInfo?
            if start < endExclusive {
                for off in start..<endExclusive {
                    guard let parsed = parseCommon(frame, off, secured: true) else { continue }
                    if candidate != nil { return .unsupported(reason: "Ambiguous secured GeoNetworking payload", secured: true) }
                    candidate = parsed
                }
            }
            if let c = candidate { return .success(c) }
            return .unsupported(reason: "Secured payload without supported BTP-B Common Header", secured: true)
        case let nh:
            return .unsupported(reason: "Unsupported Basic Header next-header \(nh)", secured: false)
        }
    }

    private static func parseCommon(_ f: [UInt8], _ common: Int, secured: Bool) -> ItsPacketInfo? {
        guard f.count >= common + commonHeaderLen else { return nil }
        guard (f[common] >> 4) & 0x0f == 2 else { return nil } // BTP-B
        let headerType = Int(f[common + 1] & 0xf0)
        let extLen: Int, posOffset: Int
        switch headerType {
        case headerTypeGBC: extLen = 44; posOffset = 4
        case headerTypeSHB: extLen = 28; posOffset = 0
        default: return nil
        }
        let payloadLength = Int(f.u16be(common + 4))
        guard payloadLength >= btpHeaderLen + itsPduHeaderLen else { return nil }
        let ext = common + commonHeaderLen
        let btp = ext + extLen
        guard btp + payloadLength <= f.count else { return nil }
        let its = btp + btpHeaderLen
        let protocolVersion = Int(f[its]), messageId = Int(f[its + 1])
        guard (1...3).contains(protocolVersion), messageId != 0 else { return nil }

        let lpv = ext + posOffset
        func coord(_ o: Int) -> Double? {
            guard f.count >= o + 4 else { return nil }
            let raw = Int32(bitPattern: f.u32be(o))
            return Double(raw) / 10_000_000
        }
        var lat = coord(lpv + 12), lon = coord(lpv + 16)
        if let a = lat, let o = lon, abs(a) > 90 || abs(o) > 180 || (a == 0 && o == 0) { lat = nil; lon = nil }

        return ItsPacketInfo(
            destinationPort: Int(f.u16be(btp)),
            protocolVersion: protocolVersion,
            messageId: messageId,
            stationId: f.u32be(its + 2),
            payload: Array(f[its..<(btp + payloadLength)]),
            sourceLatitude: lat,
            sourceLongitude: lon,
            secured: secured
        )
    }

    private static func indexOf(_ pattern: [UInt8], in data: [UInt8]) -> Int? {
        guard data.count >= pattern.count else { return nil }
        outer: for off in 0...(data.count - pattern.count) {
            for i in 0..<pattern.count where data[off + i] != pattern[i] { continue outer }
            return off
        }
        return nil
    }
}

enum Ieee80211Mac {
    static func sourceAddress(_ frame: [UInt8]) -> String? {
        guard frame.count >= 16 else { return nil }
        let fc = Int(frame.u16le(0))
        let type = (fc >> 2) & 0x03
        guard type == 0 || type == 2 else { return nil }
        let toDs = fc & 0x0100 != 0, fromDs = fc & 0x0200 != 0
        let off: Int = type == 0 ? 10 : (toDs && fromDs ? 24 : fromDs ? 16 : 10)
        guard frame.count >= off + 6 else { return nil }
        let mac = frame[off..<(off + 6)]
        if mac.allSatisfy({ $0 == 0 }) || mac.first! & 0x01 != 0 { return nil }
        return mac.map { String(format: "%02x", $0) }.joined(separator: ":")
    }
}
