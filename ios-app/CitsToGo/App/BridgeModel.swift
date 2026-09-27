import CoreLocation
import Foundation
import Observation

struct LogEntry: Identifiable {
    let id = UUID()
    let date: Date
    let message: String
}

struct StationSummary: Identifiable {
    let id: UInt32
    var lastSeen: Date
    var count: Int
    var lastType: String
    var types: Set<String>
    var rssi: Int
    var coordinate: CLLocationCoordinate2D?
    var secured: Bool
    var stationType: StationType? = nil
    var speedKmh: Double? = nil
    var headingDegrees: Double? = nil
    var emergency = false
    var summary: String? = nil
    var lastCam: CamInfo? = nil
    var lastDenm: DenmInfo? = nil
    var node: String? = nil          // which receiver heard it last (live/replay: this phone)
}

/// An active DENM warning, keyed by its action ID (originating station + sequence number).
struct WarningSummary: Identifiable {
    var id: String { "\(denm.originatingStationId)-\(denm.sequenceNumber)" }
    var denm: DenmInfo
    var lastSeen: Date
    var count: Int
    var coordinate: CLLocationCoordinate2D? {
        guard let lat = denm.latitude, let lon = denm.longitude else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}

@MainActor
@Observable
final class BridgeModel {
    static let defaultMqttUri = "mqtts://cits1.opentrafficmap.org"
    static let maxRecentPackets = 500

    // Live state
    private(set) var linkState: BleLinkState = .idle
    private(set) var mqttState: MqttClient.State = .disabled
    private(set) var recent: [PacketRecord] = []
    private(set) var stations: [UInt32: StationSummary] = [:]
    private(set) var warnings: [String: WarningSummary] = [:]
    private(set) var countsByType: [String: Int] = [:]
    private(set) var totalPackets = 0
    private(set) var packetsPerSecond = 0.0
    private(set) var missingSequences: UInt64 = 0
    private(set) var protocolErrors = 0
    private(set) var lastError: String?
    private(set) var firmware: FirmwareStatistics?
    private(set) var mqttCounters: (published: UInt64, dropped: UInt64, spooled: Int) = (0, 0, 0)
    private(set) var communityState: MqttClient.State = .disabled
    private(set) var communityCounters: (published: UInt64, dropped: UInt64, spooled: Int) = (0, 0, 0)
    private(set) var customState: MqttClient.State = .disabled
    private(set) var customCounters: (published: UInt64, dropped: UInt64, spooled: Int) = (0, 0, 0)
    private(set) var recordingURL: URL?
    var showEnrollmentHint = false
    var showPairingLostHint = false
    /// Result of the last PIN change (nil while none pending/finished).
    var pinChangeMessage: String?
    private(set) var eventLog: [LogEntry] = []
    private(set) var intersections: [IntersectionSnapshot] = []
    @ObservationIgnored var onNewWarning: ((DenmInfo) -> Void)?
    @ObservationIgnored var onTxResults: (([(requestId: UInt32, status: UInt32)]) -> Void)?
    private(set) var intersectionDiagnostics = IntersectionDiagnostics()

    // Settings (persisted)
    var mqttEnabled: Bool { didSet { persist(); applyMqtt() } }
    var mqttUri: String { didSet { persist() } }
    var communityEnabled: Bool { didSet { persist(); applyMqtt() } }
    var rollingEnabled: Bool { didSet { persist(); applyRolling() } }
    var rollingHours: Int { didSet { persist(); applyRolling() } }
    // User-configured extra broker; edits take effect via applyMqtt() ("Übernehmen")
    var customEnabled: Bool { didSet { persist(); applyMqtt() } }
    var customHost: String { didSet { persist() } }
    var customPort: String { didSet { persist() } }
    var customTLS: Bool { didSet { persist() } }
    var customUser: String { didSet { persist() } }
    var customPassword: String { didSet { Keychain.set(customPassword, for: "custom") } }
    var customPrefix: String { didSet { persist() } }
    var nodeId: String { didSet { persist() } }
    var autoConnect: Bool { didSet { persist() } }

