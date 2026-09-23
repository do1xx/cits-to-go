import Foundation

/// A decoded capture ready for display.
struct PacketRecord: Identifiable, Sendable {
    let id: UInt64
    let receivedAt: Date
    let packet: CitsPacket
    let its: ItsPacketInfo?
    let note: String?          // extraction failure reason, if any
    let sourceMac: String?

    var title: String { its?.displayName ?? (note == nil ? "802.11" : "GN ?") }
}

/// Everything the UI needs since the last drain.
struct PipelineDrain {
    var records: [PacketRecord] = []
    var statistics: FirmwareStatistics?
    var linkState: BleLinkState?
    var rejectedUnenrolled = false
    var protocolErrors = 0
    var missingSequences: UInt32 = 0
    var lastError: String?
    var log: [(Date, String)] = []
    var intersections: [IntersectionSnapshot]?
    var intersectionDiagnostics: IntersectionDiagnostics?
}

/// Runs on the BLE transport queue: stream reassembly, CTG decoding, ITS extraction and
/// forwarding (MQTT + PCAP) happen here, off the main thread. The UI drains batches.
final class PacketPipeline: BleTransportDelegate {
    let transport = BleTransport()
    let mqtt = MqttClient()            // OpenTrafficMap (or a user-defined broker)
    let community = MqttClient()       // built-in 1xx community broker

    private var reader = CtgStreamReader()
    private var sequence = CaptureSequenceTracker()
    private var pcap: PcapWriter?
    private var pending = PipelineDrain()
    private var nextId: UInt64 = 0
    private var mqttEnabled = false
    private var communityEnabled = false
    private var intersectionStore = IntersectionStore()
    private var intersectionsDirty = false
    private var lastIntersectionPublish = Date.distantPast
    static let intersectionMaxAge: TimeInterval = 60

    init() {
        transport.delegate = self
    }

    func drain() -> PipelineDrain {
        transport.queue.sync {
            let now = Date()
            // Publish on change, and once a second so stale intersections expire.
            if intersectionsDirty || now.timeIntervalSince(lastIntersectionPublish) > 1 {
                pending.intersections = intersectionStore.activeSnapshots(now: now, maxAge: Self.intersectionMaxAge)
                pending.intersectionDiagnostics = intersectionStore.diagnostics
                intersectionsDirty = false
                lastIntersectionPublish = now
            }
            defer { pending = PipelineDrain() }
            return pending
        }
    }

    func setMqttEnabled(_ enabled: Bool) { transport.queue.async { self.mqttEnabled = enabled } }
    func setCommunityEnabled(_ enabled: Bool) { transport.queue.async { self.communityEnabled = enabled } }

    /// Starts or stops PCAP recording; returns the file URL when a capture was started.
    func setRecording(_ on: Bool) -> URL? {
        transport.queue.sync {
            if on {
                if pcap == nil { pcap = try? PcapWriter() }
                return pcap?.url
            }
            pcap?.close()
            pcap = nil
            return nil
        }
    }

    func flushRecording() { transport.queue.async { self.pcap?.flush() } }

    // MARK: Demo

    /// Feeds a real recorded MAPEM (Bahnhofstr. - 8. Mai Str., AT) through the normal pipeline and
    /// simulates SPATEM phases for its signal groups, so the intersection view can be tried anywhere.
    func startDemo() {
        transport.queue.async {
            guard let url = Bundle.main.url(forResource: "demo-mapem", withExtension: "bin"),
                  let data = try? Data(contentsOf: url) else { return }
            let frame = [UInt8](data)
            self.demoFrame = frame
            self.demoTick()
        }
    }

    private var demoFrame: [UInt8]?

