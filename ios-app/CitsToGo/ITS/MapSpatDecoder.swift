import Foundation

struct IntersectionDecodeError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

/// Unaligned PER bit reader (port of the Android UperBitReader).
struct UperBitReader {
    private let bytes: [UInt8]
    private var bitOffset: Int

    init(_ bytes: [UInt8], byteOffset: Int = 0) {
        self.bytes = bytes
        bitOffset = byteOffset * 8
    }

    var remainingBits: Int { bytes.count * 8 - bitOffset }

    mutating func bit() throws -> Bool { try bits(1) != 0 }

    mutating func bits(_ width: Int) throws -> Int64 {
        guard remainingBits >= width else { throw IntersectionDecodeError("PER payload ended early") }
        var value: Int64 = 0
        for _ in 0..<width {
            let byte = bytes[bitOffset >> 3]
            value = (value << 1) | Int64((byte >> (7 - UInt8(bitOffset & 7))) & 1)
            bitOffset += 1
        }
        return value
    }

    mutating func constrained(_ minimum: Int64, _ maximum: Int64) throws -> Int64 {
        let range = maximum - minimum + 1
        let width = range <= 1 ? 0 : 64 - (range - 1).leadingZeroBitCount
        return minimum + (try bits(width))
    }

    mutating func int(_ minimum: Int64, _ maximum: Int64) throws -> Int { Int(try constrained(minimum, maximum)) }

    mutating func skip(_ width: Int) throws {
        guard remainingBits >= width else { throw IntersectionDecodeError("PER payload ended early") }
        bitOffset += width
    }
}

/// Port of MapSpatDecoder.kt: decodes ETSI MAPEM / SPATEM (ISO TS 19091 / DSRC, UPER).
/// Unsupported optional branches throw, matching the Android implementation.
enum MapSpatDecoder {
    static func decodeMap(_ packet: ItsPacketInfo, receivedAt: Date) throws -> [MapIntersection] {
        guard packet.protocolVersion == 2, packet.messageId == 5 else { return [] }
        var r = UperBitReader(packet.payload, byteOffset: 6)
        return try readMapData(&r, receivedAt)
    }

    static func decodeSpat(_ packet: ItsPacketInfo, receivedAt: Date) throws -> [SpatIntersection] {
        guard packet.protocolVersion == 2, packet.messageId == 4 else { return [] }
        var r = UperBitReader(packet.payload, byteOffset: 6)
        return try readSpat(&r, receivedAt)
    }

    // MARK: MAP

    private static func readMapData(_ r: inout UperBitReader, _ at: Date) throws -> [MapIntersection] {
        _ = try r.bit()                                        // extension additions come last; we stop earlier
        let hasTimeStamp = try r.bit(), hasLayerType = try r.bit(), hasLayerId = try r.bit()
        let hasIntersections = try r.bit(), hasRoadSegments = try r.bit(), hasDataParameters = try r.bit()
        let hasRestrictionList = try r.bit(), hasRegional = try r.bit()
        _ = hasRoadSegments; _ = hasDataParameters; _ = hasRestrictionList; _ = hasRegional
        if hasTimeStamp { _ = try r.constrained(0, 527_040) }
        _ = try r.constrained(0, 127) // msgIssueRevision
        if hasLayerType { _ = try r.enumerated(rootCount: 8, extensible: true) }
        if hasLayerId { _ = try r.constrained(0, 100) }
        var result: [MapIntersection] = []
        if hasIntersections {
            for _ in 0..<(try r.int(1, 32)) { result.append(try intersectionGeometry(&r, at)) }
        }
        // roadSegments, dataParameters, restrictionList and regional data follow the intersections;
        // nothing in them is displayed, so decoding stops here.
        return result
    }

    private enum NodeListResult {
        case nodes([LaneNode])
        case computed(referenceLaneId: Int, offsetX: Int, offsetY: Int)
    }

