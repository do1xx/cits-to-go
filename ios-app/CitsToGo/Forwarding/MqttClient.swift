import Foundation
import Network

/// Minimal MQTT 3.1.1 publisher (QoS 0) compatible with the OpenTrafficMap receiver topics:
///   its/<nodeid>/packet  raw 802.11 frame bytes
///   its/<nodeid>/status  "online" (retained) / "offline" (last will)
///   its/<nodeid>/info    {"emac":…,"ver":…,"hwv":…}
///   its/<nodeid>/stats   {"rbt":<seconds since start>}
/// Packets are spooled in a bounded queue while offline and the client reconnects with backoff.
final class MqttClient {
    enum State: Equatable, Sendable {
        case disabled, connecting, connected, offline(String)
        var label: String {
            switch self {
            case .disabled: "Aus"
            case .connecting: "Verbinde…"
            case .connected: "Verbunden"
            case .offline(let r): "Offline (\(r))"
            }
        }
    }

    struct Config: Equatable {
        var uri: String
        var nodeId: String
        var appVersion: String
        var hardware = "ios-ble-bridge"
    }

    static let keepAliveSeconds: UInt16 = 60
    static let maxSpool = 5_000

    private let queue = DispatchQueue(label: "cits.mqtt")
    private var connection: NWConnection?
    private var config: Config?
    private var spool: [[UInt8]] = []
    private var connected = false
    private var receiveBuffer: [UInt8] = []
    private var pingTimer: DispatchSourceTimer?
    private var statsTimer: DispatchSourceTimer?
    private var backoff: TimeInterval = 1
    private var generation = 0
    private let startedAt = Date()

    private(set) var published: UInt64 = 0
    private(set) var dropped: UInt64 = 0
    var onStateChange: ((State) -> Void)?

    private var state: State = .disabled {
        didSet { if state != oldValue { onStateChange?(state) } }
    }

    // MARK: Public

    func configure(_ newConfig: Config?) {
        queue.async {
            guard newConfig != self.config else { return }
            self.teardown(sendDisconnect: true)
            self.config = newConfig
            if newConfig == nil { self.state = .disabled; self.spool.removeAll() } else { self.open() }
        }
    }

    func publishPacket(_ payload: [UInt8]) {
        queue.async {
            guard self.config != nil else { return }
            if self.connected, let topic = self.topic("packet") {
                self.send(Self.publishPacket(topic: topic, payload: payload, retain: false))
                self.published += 1
            } else {
                if self.spool.count >= Self.maxSpool { self.spool.removeFirst(); self.dropped += 1 }
                self.spool.append(payload)
            }
        }
    }

    func counters() -> (published: UInt64, dropped: UInt64, spooled: Int) {
        queue.sync { (published, dropped, spool.count) }
    }

    // MARK: Connection handling

    private func topic(_ leaf: String) -> String? {
        guard let node = config?.nodeId.trimmingCharacters(in: .whitespaces), !node.isEmpty else { return nil }
        return "its/\(node)/\(leaf)"
    }

    private func open() {
        guard let config else { return }
        guard let target = Self.parse(config.uri) else { state = .offline("ungültige URI"); return }
        generation += 1
        let gen = generation
        state = .connecting

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        let params = target.tls ? NWParameters(tls: NWProtocolTLS.Options(), tcp: tcp) : NWParameters(tls: nil, tcp: tcp)
        let conn = NWConnection(host: NWEndpoint.Host(target.host), port: NWEndpoint.Port(rawValue: target.port)!, using: params)
        connection = conn
        receiveBuffer.removeAll()

        conn.stateUpdateHandler = { [weak self] st in
            guard let self, gen == self.generation else { return }
            switch st {
            case .ready:
                self.sendConnect(target: target)
                self.receive(conn, gen: gen)
            case .failed(let e):
                self.fail("\(e.localizedDescription)")
            case .waiting(let e):
                self.state = .offline(e.localizedDescription)
            default: break
            }
        }
        conn.start(queue: queue)
    }

