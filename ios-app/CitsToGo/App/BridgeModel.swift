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
    private(set) var countsByType: [String: Int] = [:]
    private(set) var totalPackets = 0
    private(set) var packetsPerSecond = 0.0
    private(set) var missingSequences: UInt64 = 0
    private(set) var protocolErrors = 0
    private(set) var lastError: String?
    private(set) var firmware: FirmwareStatistics?
    private(set) var mqttCounters: (published: UInt64, dropped: UInt64, spooled: Int) = (0, 0, 0)
    private(set) var recordingURL: URL?
    var showEnrollmentHint = false
    private(set) var eventLog: [LogEntry] = []
    private(set) var intersections: [IntersectionSnapshot] = []
    private(set) var intersectionDiagnostics = IntersectionDiagnostics()

    // Settings (persisted)
    var mqttEnabled: Bool { didSet { persist(); applyMqtt() } }
    var mqttUri: String { didSet { persist() } }
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
        record("App gestartet (Version \(appVersion), MQTT \(mqttEnabled ? "an" : "aus"), Node \(nodeId))")
        applyMqtt()
        if autoConnect { pipeline.transport.start() }
        if ProcessInfo.processInfo.arguments.contains("-demo") { toggleDemo() }

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
    }

    func toggleRecording() {
        recordingURL = pipeline.setRecording(recordingURL == nil)
    }

    func clear() {
        recent.removeAll()
        stations.removeAll()
        countsByType.removeAll()
        totalPackets = 0
        missingSequences = 0
        protocolErrors = 0
        lastError = nil
    }

    func flushRecording() { pipeline.flushRecording() }

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
            if s.isStreaming { showEnrollmentHint = false }
        }
        if d.rejectedUnenrolled { showEnrollmentHint = true }
        for (date, message) in d.log { record(message, at: date) }
        if let f = d.statistics { firmware = f }
        if let i = d.intersections { intersections = i }
        if let i = d.intersectionDiagnostics { intersectionDiagnostics = i }
        protocolErrors += d.protocolErrors
        missingSequences += UInt64(d.missingSequences)
        if let e = d.lastError { lastError = e }
        mqttCounters = pipeline.mqtt.counters()
        if now.timeIntervalSince(lastSummary) >= 60 {
            lastSummary = now
            record("Minute: \(totalPackets) Pakete gesamt, \(String(format: "%.1f", packetsPerSecond))/s · BLE \(linkState.label) · MQTT \(mqttState.label), \(mqttCounters.published) gesendet, \(mqttCounters.dropped) verworfen, \(mqttCounters.spooled) wartend")
        }

        rateWindow.append((now, d.records.count))
        rateWindow.removeAll { now.timeIntervalSince($0.0) > 5 }
        let span = max(1, now.timeIntervalSince(rateWindow.first?.0 ?? now) + 0.25)
        packetsPerSecond = Double(rateWindow.reduce(0) { $0 + $1.1 }) / span

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
            stations[its.stationId] = s
        }
        recent.insert(contentsOf: d.records.reversed(), at: 0)
        if recent.count > Self.maxRecentPackets { recent.removeLast(recent.count - Self.maxRecentPackets) }
    }

    private func persist() {
        let d = UserDefaults.standard
        d.set(mqttEnabled, forKey: "mqtt.enabled")
        d.set(mqttUri, forKey: "mqtt.uri")
        d.set(nodeId, forKey: "node.id")
        d.set(autoConnect, forKey: "ble.autoConnect")
    }
}
