import Foundation

/// ETSI TS 102 894-2 StationType.
enum StationType: Int, Sendable {
    case unknown = 0, pedestrian, cyclist, moped, motorcycle, passengerCar, bus, lightTruck, heavyTruck, trailer,
         specialVehicle, tram, roadSideUnit = 15

    init(code: Int) { self = StationType(rawValue: code) ?? .unknown }

    var label: String {
        switch self {
        case .unknown: "Unbekannt"
        case .pedestrian: "Fußgänger"
        case .cyclist: "Radfahrer"
        case .moped: "Moped"
        case .motorcycle: "Motorrad"
        case .passengerCar: "Pkw"
        case .bus: "Bus"
        case .lightTruck: "Leichter Lkw"
        case .heavyTruck: "Schwerer Lkw"
        case .trailer: "Anhänger"
        case .specialVehicle: "Sonderfahrzeug"
        case .tram: "Straßenbahn"
        case .roadSideUnit: "Straßenstation"
        }
    }

    var symbol: String {
        switch self {
        case .pedestrian: "figure.walk"
        case .cyclist: "bicycle"
        case .moped, .motorcycle: "scooter"
        case .bus: "bus.fill"
        case .lightTruck, .heavyTruck, .trailer: "truck.box.fill"
        case .tram: "tram.fill"
        case .roadSideUnit: "antenna.radiowaves.left.and.right"
        case .specialVehicle: "car.side.fill"
        default: "car.fill"
        }
    }
}

/// ETSI TS 102 894-2 VehicleRole.
enum VehicleRole: Int, Sendable {
    case `default` = 0, publicTransport, specialTransport, dangerousGoods, roadWork, rescue, emergency, safetyCar,
         agriculture, commercial, military, roadOperator, taxi

    var label: String {
        switch self {
        case .default: "Standard"
        case .publicTransport: "ÖPNV"
        case .specialTransport: "Sondertransport"
        case .dangerousGoods: "Gefahrgut"
        case .roadWork: "Straßenbau"
        case .rescue: "Rettung/Bergung"
        case .emergency: "Einsatzfahrzeug"
        case .safetyCar: "Sicherungsfahrzeug"
        case .agriculture: "Landwirtschaft"
        case .commercial: "Gewerblich"
        case .military: "Militär"
        case .roadOperator: "Straßenbetreiber"
        case .taxi: "Taxi"
        }
    }
}

struct CamInfo: Sendable {
    var stationType: StationType
    var latitude: Double?
    var longitude: Double?
    var headingDegrees: Double?     // nil = unavailable
    var speedKmh: Double?           // nil = unavailable
    var vehicleLengthM: Double?
    var vehicleWidthM: Double?
    var vehicleRole: VehicleRole?
    var lightBarActive = false
    var sirenActive = false
    var exteriorLights: [String] = []

    var isEmergency: Bool { lightBarActive || sirenActive || vehicleRole == .emergency }

    var summary: String {
        var parts = [vehicleRole.map { $0 == .default ? stationType.label : $0.label } ?? stationType.label]
        if let s = speedKmh { parts.append("\(Int(s.rounded())) km/h") }
        if lightBarActive || sirenActive { parts.append(sirenActive ? "Blaulicht + Horn" : "Blaulicht") }
        return parts.joined(separator: ", ")
    }
}

struct DenmInfo: Sendable {
    var originatingStationId: UInt32
    var sequenceNumber: Int
    var detectionTime: Date
    var referenceTime: Date
    var terminated: Bool
    var latitude: Double?
    var longitude: Double?
    var validitySeconds: Int
    var stationType: StationType
    var causeCode: Int?
    var subCauseCode: Int?
    var informationQuality: Int?

