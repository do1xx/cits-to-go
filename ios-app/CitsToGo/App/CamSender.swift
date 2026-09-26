import CoreLocation
import Foundation
import Observation

/// Broadcasts the phone's own position as CAM through the ESP32-C5 (TX).
/// Off by default and never persisted as "on"; stops when the app leaves the foreground
/// or the receiver disconnects.
@MainActor
@Observable
final class CamSender {
    enum IdentityMode: String, CaseIterable, Identifiable {
        case fixed, rotating
        var id: String { rawValue }
        var label: String { self == .fixed ? "Fest" : "Wechselnd (alle 10 min)" }
    }

    static let selectableTypes: [StationType] = [.pedestrian, .cyclist, .moped, .motorcycle, .passengerCar, .bus,
                                                 .lightTruck, .heavyTruck, .specialVehicle, .tram]

    private(set) var active = false
    private(set) var identity: CamIdentity
    private(set) var sent = 0
    private(set) var confirmed = 0
    private(set) var failed = 0
    private(set) var lastError: String?
    private(set) var lastSentAt: Date?
    private(set) var waitingForGps = false

    var stationType: StationType { didSet { UserDefaults.standard.set(stationType.rawValue, forKey: "tx.stationType") } }
    var identityMode: IdentityMode {
        didSet {
            UserDefaults.standard.set(identityMode.rawValue, forKey: "tx.identityMode")
            identity = identityMode == .fixed ? Self.fixedIdentity() : .random()
        }
    }
    var intervalMs: Int { didSet { UserDefaults.standard.set(intervalMs, forKey: "tx.intervalMs") } }

    @ObservationIgnored private weak var model: BridgeModel?
    @ObservationIgnored private weak var location: LocationProvider?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastLocation: CLLocation?
    @ObservationIgnored private var identitySince = Date()
    @ObservationIgnored private var pending: Set<UInt32> = []

    init() {
        let d = UserDefaults.standard
        stationType = StationType(rawValue: d.integer(forKey: "tx.stationType")).flatMap { Self.selectableTypes.contains($0) ? $0 : nil } ?? .passengerCar
        identityMode = IdentityMode(rawValue: d.string(forKey: "tx.identityMode") ?? "") ?? .rotating
        intervalMs = d.object(forKey: "tx.intervalMs") as? Int ?? 1000
        identity = .random()
        if identityMode == .fixed { identity = Self.fixedIdentity() }
    }

    func attach(model: BridgeModel, location: LocationProvider) {
        self.model = model
        self.location = location
        model.onTxResults = { [weak self] in self?.handle($0) }
    }

    func start() {
        guard !active, let model, model.linkState.isStreaming else {
            lastError = "Empfänger nicht verbunden"
            return
        }
        active = true
        sent = 0; confirmed = 0; failed = 0; lastError = nil; lastLocation = nil
        if identityMode == .rotating { identity = .random(); identitySince = Date() }
        location?.start()
        model.record("CAM-Senden gestartet: \(stationType.label), Station \(identity.stationId), MAC \(identity.macString)")
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop(reason: String = "beendet") {
        guard active else { return }
        active = false
        timer?.invalidate(); timer = nil
        location?.stop()
        waitingForGps = false
        model?.record("CAM-Senden \(reason): \(sent) gesendet, \(confirmed) bestätigt, \(failed) Fehler")
    }

    /// New fixed station ID / MAC (only relevant in fixed mode).
    func renewFixedIdentity() {
        let id = CamIdentity.random()
        UserDefaults.standard.set(Int(id.stationId), forKey: "tx.fixed.stationId")
        UserDefaults.standard.set(id.mac, forKey: "tx.fixed.mac")
        if identityMode == .fixed { identity = id }
    }

    private static func fixedIdentity() -> CamIdentity {
        let d = UserDefaults.standard
        if let mac = d.array(forKey: "tx.fixed.mac") as? [UInt8], mac.count == 6, d.integer(forKey: "tx.fixed.stationId") > 0 {
            return CamIdentity(stationId: UInt32(d.integer(forKey: "tx.fixed.stationId")), mac: mac)
        }
        let id = CamIdentity.random()
        d.set(Int(id.stationId), forKey: "tx.fixed.stationId")
        d.set(id.mac, forKey: "tx.fixed.mac")
        return id
    }

    private func tick() {
        guard active, let model else { return }
        guard model.linkState.isStreaming else { stop(reason: "gestoppt (Empfänger getrennt)"); return }
        guard let loc = location?.location, Date().timeIntervalSince(loc.timestamp) < 5,
              loc.horizontalAccuracy >= 0, loc.horizontalAccuracy < 100 else {
            waitingForGps = true
            return
        }
        waitingForGps = false
        if identityMode == .rotating, Date().timeIntervalSince(identitySince) > 600 {
            identity = .random(); identitySince = Date()
            model.record("CAM-Kennung gewechselt: Station \(identity.stationId)")
        }
        guard due(now: Date(), location: loc) else { return }
        let frame = CamEncoder.camFrame(identity: identity, stationType: stationType, position: CamPosition(location: loc), now: Date())
        pending.insert(model.transmit(frame))
        if pending.count > 50 { pending.removeFirst() }
        sent += 1
        lastSentAt = Date()
        lastLocation = loc
    }

    /// ETSI EN 302 637-2 generation rules: at the configured interval, sooner (≥ 100 ms) on
    /// 4 m movement, 4° heading or 0.5 m/s speed change.
    private func due(now: Date, location l: CLLocation) -> Bool {
        guard let last = lastSentAt, let prev = lastLocation else { return true }
        let elapsed = now.timeIntervalSince(last) * 1000
        if elapsed >= Double(intervalMs) { return true }
        if elapsed < 100 { return false }
        if l.distance(from: prev) > 4 { return true }
        if l.speed >= 0, prev.speed >= 0, abs(l.speed - prev.speed) > 0.5 { return true }
        if l.course >= 0, prev.course >= 0 {
            let d = abs(l.course - prev.course).truncatingRemainder(dividingBy: 360)
            if min(d, 360 - d) > 4 { return true }
        }
        return false
    }

    private func handle(_ results: [(requestId: UInt32, status: UInt32)]) {
        for r in results where pending.remove(r.requestId) != nil || active {
            if r.status == 0 { confirmed += 1 } else {
                failed += 1
                lastError = switch Int32(bitPattern: r.status) {
                case 0x101: "Firmware: kein Speicher frei"
                case 0x104: "Firmware: ungültige Größe"
                case 0x109: "Firmware: Prüfsummenfehler"
                default: "Firmware-Fehler 0x\(String(r.status, radix: 16))"
                }
            }
        }
    }
}