    private static func intersectionGeometry(_ r: inout UperBitReader, _ at: Date) throws -> MapIntersection {
        let ext = try r.bit()
        let hasName = try r.bit(), hasLaneWidth = try r.bit(), hasSpeedLimits = try r.bit()
        let hasPreempt = try r.bit(), hasRegional = try r.bit()
        let name = hasName ? try ia5String(&r, 1, 63) : nil
        let key = try intersectionReferenceId(&r)
        let revision = try r.int(0, 127)
        let ref = try position3D(&r)
        let laneWidth = hasLaneWidth ? try r.int(0, 32767) : nil
        if hasSpeedLimits { for _ in 0..<(try r.int(1, 9)) { try regulatorySpeedLimit(&r) } }
        var parsed: [(lane: MapLane, geometry: NodeListResult)] = []
        for _ in 0..<(try r.int(1, 255)) { parsed.append(try genericLane(&r)) }
        if hasPreempt {                                        // PreemptPriorityList of SignalControlZone
            for _ in 0..<(try r.int(1, 32)) {
                let zoneExt = try r.bit()
                _ = try r.constrained(0, 255); try r.skipOpenType()
                if zoneExt { try r.skipSequenceExtensions() }
            }
        }
        if hasRegional { try r.skipRegionalExtensions() }
        if ext { try r.skipSequenceExtensions() }

        // Resolve computed lanes against their reference lane (offset only; rotation/scale ignored).
        var byId: [Int: [LaneNode]] = [:]
        for p in parsed { if case .nodes(let n) = p.geometry { byId[p.lane.id] = n } }
        let lanes: [MapLane] = parsed.compactMap { p in
            switch p.geometry {
            case .nodes: return p.lane
            case .computed(let refId, let dx, let dy):
                guard let refNodes = byId[refId] else { return nil }
                let l = p.lane
                return MapLane(id: l.id, ingressApproach: l.ingressApproach, egressApproach: l.egressApproach,
                               laneType: l.laneType, ingress: l.ingress, egress: l.egress,
                               nodes: refNodes.map { LaneNode(xCm: $0.xCm + dx, yCm: $0.yCm + dy, stopLine: $0.stopLine) },
                               connections: l.connections)
            }
        }
        return MapIntersection(key: key, name: name, revision: revision, latitudeE7: ref.lat, longitudeE7: ref.lon,
                               laneWidthCm: laneWidth, lanes: lanes, receivedAt: at)
    }

    private static func genericLane(_ r: inout UperBitReader) throws -> (lane: MapLane, geometry: NodeListResult) {
        let ext = try r.bit()
        let hasName = try r.bit(), hasIngress = try r.bit(), hasEgress = try r.bit(), hasManeuvers = try r.bit()
        let hasConnectsTo = try r.bit(), hasOverlays = try r.bit(), hasRegional = try r.bit()
        let laneId = try r.int(0, 255)
        if hasName { _ = try ia5String(&r, 1, 63) }
        let ingressApproach = hasIngress ? try r.int(0, 15) : nil
        let egressApproach = hasEgress ? try r.int(0, 15) : nil
        let attrs = try laneAttributes(&r)
        if hasManeuvers { try r.skip(12) }
        let geometry = try nodeList(&r)
        var connections: [LaneConnection] = []
        if hasConnectsTo { for _ in 0..<(try r.int(1, 16)) { connections.append(try connection(&r)) } }
        if hasOverlays { for _ in 0..<(try r.int(1, 5)) { _ = try r.constrained(0, 255) } }
        if hasRegional { try r.skipRegionalExtensions() }
        if ext { try r.skipSequenceExtensions() }
        var nodes: [LaneNode] = []
        if case .nodes(let n) = geometry { nodes = n }
        let lane = MapLane(id: laneId, ingressApproach: ingressApproach, egressApproach: egressApproach,
                           laneType: attrs.type, ingress: attrs.ingress, egress: attrs.egress,
                           nodes: nodes, connections: connections)
        return (lane, geometry)
    }

    private static func laneAttributes(_ r: inout UperBitReader) throws -> (type: LaneType, ingress: Bool, egress: Bool) {
        let hasRegional = try r.bit()
        let ingress = try r.bit(), egress = try r.bit()
        try r.skip(10)                                         // sharedWith
        let typeIndex = try r.choice(rootCount: 8, extensible: true)
        switch typeIndex {
        case 0:                                                // LaneAttributes-Vehicle: BIT STRING (SIZE(8, ...))
            if try r.bit() { try r.skip(try r.lengthDeterminant()) } else { try r.skip(8) }
        case .some: try r.skip(16)
        case nil: break                                        // extension alternative, already skipped
        }
        if hasRegional { try r.skipRegionalExtensions() }
        let types: [LaneType] = [.vehicle, .crosswalk, .bike, .sidewalk, .median, .striping, .trackedVehicle, .parking]
        return (typeIndex.map { $0 < types.count ? types[$0] : .other } ?? .other, ingress, egress)
    }

