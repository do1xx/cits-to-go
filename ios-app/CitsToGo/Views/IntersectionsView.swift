import CoreLocation
import SwiftUI

struct IntersectionsView: View {
    @Environment(BridgeModel.self) private var model
    @Environment(LocationProvider.self) private var location
    @Environment(AssistantModel.self) private var assistant
    @AppStorage("intersections.sortByDistance") private var sortByDistance = false
    @State private var selection: IntersectionKey?

    private var sorted: [IntersectionSnapshot] {
        guard sortByDistance, let loc = location.location else { return model.intersections }
        return model.intersections.sorted {
            ($0.map?.distance(latitude: loc.coordinate.latitude, longitude: loc.coordinate.longitude) ?? .infinity) <
            ($1.map?.distance(latitude: loc.coordinate.latitude, longitude: loc.coordinate.longitude) ?? .infinity)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if sorted.isEmpty {
                    emptyState
                } else {
                    VStack(spacing: 0) {
                    if let advice = assistant.advice {
                        SignalAdviceCard(advice: advice)
                            .padding(.horizontal).padding(.vertical, 8)
                            .background(Color(.secondarySystemGroupedBackground))
                    }
                    TabView(selection: $selection) {
                        ForEach(sorted) { snapshot in
                            ScrollView {
                                IntersectionCard(snapshot: snapshot, userLocation: location.location)
                                    .padding(.horizontal)
                                    .padding(.bottom, 40)
                            }
                            .tag(Optional(snapshot.key))
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: sorted.count > 1 ? .always : .never))
                    .indexViewStyle(.page(backgroundDisplayMode: .always))
                    }
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(sorted.count > 1 ? "Kreuzungen (\(sorted.count))" : "Kreuzung")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if sorted.count > 1 {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Picker("Sortierung", selection: $sortByDistance) {
                                Text("Zuerst empfangen").tag(false)
                                Text("Entfernung").tag(true)
                            }
                        } label: { Image(systemName: "arrow.up.arrow.down") }
                    }
                }
            }
        }
        .onAppear { location.start() }
        .onDisappear { location.stop() }
    }

    private var emptyState: some View {
        let d = model.intersectionDiagnostics
        return ContentUnavailableView {
            Label("Warte auf MAPEM/SPATEM", systemImage: "light.beacon.max")
        } description: {
            VStack(spacing: 6) {
                Text(model.linkState.isStreaming
                     ? "Sobald eine Ampel in Reichweite ist, erscheint hier die Kreuzung mit Signalphasen."
                     : "Empfänger ist nicht verbunden.")
                if d.mapemSeen + d.spatemSeen > 0 {
                    Text("MAPEM \(d.mapemDecoded)/\(d.mapemSeen) · SPATEM \(d.spatemDecoded)/\(d.spatemSeen) dekodiert")
                        .font(.caption.monospacedDigit())
                }
                if let e = d.lastDecodeError { Text(e).font(.caption2).foregroundStyle(.secondary) }
            }
        }
    }
}

// MARK: - Card

