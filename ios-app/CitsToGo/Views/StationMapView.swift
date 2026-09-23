import MapKit
import SwiftUI

struct StationMapView: View {
    @Environment(BridgeModel.self) private var model
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)

    private var located: [StationSummary] {
        model.stations.values.filter { $0.coordinate != nil }.sorted { $0.lastSeen > $1.lastSeen }
    }

    var body: some View {
        NavigationStack {
            Map(position: $position) {
                ForEach(located) { s in
                    Annotation(s.lastType, coordinate: s.coordinate!) {
                        ZStack {
                            Circle().fill(MessageColor.of(s.lastType)).frame(width: 26, height: 26)
                            Image(systemName: icon(for: s)).font(.caption.bold()).foregroundStyle(.white)
                        }
                        .opacity(Date().timeIntervalSince(s.lastSeen) > 30 ? 0.45 : 1)
                    }
                }
            }
            .mapControls { MapCompass(); MapScaleView() }
            .safeAreaInset(edge: .bottom) {
                if !located.isEmpty {
                    List(located.prefix(6)) { s in
                        HStack {
                            Text("\(s.id)").font(.subheadline.monospacedDigit())
                            Text(s.types.sorted().joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text("\(s.count)× · \(s.rssi) dBm").font(.caption.monospacedDigit())
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if let c = s.coordinate { withAnimation { position = .camera(MapCamera(centerCoordinate: c, distance: 600)) } }
                        }
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
            .navigationTitle("Stationen")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func icon(for s: StationSummary) -> String {
        if s.types.contains("SPATEM") || s.types.contains("MAPEM") { return "light.beacon.max" }
        if s.types.contains("DENM") { return "exclamationmark" }
        if s.types.contains("IVIM") { return "signpost.right" }
        if s.types.contains("CAM") { return "car.fill" }
        return "antenna.radiowaves.left.and.right"
    }
}