    private static func nodeList(_ r: inout UperBitReader) throws -> NodeListResult {
        switch try r.choice(rootCount: 2, extensible: true) {
        case 0:
            var x = 0, y = 0
            var nodes: [LaneNode] = []
            for _ in 0..<(try r.int(2, 63)) {
                var node = try nodeXY(&r)
                x += node.xCm; y += node.yCm
                node.xCm = x; node.yCm = y
                nodes.append(node)
            }
            return .nodes(nodes)
        case 1:                                                // ComputedLane
            let ext = try r.bit()
            let hasRotate = try r.bit(), hasScaleX = try r.bit(), hasScaleY = try r.bit(), hasRegional = try r.bit()
            let refId = try r.int(0, 255)
            func offset() throws -> Int {
                try r.choice(rootCount: 2, extensible: false) == 0 ? try r.int(-2047, 2047) : try r.int(-32767, 32767)
            }
            let dx = try offset(), dy = try offset()
            if hasRotate { _ = try r.constrained(0, 28800) }
            if hasScaleX { _ = try r.constrained(-2048, 2047) }
            if hasScaleY { _ = try r.constrained(-2048, 2047) }
            if hasRegional { try r.skipRegionalExtensions() }
            if ext { try r.skipSequenceExtensions() }
            return .computed(referenceLaneId: refId, offsetX: dx, offsetY: dy)
        default:
            return .nodes([])
        }
    }

    private static func nodeXY(_ r: inout UperBitReader) throws -> LaneNode {
        let ext = try r.bit()
        let hasAttributes = try r.bit()
        let delta = try nodeOffsetPoint(&r)
        var node = LaneNode(xCm: delta.0, yCm: delta.1)
        if hasAttributes {
            let a = try nodeAttributeSetXY(&r)
            node.stopLine = a.stopLine
            node.widthDeltaCm = a.width
        }
        if ext { try r.skipSequenceExtensions() }
        return node
    }

    private static func nodeAttributeSetXY(_ r: inout UperBitReader) throws -> (stopLine: Bool, width: Int?) {
        let ext = try r.bit()
        let hasLocal = try r.bit(), hasDisabled = try r.bit(), hasEnabled = try r.bit(), hasData = try r.bit()
        let hasWidth = try r.bit(), hasElevation = try r.bit(), hasRegional = try r.bit()
        var stopLine = false
        if hasLocal { for _ in 0..<(try r.int(1, 8)) { if try r.enumerated(rootCount: 12, extensible: true) == 1 { stopLine = true } } }
        if hasDisabled { for _ in 0..<(try r.int(1, 8)) { _ = try r.enumerated(rootCount: 40, extensible: true) } }
        if hasEnabled { for _ in 0..<(try r.int(1, 8)) { _ = try r.enumerated(rootCount: 40, extensible: true) } }
        if hasData { for _ in 0..<(try r.int(1, 8)) { try laneDataAttribute(&r) } }
        let width = hasWidth ? try r.int(-512, 511) : nil
        if hasElevation { _ = try r.constrained(-512, 511) }
        if hasRegional { try r.skipRegionalExtensions() }
        if ext { try r.skipSequenceExtensions() }
        return (stopLine, width)
    }

    private static func laneDataAttribute(_ r: inout UperBitReader) throws {
        switch try r.choice(rootCount: 7, extensible: true) {
        case 0: _ = try r.constrained(-150, 150)
        case 1, 2, 3: _ = try r.constrained(-128, 127)
        case 4: _ = try r.constrained(-180, 180)
        case 5: for _ in 0..<(try r.int(1, 9)) { try regulatorySpeedLimit(&r) }
        case 6: try r.skipRegionalExtensions()
        default: break                                         // extension alternative, already skipped
        }
    }

