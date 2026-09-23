import XCTest
@testable import CitsToGo

final class ProtocolTests: XCTestCase {
    func testCobsRoundTrip() throws {
        for input: [UInt8] in [[], [0], [1, 2, 0, 3], [UInt8](repeating: 7, count: 300), (0..<600).map { UInt8($0 % 256) }] {
            let encoded = Cobs.encode(input)
            XCTAssertFalse(encoded.contains(0))
            XCTAssertEqual(try Cobs.decode(encoded), input)
        }
    }

    func testCrc32MatchesZlib() {
        XCTAssertEqual(Crc32.checksum(Array("123456789".utf8)), 0xCBF4_3926)
    }

    func testEnrollmentRequestIsValidCtgRecord() throws {
        let record = CtgProtocol.bluetoothEnrollmentRequest()
        XCTAssertEqual(record.last, 0)
        let decoded = try Cobs.decode(record.dropLast())
        XCTAssertEqual(Array(decoded[0..<4]), Array("CTG1".utf8))
        XCTAssertEqual(decoded[5], CtgProtocol.typeBleEnrollRequest)
        XCTAssertEqual(decoded.count, 16)
    }

    /// Builds a capture record exactly as firmware/src/protocol.rs does and feeds it
    /// through the stream reader in awkward BLE-sized chunks.
    func testCaptureFrameThroughStreamReader() throws {
        let payload: [UInt8] = [0x88, 0x00, 0x00, 0x11, 0x22, 0x00, 0x33]
        var d = [UInt8](repeating: 0, count: 32 + payload.count + 4)
        d[0] = 0x43; d[1] = 0x54; d[2] = 0x47; d[3] = 0x31; d[4] = 1; d[5] = CtgProtocol.typeCapture
        d.putU16le(32, at: 6)
        d.putU16le(CitsPacket.flagBroadcast, at: 8)
        d.putU32le(42, at: 10)
        d.putU32le(1_234_567, at: 14)
        d.putU16le(5900, at: 22)
        d.putU16le(UInt16(payload.count), at: 24)
        d.putU16le(UInt16(payload.count), at: 26)
        d[28] = UInt8(bitPattern: -71)
        d.replaceSubrange(32..<(32 + payload.count), with: payload)
        d.putU32le(Crc32.checksum(d[0..<(d.count - 4)]), at: d.count - 4)
        let stream = [0] + Cobs.encode(d) + [0] + [0] + Cobs.encode(d) + [0]

        var reader = CtgStreamReader()
        var captures: [CitsPacket] = []
        var i = 0
        while i < stream.count {
            let chunk = stream[i..<min(i + 5, stream.count)]
            for r in reader.accept(chunk) {
                if case .success(.capture(let p)) = r { captures.append(p) } else { XCTFail("unexpected \(r)") }
            }
            i += 5
        }
        XCTAssertEqual(captures.count, 2)
        XCTAssertEqual(captures[0].sequence, 42)
        XCTAssertEqual(captures[0].frequencyMhz, 5900)
        XCTAssertEqual(captures[0].rssiDbm, -71)
        XCTAssertTrue(captures[0].broadcast)
        XCTAssertEqual(captures[0].payload, payload)
    }

    func testCrcMismatchIsReported() {
        var d = [UInt8](repeating: 0, count: 16)
        d[0] = 0x43; d[1] = 0x54; d[2] = 0x47; d[3] = 0x31; d[4] = 1; d[5] = 5
        d.putU16le(12, at: 6)
        var reader = CtgStreamReader()
        let results = reader.accept(Cobs.encode(d) + [0])
        guard case .failure(let e) = results.first else { return XCTFail() }
        XCTAssertEqual(e.description, "CRC mismatch")
    }

    func testSequenceTrackerWraps() {
        var t = CaptureSequenceTracker()
        XCTAssertEqual(t.observe(0xffff_fffe), 0)
        XCTAssertEqual(t.observe(1), 2) // skipped 0xffffffff and 0
        XCTAssertEqual(t.observe(2), 0)
        XCTAssertEqual(t.observe(1), 0) // reorder/reset is not counted
    }