    private func demoTick() {
        guard let frame = demoFrame else { return }
        nextId &+= 1
        handle(CitsPacket(sequence: UInt32(truncatingIfNeeded: nextId), timestampUs: UInt64(Date().timeIntervalSince1970 * 1e6),
                          frequencyMhz: 5900, rssiDbm: -62, wifiType: 0, rxState: 0, flags: CitsPacket.flagBroadcast,
                          originalLength: UInt16(frame.count), payload: frame), forward: false)
        if let map = intersectionStore.maps.values.first {
            let now = Date()
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "UTC")!
            let secondsInYear = now.timeIntervalSince(cal.dateInterval(of: .year, for: now)!.start)
            let moy = Int(secondsInYear / 60)
            let msInMinute = Int((secondsInYear.truncatingRemainder(dividingBy: 60)) * 1000)
            let nowTenths = (moy % 60) * 600 + msInMinute / 100
            let groups = Set(map.lanes.flatMap { $0.connections.compactMap(\.signalGroup) }).sorted()
            let movements = groups.map { sg -> SignalMovement in
                // 60 s cycle per group, phase-shifted: 25 s green, 3 s yellow, 30 s red, 2 s red-yellow.
                let cycle = 600, t = (nowTenths + sg * 170) % cycle
                let (state, left): (MovementPhaseState, Int) =
                    t < 250 ? (.protectedAllowed, 250 - t) : t < 280 ? (.protectedClearance, 280 - t)
                    : t < 580 ? (.stopAndRemain, 580 - t) : (.preMovement, 600 - t)
                let end = (nowTenths + left) % 36_000
                return SignalMovement(signalGroup: sg, events: [SignalEvent(state: state, minEndTime: end, likelyTime: end,
                                                                             maxEndTime: end, confidence: nil)], connectionIds: [])
            }
            intersectionStore.inject(SpatIntersection(key: map.key, revision: map.revision, moy: moy, timestampMs: msInMinute,
                                                      movements: movements, receivedAt: now))
            intersectionsDirty = true
        }
        transport.queue.asyncAfter(deadline: .now() + 1) { self.demoTick() }
    }

    func stopDemo() { transport.queue.async { self.demoFrame = nil } }

    // MARK: BleTransportDelegate (transport queue)

    func bleTransport(_ t: BleTransport, didReceive bytes: Data) {
        for result in reader.accept(bytes) {
            switch result {
            case .success(.capture(let packet)):
                handle(packet)
            case .success(.statistics(let s)):
                pending.statistics = s
            case .success(.txResult), .success(.bluetoothEnrollmentResult):
                break
            case .failure(let e):
                pending.protocolErrors += 1
                pending.lastError = e.description
            }
        }
    }

    func bleTransport(_ t: BleTransport, didChange state: BleLinkState) {
        pending.linkState = state
        if !state.isStreaming {
            reader.reset()
            sequence.reset()
        }
    }

    func bleTransportRejectedUnenrolled(_ t: BleTransport) {
        pending.rejectedUnenrolled = true
    }

    func bleTransport(_ t: BleTransport, log message: String) {
        pending.log.append((Date(), message))
    }

    private func handle(_ packet: CitsPacket, forward: Bool = true) {
        if forward {
            pending.missingSequences += sequence.observe(packet.sequence)
            if mqttEnabled { mqtt.publishPacket(packet.payload) }
            if communityEnabled { community.publishPacket(packet.payload) }
            pcap?.write(packet)
        }

        let its: ItsPacketInfo?, note: String?
        switch ItsFrameExtractor.extract(packet.payload) {
        case .success(let info):
            its = info; note = nil
            if intersectionStore.accept(info, receivedAt: Date()) { intersectionsDirty = true }
        case .notGeoNetworking: its = nil; note = nil
        case .unsupported(let reason, _): its = nil; note = reason
        }
        nextId += 1
        pending.records.append(PacketRecord(
            id: nextId, receivedAt: Date(), packet: packet, its: its, note: note,
            sourceMac: Ieee80211Mac.sourceAddress(packet.payload)
        ))
        // Bound memory if the UI is not draining (e.g. app in background).
        if pending.records.count > 2_000 { pending.records.removeFirst(pending.records.count - 2_000) }
    }
}