    private static func nodeOffsetPoint(_ r: inout UperBitReader) throws -> (Int, Int) {
        func pair(_ lo: Int64, _ hi: Int64) throws -> (Int, Int) { (try r.int(lo, hi), try r.int(lo, hi)) }
        switch try r.choice(rootCount: 8, extensible: false) {
        case 0: return try pair(-512, 511)
        case 1: return try pair(-1024, 1023)
        case 2: return try pair(-2048, 2047)
        case 3: return try pair(-4096, 4095)
        case 4: return try pair(-8192, 8191)
        case 5: return try pair(-32768, 32767)
        case 6:
            _ = try r.constrained(-1_800_000_000, 1_800_000_001)
            _ = try r.constrained(-900_000_000, 900_000_001)
            return (0, 0)
        default:                                               // regional
            _ = try r.constrained(0, 255); try r.skipOpenType()
            return (0, 0)
        }
    }

    private static func connection(_ r: inout UperBitReader) throws -> LaneConnection {
        let hasRemote = try r.bit(), hasSignalGroup = try r.bit(), hasUserClass = try r.bit()
        let hasConnectionId = try r.bit(), hasManeuver = try r.bit()
        let lane = try r.int(0, 255)
        if hasManeuver { try r.skip(12) }
        let remote = hasRemote ? try intersectionReferenceId(&r) : nil
        let signalGroup = hasSignalGroup ? try r.int(0, 255) : nil
        if hasUserClass { _ = try r.constrained(0, 255) }
        let connectionId = hasConnectionId ? try r.int(0, 255) : nil
        return LaneConnection(laneId: lane, signalGroup: signalGroup, connectionId: connectionId, remoteIntersection: remote)
    }

    // MARK: SPAT

    private static func readSpat(_ r: inout UperBitReader, _ at: Date) throws -> [SpatIntersection] {
        let ext = try r.bit()
        let hasTimeStamp = try r.bit(), hasName = try r.bit(), hasRegional = try r.bit()
        if hasTimeStamp { _ = try r.constrained(0, 527_040) }
        if hasName { _ = try ia5String(&r, 1, 63) }
        var result: [SpatIntersection] = []
        for _ in 0..<(try r.int(1, 32)) { result.append(try intersectionState(&r, at)) }
        if hasRegional { try r.skipRegionalExtensions() }
        if ext { try r.skipSequenceExtensions() }
        return result
    }

    private static func intersectionState(_ r: inout UperBitReader, _ at: Date) throws -> SpatIntersection {
        let ext = try r.bit()
        let hasName = try r.bit(), hasMoy = try r.bit(), hasTimestamp = try r.bit()
        let hasEnabledLanes = try r.bit(), hasManeuverAssist = try r.bit(), hasRegional = try r.bit()
        if hasName { _ = try ia5String(&r, 1, 63) }
        let key = try intersectionReferenceId(&r)
        let revision = try r.int(0, 127)
        try r.skip(16) // IntersectionStatusObject
        let moy = hasMoy ? try r.int(0, 527_040) : nil
        let timestamp = hasTimestamp ? try r.int(0, 65535) : nil
        if hasEnabledLanes { for _ in 0..<(try r.int(1, 16)) { _ = try r.constrained(0, 255) } }
        var movements: [SignalMovement] = []
        for _ in 0..<(try r.int(1, 255)) { movements.append(try movementState(&r)) }
        if hasManeuverAssist { for _ in 0..<(try r.int(1, 16)) { _ = try connectionManeuverAssist(&r) } }
        if hasRegional { try r.skipRegionalExtensions() }
        if ext { try r.skipSequenceExtensions() }
        return SpatIntersection(key: key, revision: revision, moy: moy, timestampMs: timestamp,
                                movements: movements, receivedAt: at)
    }

    private static func movementState(_ r: inout UperBitReader) throws -> SignalMovement {
        let ext = try r.bit()
        let hasName = try r.bit(), hasManeuverAssist = try r.bit(), hasRegional = try r.bit()
        if hasName { _ = try ia5String(&r, 1, 63) }
        let signalGroup = try r.int(0, 255)
        var events: [SignalEvent] = []
        for _ in 0..<(try r.int(1, 16)) { events.append(try movementEvent(&r)) }
        var ids: [Int] = []
        if hasManeuverAssist { for _ in 0..<(try r.int(1, 16)) { ids.append(try connectionManeuverAssist(&r)) } }
        if hasRegional { try r.skipRegionalExtensions() }
        if ext { try r.skipSequenceExtensions() }
        return SignalMovement(signalGroup: signalGroup, events: events, connectionIds: ids)
    }