    @ObservationIgnored private let pipeline = PacketPipeline()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var rateWindow: [(Date, Int)] = []
    @ObservationIgnored private var lastSummary = Date.distantPast
    @ObservationIgnored private lazy var logWriter = DiagnosticLog()

    /// In-app event list plus the persistent Documents/diagnostics.log (survives restarts).
    func record(_ message: String, at date: Date = Date()) {
        eventLog.insert(LogEntry(date: date, message: message), at: 0)
        if eventLog.count > 200 { eventLog.removeLast(eventLog.count - 200) }
        logWriter.append(message, at: date)
    }

    init() {
        let d = UserDefaults.standard
        mqttEnabled = d.bool(forKey: "mqtt.enabled")
        mqttUri = d.string(forKey: "mqtt.uri") ?? Self.defaultMqttUri
        #if targetEnvironment(simulator)
        communityEnabled = d.object(forKey: "mqtt.community.enabled") as? Bool ?? false   // keep test runs off the shared server
        #else
        communityEnabled = d.object(forKey: "mqtt.community.enabled") as? Bool ?? true
        #endif
        customEnabled = d.bool(forKey: "mqtt.custom.enabled")
        rollingEnabled = d.object(forKey: "rolling.enabled") as? Bool ?? true
        rollingHours = d.object(forKey: "rolling.hours") as? Int ?? 24
        customHost = d.string(forKey: "mqtt.custom.host") ?? ""
        customPort = d.string(forKey: "mqtt.custom.port") ?? "8883"
        customTLS = d.object(forKey: "mqtt.custom.tls") as? Bool ?? true
        customUser = d.string(forKey: "mqtt.custom.user") ?? ""
        customPassword = Keychain.get("custom") ?? ""
        customPrefix = d.string(forKey: "mqtt.custom.prefix") ?? "its/"
        autoConnect = d.object(forKey: "ble.autoConnect") as? Bool ?? true
        if let id = d.string(forKey: "node.id"), !id.isEmpty {
            nodeId = id
        } else {
            var bytes = [UInt8](repeating: 0, count: 6)
            _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            nodeId = bytes.hexString
            d.set(nodeId, forKey: "node.id")
        }

        pipeline.mqtt.onStateChange = { [weak self] s in
            Task { @MainActor in
                self?.mqttState = s
                self?.record("MQTT: \(s.label)")
            }
        }
        pipeline.custom.onStateChange = { [weak self] s in
            Task { @MainActor in
                self?.customState = s
                self?.record("Eigener Server: \(s.label)")
            }
        }
        pipeline.community.onStateChange = { [weak self] s in
            Task { @MainActor in
                self?.communityState = s
                self?.record("\(BuiltInServers.communityName): \(s.label)")
            }
        }
        record("App gestartet (Version \(appVersion), OpenTrafficMap \(mqttEnabled ? "an" : "aus"), \(BuiltInServers.communityName) \(communityEnabled ? "an" : "aus"), Node \(nodeId))")
        applyMqtt()
        applyRolling()
        if autoConnect { pipeline.transport.start() }
        if ProcessInfo.processInfo.arguments.contains("-demo") { toggleDemo() }
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-replay"), i + 1 < args.count {
            let url = PcapWriter.capturesDirectory.appendingPathComponent(args[i + 1])
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.startReplay(url: url) }
        }

        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    // MARK: Actions

    func connect() { pipeline.transport.start() }
    func disconnect() { pipeline.transport.stop() }
    func forgetDevice() { pipeline.transport.forgetDevice() }
    var hasKnownDevice: Bool { pipeline.transport.knownPeripheralId != nil }

    /// Re-establish MQTT with the current URI/node ID (after editing settings).
    func applyMqtt() {
        pipeline.setMqttEnabled(mqttEnabled)
        pipeline.mqtt.configure(mqttEnabled ? .init(uri: mqttUri, nodeId: nodeId, appVersion: appVersion) : nil)
        pipeline.setCommunityEnabled(communityEnabled)
        pipeline.community.configure(communityEnabled ? .init(uri: BuiltInServers.communityUri, nodeId: nodeId, appVersion: appVersion) : nil)
        let host = customHost.trimmingCharacters(in: .whitespaces)
        let customOn = customEnabled && !host.isEmpty
        pipeline.setCustomEnabled(customOn)
        pipeline.custom.configure(customOn ? .init(
            uri: "\(customTLS ? "mqtts" : "mqtt")://\(host):\(Int(customPort) ?? (customTLS ? 8883 : 1883))",
            nodeId: nodeId, appVersion: appVersion,
            username: customUser.isEmpty ? nil : customUser, password: customPassword,
            topicPrefix: customPrefix.isEmpty ? "its/" : customPrefix) : nil)
    }