    func testMqttUriParsing() {
        XCTAssertEqual(MqttClient.parse("mqtts://cits1.opentrafficmap.org"),
                       .init(host: "cits1.opentrafficmap.org", port: 8883, tls: true, username: nil, password: nil))
        XCTAssertEqual(MqttClient.parse("192.168.1.5"),
                       .init(host: "192.168.1.5", port: 1883, tls: false, username: nil, password: nil))
        XCTAssertEqual(MqttClient.parse("mqtt://u%40x:p%3Aw@h:1999"),
                       .init(host: "h", port: 1999, tls: false, username: "u@x", password: "p:w"))
        XCTAssertNil(MqttClient.parse("http://x"))
    }

    func testMqttRemainingLengthEncoding() {
        XCTAssertEqual(Array(MqttClient.packet(0x30, [UInt8](repeating: 1, count: 321)).prefix(3)), [0x30, 0xC1, 0x02])
    }

    func testSecuredSpatemFrameExtraction() throws {
        let frame = try resource("secured-spatem-frame")
        guard case .success(let its) = ItsFrameExtractor.extract(frame) else { return XCTFail("not extracted") }
        XCTAssertEqual(its.messageType, .spatem)
        XCTAssertEqual(its.destinationPort, 2004)
        XCTAssertTrue(its.secured)
    }

    func testSecuredMapemFrameExtraction() throws {
        let frame = try resource("secured-mapem-regional-frame")
        guard case .success(let its) = ItsFrameExtractor.extract(frame) else { return XCTFail("not extracted") }
        XCTAssertEqual(its.messageType, .mapem)
        XCTAssertEqual(its.destinationPort, 2003)
    }

    func testDecodesSecuredSpatem() throws {
        guard case .success(let its) = ItsFrameExtractor.extract(try resource("secured-spatem-frame")) else { return XCTFail() }
        XCTAssertEqual(its.payload.count, 121)
        let spats = try MapSpatDecoder.decodeSpat(its, receivedAt: Date())
        XCTAssertEqual(spats.count, 1)
        XCTAssertEqual(spats[0].key, IntersectionKey(region: 43, id: 40103))
        XCTAssertFalse(spats[0].movements.isEmpty)
        XCTAssertTrue(spats[0].movements.allSatisfy { $0.currentEvent?.state != .unknown })
    }

    func testDecodesSecuredMapemWithRegionalExtension() throws {
        guard case .success(let its) = ItsFrameExtractor.extract(try resource("secured-mapem-regional-frame")) else { return XCTFail() }
        XCTAssertEqual(its.payload.count, 1385)
        let maps = try MapSpatDecoder.decodeMap(its, receivedAt: Date())
        XCTAssertEqual(maps.count, 1)
        XCTAssertEqual(maps[0].key, IntersectionKey(region: 43, id: 40200))
        XCTAssertEqual(maps[0].name, "Bahnhofstr. - 8. Mai Str.")
        XCTAssertEqual(maps[0].lanes.count, 19)
        XCTAssertTrue(maps[0].lanes.allSatisfy { $0.nodes.count >= 2 })
        XCTAssertEqual(maps[0].latitude, 48, accuracy: 2) // Austria
    }

    func testIntersectionStoreKeepsBoth() throws {
        var store = IntersectionStore()
        for name in ["secured-mapem-regional-frame", "secured-spatem-frame"] {
            guard case .success(let its) = ItsFrameExtractor.extract(try resource(name)) else { return XCTFail() }
            XCTAssertTrue(store.accept(its, receivedAt: Date()))
        }
        XCTAssertEqual(store.diagnostics.mapemDecoded, 1)
        XCTAssertEqual(store.diagnostics.spatemDecoded, 1)
        XCTAssertEqual(store.activeSnapshots(now: Date(), maxAge: 30).count, 2)
        XCTAssertEqual(store.activeSnapshots(now: Date().addingTimeInterval(60), maxAge: 30).count, 0)
    }