    private static func movementEvent(_ r: inout UperBitReader) throws -> SignalEvent {
        let ext = try r.bit()
        let hasTiming = try r.bit(), hasSpeeds = try r.bit(), hasRegional = try r.bit()
        let state = MovementPhaseState(rawValue: Int(try r.bits(4))) ?? .unknown // 10 root values
        var minEnd: Int?, likely: Int?, maxEnd: Int?, confidence: Int?, advisory: Int?
        if hasTiming {
            let hasStart = try r.bit(), hasMax = try r.bit(), hasLikely = try r.bit()
            let hasConfidence = try r.bit(), hasNext = try r.bit()
            if hasStart { _ = try r.constrained(0, 36001) }
            minEnd = try r.int(0, 36001)
            if hasMax { maxEnd = try r.int(0, 36001) }
            if hasLikely { likely = try r.int(0, 36001) }
            if hasConfidence { confidence = try r.int(0, 15) }
            if hasNext { _ = try r.constrained(0, 36001) }
        }
        if hasSpeeds {                                         // AdvisorySpeedList
            for _ in 0..<(try r.int(1, 16)) {
                let aExt = try r.bit()
                let hasSpeed = try r.bit(), hasConf = try r.bit(), hasDist = try r.bit()
                let hasClass = try r.bit(), hasReg = try r.bit()
                let type = try r.enumerated(rootCount: 4, extensible: true)
                if hasSpeed {
                    let v = try r.int(0, 500)                  // 0.1 m/s, 500 = unavailable
                    if v < 500, type == 1 || type == 2 || advisory == nil { advisory = Int((Double(v) * 0.36).rounded()) }
                }
                if hasConf { _ = try r.bits(3) }
                if hasDist { _ = try r.constrained(0, 10000) }
                if hasClass { _ = try r.constrained(0, 255) }
                if hasReg { try r.skipRegionalExtensions() }
                if aExt { try r.skipSequenceExtensions() }
            }
        }
        if hasRegional { try r.skipRegionalExtensions() }
        if ext { try r.skipSequenceExtensions() }
        return SignalEvent(state: state, minEndTime: minEnd, likelyTime: likely, maxEndTime: maxEnd,
                           confidence: confidence, advisorySpeedKmh: advisory)
    }

    private static func connectionManeuverAssist(_ r: inout UperBitReader) throws -> Int {
        let ext = try r.bit()
        let hasQueue = try r.bit(), hasStorage = try r.bit(), hasWait = try r.bit()
        let hasPed = try r.bit(), hasRegional = try r.bit()
        let id = try r.int(0, 255)
        if hasQueue { _ = try r.constrained(0, 10000) }
        if hasStorage { _ = try r.constrained(0, 10000) }
        if hasWait { _ = try r.bit() }
        if hasPed { _ = try r.bit() }
        if hasRegional { try r.skipRegionalExtensions() }
        if ext { try r.skipSequenceExtensions() }
        return id
    }

    // MARK: Common

    private static func intersectionReferenceId(_ r: inout UperBitReader) throws -> IntersectionKey {
        let hasRegion = try r.bit()
        let region = hasRegion ? try r.int(0, 65535) : nil
        return IntersectionKey(region: region, id: try r.int(0, 65535))
    }

    private static func position3D(_ r: inout UperBitReader) throws -> (lat: Int, lon: Int) {
        let ext = try r.bit()
        let hasElevation = try r.bit(), hasRegional = try r.bit()
        let lat = try r.int(-900_000_000, 900_000_001)
        let lon = try r.int(-1_800_000_000, 1_800_000_001)
        if hasElevation { _ = try r.constrained(-4096, 61439) }
        if hasRegional { try r.skipRegionalExtensions() }
        if ext { try r.skipSequenceExtensions() }
        return (lat, lon)
    }