    var causeLabel: String { DenmCause.label(cause: causeCode) }
    var subCauseLabel: String? { DenmCause.subLabel(cause: causeCode, sub: subCauseCode) }
    var summary: String {
        var s = terminated ? "Aufgehoben: \(causeLabel)" : causeLabel
        if let sub = subCauseLabel { s += " – \(sub)" }
        return s
    }
    var expires: Date { referenceTime.addingTimeInterval(TimeInterval(validitySeconds)) }
}

/// Decodes CAM and DENM (protocol versions 1 and 2, EN 302 637-2 / -3).
enum CamDenmDecoder {
    /// ITS epoch: 2004-01-01T00:00:00Z. TimestampIts counts milliseconds since then (TAI, leap seconds ignored).
    static let itsEpoch = Date(timeIntervalSince1970: 1_072_915_200)

    static func decodeCam(_ its: ItsPacketInfo) throws -> CamInfo {
        guard its.messageId == 2, (1...2).contains(its.protocolVersion) else { throw IntersectionDecodeError("Kein CAM") }
        var r = UperBitReader(its.payload, byteOffset: 6)
        _ = try r.bits(16)                                     // generationDeltaTime
        let camExt = try r.bit(), hasLow = try r.bit(), hasSpecial = try r.bit()

        // BasicContainer
        let basicExt = try r.bit()
        var cam = CamInfo(stationType: StationType(code: Int(try r.bits(8))))
        let pos = try referencePosition(&r)
        cam.latitude = pos.lat; cam.longitude = pos.lon
        if basicExt { try r.skipSequenceExtensions() }

        // HighFrequencyContainer
        guard let hf = try r.choice(rootCount: 2, extensible: true) else {
            return cam                                         // unknown extension alternative: basics only
        }
        if hf == 0 {
            let opt = try (0..<7).map { _ in try r.bit() }
            let heading = try r.int(0, 3601); _ = try r.bits(7)
            if heading < 3601 { cam.headingDegrees = Double(heading) / 10 }
            let speed = try r.int(0, 16383); _ = try r.bits(7)
            if speed < 16383 { cam.speedKmh = Double(speed) / 100 * 3.6 }
            _ = try r.bits(2)                                  // driveDirection
            let length = try r.int(1, 1023); _ = try r.bits(3)
            if length < 1023 { cam.vehicleLengthM = Double(length) / 10 }
            let width = try r.int(1, 62)
            if width < 62 { cam.vehicleWidthM = Double(width) / 10 }
            _ = try r.bits(9); _ = try r.bits(7)               // longitudinalAcceleration
            _ = try r.bits(11); _ = try r.bits(3)              // curvature
            _ = try r.enumerated(rootCount: 3, extensible: true) // curvatureCalculationMode
            _ = try r.bits(16); _ = try r.bits(4)              // yawRate (value, confidence)
            if opt[0] { _ = try r.bits(7) }                    // accelerationControl
            if opt[1] { _ = try r.bits(4) }                    // lanePosition
            if opt[2] { _ = try r.bits(10); _ = try r.bits(7) } // steeringWheelAngle
            if opt[3] { _ = try r.bits(9); _ = try r.bits(7) }  // lateralAcceleration
            if opt[4] { _ = try r.bits(9); _ = try r.bits(7) }  // verticalAcceleration
            if opt[5] { _ = try r.bits(3) }                    // performanceClass
            if opt[6] {                                        // cenDsrcTollingZone
                let ext = try r.bit(), hasId = try r.bit()
                _ = try r.bits(31); _ = try r.bits(32)
                if hasId { _ = try r.bits(27) }
                if ext { try r.skipSequenceExtensions() }
            }
        } else {
            cam.stationType = cam.stationType == .unknown ? .roadSideUnit : cam.stationType
            return cam                                         // RSU container: nothing more we display
        }

        // LowFrequencyContainer
        if hasLow {
            guard try r.choice(rootCount: 1, extensible: true) != nil else { return cam }
            cam.vehicleRole = VehicleRole(rawValue: Int(try r.bits(4)))
            let lights = try r.bits(8)
            let names = ["Abblendlicht", "Fernlicht", "Blinker links", "Blinker rechts", "Tagfahrlicht", "Rückfahrlicht", "Nebelscheinwerfer", "Standlicht"]
            cam.exteriorLights = names.enumerated().filter { lights & (1 << (7 - $0.offset)) != 0 }.map(\.element)
            for _ in 0..<(try r.int(0, 40)) {                  // pathHistory
                let hasDelta = try r.bit()
                _ = try r.bits(18); _ = try r.bits(18); _ = try r.bits(15)
                if hasDelta { _ = try r.bits(16) }
            }
        }

        // SpecialVehicleContainer: light bar / siren for the roles that carry it
        if hasSpecial, let kind = try r.choice(rootCount: 7, extensible: true) {
            var lightBits: Int64?
            switch kind {
            case 3:                                            // roadWorks
                let hasSub = try r.bit()
                _ = try r.bit()                                // closedLanes present
                if hasSub { _ = try r.bits(8) }
                lightBits = try r.bits(2)
            case 4:                                            // rescue
                lightBits = try r.bits(2)
            case 5:                                            // emergency
                _ = try r.bit(); _ = try r.bit()               // optional flags
                lightBits = try r.bits(2)
            case 6:                                            // safetyCar
                _ = try r.bits(3)                              // optional flags
                lightBits = try r.bits(2)
            default: break
            }
            if let b = lightBits {
                cam.lightBarActive = b & 0b10 != 0
                cam.sirenActive = b & 0b01 != 0
            }
        }
        _ = camExt
        return cam
    }