    func testSpatCountdown() {
        let event = SignalEvent(state: .stopAndRemain, minEndTime: 1200, likelyTime: nil, maxEndTime: nil, confidence: nil)
        let t0 = Date()
        // moy 61 -> minute 1 of hour -> 600 tenths; timestamp 10 s -> 700 tenths; change at 1200 -> 50 s
        let spat = SpatIntersection(key: .init(region: nil, id: 1), revision: 0, moy: 61, timestampMs: 10_000,
                                    movements: [], receivedAt: t0)
        XCTAssertEqual(spat.secondsUntilChange(event, now: t0), 50)
        XCTAssertEqual(spat.secondsUntilChange(event, now: t0.addingTimeInterval(20)), 30)
        XCTAssertNil(spat.secondsUntilChange(event, now: t0.addingTimeInterval(51)))
    }

    /// Reference values taken from Wireshark's dissection of the same capture.
    func testCamAndDenmMatchWireshark() throws {
        // Private field recording, kept out of git (*.pcap); the test is skipped without it.
        guard let url = Bundle(for: Self.self).url(forResource: "julian-cam-denm", withExtension: "pcap") else {
            throw XCTSkip("julian-cam-denm.pcap not present")
        }
        let d = [UInt8](try Data(contentsOf: url))
        var off = 24
        var cams: [CamInfo] = [], denms: [DenmInfo] = []
        while off + 16 <= d.count {
            let n = Int(d.u32le(off + 8))
            let frame = Array(d[(off + 16)..<(off + 16 + n)]); off += 16 + n
            guard case .success(let its) = ItsFrameExtractor.extract(frame) else { return XCTFail("extract") }
            if its.messageId == 2 { cams.append(try CamDenmDecoder.decodeCam(its)) }
            if its.messageId == 1 { denms.append(try CamDenmDecoder.decodeDenm(its)) }
        }
        XCTAssertEqual(cams.count, 12)
        XCTAssertEqual(denms.count, 4)
        let first = cams[0]                      // frame 1
        XCTAssertEqual(first.stationType, .passengerCar)
        XCTAssertEqual(first.latitude!, 52.0899523, accuracy: 1e-7)
        XCTAssertEqual(first.headingDegrees!, 258.5, accuracy: 0.01)
        XCTAssertEqual(first.speedKmh!, 9.61 * 3.6, accuracy: 0.01)
        XCTAssertEqual(first.vehicleLengthM!, 4.9, accuracy: 0.01)
        XCTAssertEqual(first.vehicleRole, .default)
        XCTAssertEqual(first.exteriorLights, ["Tagfahrlicht"])
        let denm = denms[0]
        XCTAssertEqual(denm.originatingStationId, 923_948_499)
        XCTAssertEqual(denm.sequenceNumber, 697)
        XCTAssertEqual(denm.causeCode, 1)
        XCTAssertEqual(denm.subCauseCode, 0)
        XCTAssertEqual(denm.validitySeconds, 60)
        XCTAssertEqual(denm.causeLabel, "Verkehrsstörung")
        // Wireshark: detectionTime 2026-09-20 12:55:42.244 UTC (716993747244 TAI ms since 2004, minus 5 leap seconds)
        XCTAssertEqual(denm.detectionTime.timeIntervalSince1970, 1_072_915_200 + 716_993_747.244 - 5, accuracy: 0.001)
    }

    func testPcapWriterHeaderAndRecord() throws {
        let w = try PcapWriter()
        w.write(CitsPacket(sequence: 1, timestampUs: 5, frequencyMhz: 5900, rssiDbm: -60, wifiType: 0, rxState: 0,
                           flags: 0, originalLength: 3, payload: [1, 2, 3]))
        w.close()
        let data = [UInt8](try Data(contentsOf: w.url))
        try? FileManager.default.removeItem(at: w.url)
        XCTAssertEqual(data.count, 24 + 16 + 3)
        XCTAssertEqual(data.u32le(0), 0xA1B2_C3D4)
        XCTAssertEqual(data.u32le(20), 105)
        XCTAssertEqual(data.u32le(32), 3)
    }

    private func resource(_ name: String) throws -> [UInt8] {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "bin"))
        return [UInt8](try Data(contentsOf: url))
    }
}
