import MapKit
import SwiftUI

/// Details of one sender (vehicle, RSU, traffic light), opened from the map or the 3D view.
struct StationDetailView: View {
    @Environment(BridgeModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let stationId: UInt32

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if let s = model.stations[stationId] {
                    List {
                        Section {
                            HStack(spacing: 14) {
                                Image(systemName: s.stationType?.symbol ?? "antenna.radiowaves.left.and.right")
                                    .font(.title2).foregroundStyle(.white)
                                    .frame(width: 48, height: 48)
                                    .background(Circle().fill(s.emergency ? Color.red : MessageColor.of(s.lastType)))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(s.summary ?? s.lastType).font(.headline)
                                    Text(verbatim: "Station \(s.id)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Section("Empfang") {
                            row("Zuletzt gehört", ago(s.lastSeen, now: context.date))
                            row("Nachrichten", "\(s.count) (\(s.types.sorted().joined(separator: ", ")))")
                            row("Signalstärke", "\(s.rssi) dBm")
                            row("Signiert", s.secured ? "ja" : "nein")
                        }
                        if let c = s.lastCam {
                            Section("Fahrzeug") {
                                row("Typ", c.stationType.label)
                                if let role = c.vehicleRole, role != .default { row("Rolle", role.label) }
                                if c.lightBarActive || c.sirenActive {
                                    row("Sondersignal", [c.lightBarActive ? "Blaulicht" : nil, c.sirenActive ? "Martinshorn" : nil]
                                        .compactMap { $0 }.joined(separator: " und "))
                                }
                                row("Geschwindigkeit", c.speedKmh.map { String(format: "%.0f km/h", $0) } ?? "–")
                                row("Richtung", c.headingDegrees.map { String(format: "%.0f°", $0) } ?? "–")
                                if let l = c.vehicleLengthM, let w = c.vehicleWidthM {
                                    row("Maße", String(format: "%.1f × %.1f m", l, w))
                                }
                                if !c.exteriorLights.isEmpty { row("Beleuchtung", c.exteriorLights.joined(separator: ", ")) }
                            }
                        }
                        if let d = s.lastDenm {
                            Section("Letzte Warnung") {
                                row("Ereignis", d.summary)
                                row("Erkannt", d.detectionTime.formatted(date: .omitted, time: .standard))
                                row("Gültig bis", d.expires.formatted(date: .omitted, time: .standard))
                            }
                        }
                        if let c = s.coordinate {
                            Section("Position") {
                                row("Koordinaten", String(format: "%.6f, %.6f", c.latitude, c.longitude))
                                Map(initialPosition: .camera(MapCamera(centerCoordinate: c, distance: 400))) {
                                    Marker(s.summary ?? s.lastType, coordinate: c)
                                }
                                .frame(height: 180).listRowInsets(EdgeInsets())
                            }
                        }
                    }
                } else {
                    ContentUnavailableView("Station nicht mehr vorhanden", systemImage: "questionmark.circle")
                }
            }
            .navigationTitle("Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        LabeledContent(k) { Text(v).monospacedDigit() }
    }

    private func ago(_ date: Date, now: Date) -> String {
        let s = Int(max(0, now.timeIntervalSince(date)))
        return s < 60 ? "vor \(s) s" : "vor \(s / 60) min"
    }
}

struct StationSelection: Identifiable { let id: UInt32 }
