import SwiftUI

struct PacketDetailView: View {
    let record: PacketRecord

    var body: some View {
        List {
            if let its = record.its {
                Section("C-ITS") {
                    row("Nachricht", its.messageType.map { "\($0.name) – \($0.longName)" } ?? "messageID \(its.messageId)")
                    row("Station-ID", "\(its.stationId)")
                    row("BTP-Port", "\(its.destinationPort)")
                    row("Protokollversion", "\(its.protocolVersion)")
                    row("Gesichert (Signatur)", its.secured ? "ja" : "nein")
                    if let lat = its.sourceLatitude, let lon = its.sourceLongitude {
                        row("GN-Position", String(format: "%.6f, %.6f", lat, lon))
                    }
                    row("ITS-PDU", "\(its.payload.count) Bytes")
                }
                if let cam = record.cam { camSection(cam) }
                if let denm = record.denm { denmSection(denm) }
            } else if let note = record.note {
                Section("C-ITS") { Text(note).foregroundStyle(.secondary) }
            }
            Section("Funk") {
                row("Sequenz", "\(record.packet.sequence)")
                row("Frequenz", "\(record.packet.frequencyMhz) MHz")
                row("RSSI", "\(record.packet.rssiDbm) dBm")
                row("Länge", "\(record.packet.payload.count) / \(record.packet.originalLength) Bytes\(record.packet.truncated ? " (abgeschnitten)" : "")")
                if let mac = record.sourceMac { row("Quell-MAC", mac) }
                row("Empfangen", record.receivedAt.formatted(date: .omitted, time: .standard))
            }
            Section("Rohdaten (802.11)") {
                Text(hexDump(record.packet.payload))
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                ShareLink(item: record.packet.payload.hexString) { Label("Hex teilen", systemImage: "square.and.arrow.up") }
            }
        }
        .navigationTitle(record.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private func camSection(_ c: CamInfo) -> some View {
        Section("Fahrzeug (CAM)") {
            row("Typ", c.stationType.label)
            if let role = c.vehicleRole, role != .default { row("Rolle", role.label) }
            if c.lightBarActive || c.sirenActive {
                row("Sondersignal", [c.lightBarActive ? "Blaulicht" : nil, c.sirenActive ? "Martinshorn" : nil].compactMap { $0 }.joined(separator: " und "))
            }
            row("Geschwindigkeit", c.speedKmh.map { String(format: "%.1f km/h", $0) } ?? "nicht verfügbar")
            row("Fahrtrichtung", c.headingDegrees.map { String(format: "%.1f° (%@)", $0, compass($0)) } ?? "nicht verfügbar")
            if let l = c.vehicleLengthM { row("Länge", String(format: "%.1f m", l)) }
            if let w = c.vehicleWidthM { row("Breite", String(format: "%.1f m", w)) }
            if !c.exteriorLights.isEmpty { row("Beleuchtung", c.exteriorLights.joined(separator: ", ")) }
            if let lat = c.latitude, let lon = c.longitude { row("Position", String(format: "%.6f, %.6f", lat, lon)) }
        }
    }

    @ViewBuilder private func denmSection(_ d: DenmInfo) -> some View {
        Section("Warnung (DENM)") {
            row("Ereignis", d.causeLabel)
            if let sub = d.subCauseLabel { row("Detail", sub) }
            if d.terminated { row("Status", "aufgehoben") }
            row("Code", "\(d.causeCode.map(String.init) ?? "–")/\(d.subCauseCode.map(String.init) ?? "–")")
            row("Erkannt", d.detectionTime.formatted(date: .abbreviated, time: .standard))
            row("Gültig", "\(d.validitySeconds) s, bis \(d.expires.formatted(date: .omitted, time: .standard))")
            row("Absender", "\(d.stationType.label) \(String(d.originatingStationId))")
            row("Meldungsnummer", "\(d.sequenceNumber)")
            if let q = d.informationQuality { row("Informationsqualität", "\(q) von 7") }
            if let lat = d.latitude, let lon = d.longitude { row("Ort", String(format: "%.6f, %.6f", lat, lon)) }
        }
    }

    private func compass(_ deg: Double) -> String {
        ["N", "NO", "O", "SO", "S", "SW", "W", "NW"][Int(((deg + 22.5).truncatingRemainder(dividingBy: 360)) / 45)]
    }

    private func row(_ k: String, _ v: String) -> some View {
        LabeledContent(k) { Text(v).monospacedDigit().textSelection(.enabled) }
    }

    private func hexDump(_ bytes: [UInt8]) -> String {
        stride(from: 0, to: bytes.count, by: 16).map { off in
            let line = bytes[off..<min(off + 16, bytes.count)]
            return String(format: "%04x  ", off) + line.map { String(format: "%02x", $0) }.joined(separator: " ")
        }.joined(separator: "\n")
    }
}
