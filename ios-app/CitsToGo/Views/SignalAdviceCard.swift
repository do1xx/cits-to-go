import SwiftUI

/// "Nächste Ampel" – big phase, countdown, distance and advisory speed for the approach lane.
struct SignalAdviceCard: View {
    let advice: SignalAdvice

    var body: some View {
        let g = advice.primary
        HStack(spacing: 16) {
            ZStack {
                Circle().fill(PhaseColors.color(g?.state)).frame(width: 74, height: 74)
                if let s = g?.secondsLeft {
                    VStack(spacing: -2) {
                        Text("\(s)").font(.system(size: 30, weight: .heavy).monospacedDigit())
                        Text("s").font(.caption.weight(.bold))
                    }
                    .foregroundStyle(.white)
                } else {
                    Image(systemName: "light.beacon.max").font(.title).foregroundStyle(.white)
                }
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Nächste Ampel").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(g?.state.label ?? "Unbekannt").font(.title2.weight(.bold))
                Text("\(Int(advice.distanceToStopLine.rounded())) m bis zur Haltelinie").font(.subheadline)
                Text(advice.intersection).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let v = g?.advisoryKmh {
                    Label("Empfohlen \(v) km/h", systemImage: "speedometer").font(.caption.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(PhaseColors.go.opacity(0.18)))
                }
                if advice.groups.count > 1 {
                    HStack(spacing: 6) {
                        ForEach(advice.groups, id: \.signalGroup) { o in
                            HStack(spacing: 3) {
                                Circle().fill(PhaseColors.color(o.state)).frame(width: 8, height: 8)
                                Text("SG \(o.signalGroup)\(o.secondsLeft.map { " \($0)s" } ?? "")").font(.caption2.monospacedDigit())
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Nächste Ampel \(g?.state.label ?? ""), \(g?.secondsLeft.map { "Wechsel in \($0) Sekunden" } ?? ""), \(Int(advice.distanceToStopLine)) Meter bis zur Haltelinie")
    }
}