    static func decodeDenm(_ its: ItsPacketInfo) throws -> DenmInfo {
        guard its.messageId == 1, (1...2).contains(its.protocolVersion) else { throw IntersectionDecodeError("Keine DENM") }
        var r = UperBitReader(its.payload, byteOffset: 6)
        let hasSituation = try r.bit()
        _ = try r.bit(); _ = try r.bit()                       // location, alacarte (not displayed)

        // ManagementContainer
        let mgmtExt = try r.bit()
        let hasTermination = try r.bit(), hasRelDist = try r.bit(), hasRelDir = try r.bit()
        let hasValidity = try r.bit(), hasInterval = try r.bit()
        let origin = UInt32(try r.bits(32))
        let seq = try r.int(0, 65535)
        let detection = try r.bits(42), reference = try r.bits(42)
        var terminated = false
        if hasTermination { _ = try r.bits(1); terminated = true }
        let pos = try referencePosition(&r)
        if hasRelDist { _ = try r.bits(3) }
        if hasRelDir { _ = try r.bits(2) }
        let validity = hasValidity ? try r.int(0, 86400) : 600
        if hasInterval { _ = try r.bits(14) }
        let station = StationType(code: Int(try r.bits(8)))
        if mgmtExt { try r.skipSequenceExtensions() }

        var denm = DenmInfo(
            originatingStationId: origin, sequenceNumber: seq,
            detectionTime: itsEpoch.addingTimeInterval(Double(detection) / 1000),
            referenceTime: itsEpoch.addingTimeInterval(Double(reference) / 1000),
            terminated: terminated, latitude: pos.lat, longitude: pos.lon,
            validitySeconds: validity, stationType: station)

        if hasSituation {
            _ = try r.bit(); _ = try r.bit(); _ = try r.bit() // ext, linkedCause, eventHistory
            denm.informationQuality = Int(try r.bits(3))
            let ccExt = try r.bit()
            denm.causeCode = Int(try r.bits(8))
            denm.subCauseCode = Int(try r.bits(8))
            _ = ccExt
        }
        return denm
    }

    private static func referencePosition(_ r: inout UperBitReader) throws -> (lat: Double?, lon: Double?) {
        let lat = try r.int(-900_000_000, 900_000_001)
        let lon = try r.int(-1_800_000_000, 1_800_000_001)
        _ = try r.bits(12); _ = try r.bits(12); _ = try r.bits(12) // PositionConfidenceEllipse
        _ = try r.bits(20); _ = try r.bits(4)                       // Altitude
        let valid = lat != 900_000_001 && lon != 1_800_000_001
        return valid ? (Double(lat) / 1e7, Double(lon) / 1e7) : (nil, nil)
    }
}

