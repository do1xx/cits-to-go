import CoreLocation
import MapKit
import SceneKit
import SwiftUI
import UIKit

/// Tesla-style surround view: own position in the centre, received stations as 3D bodies,
/// MAPEM lanes on the ground coloured by the current SPATEM phase. Tap a body for details.
struct Scene3DView: View {
    @Environment(BridgeModel.self) private var model
    @Environment(LocationProvider.self) private var location
    @State private var topDown = false
    @AppStorage("scene3d.showMap") private var showMap = true
    @State private var selected: StationSelection?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let snap = snapshot(now: context.date)
            ZStack(alignment: .bottom) {
                SceneKitContainer(snapshot: snap, topDown: topDown, showMap: showMap) { selected = StationSelection(id: $0) }
                    .ignoresSafeArea(edges: .top)
                HStack {
                    Text(snap.caption).font(.caption).padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                    Spacer()
                    Button { showMap.toggle() } label: {
                        Image(systemName: showMap ? "map.fill" : "map")
                            .padding(10).background(.ultraThinMaterial, in: Circle())
                    }
                    .accessibilityLabel(showMap ? "Karte ausblenden" : "Karte einblenden")
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
        let x: Float, z: Float          // metres east / south of the origin
        let heading: Float?             // degrees, 0 = north
        let type: StationType?
        let emergency: Bool
        let label: String
        let stale: Bool
    }

    struct Lane3D: Equatable {
        let points: [SIMD2<Float>]      // (x, z)
        let width: Float
        let color: UIColor
    }

    struct Snapshot3D {
        var bodies: [Body3D] = []
        var lanes: [Lane3D] = []
        var egoHeading: Float = 0      // direction the camera looks (degrees)
        var extent: Float = 40          // distance to the farthest body (m), sizes the camera
        var hasEgo = false
        var origin: CLLocationCoordinate2D?  // geographic position of scene (0, 0)
        var caption = ""
    }

    private func snapshot(now: Date) -> Snapshot3D {
        var s = Snapshot3D()
        let recent = model.stations.values.filter { $0.coordinate != nil && now.timeIntervalSince($0.lastSeen) < 60 }
        let origin: CLLocationCoordinate2D
        var driving = false
        if let l = location.location, now.timeIntervalSince(l.timestamp) < 30 {
            origin = l.coordinate
            s.hasEgo = true
            if l.course >= 0, l.speed > 1 { s.egoHeading = Float(l.course); driving = true }
        } else if let first = recent.max(by: { $0.lastSeen < $1.lastSeen })?.coordinate {
            origin = first
        } else {
            s.caption = "Noch keine Stationen mit Position"
            return s
        }
        s.origin = origin
        let mPerDegLat = 111_320.0, mPerDegLon = 111_320.0 * cos(origin.latitude * .pi / 180)
        func local(_ c: CLLocationCoordinate2D) -> (Float, Float) {
            (Float((c.longitude - origin.longitude) * mPerDegLon), Float(-(c.latitude - origin.latitude) * mPerDegLat))
        }
        for st in recent {
            let (x, z) = local(st.coordinate!)
            guard x * x + z * z < 600 * 600 else { continue }
            let label = st.lastCam?.speedKmh.map { "\(Int($0.rounded())) km/h" }
                ?? (st.lastDenm != nil ? "Warnung" : (st.stationType?.label ?? st.lastType))
            s.bodies.append(Body3D(id: st.id, x: x, z: z, heading: st.headingDegrees.map(Float.init),
                                   type: st.stationType ?? (st.types.contains("SPATEM") || st.types.contains("MAPEM") ? .roadSideUnit : nil),
                                   emergency: st.emergency, label: label, stale: now.timeIntervalSince(st.lastSeen) > 10))
        }
        for snap in model.intersections {
            guard let map = snap.map else { continue }
            let phases = snap.spat?.movementsBySignalGroup ?? [:]
            let (ox, oz) = local(CLLocationCoordinate2D(latitude: map.latitude, longitude: map.longitude))
            guard ox * ox + oz * oz < 800 * 800 else { continue }
            for lane in map.lanes where lane.nodes.count >= 2 {
                let pts = lane.nodes.map { SIMD2<Float>(ox + Float($0.xCm) / 100, oz - Float($0.yCm) / 100) }
                let phase = lane.connections.lazy.compactMap { $0.signalGroup.flatMap { phases[$0]?.currentEvent?.state } }.first
                let color: UIColor = switch phase?.category {
                case .stop: .systemRed
                case .caution: .systemOrange
                case .go: .systemGreen
                default: lane.laneType == .crosswalk ? UIColor.white.withAlphaComponent(0.6) : UIColor(white: 0.45, alpha: 1)
                }
                s.lanes.append(Lane3D(points: pts, width: lane.laneType == .crosswalk ? 2.5 : 3.0, color: color))
            }
        }
        let live = s.bodies.filter { !$0.stale }.isEmpty ? s.bodies : s.bodies.filter { !$0.stale }
        if let far = live.map({ ($0.x * $0.x + $0.z * $0.z).squareRoot() }).max() { s.extent = max(40, far) }
        if !driving, !live.isEmpty {
            // Standing still: face the centre of what we receive instead of an arbitrary north.
            let cx = live.map(\.x).reduce(0, +) / Float(live.count), cz = live.map(\.z).reduce(0, +) / Float(live.count)
            if cx * cx + cz * cz > 25 { s.egoHeading = atan2(cx, -cz) * 180 / .pi }
        }
        s.caption = "\(s.bodies.count) Stationen im Umkreis von 600 m" + (s.hasEgo ? "" : " (ohne eigene Position)")
        return s
    }
}

private struct SceneKitContainer: UIViewRepresentable {
    let snapshot: Scene3DView.Snapshot3D
    let topDown: Bool
    let showMap: Bool
    let onSelect: (UInt32) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = context.coordinator.scene
        view.pointOfView = context.coordinator.camera
        view.antialiasingMode = .multisampling4X
        view.backgroundColor = UIColor(red: 0.08, green: 0.09, blue: 0.11, alpha: 1)
        view.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:))))
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.onSelect = onSelect
        context.coordinator.update(snapshot, topDown: topDown)
        context.coordinator.updateGroundMap(origin: snapshot.origin, visible: showMap)
    }

    @MainActor
    final class Coordinator: NSObject {
        let scene = SCNScene()
        let camera = SCNNode()
        private let ego = SCNNode()
        private let laneRoot = SCNNode()
        private var bodies: [UInt32: SCNNode] = [:]
        private var lastLanes: [Scene3DView.Lane3D] = []
        private let groundMap = SCNNode()
        private var mapCenter: CLLocationCoordinate2D?
        private var mapLoading = false
        private var mapLastAttempt = Date.distantPast
        private static let mapSize: Double = 2_000       // metres per side of the map texture
        var onSelect: (UInt32) -> Void

        init(onSelect: @escaping (UInt32) -> Void) {
            self.onSelect = onSelect
            super.init()
            let floor = SCNFloor()
            floor.reflectivity = 0
            floor.firstMaterial?.diffuse.contents = UIColor(red: 0.13, green: 0.14, blue: 0.16, alpha: 1)
            floor.firstMaterial?.writesToDepthBuffer = false
            let floorNode = SCNNode(geometry: floor)
            floorNode.renderingOrder = -2
            scene.rootNode.addChildNode(floorNode)
            // Street map under the scene; drawn right after the floor and without depth so lanes and rings stay on top.
            let plane = SCNPlane(width: Self.mapSize, height: Self.mapSize)
            plane.firstMaterial?.lightingModel = .constant
            plane.firstMaterial?.writesToDepthBuffer = false
            plane.firstMaterial?.diffuse.contents = UIColor.clear
            groundMap.geometry = plane
            groundMap.eulerAngles.x = -.pi / 2             // texture top points north (-z)
            groundMap.renderingOrder = -1
            groundMap.isHidden = true
            scene.rootNode.addChildNode(groundMap)
            let ambient = SCNNode(); ambient.light = SCNLight(); ambient.light?.type = .ambient; ambient.light?.intensity = 500
            let sun = SCNNode(); sun.light = SCNLight(); sun.light?.type = .directional; sun.light?.intensity = 800
            sun.eulerAngles = SCNVector3(-Float.pi / 3, Float.pi / 4, 0)
            scene.rootNode.addChildNode(ambient); scene.rootNode.addChildNode(sun)
            scene.rootNode.addChildNode(laneRoot)
            // Distance rings around the own position (25/50/100/200/400 m) with small labels.
            for r in [25, 50, 100, 200, 400] as [CGFloat] {
                let ring = SCNTorus(ringRadius: r, pipeRadius: r / 250)
                ring.firstMaterial?.diffuse.contents = UIColor(white: 1, alpha: 0.18)
                ring.firstMaterial?.lightingModel = .constant
                let node = SCNNode(geometry: ring)
                node.position.y = 0.03
                scene.rootNode.addChildNode(node)
                let t = SCNText(string: "\(Int(r)) m", extrusionDepth: 0)
                t.font = UIFont.systemFont(ofSize: r / 12, weight: .medium)
                t.firstMaterial?.diffuse.contents = UIColor(white: 1, alpha: 0.35)
                t.firstMaterial?.lightingModel = .constant
                let tn = SCNNode(geometry: t)
                tn.eulerAngles.x = -.pi / 2
                tn.position = SCNVector3(Float(r) + 1, 0.05, 0)
                scene.rootNode.addChildNode(tn)
            }
            camera.camera = SCNCamera(); camera.camera?.zFar = 2000; camera.camera?.fieldOfView = 60
            scene.rootNode.addChildNode(camera)
            ego.addChildNode(Self.vehicle(type: .passengerCar, color: .systemBlue))
            scene.rootNode.addChildNode(ego)
        }

        func update(_ s: Scene3DView.Snapshot3D, topDown: Bool) {
            ego.isHidden = !s.hasEgo
            ego.eulerAngles.y = -s.egoHeading * .pi / 180
            // Camera: chase from behind the ego heading, or straight down.
            let h = s.egoHeading * .pi / 180
            SCNTransaction.begin(); SCNTransaction.animationDuration = 0.5
            let e = min(max(s.extent, 40), 600)
            if topDown {
                camera.position = SCNVector3(0, e * 2.1, 0.01)
                camera.look(at: SCNVector3(0, 0, 0))
            } else {
                let back = min(max(e * 0.45, 22), 260)
                camera.position = SCNVector3(-sin(h) * back, back * 0.55, cos(h) * back)
                camera.look(at: SCNVector3(sin(h) * e * 0.5, 0, -cos(h) * e * 0.5))
            }
            SCNTransaction.commit()

            var seen = Set<UInt32>()
            for b in s.bodies {
                seen.insert(b.id)
                let node = bodies[b.id] ?? {
                    let n = SCNNode()
                    n.name = String(b.id)
                    scene.rootNode.addChildNode(n)
                    bodies[b.id] = n
                    return n
                }()
                if node.childNodes.isEmpty || node.value(forKey: "kind") as? String != "\(b.type?.rawValue ?? -1)-\(b.emergency)" {
                    node.childNodes.forEach { $0.removeFromParentNode() }
                    node.addChildNode(Self.vehicle(type: b.type, color: Self.color(for: b)))
                    node.setValue("\(b.type?.rawValue ?? -1)-\(b.emergency)", forKey: "kind")
                }
                Self.setLabel(on: node, text: b.label)
                SCNTransaction.begin(); SCNTransaction.animationDuration = 0.5
                node.position = SCNVector3(b.x, 0, b.z)
                if let hd = b.heading { node.childNodes.first?.eulerAngles.y = -hd * .pi / 180 }
                node.opacity = b.stale ? 0.35 : 1
                SCNTransaction.commit()
            }
            for (id, node) in bodies where !seen.contains(id) {
                node.removeFromParentNode()
                bodies[id] = nil
            }
            if s.lanes != lastLanes {
                lastLanes = s.lanes
                laneRoot.childNodes.forEach { $0.removeFromParentNode() }
                for lane in s.lanes { for n in Self.laneSegments(lane) { laneRoot.addChildNode(n) } }
            }
        }

        /// Keeps a dark Apple Maps snapshot under the scene. Re-rendered when the origin moves
        /// more than a quarter of the texture away from its centre; failed loads retry after 30 s.
        func updateGroundMap(origin: CLLocationCoordinate2D?, visible: Bool) {
            guard visible, let origin else { groundMap.isHidden = true; return }
            if let c = mapCenter {
                let dx = (c.longitude - origin.longitude) * 111_320 * cos(origin.latitude * .pi / 180)
                let dz = -(c.latitude - origin.latitude) * 111_320
                groundMap.position = SCNVector3(Float(dx), 0.01, Float(dz))
                groundMap.isHidden = false
                if (dx * dx + dz * dz).squareRoot() < Self.mapSize / 4 { return }
            }
            guard !mapLoading, Date().timeIntervalSince(mapLastAttempt) > 30 else { return }
            mapLoading = true
            mapLastAttempt = Date()
            let options = MKMapSnapshotter.Options()
            options.region = MKCoordinateRegion(center: origin, latitudinalMeters: Self.mapSize, longitudinalMeters: Self.mapSize)
            options.size = CGSize(width: 2_048, height: 2_048)
            options.scale = 1
            options.mapType = .mutedStandard
            options.pointOfInterestFilter = .excludingAll
            options.traitCollection = UITraitCollection(userInterfaceStyle: .dark)
            Task { @MainActor in
                defer { mapLoading = false }
                guard let shot = try? await MKMapSnapshotter(options: options).start() else { return }
                groundMap.geometry?.firstMaterial?.diffuse.contents = shot.image
                groundMap.geometry?.firstMaterial?.multiply.contents = UIColor(white: 0.8, alpha: 1)
                mapCenter = origin
                updateGroundMap(origin: origin, visible: true)
            }
        }

        @objc func tap(_ g: UITapGestureRecognizer) {
            guard let view = g.view as? SCNView else { return }
            for hit in view.hitTest(g.location(in: view), options: [.searchMode: SCNHitTestSearchMode.all.rawValue]) {
                var n: SCNNode? = hit.node
                while let cur = n, cur.name == nil || UInt32(cur.name!) == nil { n = cur.parent }
                if let name = n?.name, let id = UInt32(name) { onSelect(id); return }
            }
        }

        private static func color(for b: Scene3DView.Body3D) -> UIColor {
            if b.emergency { return .systemRed }
            switch b.type {
            case .passengerCar: return UIColor(white: 0.85, alpha: 1)
            case .bus, .tram: return .systemYellow
            case .lightTruck, .heavyTruck, .trailer: return .systemOrange
            case .cyclist, .pedestrian: return .systemTeal
            case .moped, .motorcycle: return .systemPurple
            case .roadSideUnit: return .systemGreen
            default: return .systemGray
            }
        }

        /// Simple body per station type; length along -z (forward).
        private static func vehicle(type: StationType?, color: UIColor) -> SCNNode {
            let (l, w, h): (CGFloat, CGFloat, CGFloat) = switch type {
            case .pedestrian: (0.5, 0.5, 1.8)
            case .cyclist: (1.8, 0.6, 1.7)
            case .moped, .motorcycle: (2.1, 0.8, 1.4)
            case .bus: (12, 2.55, 3.2)
            case .tram: (30, 2.65, 3.4)
            case .lightTruck: (6.5, 2.2, 2.8)
            case .heavyTruck, .trailer: (16, 2.55, 3.8)
            case .roadSideUnit: (0.4, 0.4, 5.5)
            default: (4.5, 1.85, 1.5)
            }
            let box = SCNBox(width: w, height: h, length: l, chamferRadius: min(w, h) * 0.2)
            let m = SCNMaterial(); m.diffuse.contents = color; m.lightingModel = .physicallyBased; m.roughness.contents = 0.5
            box.materials = [m]
            let node = SCNNode(geometry: box)
            node.position.y = Float(h / 2)
            let root = SCNNode()
            root.addChildNode(node)
            if type != .roadSideUnit, type != .pedestrian {       // windscreen marker shows the front
                let front = SCNBox(width: w * 0.8, height: h * 0.3, length: 0.05, chamferRadius: 0)
                front.firstMaterial?.diffuse.contents = UIColor.black.withAlphaComponent(0.7)
                let fn = SCNNode(geometry: front); fn.position = SCNVector3(0, Float(h * 0.75), Float(-l / 2) - 0.03)
                root.addChildNode(fn)
            }
            return root
        }

        private static func setLabel(on node: SCNNode, text: String) {
            if let existing = node.childNode(withName: "label", recursively: false), existing.value(forKey: "text") as? String == text { return }
            node.childNode(withName: "label", recursively: false)?.removeFromParentNode()
            let t = SCNText(string: text, extrusionDepth: 0)
            t.font = UIFont.systemFont(ofSize: 3, weight: .bold)
            t.flatness = 0.05
            t.firstMaterial?.diffuse.contents = UIColor.white
            t.firstMaterial?.lightingModel = .constant
            let n = SCNNode(geometry: t)
            n.name = "label"
            n.setValue(text, forKey: "text")
            let (minB, maxB) = t.boundingBox
            n.pivot = SCNMatrix4MakeTranslation((maxB.x - minB.x) / 2 + minB.x, 0, 0)
            n.position.y = 6
            n.constraints = [SCNBillboardConstraint()]
            node.addChildNode(n)
        }

        private static func laneSegments(_ lane: Scene3DView.Lane3D) -> [SCNNode] {
            zip(lane.points, lane.points.dropFirst()).map { a, b in
                let d = b - a
                let len = CGFloat(max(0.1, (d.x * d.x + d.y * d.y).squareRoot()))
                let plane = SCNBox(width: CGFloat(lane.width), height: 0.02, length: len, chamferRadius: 0)
                plane.firstMaterial?.diffuse.contents = lane.color
                plane.firstMaterial?.lightingModel = .constant
                let n = SCNNode(geometry: plane)
                n.position = SCNVector3((a.x + b.x) / 2, 0.02, (a.y + b.y) / 2)
                n.eulerAngles.y = atan2(d.x, d.y)
                return n
            }
        }
    }
}