    private static func regulatorySpeedLimit(_ r: inout UperBitReader) throws {
        _ = try r.enumerated(rootCount: 13, extensible: true)
        _ = try r.constrained(0, 8191)
    }

    private static func ia5String(_ r: inout UperBitReader, _ minimum: Int64, _ maximum: Int64) throws -> String {
        let length = try r.int(minimum, maximum)
        var scalars = String.UnicodeScalarView()
        for _ in 0..<length { scalars.append(UnicodeScalar(UInt8(try r.bits(7)))) }
        return String(scalars)
    }
}

/// Keeps the latest MAP geometry and SPAT state per intersection (runs on the pipeline queue).
struct IntersectionStore {
    private(set) var maps: [IntersectionKey: MapIntersection] = [:]
    private(set) var spats: [IntersectionKey: SpatIntersection] = [:]
    private var firstSeen: [IntersectionKey: Date] = [:]
    private(set) var diagnostics = IntersectionDiagnostics()

    /// Returns true when an intersection changed.
    mutating func accept(_ its: ItsPacketInfo, receivedAt: Date) -> Bool {
        if its.destinationPort == 2003 && its.messageId == 5 {
            diagnostics.mapemSeen += 1
            do {
                let decoded = try MapSpatDecoder.decodeMap(its, receivedAt: receivedAt)
                for m in decoded {
                    if firstSeen[m.key] == nil { firstSeen[m.key] = receivedAt }
                    maps[m.key] = merge(maps[m.key], m)
                }
                diagnostics.mapemDecoded += 1
                return !decoded.isEmpty
            } catch {
                diagnostics.mapemFailures += 1
                diagnostics.lastDecodeError = "MAPEM: \(error)"
            }
        } else if its.destinationPort == 2004 && its.messageId == 4 {
            diagnostics.spatemSeen += 1
            do {
                let decoded = try MapSpatDecoder.decodeSpat(its, receivedAt: receivedAt)
                for s in decoded {
                    if firstSeen[s.key] == nil { firstSeen[s.key] = receivedAt }
                    if let existing = spats[s.key], !s.isAtLeastAsRecent(as: existing) { continue }
                    spats[s.key] = s
                }
                diagnostics.spatemDecoded += 1
                return !decoded.isEmpty
            } catch {
                diagnostics.spatemFailures += 1
                diagnostics.lastDecodeError = "SPATEM: \(error)"
            }
        }
        return false
    }

    mutating func inject(_ spat: SpatIntersection) {
        if firstSeen[spat.key] == nil { firstSeen[spat.key] = spat.receivedAt }
        spats[spat.key] = spat
    }

    /// Snapshots updated within `maxAge`, oldest first; stale ones are dropped.
    mutating func activeSnapshots(now: Date, maxAge: TimeInterval) -> [IntersectionSnapshot] {
        let keys = Set(maps.keys).union(spats.keys)
        var result: [IntersectionSnapshot] = []
        for key in keys {
            let updated = max(maps[key]?.receivedAt ?? .distantPast, spats[key]?.receivedAt ?? .distantPast)
            if now.timeIntervalSince(updated) > maxAge {
                maps[key] = nil; spats[key] = nil; firstSeen[key] = nil
                continue
            }
            result.append(IntersectionSnapshot(key: key, map: maps[key], spat: spats[key], firstReceivedAt: firstSeen[key] ?? updated))
        }
        return result.sorted { $0.firstReceivedAt < $1.firstReceivedAt }
    }

    private func merge(_ existing: MapIntersection?, _ incoming: MapIntersection) -> MapIntersection {
        guard let existing, existing.revision == incoming.revision else { return incoming }
        var byId: [Int: MapLane] = [:]
        var order: [Int] = []
        for lane in existing.lanes + incoming.lanes {
            if byId[lane.id] == nil { order.append(lane.id) }
            byId[lane.id] = lane
        }
        var merged = incoming
        merged.name = incoming.name ?? existing.name
        merged.laneWidthCm = incoming.laneWidthCm ?? existing.laneWidthCm
        merged.lanes = order.compactMap { byId[$0] }
        merged.receivedAt = max(existing.receivedAt, incoming.receivedAt)
        return merged
    }
}