/// Cause and sub-cause codes (ETSI TS 102 894-2), German labels.
enum DenmCause {
    static func label(cause: Int?) -> String {
        guard let cause else { return "Warnung" }
        switch cause {
        case 1: return "Verkehrsstörung"
        case 2: return "Unfall"
        case 3: return "Baustelle"
        case 6: return "Glätte"
        case 9: return "Gefährlicher Straßenzustand"
        case 10: return "Hindernis auf der Fahrbahn"
        case 11: return "Tier auf der Fahrbahn"
        case 12: return "Personen auf der Fahrbahn"
        case 14: return "Falschfahrer"
        case 15: return "Rettungs- und Bergungsarbeiten"
        case 17: return "Extremwetter"
        case 18: return "Sichtbehinderung"
        case 19: return "Niederschlag"
        case 26: return "Langsames Fahrzeug"
        case 27: return "Stauende"
        case 91: return "Panne"
        case 92: return "Unfallfahrzeug"
        case 93: return "Notfall im Fahrzeug"
        case 94: return "Liegengebliebenes Fahrzeug"
        case 95: return "Einsatzfahrzeug nähert sich"
        case 96: return "Gefährliche Kurve"
        case 97: return "Kollisionsgefahr"
        case 98: return "Rotlichtverstoß"
        case 99: return "Gefahrensituation"
        default: return "Warnung (Code \(cause))"
        }
    }

    static func subLabel(cause: Int?, sub: Int?) -> String? {
        guard let cause, let sub, sub != 0 else { return nil }
        let table: [Int: [Int: String]] = [
            1: [1: "erhöhtes Verkehrsaufkommen", 2: "Stau wächst langsam", 3: "Stau wächst", 4: "Stau wächst stark",
                5: "stehender Verkehr", 6: "Stau nimmt leicht ab", 7: "Stau nimmt ab", 8: "Stau nimmt stark ab"],
            2: [1: "mehrere Fahrzeuge", 2: "schwerer Unfall", 3: "Lkw beteiligt", 4: "Bus beteiligt",
                5: "Gefahrgut beteiligt", 6: "auf Gegenfahrbahn", 7: "unsicher gesichert", 8: "Unfallstelle geräumt"],
            3: [1: "große Baustelle", 2: "Markierungsarbeiten", 3: "Wanderbaustelle", 4: "Tagesbaustelle",
                5: "Straßenreinigung", 6: "Winterdienst"],
            14: [1: "falsche Spur", 2: "falsche Richtung"],
            26: [1: "Wartungsfahrzeug", 2: "Fahrzeuge verlangsamen", 3: "Schneepflug", 4: "Streufahrzeug",
                 5: "Schwertransport", 6: "Landmaschine"],
            27: [1: "plötzliches Stauende", 2: "Stau hinter Kuppe", 3: "Stau hinter Kurve", 4: "Stau im Tunnel"],
            91: [1: "Kraftstoffmangel", 2: "leere Batterie", 3: "Motorproblem", 4: "Getriebeproblem",
                 5: "Motorkühlung", 6: "Bremsen", 7: "Lenkung", 8: "Reifenpanne"],
            94: [1: "Notfall im Fahrzeug", 2: "Panne", 3: "Unfallfahrzeug", 4: "Haltestelle",
                 5: "Gefahrgut"],
            95: [1: "Einsatzfahrzeug", 2: "bevorrechtigtes Fahrzeug"],
            97: [1: "Längsverkehr", 2: "Querverkehr", 3: "seitlich", 4: "gefährdete Verkehrsteilnehmer"],
        ]
        return table[cause]?[sub]
    }
}
