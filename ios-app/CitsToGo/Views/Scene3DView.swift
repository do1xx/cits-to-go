import CoreLocation
import MapLibre
import SwiftUI
import UIKit

/// Tesla-style surround view on an OpenFreeMap vector map with 3D buildings: own position in the
/// centre, received stations as extruded arrows, MAPEM lanes coloured by the current SPATEM phase.
/// Tap a vehicle for details. Pinch/rotate works; the camera follows again 20 s after the last gesture.
struct Scene3DView: View {
    @Environment(BridgeModel.self) private var model
    @Environment(LocationProvider.self) private var location
    @State private var topDown = false
    @State private var selected: StationSelection?
    @AppStorage("scene3d.buildings") private var showBuildings = true

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let snap = snapshot(now: context.date)
            ZStack(alignment: .bottom) {
                MapLibre3DContainer(snapshot: snap, topDown: topDown, showBuildings: showBuildings) { selected = StationSelection(id: $0) }
                    .ignoresSafeArea(edges: .top)
                HStack {
                    Text(snap.caption).font(.caption).padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                    Spacer()
                    Button { showBuildings.toggle() } label: {
                        Image(systemName: showBuildings ? "building.2.fill" : "building.2")
                            .padding(10).background(.ultraThinMaterial, in: Circle())
                    }
                    .accessibilityLabel(showBuildings ? "Gebäude ausblenden" : "Gebäude einblenden")
                    Button { topDown.toggle() } label: {
                        Image(systemName: topDown ? "view.3d" : "square.grid.3x3.topleft.filled")
                            .padding(10).background(.ultraThinMaterial, in: Circle())
                    }
                    .accessibilityLabel(topDown ? "Verfolgeransicht" : "Draufsicht")
                }
                .padding()
                .padding(.bottom, 80)
            }
        }
        .onAppear { location.start() }
        .onDisappear { location.stop() }
        .sheet(item: $selected) { StationDetailView(stationId: $0.id).presentationDetents([.medium, .large]) }
    }

    struct Body3D: Equatable {
        let id: UInt32
        let coordinate: CLLocationCoordinate2D
        let heading: Double?            // degrees, 0 = north
        let type: StationType?
        let emergency: Bool
        var warning = false             // only DENM received, no CAM
        let label: String
        let stale: Bool

        static func == (a: Body3D, b: Body3D) -> Bool {
            a.id == b.id && a.coordinate.latitude == b.coordinate.latitude && a.coordinate.longitude == b.coordinate.longitude
                && a.heading == b.heading && a.type == b.type && a.emergency == b.emergency && a.warning == b.warning && a.label == b.label && a.stale == b.stale
        }
    }

    struct Lane3D: Equatable {
        let points: [SIMD2<Double>]     // (east, north) metres from the intersection reference point
        let reference: SIMD2<Double>    // (lat, lon)
        let width: Double
        let color: String               // CSS colour for the style expression
    }

    struct Snapshot3D {
        var bodies: [Body3D] = []
        var lanes: [Lane3D] = []
        var ego: CLLocationCoordinate2D?
        var center: CLLocationCoordinate2D?
        var egoHeading: Double = 0      // direction the camera looks (degrees)
        var extent: Double = 40         // distance to the farthest body (m), sizes the camera
        var caption = ""
    }

    private func snapshot(now: Date) -> Snapshot3D {
        var s = Snapshot3D()
        let recent = model.stations.values.filter { $0.coordinate != nil && now.timeIntervalSince($0.lastSeen) < 60 }
        let origin: CLLocationCoordinate2D
        var driving = false
        if let l = location.location, now.timeIntervalSince(l.timestamp) < 30 {
            origin = l.coordinate
            s.ego = origin
            if l.course >= 0, l.speed > 1 { s.egoHeading = l.course; driving = true }
        } else if let first = recent.max(by: { $0.lastSeen < $1.lastSeen })?.coordinate {
            origin = first
        } else {
            s.caption = "Noch keine Stationen mit Position"
            return s
        }
        s.center = origin
        var live: [(Double, Double)] = []
        for st in recent {
            let c = st.coordinate!
            let (x, z) = Geo.metres(from: origin, to: c)
            guard x * x + z * z < 600 * 600 else { continue }
            let stale = now.timeIntervalSince(st.lastSeen) > 10
            let label = st.lastCam?.speedKmh.map { "\(Int($0.rounded())) km/h" }
                ?? (st.lastDenm != nil ? "Warnung" : (st.stationType?.label ?? st.lastType))
            s.bodies.append(Body3D(id: st.id, coordinate: c, heading: st.headingDegrees,
                                   type: st.stationType ?? (st.types.contains("SPATEM") || st.types.contains("MAPEM") ? .roadSideUnit : nil),
                                   emergency: st.emergency, warning: st.lastDenm != nil && st.lastCam == nil, label: label, stale: stale))
            if !stale { live.append((x, z)) }
        }
        if live.isEmpty { live = s.bodies.map { Geo.metres(from: origin, to: $0.coordinate) } }
        for snap in model.intersections {
            guard let map = snap.map else { continue }
            let (ox, oz) = Geo.metres(from: origin, to: CLLocationCoordinate2D(latitude: map.latitude, longitude: map.longitude))
            guard ox * ox + oz * oz < 800 * 800 else { continue }
            let phases = snap.spat?.movementsBySignalGroup ?? [:]
            for lane in map.lanes where lane.nodes.count >= 2 {
                let phase = lane.connections.lazy.compactMap { $0.signalGroup.flatMap { phases[$0]?.currentEvent?.state } }.first
                let color = switch phase?.category {
                case .stop: "#e5352b"
                case .caution: "#f59e0b"
                case .go: "#22b04b"
                default: lane.laneType == .crosswalk ? "#ffffff" : "#8a94a0"
                }
                s.lanes.append(Lane3D(points: lane.nodes.map { SIMD2(Double($0.xCm) / 100, Double($0.yCm) / 100) },
                                      reference: SIMD2(map.latitude, map.longitude),
                                      width: lane.laneType == .crosswalk ? 2.5 : 3.0, color: color))
            }
        }
        if let far = live.map({ ($0.0 * $0.0 + $0.1 * $0.1).squareRoot() }).max() { s.extent = max(40, far) }
        if !driving, !live.isEmpty {
            // Standing still: face the centre of what we receive instead of an arbitrary north.
            let cx = live.map(\.0).reduce(0, +) / Double(live.count), cz = live.map(\.1).reduce(0, +) / Double(live.count)
            if cx * cx + cz * cz > 25 { s.egoHeading = atan2(cx, -cz) * 180 / .pi }
        }
        s.caption = "\(s.bodies.count) Stationen im Umkreis von 600 m" + (s.ego == nil ? " (ohne eigene Position)" : "")
        return s
    }
}

