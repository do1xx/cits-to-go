import SwiftUI

struct LiveView: View {
    @Environment(BridgeModel.self) private var model
    @State private var filter: String?

    private var filtered: [PacketRecord] {
        guard let filter else { return model.recent }
        return model.recent.filter { $0.title == filter }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    StatusCard()
                }
                if model.showEnrollmentHint {
                    Section { EnrollmentHint() }
                }
                if !model.countsByType.isEmpty {
                    Section("Nachrichtentypen") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(model.countsByType.sorted { $0.value > $1.value }, id: \.key) { type, count in
                                    Button {
                                        filter = filter == type ? nil : type
                                    } label: {
                                        Text("\(type) \(count)")
                                            .font(.caption.monospacedDigit().weight(.semibold))
                                            .padding(.horizontal, 10).padding(.vertical, 6)
                                            .background(Capsule().fill(filter == type ? Color.accentColor : MessageColor.of(type).opacity(0.18)))
                                            .foregroundStyle(filter == type ? .white : .primary)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                if !model.warnings.isEmpty {
                    Section("Aktive Warnungen") {
                        ForEach(model.warnings.values.sorted { $0.lastSeen > $1.lastSeen }) { w in
                            WarningRow(warning: w)
                        }
                    }
                }
                Section(filter.map { "Pakete · \($0)" } ?? "Letzte Pakete") {
                    if filtered.isEmpty {
                        ContentUnavailableView("Noch keine Pakete", systemImage: "antenna.radiowaves.left.and.right.slash",
                                               description: Text("Sobald der Empfänger C-ITS-Nachrichten hört, erscheinen sie hier."))
                    }
                    ForEach(filtered) { r in
                        NavigationLink(value: r.id) { PacketRow(record: r) }
                    }
                }
            }
            .navigationTitle("CITS-to-go")
            .navigationDestination(for: UInt64.self) { id in
                if let r = model.recent.first(where: { $0.id == id }) { PacketDetailView(record: r) }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(role: .destructive) { model.clear() } label: { Image(systemName: "trash") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { model.toggleRecording() } label: {
                        Image(systemName: model.recordingURL == nil ? "record.circle" : "stop.circle.fill")
                            .foregroundStyle(model.recordingURL == nil ? Color.accentColor : .red)
                    }
                    .accessibilityLabel(model.recordingURL == nil ? "PCAP-Aufnahme starten" : "Aufnahme stoppen")
                }
            }
        }
    }
}

struct StatusCard: View {
    @Environment(BridgeModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle().fill(model.linkState.isStreaming ? .green : .orange).frame(width: 10, height: 10)
                Text(model.linkState.label).font(.subheadline.weight(.semibold))
                Spacer()
                if model.linkState.isStreaming {
                    Button("Trennen") { model.disconnect() }.buttonStyle(.bordered).controlSize(.small)
                } else {
                    Button("Verbinden") { model.connect() }.buttonStyle(.borderedProminent).controlSize(.small)
                }
            }
            HStack(spacing: 0) {
                Metric(value: "\(model.totalPackets)", label: "Pakete")
                Metric(value: String(format: "%.1f", model.packetsPerSecond), label: "Pakete/s")
                Metric(value: "\(model.stations.count)", label: "Stationen")
                Metric(value: "\(model.missingSequences)", label: "verloren")
            }
            VStack(alignment: .leading, spacing: 2) {
                ForwardLine(name: "OpenTrafficMap", enabled: model.mqttEnabled, state: model.mqttState, counters: model.mqttCounters)
                ForwardLine(name: BuiltInServers.communityName, enabled: model.communityEnabled, state: model.communityState, counters: model.communityCounters)
            }
            if let url = model.recordingURL {
                Label("Aufnahme läuft: \(url.lastPathComponent)", systemImage: "record.circle")
                    .font(.caption).foregroundStyle(.red)
            }
            if let fw = model.firmware {
                Text("Firmware: Uptime \(fw.uptimeMs / 1000) s · WLAN-RX \(fw.wifiRxPacketsPerSecond)/s · BLE-Queue \(fw.bleQueueDepth)/\(fw.bleQueueCapacity) · Drops \(fw.bleOutputDropsTotal)")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct Metric: View {
    let value: String
    let label: String
    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.title3.monospacedDigit().weight(.semibold))
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

struct EnrollmentHint: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Empfänger lehnt dieses iPhone ab", systemImage: "lock.trianglebadge.exclamationmark")
                .font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
            Text("Die Firmware akzeptiert neue Geräte nur nach USB-Freigabe. Empfänger an einen Computer anschließen, auf cits.dirksreich.de „Kopplung freigeben“ klicken und innerhalb von 30 s hier „Verbinden“ tippen und die Kopplung bestätigen.")
                .font(.caption)
        }
    }
}

struct PacketRow: View {
    let record: PacketRecord

    var body: some View {
        HStack(spacing: 10) {
            Text(record.title)
                .font(.caption.weight(.bold))
                .frame(width: 62)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(MessageColor.of(record.title).opacity(0.2)))
            VStack(alignment: .leading, spacing: 2) {
                if let its = record.its {
                    HStack(spacing: 4) {
                        if let summary = record.summary {
                            Text(summary).font(.subheadline).lineLimit(1)
                                .foregroundStyle(record.cam?.isEmergency == true || record.denm != nil ? Color.red : Color.primary)
                        } else {
                            Text(verbatim: "Station \(its.stationId)").font(.subheadline.monospacedDigit())
                        }
                        if its.secured { Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary) }
                    }
                } else {
                    Text(record.note ?? "Kein GeoNetworking").font(.subheadline).lineLimit(1)
                }
                Text("\(record.packet.payload.count) B · \(record.packet.rssiDbm) dBm · \(record.packet.frequencyMhz) MHz")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer()
            Text(record.receivedAt, format: .dateTime.hour().minute().second())
                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}

enum MessageColor {
    static func of(_ type: String) -> Color {
        switch type {
        case "CAM": .blue
        case "DENM": .red
        case "SPATEM": .green
        case "MAPEM": .teal
        case "IVIM": .orange
        case "CPM": .purple
        case "SREM", "SSEM": .yellow
        case "VAM": .pink
        default: .gray
        }
    }
}

private struct ForwardLine: View {
    let name: String
    let enabled: Bool
    let state: MqttClient.State
    let counters: (published: UInt64, dropped: UInt64, spooled: Int)

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: state == .connected ? "arrow.up.circle.fill" : "arrow.up.circle")
                .foregroundStyle(state == .connected ? .green : .secondary)
            Text("\(name): \(enabled ? state.label : "aus")")
            if enabled {
                Text("– \(counters.published) gesendet")
                if counters.spooled > 0 { Text("– \(counters.spooled) wartend") }
            }
        }
        .font(.caption).foregroundStyle(.secondary)
    }
}

struct WarningRow: View {
    let warning: WarningSummary

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.red))
            VStack(alignment: .leading, spacing: 2) {
                Text(warning.denm.causeLabel).font(.subheadline.weight(.semibold))
                if let sub = warning.denm.subCauseLabel { Text(sub).font(.caption) }
                Text(verbatim: "Von \(warning.denm.stationType.label) \(warning.denm.originatingStationId), erkannt \(warning.denm.detectionTime.formatted(date: .omitted, time: .shortened)), gültig bis \(warning.denm.expires.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
