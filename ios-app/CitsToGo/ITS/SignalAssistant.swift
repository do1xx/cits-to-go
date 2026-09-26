import CoreLocation
import Foundation

/// "Which traffic light am I driving towards?" – matches the phone's position and course against
/// the ingress lanes of received MAPEMs and reads the phase of their signal groups from SPATEM.
struct SignalAdvice: Equatable, Sendable {
    struct Group: Equatable, Sendable {
        let signalGroup: Int
        let state: MovementPhaseState
        let secondsLeft: Int?
        let advisoryKmh: Int?
    }
    let intersection: String
    let key: IntersectionKey
    let laneId: Int
    let distanceToStopLine: Double      // metres
    let groups: [Group]

    /// The group to show prominently: the most permissive one (green beats caution beats red).
    var primary: Group? {
        groups.min { rank($0.state) < rank($1.state) }
    }
    private func rank(_ s: MovementPhaseState) -> Int {
        switch s.category { case .go: 0; case .caution: 1; case .stop: 2; case .unknown: 3 }
    }
}

enum SignalAssistant {
    static let maxDistance = 350.0           // metres to the stop line
    static let maxLateral = 8.0              // metres off the lane centre line
    static let maxAngle = 40.0               // degrees between course and lane direction

    static func advice(location: CLLocation, snapshots: [IntersectionSnapshot], now: Date = Date()) -> SignalAdvice? {
        guard location.course >= 0, location.horizontalAccuracy >= 0, location.horizontalAccuracy < 30 else { return nil }
        var best: (score: Double, advice: SignalAdvice)?
        for snap in snapshots {
            guard let map = snap.map, let spat = snap.spat else { continue }
            guard map.distance(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude) < maxDistance + 200 else { continue }
            let me = map.localOffsetCm(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
            let p = SIMD2(me.x / 100, me.y / 100)                    // metres, x east / y north
            let phases = spat.movementsBySignalGroup
            for lane in map.lanes where lane.ingress && lane.nodes.count >= 2 && lane.laneType == .vehicle {
                let groups = Array(Set(lane.connections.compactMap(\.signalGroup))).sorted()
                guard !groups.isEmpty else { continue }
                // Ingress lanes are described from the stop line outwards: travel direction is towards node 0.
                let pts = lane.nodes.map { SIMD2(Double($0.xCm) / 100, Double($0.yCm) / 100) }
                var bestSeg: (lateral: Double, along: Double, dir: SIMD2<Double>)?
                var cumulative = 0.0
                for i in 0..<(pts.count - 1) {
                    let a = pts[i], b = pts[i + 1]              // a is closer to the stop line
                    let ab = b - a
                    let len = (ab * ab).sum().squareRoot()
                    guard len > 0.1 else { continue }
                    let t = max(0, min(1, ((p - a) * ab).sum() / (len * len)))
                    let q = a + ab * t
                    let lateral = ((p - q) * (p - q)).sum().squareRoot()
                    if bestSeg == nil || lateral < bestSeg!.lateral {
                        bestSeg = (lateral, cumulative + t * len, -ab / len)
                    }
                    cumulative += len
                }
                guard let seg = bestSeg, seg.lateral <= maxLateral + Double(map.laneWidthCm ?? 300) / 200,
                      seg.along <= maxDistance else { continue }
                let laneBearing = atan2(seg.dir.x, seg.dir.y) * 180 / .pi       // 0 = north
                var diff = abs(laneBearing - location.course).truncatingRemainder(dividingBy: 360)
                if diff > 180 { diff = 360 - diff }
                guard diff <= maxAngle else { continue }
                let infos = groups.compactMap { sg -> SignalAdvice.Group? in
                    guard let event = phases[sg]?.currentEvent else { return nil }
                    return .init(signalGroup: sg, state: event.state,
                                 secondsLeft: spat.secondsUntilChange(event, now: now), advisoryKmh: event.advisorySpeedKmh)
                }
                guard !infos.isEmpty else { continue }
                let score = seg.lateral * 3 + seg.along * 0.1 + diff
                if best == nil || score < best!.score {
                    best = (score, SignalAdvice(intersection: snap.title, key: snap.key, laneId: lane.id,
                                                distanceToStopLine: seg.along, groups: infos))
                }
            }
        }
        return best?.advice
    }
}
