import MapKit
import SwiftUI

struct StationMapView: View {
    @Environment(BridgeModel.self) private var model
    @State private var position: MapCameraPosition = .automatic
    @State private var selected: StationSelection?
    @AppStorage("map.show3D") private var show3D = false

    private var located: [StationSummary] {
        model.stations.values.filter { $0.coordinate != nil }.sorted { $0.lastSeen > $1.lastSeen }
    }

    var body: some View {
        NavigationStack {
            Group {
                if show3D {
                    Scene3DView()
                } else {
                    mapView
                }
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Ansicht", selection: $show3D) {
                        Text("Karte").tag(false)
                        Text("3D").tag(true)
                    }
                    .pickerStyle(.segmented).frame(width: 180)
                }
            }
            .navigationTitle("Stationen")
            .sheet(item: $selected) { StationDetailView(stationId: $0.id).presentationDetents([.medium, .large]) }
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func icon(for s: StationSummary) -> String {
        if s.types.contains("SPATEM") || s.types.contains("MAPEM") { return "light.beacon.max" }
        if s.types.contains("DENM") { return "exclamationmark" }
        if s.types.contains("IVIM") { return "signpost.right" }
        if let t = s.stationType { return t.symbol }
        if s.types.contains("CAM") { return "car.fill" }
        return "antenna.radiowaves.left.and.right"
    }

    private var mapView: some View {
            Map(position: $position) {
                ForEach(located) { s in
                    Annotation(s.summary ?? s.lastType, coordinate: s.coordinate!) {
                        Button { selected = StationSelection(id: s.id) } label: {
                        ZStack {
                            Circle().fill(s.emergency ? Color.red : MessageColor.of(s.lastType)).frame(width: 26, height: 26)
                            Image(systemName: icon(for: s)).font(.caption.bold()).foregroundStyle(.white)
                        }
                        .overlay(alignment: .top) {
                            if let h = s.headingDegrees, (s.speedKmh ?? 0) > 2 {
                                Image(systemName: "arrowtriangle.up.fill").font(.system(size: 8))
                                    .foregroundStyle(s.emergency ? Color.red : MessageColor.of(s.lastType))
                                    .offset(y: -9).rotationEffect(.degrees(h), anchor: .center)
                            }
                        }
                        .opacity(Date().timeIntervalSince(s.lastSeen) > 30 ? 0.45 : 1)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(s.summary ?? s.lastType)
                    }
                }
                ForEach(model.warnings.values.filter { $0.coordinate != nil }) { w in
                    Annotation(w.denm.causeLabel, coordinate: w.coordinate!) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.title3).foregroundStyle(.white, .red)
                            .shadow(radius: 2)
                    }
                }
            }
            .mapControls { MapUserLocationButton(); MapCompass(); MapScaleView() }
            .safeAreaInset(edge: .bottom) {
                if !located.isEmpty {
                    List(located.prefix(6)) { s in
                        HStack {
                            Text(verbatim: String(s.id)).font(.subheadline.monospacedDigit())
                            Text(s.summary ?? s.types.sorted().joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Spacer()
                            Text("\(s.count)× · \(s.rssi) dBm").font(.caption.monospacedDigit())
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { selected = StationSelection(id: s.id) }
                    }
                    .listStyle(.plain)
                    .frame(height: min(CGFloat(located.count), 4) * 44)
                    .background(.regularMaterial)
                }
            }
            .overlay {
                if located.isEmpty {
                    ContentUnavailableView("Keine Positionen", systemImage: "mappin.slash",
                                           description: Text("Stationen erscheinen, sobald GeoNetworking-Pakete mit Positionsvektor empfangen werden."))
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                        .padding(40)
                }
            }
    }
}