    func applyRolling() { pipeline.configureRolling(enabled: rollingEnabled, retentionHours: rollingHours) }
    func rollingUsage() -> (bytes: Int64, oldest: Date?) { pipeline.rollingUsage() }
    func deleteRolling() { pipeline.deleteRolling(); record("Automatischer Mitschnitt gelöscht") }

    /// Exports the rolling capture since `since` (nil = all) into the captures folder.
    func exportRolling(since: Date?) -> URL? {
        switch pipeline.exportRolling(since: since) {
        case .success(let r):
            record("Mitschnitt exportiert: \(r.url.lastPathComponent) (\(r.packets) Pakete)")
            return r.url
        case .failure:
            record("Mitschnitt-Export: keine Pakete im gewählten Zeitraum")
            return nil
        }
    }

    func toggleRecording() {
        recordingURL = pipeline.setRecording(recordingURL == nil)
    }

    func clear() {
        recent.removeAll()
        stations.removeAll()
        warnings.removeAll()
        countsByType.removeAll()
        totalPackets = 0
        missingSequences = 0
        protocolErrors = 0
        lastError = nil
    }

    func flushRecording() { pipeline.flushRecording() }
    func transmit(_ frame: [UInt8]) -> UInt32 { pipeline.transmit(frame) }

    func setBluetoothPin(_ pin: UInt32) {
        pinChangeMessage = "PIN wird gesendet …"
        pipeline.setBluetoothPin(pin)
    }

    private(set) var replay: (name: String, played: Int, total: Int)?

    /// Plays a PCAP through all views (not forwarded, not recorded).
    func startReplay(url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { record("Aufnahme konnte nicht gelesen werden: \(url.lastPathComponent)"); return }
        let name = url.lastPathComponent
        let ok = pipeline.startReplay(data) { [weak self] played, total in
            Task { @MainActor in
                guard let self else { return }
                self.replay = played >= total ? nil : (name, played, total)
                if played >= total { self.record("Wiedergabe beendet: \(name) (\(total) Pakete)") }
            }
        }
        if ok {
            replay = (name, 0, 0)
            record("Wiedergabe gestartet: \(name)")
        } else {
            record("Keine gültige PCAP-Datei: \(name)")
        }
    }

    func stopReplay() {
        pipeline.stopReplay()
        if let r = replay { record("Wiedergabe gestoppt: \(r.name)") }
        replay = nil
    }

    private(set) var demoRunning = false
    func toggleDemo() {
        demoRunning.toggle()
        if demoRunning { pipeline.startDemo() } else { pipeline.stopDemo() }
    }

    // MARK: Drain loop

