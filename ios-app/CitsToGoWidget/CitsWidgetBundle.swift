import ActivityKit
import SwiftUI
import WidgetKit

@main
struct CitsWidgetBundle: WidgetBundle {
    var body: some Widget { CitsLiveActivity() }
}

private func phaseColor(_ p: String?) -> Color {
    switch p {
    case "go": Color(red: 0.086, green: 0.639, blue: 0.290)
    case "caution": Color(red: 0.851, green: 0.467, blue: 0.024)
    case "stop": Color(red: 0.863, green: 0.149, blue: 0.149)
    default: .gray
    }
}

private struct Badge: View {
    let state: CitsActivityAttributes.ContentState
    var size: CGFloat = 44
    var body: some View {
        ZStack {
            Circle().fill(state.mode == .signal ? phaseColor(state.phase) : state.mode == .warning ? .red : .blue)
            switch state.mode {
            case .signal:
                if let end = state.countdownEnd, end > .now {
                    Text(timerInterval: Date.now...end, countsDown: true, showsHours: false)
                        .font(.system(size: size * 0.32, weight: .heavy).monospacedDigit())
                        .multilineTextAlignment(.center).foregroundStyle(.white).padding(2)
                } else {
                    Image(systemName: "light.beacon.max").foregroundStyle(.white)
                }
            case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.white)
            case .status: Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
    }
}

struct CitsLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CitsActivityAttributes.self) { context in
            // Lock screen / banner
            HStack(spacing: 14) {
                Badge(state: context.state, size: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.state.title).font(.headline)
                    Text(context.state.subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                    if let v = context.state.advisoryKmh {
                        Text("Empfohlen \(v) km/h").font(.caption.weight(.semibold))
                    }
                }
                Spacer()
                VStack(alignment: .trailing) {
                    Text("\(context.state.packets)").font(.caption.monospacedDigit().weight(.semibold))
                    Text("Pakete").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding()
            .activityBackgroundTint(Color.black.opacity(0.35))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Badge(state: context.state, size: 48) }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading) {
                        Text(context.state.title).font(.headline)
                        Text(context.state.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let v = context.state.advisoryKmh { Text("\(v) km/h").font(.caption.weight(.bold)) }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("\(context.attributes.receiverName) · \(context.state.stations) Stationen · \(context.state.packets) Pakete")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } compactLeading: {
                Circle().fill(context.state.mode == .signal ? phaseColor(context.state.phase) : context.state.mode == .warning ? .red : .blue)
                    .frame(width: 14, height: 14)
            } compactTrailing: {
                if context.state.mode == .signal, let end = context.state.countdownEnd, end > .now {
                    Text(timerInterval: Date.now...end, countsDown: true, showsHours: false)
                        .monospacedDigit().frame(width: 42)
                } else if context.state.mode == .warning {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                } else {
                    Text("\(context.state.stations)").monospacedDigit()
                }
            } minimal: {
                Circle().fill(context.state.mode == .signal ? phaseColor(context.state.phase) : context.state.mode == .warning ? .red : .blue)
                    .frame(width: 12, height: 12)
            }
        }
    }
}