    private func fail(_ reason: String) {
        teardown(sendDisconnect: false)
        state = .offline(reason)
        let delay = backoff
        backoff = min(backoff * 2, 60)
        let gen = generation
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, gen == self.generation, self.config != nil, self.connection == nil else { return }
            self.open()
        }
    }

    private func teardown(sendDisconnect: Bool) {
        if sendDisconnect, connected { connection?.send(content: Data([0xE0, 0x00]), completion: .idempotent) }
        generation += 1
        connected = false
        pingTimer?.cancel(); pingTimer = nil
        statsTimer?.cancel(); statsTimer = nil
        connection?.cancel()
        connection = nil
    }

    private func receive(_ conn: NWConnection, gen: Int) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            guard let self, gen == self.generation else { return }
            if let data { self.receiveBuffer.append(contentsOf: data); self.processIncoming() }
            if let error { self.fail(error.localizedDescription); return }
            if complete { self.fail("Server hat Verbindung geschlossen"); return }
            self.receive(conn, gen: gen)
        }
    }

    private func processIncoming() {
        while receiveBuffer.count >= 2 {
            var multiplier = 1, length = 0, idx = 1
            var complete = false
            while idx < receiveBuffer.count && idx <= 4 {
                let b = Int(receiveBuffer[idx]); idx += 1
                length += (b & 0x7f) * multiplier
                multiplier *= 128
                if b & 0x80 == 0 { complete = true; break }
            }
            guard complete, receiveBuffer.count >= idx + length else { return }
            let type = receiveBuffer[0] & 0xf0
            let body = Array(receiveBuffer[idx..<(idx + length)])
            receiveBuffer.removeFirst(idx + length)

            if type == 0x20 { // CONNACK
                guard body.count == 2, body[1] == 0 else {
                    fail("CONNACK abgelehnt (Code \(body.count == 2 ? Int(body[1]) : -1))")
                    return
                }
                onConnected()
            }
            // PINGRESP (0xD0) and anything else: ignore.
        }
    }

    private func onConnected() {
        connected = true
        backoff = 1
        state = .connected
        guard let config, let status = topic("status"), let info = topic("info"), let packet = topic("packet") else { return }
        send(Self.publishPacket(topic: status, payload: Array("online".utf8), retain: true))
        send(Self.publishPacket(topic: info, payload: Self.infoPayload(config), retain: false))
        sendStats()
        let backlog = spool
        spool.removeAll()
        for p in backlog { send(Self.publishPacket(topic: packet, payload: p, retain: false)); published += 1 }

        let ping = DispatchSource.makeTimerSource(queue: queue)
        let half = Double(Self.keepAliveSeconds) / 2
        ping.schedule(deadline: .now() + half, repeating: half)
        ping.setEventHandler { [weak self] in self?.send([0xC0, 0x00]) }
        ping.resume()
        pingTimer = ping

        let stats = DispatchSource.makeTimerSource(queue: queue)
        stats.schedule(deadline: .now() + 60, repeating: 60)
        stats.setEventHandler { [weak self] in self?.sendStats() }
        stats.resume()
        statsTimer = stats
    }

    private func sendStats() {
        guard let t = topic("stats") else { return }
        let seconds = Int(Date().timeIntervalSince(startedAt))
        send(Self.publishPacket(topic: t, payload: Array("{\"rbt\":\(seconds)}".utf8), retain: false))
    }

    private func send(_ bytes: [UInt8]) {
        connection?.send(content: Data(bytes), completion: .contentProcessed { [weak self] error in
            if let error { self?.fail(error.localizedDescription) }
        })
    }

    private func sendConnect(target: Target) {
        guard let config, let willTopic = topic("status") else { return }
        let node = config.nodeId.trimmingCharacters(in: .whitespaces)
        let clientId = "cits-ios-" + String(node.addingPercentEncoding(withAllowedCharacters: .alphanumerics)?.prefix(48) ?? "")

        var vh: [UInt8] = Self.utf8("MQTT") + [4]
        var flags: UInt8 = 0x02 | 0x04 | 0x20 // clean session, will flag, will retain
        if target.password != nil { flags |= 0x40 }
        if target.username != nil { flags |= 0x80 }
        vh.append(flags)
        vh += [UInt8(Self.keepAliveSeconds >> 8), UInt8(Self.keepAliveSeconds & 0xff)]

        var payload = Self.utf8(clientId) + Self.utf8(willTopic) + Self.utf8("offline")
        if let u = target.username { payload += Self.utf8(u) }
        if let p = target.password { payload += Self.utf8(p) }
        send(Self.packet(0x10, vh + payload))
    }

    // MARK: Encoding helpers

    static func publishPacket(topic: String, payload: [UInt8], retain: Bool) -> [UInt8] {
        packet(retain ? 0x31 : 0x30, utf8(topic) + payload)
    }

    static func packet(_ header: UInt8, _ body: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [header]
        var remaining = body.count
        repeat {
            var b = UInt8(remaining % 128)
            remaining /= 128
            if remaining > 0 { b |= 0x80 }
            out.append(b)
        } while remaining > 0
        return out + body
    }

    static func utf8(_ s: String) -> [UInt8] {
        let b = Array(s.utf8)
        return [UInt8(b.count >> 8), UInt8(b.count & 0xff)] + b
    }

    static func infoPayload(_ c: Config) -> [UInt8] {
        let node = c.nodeId.trimmingCharacters(in: .whitespaces)
        let isMac = node.count == 12 && node.allSatisfy(\.isHexDigit)
        let emac = isMac ? stride(from: 0, to: 12, by: 2).map { i -> String in
            let s = node.index(node.startIndex, offsetBy: i)
            return String(node[s..<node.index(s, offsetBy: 2)])
        }.joined(separator: ":") : node
        func esc(_ v: String) -> String { v.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        return Array("{\"emac\":\"\(esc(emac))\",\"ver\":\"\(esc(c.appVersion))\",\"hwv\":\"\(esc(c.hardware))\"}".utf8)
    }

    struct Target: Equatable {
        var host: String, port: UInt16, tls: Bool, username: String?, password: String?
    }

    static func parse(_ raw: String) -> Target? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let url = URLComponents(string: trimmed.contains("://") ? trimmed : "mqtt://\(trimmed)"),
              let scheme = url.scheme?.lowercased(), let host = url.host, !host.isEmpty else { return nil }
        let tls: Bool
        switch scheme {
        case "mqtt", "tcp": tls = false
        case "mqtts", "ssl", "tls": tls = true
        default: return nil
        }
        let port = UInt16(url.port ?? (tls ? 8883 : 1883))
        return Target(host: host, port: port, tls: tls, username: url.user?.removingPercentEncoding,
                      password: url.password?.removingPercentEncoding)
    }
}