    private func tick() {
        let d = pipeline.drain()
        let now = Date()
        if let s = d.linkState {
            linkState = s
            if s.isStreaming { showEnrollmentHint = false; showPairingLostHint = false }
        }
        if d.rejectedUnenrolled { showEnrollmentHint = true }
        if d.pairingLost { showPairingLostHint = true }
        for (date, message) in d.log { record(message, at: date) }
        if let f = d.statistics { firmware = f }
        if let i = d.intersections { intersections = i }
        if !d.txResults.isEmpty { onTxResults?(d.txResults) }
        if let r = d.pinResult {
            pinChangeMessage = r.status == 0 ? String(format: "Neuer PIN %06u ist aktiv.", r.pin)
                : String(format: "PIN nicht geändert (Fehler 0x%X), aktiv bleibt %06u.", r.status, r.pin)
            record(pinChangeMessage!)
        }
        if let i = d.intersectionDiagnostics { intersectionDiagnostics = i }
        protocolErrors += d.protocolErrors
        missingSequences += UInt64(d.missingSequences)
        if let e = d.lastError { lastError = e }
        mqttCounters = pipeline.mqtt.counters()
        communityCounters = pipeline.community.counters()
        customCounters = pipeline.custom.counters()
        if now.timeIntervalSince(lastSummary) >= 60 {
            lastSummary = now
            record("Minute: \(totalPackets) Pakete gesamt, \(String(format: "%.1f", packetsPerSecond))/s · BLE \(linkState.label) · OTM \(mqttState.label), \(mqttCounters.published) gesendet, \(mqttCounters.spooled) wartend · 1xx \(communityState.label), \(communityCounters.published) gesendet, \(communityCounters.spooled) wartend · eigener \(customState.label), \(customCounters.published) gesendet")
        }

        rateWindow.append((now, d.records.count))
        rateWindow.removeAll { now.timeIntervalSince($0.0) > 5 }
        let span = max(1, now.timeIntervalSince(rateWindow.first?.0 ?? now) + 0.25)
        packetsPerSecond = Double(rateWindow.reduce(0) { $0 + $1.1 }) / span

        // Drop warnings that were cancelled or are past their validity (and not repeated for 60 s).
        warnings = warnings.filter { !$0.value.denm.terminated && (now < $0.value.denm.expires || now.timeIntervalSince($0.value.lastSeen) < 60) }
        guard !d.records.isEmpty else { return }
        totalPackets += d.records.count
        for r in d.records {
            countsByType[r.title, default: 0] += 1
            guard let its = r.its else { continue }
            var s = stations[its.stationId] ?? StationSummary(
                id: its.stationId, lastSeen: r.receivedAt, count: 0, lastType: its.displayName,
                types: [], rssi: Int(r.packet.rssiDbm), coordinate: nil, secured: its.secured)
            s.lastSeen = r.receivedAt
            s.count += 1
            s.lastType = its.displayName
            s.types.insert(its.displayName)
            s.rssi = Int(r.packet.rssiDbm)
            s.secured = its.secured
            if let lat = its.sourceLatitude, let lon = its.sourceLongitude {
                s.coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            }
            if let cam = r.cam {
                s.lastCam = cam
                s.stationType = cam.stationType
                s.speedKmh = cam.speedKmh
                s.headingDegrees = cam.headingDegrees
                s.emergency = cam.isEmergency
                s.summary = cam.summary
                if let lat = cam.latitude, let lon = cam.longitude {
                    s.coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                }
            }
            if let denm = r.denm { s.summary = "Meldet: \(denm.summary)"; s.lastDenm = denm }
            stations[its.stationId] = s
            if let denm = r.denm {
                let key = "\(denm.originatingStationId)-\(denm.sequenceNumber)"
                if warnings[key] == nil, r.live { onNewWarning?(denm) }
                var w = warnings[key] ?? WarningSummary(denm: denm, lastSeen: r.receivedAt, count: 0)
                w.denm = denm; w.lastSeen = r.receivedAt; w.count += 1
                warnings[key] = w
            }
        }
        recent.insert(contentsOf: d.records.reversed(), at: 0)
        if recent.count > Self.maxRecentPackets { recent.removeLast(recent.count - Self.maxRecentPackets) }
    }

    private func persist() {
        let d = UserDefaults.standard
        d.set(mqttEnabled, forKey: "mqtt.enabled")
        d.set(mqttUri, forKey: "mqtt.uri")
        d.set(communityEnabled, forKey: "mqtt.community.enabled")
        d.set(rollingEnabled, forKey: "rolling.enabled")
        d.set(rollingHours, forKey: "rolling.hours")
        d.set(customEnabled, forKey: "mqtt.custom.enabled")
        d.set(customHost, forKey: "mqtt.custom.host")
        d.set(customPort, forKey: "mqtt.custom.port")
        d.set(customTLS, forKey: "mqtt.custom.tls")
        d.set(customUser, forKey: "mqtt.custom.user")
        d.set(customPrefix, forKey: "mqtt.custom.prefix")
        d.set(nodeId, forKey: "node.id")
        d.set(autoConnect, forKey: "ble.autoConnect")
    }
}
