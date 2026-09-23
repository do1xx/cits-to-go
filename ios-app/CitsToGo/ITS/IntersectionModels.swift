import Foundation

struct IntersectionKey: Hashable, Sendable, CustomStringConvertible {
    let region: Int?
    let id: Int
    var description: String { region.map { "\($0)/\(id)" } ?? "\(id)" }
}

enum LaneType: Sendable {
    case vehicle, crosswalk, bike, sidewalk, median, striping, trackedVehicle, parking, other
}

struct LaneNode: Sendable {
    var xCm: Int
    var yCm: Int
    var stopLine = false
    var widthDeltaCm: Int?
}

struct LaneConnection: Sendable {
    let laneId: Int
    let signalGroup: Int?
    let connectionId: Int?
    let remoteIntersection: IntersectionKey?
}

struct MapLane: Sendable, Identifiable {
    let id: Int
    let ingressApproach: Int?
    let egressApproach: Int?
    let laneType: LaneType
    let ingress: Bool
    let egress: Bool
    let nodes: [LaneNode]
    let connections: [LaneConnection]
}

struct MapIntersection: Sendable {
    let key: IntersectionKey
    var name: String?
    let revision: Int
    let latitudeE7: Int
    let longitudeE7: Int
    var laneWidthCm: Int?
    var lanes: [MapLane]
    var receivedAt: Date

    var latitude: Double { Double(latitudeE7) / 1e7 }
    var longitude: Double { Double(longitudeE7) / 1e7 }

    /// Approximate distance in metres (equirectangular, fine at intersection scale).
    func distance(latitude lat: Double, longitude lon: Double) -> Double {
        let dLat = (latitude - lat) * 111_320
        let dLon = (longitude - lon) * 111_320 * cos(latitude * .pi / 180)
        return (dLat * dLat + dLon * dLon).squareRoot()
    }

    /// Converts a WGS84 position into this intersection's local XY frame (cm, y = north).
    func localOffsetCm(latitude lat: Double, longitude lon: Double) -> (x: Double, y: Double) {
        let cmPerDegree = 11_132_000.0
        return ((lon - longitude) * cmPerDegree * cos(latitude * .pi / 180), (lat - latitude) * cmPerDegree)
    }
}

enum MovementPhaseState: Int, Sendable {
    case unavailable = 0, dark, stopThenProceed, stopAndRemain, preMovement, permissiveAllowed,
         protectedAllowed, permissiveClearance, protectedClearance, cautionConflictingTraffic
    case unknown = -1

    var label: String {
        switch self {
        case .unavailable: "Nicht verfügbar"
        case .dark: "Aus"
        case .stopThenProceed: "Halt, dann fahren"
        case .stopAndRemain: "Rot"
        case .preMovement: "Rot-Gelb"
        case .permissiveAllowed: "Grün (bedingt)"
        case .protectedAllowed: "Grün"
        case .permissiveClearance, .protectedClearance: "Gelb"
        case .cautionConflictingTraffic: "Achtung"
        case .unknown: "Unbekannt"
        }
    }

    enum Category { case stop, caution, go, unknown }

    var category: Category {
        switch self {
        case .stopAndRemain, .stopThenProceed: .stop
        case .preMovement, .permissiveClearance, .protectedClearance, .cautionConflictingTraffic: .caution
        case .permissiveAllowed, .protectedAllowed: .go
        case .dark, .unavailable, .unknown: .unknown
        }
    }
}

struct SignalEvent: Sendable {
    let state: MovementPhaseState
    let minEndTime: Int?
    let likelyTime: Int?
    let maxEndTime: Int?
    let confidence: Int?
    var advisorySpeedKmh: Int? = nil
}

struct SignalMovement: Sendable {
    let signalGroup: Int
    let events: [SignalEvent]
    let connectionIds: [Int]
    var currentEvent: SignalEvent? { events.first }
}

struct SpatIntersection: Sendable {
    let key: IntersectionKey
    let revision: Int
    let moy: Int?
    let timestampMs: Int?
    let movements: [SignalMovement]
    let receivedAt: Date

    var movementsBySignalGroup: [Int: SignalMovement] {
        Dictionary(movements.map { ($0.signalGroup, $0) }, uniquingKeysWith: { _, b in b })
    }

    private static let minutesPerLeapYear = 527_040

    private var timeWithinHourTenths: Int? {
        guard let moy, (0..<Self.minutesPerLeapYear).contains(moy),
              let ts = timestampMs, (0..<60_000).contains(ts) else { return nil }
        return (moy % 60) * 600 + ts / 100
    }

    /// Stable, non-negative countdown for a SPATEM TimeMark (tenths of a second within the hour).
    func secondsUntilChange(_ event: SignalEvent, now: Date) -> Int? {
        guard let target = [event.likelyTime, event.minEndTime, event.maxEndTime]
                .compactMap({ $0 }).first(where: { (0..<36_000).contains($0) }),
              let message = timeWithinHourTenths else { return nil }
        var remaining = target - message
        if remaining < 0 {
            guard message >= 36_000 - 600 && target < 600 else { return nil }
            remaining += 36_000
        }
        let elapsed = Int(max(0, now.timeIntervalSince(receivedAt)) * 10)
        let left = remaining - elapsed
        return left < 0 ? nil : (left + 9) / 10
    }

    func isAtLeastAsRecent(as other: SpatIntersection) -> Bool {
        guard let m = moy, (0..<Self.minutesPerLeapYear).contains(m),
              let om = other.moy, (0..<Self.minutesPerLeapYear).contains(om),
              let t = timestampMs, (0..<60_000).contains(t),
              let ot = other.timestampMs, (0..<60_000).contains(ot) else { return true }
        if m != om { return m > om || (om >= Self.minutesPerLeapYear - 2 && m < 2) }
        return t >= ot
    }
}

struct IntersectionSnapshot: Sendable, Identifiable {
    let key: IntersectionKey
    let map: MapIntersection?
    let spat: SpatIntersection?
    let firstReceivedAt: Date
    var id: IntersectionKey { key }
    var updatedAt: Date { max(map?.receivedAt ?? .distantPast, spat?.receivedAt ?? .distantPast) }
    var title: String { map?.name.flatMap { $0.isEmpty ? nil : $0 } ?? "Kreuzung \(key)" }
}

struct IntersectionDiagnostics: Sendable {
    var mapemSeen = 0, mapemDecoded = 0, mapemFailures = 0
    var spatemSeen = 0, spatemDecoded = 0, spatemFailures = 0
    var lastDecodeError: String?
}
