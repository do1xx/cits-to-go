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
    @State private var recenter = 0
    @State private var following = true
    @AppStorage("scene3d.buildings") private var showBuildings = true

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let snap = snapshot(now: context.date)
            ZStack(alignment: .bottom) {
                MapLibre3DContainer(snapshot: snap, topDown: topDown, showBuildings: showBuildings, recenterToken: recenter,
                                    onFollowingChange: { following = $0 }) { selected = StationSelection(id: $0) }
                    .ignoresSafeArea(edges: .top)
                HStack {
                    Text(snap.caption).font(.caption).padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                    Spacer()
                    Button { recenter += 1 } label: {
                        Image(systemName: following ? "location.north.line.fill" : "location")
                            .padding(10).background(.ultraThinMaterial, in: Circle())
                    }
                    .accessibilityLabel(following ? "Folgt deiner Position" : "Auf mich zentrieren")
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
        var egoSpeedKmh: Double = 0
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
            s.egoSpeedKmh = max(0, l.speed) * 3.6
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
    let recenterToken: Int
    let onFollowingChange: (Bool) -> Void
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
        context.coordinator.onFollowingChange = onFollowingChange
        context.coordinator.recenter(token: recenterToken)
        context.coordinator.update(snapshot, topDown: topDown, showBuildings: showBuildings)
    }

    @MainActor
    final class Coordinator: NSObject, MLNMapViewDelegate {
        weak var mapView: MLNMapView?
        var onSelect: (UInt32) -> Void
        var onFollowingChange: ((Bool) -> Void)?
        private var recenterToken = 0
        private var reportedFollowing: Bool?
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
        private var lastZoomChange = Date.distantPast
        private var lastTopDown: Bool?
        private var triedFallback = false

        init(onSelect: @escaping (UInt32) -> Void) { self.onSelect = onSelect }

        /// Standort-Knopf: snap back to following the own position immediately.
        func recenter(token: Int) {
            guard token != recenterToken else { return }
            recenterToken = token
            lastUserGesture = .distantPast
            lastTopDown = nil
            lastCameraKey = ""
        }

        private func reportFollowing(_ value: Bool) {
            guard value != reportedFollowing else { return }
            reportedFollowing = value
            let callback = onFollowingChange
            DispatchQueue.main.async { callback?(value) }
        }

        // Own position: navigation arrow instead of the default dot.
        nonisolated func mapView(_ mapView: MLNMapView, viewFor annotation: MLNAnnotation) -> MLNAnnotationView? {
            MainActor.assumeIsolated {
                guard annotation is MLNUserLocation else { return nil }
                return mapView.dequeueReusableAnnotationView(withIdentifier: NavArrowView.reuseId) ?? NavArrowView(reuseIdentifier: NavArrowView.reuseId)
            }
        }

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
                l.fillExtrusionBase = NSExpression(forKeyPath: "base")
                l.fillExtrusionOpacity = NSExpression(forConstantValue: stale ? 0.45 : 1.0)
                style.addLayer(l)
            }
            // Soft coloured glow under every vehicle so it stays visible when zoomed out.
            let glow = MLNCircleStyleLayer(identifier: "cits-glow", source: labels)
            glow.circleColor = NSExpression(mglJSONObject: ["to-color", ["get", "color"]])
            glow.circleRadius = NSExpression(forConstantValue: 20)
            glow.circleBlur = NSExpression(forConstantValue: 0.7)
            glow.circleOpacity = NSExpression(forConstantValue: 0.55)
            glow.circlePitchAlignment = NSExpression(forConstantValue: "map")
            if let first = style.layer(withIdentifier: "cits-vehicles-stale") { style.insertLayer(glow, below: first) } else { style.addLayer(glow) }
            let text = MLNSymbolStyleLayer(identifier: "cits-labels", source: labels)
            text.text = NSExpression(forKeyPath: "label")
            text.textFontNames = NSExpression(forConstantValue: ["Noto Sans Bold"])
            text.textFontSize = NSExpression(forConstantValue: 13)
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
            // Always drawn about twice real size so they read well on the phone; more when zoomed out.
            let scale = min(max(pow(2, 18.4 - mapView.zoomLevel) * 1.9, 1.9), 6)
            for b in s.bodies {
                let color = Self.color(for: b)
                bodies += Self.vehicle(at: b.coordinate, heading: b.heading ?? 0, type: b.type, color: color, stale: b.stale, id: b.id, scale: scale)
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

            if s.ego != nil {
                navigationCamera(mapView, speedKmh: s.egoSpeedKmh, topDown: topDown)
            } else {
                stationCamera(mapView, s, topDown: topDown)
            }
        }

        /// Like a car navigation system: MapLibre follows the GPS itself (smoothly interpolated),
        /// the map turns with the driving direction, the own arrow sits in the lower part of the
        /// screen and the zoom depends on the speed. After a gesture it snaps back after 15 s,
        /// or at once with the Standort-Knopf.
        private func navigationCamera(_ mapView: MLNMapView, speedKmh: Double, topDown: Bool) {
            if !mapView.showsUserLocation {
                mapView.locationManager.setDesiredAccuracy?(kCLLocationAccuracyBestForNavigation)
                mapView.locationManager.setActivityType?(.automotiveNavigation)
                mapView.showsUserHeadingIndicator = false
                mapView.showsUserLocation = true
            }
            let inset = topDown ? 0 : mapView.bounds.height * 0.38
            if abs(mapView.contentInset.top - inset) > 1 {
                mapView.setContentInset(UIEdgeInsets(top: inset, left: 0, bottom: 0, right: 0), animated: true, completionHandler: nil)
            }
            let idle = Date().timeIntervalSince(lastUserGesture) > 15
            reportFollowing(mapView.userTrackingMode != .none)
            let wanted: MLNUserTrackingMode = topDown ? .follow : .followWithCourse
            if (mapView.userTrackingMode != wanted || lastTopDown != topDown) && idle {
                lastTopDown = topDown
                let cam = mapView.camera.copy() as! MLNMapCamera
                cam.pitch = topDown ? 0 : 60
                if topDown { cam.heading = 0 }
                cam.altitude = MLNAltitudeForZoomLevel(Self.zoom(forKmh: speedKmh, topDown: topDown), cam.pitch,
                                                       mapView.centerCoordinate.latitude, mapView.bounds.size)
                mapView.setCamera(cam, animated: false)
                mapView.setUserTrackingMode(wanted, animated: false, completionHandler: nil)
                lastZoomChange = Date()
                return
            }
            // Faster → further ahead; only small, rare steps so the picture stays calm.
            let target = Self.zoom(forKmh: speedKmh, topDown: topDown)
            if idle, abs(mapView.zoomLevel - target) > 0.3, Date().timeIntervalSince(lastZoomChange) > 4 {
                lastZoomChange = Date()
                mapView.setZoomLevel(target, animated: true)
            }
        }

        private static func zoom(forKmh v: Double, topDown: Bool) -> Double {
            (topDown ? 17.2 : 18.4) - min(max((v - 15) / 35, 0), 2.2)  // 18.4 slow … 16.2 on the motorway
        }

        /// Without an own position: chase camera over the received stations, as before.
        private func stationCamera(_ mapView: MLNMapView, _ s: Scene3DView.Snapshot3D, topDown: Bool) {
            if mapView.showsUserLocation {
                mapView.userTrackingMode = .none
                mapView.showsUserLocation = false
                mapView.setContentInset(.zero, animated: false, completionHandler: nil)
            }
            reportFollowing(Date().timeIntervalSince(lastUserGesture) > 20)
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
            case .passengerCar: return "#2f3b4c"
            case .bus, .tram: return "#e8b400"
            case .lightTruck, .heavyTruck, .trailer: return "#f07c1b"
            case .cyclist, .pedestrian: return "#0fa3a3"
            case .moped, .motorcycle: return "#8b5cf6"
            case .roadSideUnit: return "#22b04b"
            default: return "#5b6570"
            }
        }

        /// Simple low-poly vehicle from stacked extrusions: body, dark glass cabin set back from
        /// the front (shows the driving direction) and headlights. `scale` enlarges it for legibility.
        private static func vehicle(at c: CLLocationCoordinate2D, heading: Double, type: StationType?, color: String,
                                    stale: Bool, id: UInt32, scale k: Double) -> [MLNShape & MLNFeature] {
            let glass = "#0e1520", light = "#fff3c4"
            func part(_ ring: [(Double, Double)], _ base: Double, _ top: Double, _ col: String) -> MLNShape & MLNFeature {
                var pts = ring.map { Geo.local(c, heading: heading, forward: $0.0 * k, right: $0.1 * k) }
                pts.append(pts[0])
                let f = MLNPolygonFeature(coordinates: &pts, count: UInt(pts.count))
                f.attributes = ["color": col, "base": base * k, "height": top * k, "stale": stale, "id": NSNumber(value: id)]
                return f
            }
            func rounded(_ l: Double, _ w: Double, r: Double, from: Double = 0) -> [(Double, Double)] {
                // Rectangle from `from - l/2` to `from + l/2` (forward) and ±w/2 with corner radius r.
                var ring: [(Double, Double)] = []
                let corners = [(l / 2 - r, w / 2 - r, 0.0), (-l / 2 + r, w / 2 - r, 90.0), (-l / 2 + r, -w / 2 + r, 180.0), (l / 2 - r, -w / 2 + r, 270.0)]
                for (cx, cy, start) in corners {
                    for i in 0...4 {
                        let a = (start + Double(i) * 22.5) * .pi / 180
                        ring.append((from + cx + r * cos(a), cy + r * sin(a)))
                    }
                }
                return ring
            }
            func octagon(_ d: Double) -> [(Double, Double)] {
                (0..<8).map { i in let a = Double(i) * .pi / 4; return (d / 2 * cos(a), d / 2 * sin(a)) }
            }
            switch type {
            case .pedestrian:
                return [part(octagon(0.6), 0, 1.2, color), part(octagon(0.35), 1.2, 1.8, color)]
            case .cyclist, .moped, .motorcycle:
                let l = type == .cyclist ? 1.9 : 2.2
                return [part(rounded(l, 0.5, r: 0.2), 0, 0.9, color), part(octagon(0.5), 0.9, 1.75, color)]
            case .roadSideUnit:
                return [part(octagon(0.35), 0, 5.2, "#6b7580"), part(rounded(0.9, 0.5, r: 0.1), 5.2, 6.2, color)]
            case .bus, .tram:
                let l = type == .tram ? 30.0 : 12.0, w = 2.55
                return [part(rounded(l, w, r: 0.35), 0, 1.0, color),
                        part(rounded(l - 0.2, w - 0.1, r: 0.3), 1.0, 2.4, glass),
                        part(rounded(l, w, r: 0.35), 2.4, 3.2, color),
                        part(rounded(0.12, w * 0.8, r: 0.05, from: l / 2), 0.5, 0.9, light)]
            case .lightTruck, .heavyTruck, .trailer:
                let l = type == .lightTruck ? 6.5 : 16.0, w = type == .lightTruck ? 2.2 : 2.55, cab = 2.3
                return [part(rounded(cab, w, r: 0.3, from: l / 2 - cab / 2), 0, 1.7, color),
                        part(rounded(cab * 0.6, w - 0.2, r: 0.2, from: l / 2 - cab * 0.35), 1.7, 2.9, glass),
                        part(rounded(l - cab - 0.3, w, r: 0.15, from: -cab / 2 - 0.15), 0, 3.6, "#dfe3e8"),
                        part(rounded(0.12, w * 0.8, r: 0.05, from: l / 2), 0.6, 1.0, light)]
            default:
                let l = 4.6, w = 1.9
                return [part(rounded(l, w, r: 0.45), 0, 0.85, color),
                        part(rounded(l * 0.5, w * 0.84, r: 0.35, from: -l * 0.08), 0.85, 1.45, glass),
                        part(rounded(0.12, w * 0.75, r: 0.05, from: l / 2), 0.45, 0.7, light)]
            }
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

/// Navigation arrow for the own position: turns with the driving direction and tilts with the
/// map, so it lies flat on the road like in a car navigation system.
private final class NavArrowView: MLNUserLocationAnnotationView {
    static let reuseId = "cits-nav-arrow"
    private let arrow = CAShapeLayer()
    private var lastCourse: Double = 0

    override func update() {
        if frame.size == .zero {
            frame = CGRect(x: 0, y: 0, width: 54, height: 54)
            setNeedsLayout()
        }
        if arrow.superlayer == nil {
            let p = UIBezierPath()
            p.move(to: CGPoint(x: 27, y: 4))
            p.addLine(to: CGPoint(x: 47, y: 48))
            p.addLine(to: CGPoint(x: 27, y: 37))
            p.addLine(to: CGPoint(x: 7, y: 48))
            p.close()
            arrow.frame = CGRect(x: 0, y: 0, width: 54, height: 54)
            arrow.path = p.cgPath
            arrow.fillColor = UIColor(red: 0.12, green: 0.44, blue: 0.85, alpha: 1).cgColor
            arrow.strokeColor = UIColor.white.cgColor
            arrow.lineWidth = 3.5
            arrow.lineJoin = .round
            arrow.shadowColor = UIColor.black.cgColor
            arrow.shadowOpacity = 0.35
            arrow.shadowRadius = 4
            arrow.shadowOffset = CGSize(width: 0, height: 2)
            layer.addSublayer(arrow)
        }
        guard let mapView else { return }
        if let course = userLocation?.location?.course, course >= 0 { lastCourse = course }
        var t = CATransform3DIdentity
        t.m34 = -1 / 400
        t = CATransform3DRotate(t, CGFloat(mapView.camera.pitch * .pi / 180), 1, 0, 0)
        t = CATransform3DRotate(t, CGFloat((lastCourse - mapView.direction) * .pi / 180), 0, 0, 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arrow.transform = t
        CATransaction.commit()
    }
}