/// Flat-earth helpers, accurate enough within a few kilometres.
enum Geo {
    static let mPerDegLat = 111_320.0

    /// (east, south) metres from `a` to `b`.
    static func metres(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> (Double, Double) {
        ((b.longitude - a.longitude) * mPerDegLat * cos(a.latitude * .pi / 180), -(b.latitude - a.latitude) * mPerDegLat)
    }

    static func offset(_ c: CLLocationCoordinate2D, east: Double, north: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: c.latitude + north / mPerDegLat,
                               longitude: c.longitude + east / (mPerDegLat * cos(c.latitude * .pi / 180)))
    }

    /// Point `forward`/`right` metres from `c` in a frame rotated by `heading` (degrees from north).
    static func local(_ c: CLLocationCoordinate2D, heading: Double, forward: Double, right: Double) -> CLLocationCoordinate2D {
        let h = heading * .pi / 180
        return offset(c, east: forward * sin(h) + right * cos(h), north: forward * cos(h) - right * sin(h))
    }
}

private struct MapLibre3DContainer: UIViewRepresentable {
    let snapshot: Scene3DView.Snapshot3D
    let topDown: Bool
    let showBuildings: Bool
    let onSelect: (UInt32) -> Void

    static let styleURL = URL(string: "https://tiles.openfreemap.org/styles/liberty")!

    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }

    func makeUIView(context: Context) -> MLNMapView {
        let view = MLNMapView(frame: .zero, styleURL: Self.styleURL)
        view.delegate = context.coordinator
        view.logoView.isHidden = true
        view.compassView.isHidden = true
        view.attributionButtonPosition = .bottomLeft
        view.attributionButtonMargins = CGPoint(x: 12, y: 150)
        view.isPitchEnabled = false
        view.maximumZoomLevel = 19.5
        view.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:))))
        context.coordinator.mapView = view
        return view
    }

    func updateUIView(_ view: MLNMapView, context: Context) {
        context.coordinator.onSelect = onSelect
        context.coordinator.update(snapshot, topDown: topDown, showBuildings: showBuildings)
    }

    @MainActor
    final class Coordinator: NSObject, MLNMapViewDelegate {
        weak var mapView: MLNMapView?
        var onSelect: (UInt32) -> Void
        private var style: MLNStyle?
        private let vehicles = MLNShapeSource(identifier: "cits-vehicles", shape: nil)
        private let labels = MLNShapeSource(identifier: "cits-labels", shape: nil)
        private let lanes = MLNShapeSource(identifier: "cits-lanes", shape: nil)
        private let rings = MLNShapeSource(identifier: "cits-rings", shape: nil)
        private var pending: (Scene3DView.Snapshot3D, Bool, Bool)?
        private var lastLanes: [Scene3DView.Lane3D] = []
        private var lastRingCenter: CLLocationCoordinate2D?
        private var lastUserGesture = Date.distantPast
        private var lastCameraKey = ""
        private var triedFallback = false

        init(onSelect: @escaping (UInt32) -> Void) { self.onSelect = onSelect }

        // MARK: Style

        nonisolated func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            MainActor.assumeIsolated { configure(style) }
        }

        nonisolated func mapViewDidFailLoadingMap(_ mapView: MLNMapView, withError error: Error) {
            MainActor.assumeIsolated {
                // Offline without a cached style: plain background so vehicles and lanes still show.
                guard !triedFallback else { return }
                triedFallback = true
                let json = ##"{"version":8,"glyphs":"https://tiles.openfreemap.org/fonts/{fontstack}/{range}.pbf","sources":{},"layers":[{"id":"background","type":"background","paint":{"background-color":"#e9ecef"}}]}"##
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("cits-fallback-style.json")
                try? json.write(to: url, atomically: true, encoding: .utf8)
                mapView.styleURL = url
            }
        }

        nonisolated func mapView(_ mapView: MLNMapView, regionWillChangeWith reason: MLNCameraChangeReason, animated: Bool) {
            let gesture: MLNCameraChangeReason = [.gesturePan, .gesturePinch, .gestureRotate, .gestureZoomIn, .gestureZoomOut, .gestureTilt, .gestureOneFingerZoom]
            if !reason.intersection(gesture).isEmpty {
                MainActor.assumeIsolated { lastUserGesture = Date() }
            }
        }

        private func configure(_ style: MLNStyle) {
            self.style = style
            // Keep the map calm: no shops, POIs or house numbers; buildings light and slightly transparent.
            for layer in style.layers where layer.identifier.hasPrefix("poi") || layer.identifier.contains("housenumber") {
                layer.isVisible = false
            }
            if let b = style.layer(withIdentifier: "building-3d") as? MLNFillExtrusionStyleLayer {
                b.fillExtrusionColor = NSExpression(forConstantValue: UIColor(red: 0.93, green: 0.94, blue: 0.95, alpha: 1))
                b.fillExtrusionOpacity = NSExpression(forConstantValue: 0.55)
            }
            let anchor = style.layer(withIdentifier: "building-3d") ?? style.layer(withIdentifier: "building")
            for source in [vehicles, labels, lanes, rings] where style.source(withIdentifier: source.identifier) == nil {
                style.addSource(source)
            }

            let laneLayer = MLNFillStyleLayer(identifier: "cits-lanes", source: lanes)
            laneLayer.fillColor = NSExpression(mglJSONObject: ["to-color", ["get", "color"]])
            laneLayer.fillOpacity = NSExpression(forConstantValue: 0.85)
            let ringLayer = MLNLineStyleLayer(identifier: "cits-rings", source: rings)
            ringLayer.lineColor = NSExpression(forConstantValue: UIColor(red: 0.04, green: 0.31, blue: 0.54, alpha: 1))
            ringLayer.lineOpacity = NSExpression(forConstantValue: 0.35)
            ringLayer.lineWidth = NSExpression(forConstantValue: 1.5)
            ringLayer.lineDashPattern = NSExpression(forConstantValue: [3, 3])
            if let anchor {
                style.insertLayer(laneLayer, below: anchor)
                style.insertLayer(ringLayer, below: anchor)
            } else {
                style.addLayer(laneLayer)
                style.addLayer(ringLayer)
            }

            for stale in [true, false] {
                let l = MLNFillExtrusionStyleLayer(identifier: stale ? "cits-vehicles-stale" : "cits-vehicles", source: vehicles)
                l.predicate = NSPredicate(format: "stale == %@", NSNumber(value: stale))
                l.fillExtrusionColor = NSExpression(mglJSONObject: ["to-color", ["get", "color"]])
                l.fillExtrusionHeight = NSExpression(forKeyPath: "height")
                l.fillExtrusionBase = NSExpression(forConstantValue: 0)
                l.fillExtrusionOpacity = NSExpression(forConstantValue: stale ? 0.35 : 0.95)
                style.addLayer(l)
            }
            // Soft coloured glow under every vehicle so it stays visible when zoomed out.
            let glow = MLNCircleStyleLayer(identifier: "cits-glow", source: labels)
            glow.circleColor = NSExpression(mglJSONObject: ["to-color", ["get", "color"]])
            glow.circleRadius = NSExpression(forConstantValue: 14)
            glow.circleBlur = NSExpression(forConstantValue: 0.7)
            glow.circleOpacity = NSExpression(forConstantValue: 0.55)
            glow.circlePitchAlignment = NSExpression(forConstantValue: "map")
            if let first = style.layer(withIdentifier: "cits-vehicles-stale") { style.insertLayer(glow, below: first) } else { style.addLayer(glow) }
            let text = MLNSymbolStyleLayer(identifier: "cits-labels", source: labels)
            text.text = NSExpression(forKeyPath: "label")
            text.textFontNames = NSExpression(forConstantValue: ["Noto Sans Bold"])
            text.textFontSize = NSExpression(forConstantValue: 12)
            text.textColor = NSExpression(forConstantValue: UIColor(white: 0.12, alpha: 1))
            text.textHaloColor = NSExpression(forConstantValue: UIColor.white)
            text.textHaloWidth = NSExpression(forConstantValue: 1.6)
            text.textAnchor = NSExpression(forConstantValue: "bottom")
            text.textOffset = NSExpression(forConstantValue: NSValue(cgVector: CGVector(dx: 0, dy: -1.2)))
            text.textAllowsOverlap = NSExpression(forConstantValue: true)
            text.textIgnoresPlacement = NSExpression(forConstantValue: true)
            style.addLayer(text)

            lastLanes = []
            lastRingCenter = nil
            if let (s, t, b) = pending { update(s, topDown: t, showBuildings: b) }
        }

        // MARK: Data

        func update(_ s: Scene3DView.Snapshot3D, topDown: Bool, showBuildings: Bool) {
            pending = (s, topDown, showBuildings)
            guard let mapView, let style else { return }
            style.layer(withIdentifier: "building-3d")?.isVisible = showBuildings

            var bodies: [MLNShape & MLNFeature] = []
            var texts: [MLNShape & MLNFeature] = []
            // Real size when close; exaggerated up to 4x when the view spans hundreds of metres.
            let scale = topDown ? min(max(s.extent / 50, 1), 5) : min(max(s.extent / 70, 1), 4)
            if let ego = s.ego {
                bodies.append(Self.arrow(at: ego, heading: s.egoHeading, type: .passengerCar, color: "#1e6fd9", stale: false, id: 0, scale: scale))
                let p = MLNPointFeature()
                p.coordinate = ego
                p.attributes = ["label": "", "color": "#1e6fd9"]
                texts.append(p)
            }
            for b in s.bodies {
                let color = Self.color(for: b)
                bodies.append(Self.arrow(at: b.coordinate, heading: b.heading ?? 0, type: b.type, color: color, stale: b.stale, id: b.id, scale: scale))
                let p = MLNPointFeature()
                p.coordinate = b.coordinate
                p.attributes = ["label": b.label, "color": color]
                texts.append(p)
            }
            vehicles.shape = MLNShapeCollectionFeature(shapes: bodies)
            labels.shape = MLNShapeCollectionFeature(shapes: texts)

            if s.lanes != lastLanes {
                lastLanes = s.lanes
                lanes.shape = MLNShapeCollectionFeature(shapes: s.lanes.flatMap(Self.laneQuads))
            }
            if let c = s.ego ?? s.center, ringsNeedUpdate(for: c) {
                lastRingCenter = c
                rings.shape = MLNShapeCollectionFeature(shapes: [25.0, 50, 100, 200, 400].map { r in
                    var pts = (0...72).map { i -> CLLocationCoordinate2D in
                        let a = Double(i) / 72 * 2 * .pi
                        return Geo.offset(c, east: r * sin(a), north: r * cos(a))
                    }
                    return MLNPolylineFeature(coordinates: &pts, count: UInt(pts.count))
                })
            }

            // Camera: chase from behind the heading, looking a bit ahead, or straight down.
            guard let center = s.center, Date().timeIntervalSince(lastUserGesture) > 20 else { return }
            let e = min(max(s.extent, 40), 600)
            let look = topDown ? center : Geo.local(center, heading: s.egoHeading, forward: e * 0.35, right: 0)
            let camera = MLNMapCamera(lookingAtCenter: look, acrossDistance: topDown ? e * 2.6 : max(160, e * 1.7),
                                      pitch: topDown ? 0 : 60, heading: topDown ? 0 : s.egoHeading)
            let key = String(format: "%.6f,%.6f,%.0f,%.0f,%d", look.latitude, look.longitude, camera.altitude, camera.heading, topDown ? 1 : 0)
            guard key != lastCameraKey else { return }
            lastCameraKey = key
            mapView.setCamera(camera, withDuration: 0.5, animationTimingFunction: CAMediaTimingFunction(name: .linear))
        }

        private func ringsNeedUpdate(for c: CLLocationCoordinate2D) -> Bool {
            guard let last = lastRingCenter else { return true }
            let (x, z) = Geo.metres(from: last, to: c)
            return x * x + z * z > 4
        }

        @objc func tap(_ g: UITapGestureRecognizer) {
            guard let mapView = g.view as? MLNMapView else { return }
            let p = g.location(in: mapView)
            let rect = CGRect(x: p.x - 22, y: p.y - 22, width: 44, height: 44)
            let hits = mapView.visibleFeatures(in: rect, styleLayerIdentifiers: ["cits-vehicles", "cits-vehicles-stale"])
            if let id = hits.lazy.compactMap({ ($0.attribute(forKey: "id") as? NSNumber)?.uint32Value }).first(where: { $0 != 0 }) {
                onSelect(id)
            }
        }

        // MARK: Geometry

        private static func color(for b: Scene3DView.Body3D) -> String {
            if b.emergency { return "#e5352b" }
            if b.warning { return "#f59e0b" }
            switch b.type {
            case .passengerCar: return "#5b6570"
            case .bus, .tram: return "#e8b400"
            case .lightTruck, .heavyTruck, .trailer: return "#f07c1b"
            case .cyclist, .pedestrian: return "#0fa3a3"
            case .moped, .motorcycle: return "#8b5cf6"
            case .roadSideUnit: return "#22b04b"
            default: return "#8a94a0"
            }
        }

        /// Footprint with a pointed nose so the driving direction is visible from above, extruded to the vehicle height.
        private static func arrow(at c: CLLocationCoordinate2D, heading: Double, type: StationType?, color: String, stale: Bool, id: UInt32, scale: Double) -> MLNShape & MLNFeature {
            let (l0, w0, h0): (Double, Double, Double) = switch type {
            case .pedestrian: (1.2, 1.2, 1.8)
            case .cyclist: (2.2, 1.0, 1.7)
            case .moped, .motorcycle: (2.4, 1.1, 1.4)
            case .bus: (12, 2.55, 3.2)
            case .tram: (30, 2.65, 3.4)
            case .lightTruck: (6.5, 2.2, 2.8)
            case .heavyTruck, .trailer: (16, 2.55, 3.8)
            case .roadSideUnit: (1.2, 1.2, 6)
            default: (4.6, 1.9, 1.5)
            }
            let (l, w, h) = (l0 * scale, w0 * scale, h0 * scale)
            let ring: [(Double, Double)] = type == .roadSideUnit || type == .pedestrian
                ? [(-l / 2, -w / 2), (-l / 2, w / 2), (l / 2, w / 2), (l / 2, -w / 2)]
                : [(-l / 2, -w / 2), (-l / 2, w / 2), (l / 2 - w * 0.6, w / 2), (l / 2, 0), (l / 2 - w * 0.6, -w / 2)]
            var pts = ring.map { Geo.local(c, heading: heading, forward: $0.0, right: $0.1) }
            pts.append(pts[0])
            let f = MLNPolygonFeature(coordinates: &pts, count: UInt(pts.count))
            f.attributes = ["color": color, "height": h, "stale": stale, "id": NSNumber(value: id)]
            return f
        }

        /// One filled quad per lane segment, `width` metres wide.
        private static func laneQuads(_ lane: Scene3DView.Lane3D) -> [MLNShape & MLNFeature] {
            let ref = CLLocationCoordinate2D(latitude: lane.reference.x, longitude: lane.reference.y)
            return zip(lane.points, lane.points.dropFirst()).compactMap { a, b in
                let d = b - a
                let len = (d.x * d.x + d.y * d.y).squareRoot()
                guard len > 0.05 else { return nil }
                let n = SIMD2(-d.y, d.x) / len * (lane.width / 2)
                var pts = [a + n, b + n, b - n, a - n, a + n].map { Geo.offset(ref, east: $0.x, north: $0.y) }
                let f = MLNPolygonFeature(coordinates: &pts, count: UInt(pts.count))
                f.attributes = ["color": lane.color]
                return f
            }
        }
    }
}