struct IntersectionCard: View {
    let snapshot: IntersectionSnapshot
    let userLocation: CLLocation?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(alignment: .leading, spacing: 4) {
                    Text(snapshot.title).font(.headline)
                    Text(subtitle(now: context.date)).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let map = snapshot.map {
                IntersectionCanvas(map: map, spat: snapshot.spat, userLocation: userLocation)
                    .frame(height: 420)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                let signalized = map.lanes.reduce(0) { $0 + $1.connections.filter { $0.signalGroup != nil }.count }
                Text("\(map.lanes.count) Spuren · \(signalized) signalisierte Verbindungen · Zoomen mit zwei Fingern, Doppeltipp setzt zurück")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("SPATEM empfangen – warte auf passende MAPEM-Geometrie.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if let spat = snapshot.spat {
                SignalPhaseTable(spat: spat)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func subtitle(now: Date) -> String {
        var parts = ["id \(snapshot.key)"]
        let age = Int(max(0, now.timeIntervalSince(snapshot.updatedAt)))
        parts.append(age < 2 ? "gerade eben" : "vor \(age) s")
        if let map = snapshot.map, let loc = userLocation {
            let d = map.distance(latitude: loc.coordinate.latitude, longitude: loc.coordinate.longitude)
            parts.append(d < 1000 ? "\(Int(d)) m entfernt" : String(format: "%.1f km entfernt", d / 1000))
        }
        return parts.joined(separator: " · ")
    }
}

struct SignalPhaseTable: View {
    let spat: SpatIntersection

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            VStack(alignment: .leading, spacing: 8) {
                Text("Signalphasen").font(.headline)
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow {
                        Text("Gruppe"); Text("Phase"); Text("Wechsel in")
                    }
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(spat.movements.sorted { $0.signalGroup < $1.signalGroup }, id: \.signalGroup) { m in
                        GridRow {
                            Text("SG \(m.signalGroup)").font(.subheadline.weight(.semibold).monospacedDigit())
                            HStack(spacing: 6) {
                                Circle().fill(PhaseColors.color(m.currentEvent?.state)).frame(width: 10, height: 10)
                                Text(m.currentEvent?.state.label ?? "–").font(.subheadline)
                            }
                            HStack(spacing: 6) {
                                Text(m.currentEvent.flatMap { spat.secondsUntilChange($0, now: context.date) }.map { "\($0) s" } ?? "–")
                                    .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                                if let v = m.currentEvent?.advisorySpeedKmh {
                                    Text("\(v) km/h").font(.caption.weight(.semibold))
                                        .padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(Capsule().fill(PhaseColors.go.opacity(0.18)))
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

enum PhaseColors {
    static let stop = Color(red: 0.863, green: 0.149, blue: 0.149)      // #DC2626
    static let caution = Color(red: 0.851, green: 0.467, blue: 0.024)   // #D97706
    static let go = Color(red: 0.086, green: 0.639, blue: 0.290)        // #16A34A
    static let unknown = Color(red: 0.392, green: 0.455, blue: 0.545)   // #64748B

    static func color(_ state: MovementPhaseState?) -> Color {
        switch state?.category {
        case .stop: stop
        case .caution: caution
        case .go: go
        default: unknown
        }
    }

    static func base(_ type: LaneType) -> Color {
        switch type {
        case .vehicle: Color(red: 0.200, green: 0.255, blue: 0.333)        // #334155
        case .crosswalk: Color(red: 0.486, green: 0.227, blue: 0.929)      // #7C3AED
        case .bike: Color(red: 0.031, green: 0.569, blue: 0.698)           // #0891B2
        case .sidewalk: Color(red: 0.392, green: 0.455, blue: 0.545)       // #64748B
        case .trackedVehicle: Color(red: 0.631, green: 0.384, blue: 0.027) // #A16207
        case .parking: Color(red: 0.278, green: 0.333, blue: 0.412)        // #475569
        case .median, .striping, .other: Color(red: 0.580, green: 0.639, blue: 0.722) // #94A3B8
        }
    }
}

// MARK: - Canvas renderer (port of the Android IntersectionRenderer)

struct IntersectionCanvas: View {
    let map: MapIntersection
    let spat: SpatIntersection?
    let userLocation: CLLocation?

    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1
    @GestureState private var drag: CGSize = .zero

    private static let background = Color(red: 0.973, green: 0.980, blue: 0.988) // #F8FAFC

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            Canvas { ctx, size in
                draw(ctx: ctx, size: size, now: context.date)
            }
        }
        .background(Self.background)
        .contentShape(Rectangle())
        .gesture(
            SimultaneousGesture(
                MagnifyGesture()
                    .updating($pinch) { v, s, _ in s = v.magnification }
                    .onEnded { v in zoom = min(8, max(1, zoom * v.magnification)) },
                DragGesture(minimumDistance: 4)
                    .updating($drag) { v, s, _ in s = v.translation }
                    .onEnded { v in pan.width += v.translation.width; pan.height += v.translation.height }
            )
        )
        .onTapGesture(count: 2) { withAnimation { zoom = 1; pan = .zero } }
    }

    private struct Style {
        var width: CGFloat
        var dash: [CGFloat] = []
        var backing: CGFloat? = nil
        var backingOpacity: Double = 0.84
        var centerGap: CGFloat? = nil
        var idleOpacity: Double = 0.72
    }

    private func style(_ type: LaneType) -> Style {
        switch type {
        case .vehicle: Style(width: 4.5, idleOpacity: 0.58)
        case .crosswalk: Style(width: 5, dash: [10, 8], backing: 8, backingOpacity: 0.76, idleOpacity: 0.76)
        case .bike: Style(width: 3.5, dash: [2, 7], backing: 5.5, backingOpacity: 0.58, idleOpacity: 0.42)
        case .sidewalk: Style(width: 3, dash: [16, 8], backing: 5, backingOpacity: 0.5, idleOpacity: 0.28)
        case .median: Style(width: 6, dash: [18, 10], idleOpacity: 0.22)
        case .striping: Style(width: 2.5, dash: [10, 4, 2, 4], idleOpacity: 0.28)
        case .trackedVehicle: Style(width: 6, backing: 8, backingOpacity: 0.54, centerGap: 3, idleOpacity: 0.4)
        case .parking: Style(width: 3, dash: [6, 6], idleOpacity: 0.25)
        case .other: Style(width: 2.5, dash: [4, 8], idleOpacity: 0.22)
        }
    }

    private func renderOrder(_ t: LaneType) -> Int {
        switch t {
        case .median: 0
        case .striping: 1
        case .parking: 2
        case .sidewalk: 3
        case .bike: 4
        case .trackedVehicle: 5
        case .vehicle: 6
        case .other: 7
        case .crosswalk: 8
        }
    }

    private func draw(ctx: GraphicsContext, size: CGSize, now: Date) {
        let lanes = map.lanes.filter { $0.nodes.count >= 2 }
        let all = lanes.flatMap(\.nodes)
        guard !all.isEmpty else { return }
        // Approach lanes can run hundreds of metres out; fit to the core (5th–95th percentile of
        // nodes, at least ±40 m around the reference point) so the junction itself stays readable.
        func range(_ v: [Int]) -> (CGFloat, CGFloat) {
            let s = v.sorted()
            let lo = s[Int(Double(s.count - 1) * 0.05)], hi = s[Int(Double(s.count - 1) * 0.95)]
            return (CGFloat(min(lo, -4000)), CGFloat(max(hi, 4000)))
        }
        let (minX, maxX) = range(all.map(\.xCm))
        let (minY, maxY) = range(all.map(\.yCm))
        let padding: CGFloat = 28
        let fit = min((size.width - padding * 2) / max(1, maxX - minX), (size.height - padding * 2) / max(1, maxY - minY))
        let z = min(8, max(1, zoom * pinch))
        let offset = CGSize(width: pan.width + drag.width, height: pan.height + drag.height)
        // Centre the fitted drawing, then zoom around the view centre.
        let drawnW = (maxX - minX) * fit, drawnH = (maxY - minY) * fit
        let originX = (size.width - drawnW) / 2, originY = (size.height - drawnH) / 2

        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            let bx = originX + (x - minX) * fit
            let by = originY + drawnH - (y - minY) * fit
            return CGPoint(x: (bx - size.width / 2) * z + size.width / 2 + offset.width,
                           y: (by - size.height / 2) * z + size.height / 2 + offset.height)
        }
        func point(_ n: LaneNode) -> CGPoint { point(CGFloat(n.xCm), CGFloat(n.yCm)) }

        let phases = spat?.movementsBySignalGroup ?? [:]
        let lanesById = Dictionary(lanes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        func lanePath(_ lane: MapLane) -> Path {
            var p = Path()
            p.move(to: point(lane.nodes[0]))
            for n in lane.nodes.dropFirst() { p.addLine(to: point(n)) }
            return p
        }

        func stroke(_ path: Path, _ s: Style, _ color: Color, _ opacity: Double) {
            if let b = s.backing {
                ctx.stroke(path, with: .color(.white.opacity(s.backingOpacity * opacity)),
                           style: StrokeStyle(lineWidth: b, lineCap: .round, lineJoin: .round, dash: s.dash))
            }
            ctx.stroke(path, with: .color(color.opacity(opacity)),
                       style: StrokeStyle(lineWidth: s.width, lineCap: .round, lineJoin: .round, dash: s.dash))
            if let g = s.centerGap {
                ctx.stroke(path, with: .color(Self.background),
                           style: StrokeStyle(lineWidth: g, lineCap: .round, lineJoin: .round, dash: s.dash))
            }
        }

        /// Current phase of the first SPAT-known signal group on this lane's own connections.
        func lanePhase(_ lane: MapLane) -> MovementPhaseState? {
            lane.connections.lazy.compactMap { $0.signalGroup.flatMap { phases[$0]?.currentEvent?.state } }.first
        }

        // 1. Lanes
        for lane in lanes.sorted(by: { renderOrder($0.laneType) < renderOrder($1.laneType) }) {
            let s = style(lane.laneType)
            if let phase = lanePhase(lane) {
                stroke(lanePath(lane), s, PhaseColors.color(phase), 0.95)
            } else {
                stroke(lanePath(lane), s, PhaseColors.base(lane.laneType), s.idleOpacity)
            }
        }

        // 2. Connections through the intersection (bezier between closest lane ends)
        var drawn = Set<[Int]>()
        for lane in lanes {
            for c in lane.connections where c.remoteIntersection == nil {
                guard let other = lanesById[c.laneId] else { continue }
                let signalized = c.signalGroup.map { phases[$0] != nil } ?? false
                let tracked = lane.laneType == .trackedVehicle || other.laneType == .trackedVehicle
                guard signalized || tracked else { continue }
                guard drawn.insert([min(lane.id, other.id), max(lane.id, other.id)]).inserted else { continue }

                let ends: (MapLane) -> [(CGPoint, CGPoint)] = { l in
                    [(point(l.nodes[0]), point(l.nodes[1])),
                     (point(l.nodes[l.nodes.count - 1]), point(l.nodes[l.nodes.count - 2]))]
                }
                var best: ((CGPoint, CGPoint), (CGPoint, CGPoint))?
                var bestDist = CGFloat.infinity
                for a in ends(lane) { for b in ends(other) {
                    let d = hypot(a.0.x - b.0.x, a.0.y - b.0.y)
                    if d < bestDist { bestDist = d; best = (a, b) }
                } }
                guard let (start, end) = best else { continue }
                let cp = controlPoints(start: start, end: end, maxDistance: 96 * z)
                var path = Path()
                path.move(to: start.0)
                path.addCurve(to: end.0, control1: cp.0, control2: cp.1)
                var s = style(lane.laneType)
                if lane.laneType == .vehicle { s.dash = [7, 6] }
                let color = c.signalGroup.flatMap { phases[$0]?.currentEvent?.state }.map(PhaseColors.color) ?? PhaseColors.base(lane.laneType)
                stroke(path, s, color, 0.8)
            }
        }

        // 3. Countdown labels, one per signal group, collision-avoided
        if let spat {
            var occupied: [CGRect] = []
            var representatives: [(Int, MapLane)] = []
            var seen = Set<Int>()
            let candidates = lanes.sorted { ($0.ingress ? 0 : 1, $0.id) < ($1.ingress ? 0 : 1, $1.id) }
            for lane in candidates {
                for c in lane.connections {
                    guard let sg = c.signalGroup, phases[sg] != nil, seen.insert(sg).inserted else { continue }
                    representatives.append((sg, lane))
                }
            }
            for (sg, lane) in representatives.sorted(by: { $0.0 < $1.0 }) {
                guard let event = phases[sg]?.currentEvent, let seconds = spat.secondsUntilChange(event, now: now) else { continue }
                let text = ctx.resolve(Text("\(seconds)s").font(.system(size: 12, weight: .bold)).foregroundColor(.white))
                let ts = text.measure(in: size)
                let w = ts.width + 12, h = ts.height + 6
                let a = point(lane.nodes[0]), b = point(lane.nodes[lane.nodes.count - 1])
                let preferred = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                guard let rect = placeLabel(at: preferred, width: w, height: h, in: size, occupied: occupied) else { continue }
                occupied.append(rect)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 5), with: .color(PhaseColors.color(event.state).opacity(0.94)))
                ctx.draw(text, at: CGPoint(x: rect.midX, y: rect.midY))
            }
        }

        // 4. User position
        if let loc = userLocation {
            let o = map.localOffsetCm(latitude: loc.coordinate.latitude, longitude: loc.coordinate.longitude)
            let margin = CGFloat(max(150, (map.laneWidthCm ?? 300) / 2))
            let inside = o.x >= minX - margin && o.x <= maxX + margin && o.y >= minY - margin && o.y <= maxY + margin
            let blue = Color(red: 0.145, green: 0.388, blue: 0.922)
            let p = point(CGFloat(o.x), CGFloat(o.y))
            if inside && size.width > 0 && CGRect(origin: .zero, size: size).contains(p) {
                let r = min(48, max(10, CGFloat(loc.horizontalAccuracy) * 100 * fit * z))
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)), with: .color(blue.opacity(0.1)))
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 8, y: p.y - 8, width: 16, height: 16)), with: .color(.white))
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)), with: .color(blue))
            } else {
                // Arrow on the edge pointing towards the user.
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let dx = p.x - c.x, dy = p.y - c.y
                let len = max(0.001, hypot(dx, dy))
                let ux = dx / len, uy = dy / len
                let s = min((size.width / 2 - 16) / max(0.001, abs(ux)), (size.height / 2 - 16) / max(0.001, abs(uy)))
                let tip = CGPoint(x: c.x + ux * s, y: c.y + uy * s)
                let base = CGPoint(x: tip.x - ux * 22, y: tip.y - uy * 22)
                var arrow = Path()
                arrow.move(to: tip)
                arrow.addLine(to: CGPoint(x: base.x - uy * 9, y: base.y + ux * 9))
                arrow.addLine(to: CGPoint(x: base.x + uy * 9, y: base.y - ux * 9))
                arrow.closeSubpath()
                ctx.stroke(arrow, with: .color(.white), style: StrokeStyle(lineWidth: 5, lineJoin: .round))
                ctx.fill(arrow, with: .color(blue))
            }
        }
    }

    private func controlPoints(start: (CGPoint, CGPoint), end: (CGPoint, CGPoint), maxDistance: CGFloat) -> (CGPoint, CGPoint) {
        let gx = end.0.x - start.0.x, gy = end.0.y - start.0.y
        let gap = hypot(gx, gy)
        guard gap > 0.001 else { return (start.0, end.0) }
        let d = min(gap * 0.38, maxDistance)
        func outward(_ x: CGFloat, _ y: CGFloat, _ fx: CGFloat, _ fy: CGFloat) -> (CGFloat, CGFloat) {
            let fl = max(0.001, hypot(fx, fy))
            let fb = (fx / fl, fy / fl)
            let l = hypot(x, y)
            guard l > 0.001 else { return fb }
            let dir = (x / l, y / l)
            return dir.0 * fb.0 + dir.1 * fb.1 < 0 ? fb : dir
        }
        let sd = outward(start.0.x - start.1.x, start.0.y - start.1.y, gx, gy)
        let ed = outward(end.0.x - end.1.x, end.0.y - end.1.y, -gx, -gy)
        return (CGPoint(x: start.0.x + sd.0 * d, y: start.0.y + sd.1 * d),
                CGPoint(x: end.0.x + ed.0 * d, y: end.0.y + ed.1 * d))
    }

    private func placeLabel(at p: CGPoint, width w: CGFloat, height h: CGFloat, in size: CGSize, occupied: [CGRect]) -> CGRect? {
        let gap: CGFloat = 4
        let hs = w + gap, vs = h + gap
        let offsets: [(CGFloat, CGFloat)] = [(0, 0), (0, -vs), (0, vs), (-hs, 0), (hs, 0), (-hs, -vs), (hs, -vs), (-hs, vs), (hs, vs)]
        let bounds = CGRect(origin: .zero, size: size)
        for (ox, oy) in offsets {
            let r = CGRect(x: p.x + ox - w / 2, y: p.y + oy - h / 2, width: w, height: h)
            if bounds.contains(r) && !occupied.contains(where: { $0.insetBy(dx: -gap, dy: -gap).intersects(r) }) { return r }
        }
        return nil
    }
}
