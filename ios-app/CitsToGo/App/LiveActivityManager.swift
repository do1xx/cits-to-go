import ActivityKit
import Foundation
import Observation

/// Keeps one Live Activity (lock screen + Dynamic Island) while the receiver is connected:
/// next traffic light > active warning > reception status.
@MainActor
@Observable
final class LiveActivityManager {
    var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "liveActivity.enabled")
            if !enabled { end() }
        }
    }
    private(set) var running = false

    @ObservationIgnored private weak var model: BridgeModel?
    @ObservationIgnored private weak var assistant: AssistantModel?
    @ObservationIgnored private var activity: Activity<CitsActivityAttributes>?
    @ObservationIgnored private var last: CitsActivityAttributes.ContentState?
    @ObservationIgnored private var lastCountsUpdate = Date.distantPast
    @ObservationIgnored private var timer: Timer?

    init() {
        enabled = UserDefaults.standard.object(forKey: "liveActivity.enabled") as? Bool ?? true
    }

    func attach(model: BridgeModel, assistant: AssistantModel) {
        self.model = model
        self.assistant = assistant
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        guard let model else { return }
        guard enabled, model.linkState.isStreaming || model.demoRunning, ActivityAuthorizationInfo().areActivitiesEnabled else {
            if activity != nil { end() }
            return
        }
        let state = currentState(model)
        if activity == nil {
            do {
                activity = try Activity.request(attributes: CitsActivityAttributes(receiverName: "CITS-to-go"),
                                                content: .init(state: state, staleDate: nil))
                running = true
                last = state
                lastCountsUpdate = Date()
                model.record("Live-Aktivität gestartet")
            } catch {
                model.record("Live-Aktivität nicht möglich: \(error.localizedDescription)")
                enabled = false
            }
            return
        }
        // Update on content changes; counters alone at most every 15 s.
        var withoutCounts = state; withoutCounts.packets = 0; withoutCounts.stations = 0
        var lastWithoutCounts = last; lastWithoutCounts?.packets = 0; lastWithoutCounts?.stations = 0
        let contentChanged = withoutCounts != lastWithoutCounts
        guard contentChanged || Date().timeIntervalSince(lastCountsUpdate) > 15 else { return }
        last = state
        lastCountsUpdate = Date()
        let act = activity
        Task { await act?.update(.init(state: state, staleDate: nil)) }
    }

    private func currentState(_ model: BridgeModel) -> CitsActivityAttributes.ContentState {
        let packets = model.totalPackets, stations = model.stations.count
        if let a = assistant?.advice, let g = a.primary {
            let phase: String = switch g.state.category { case .go: "go"; case .caution: "caution"; case .stop: "stop"; case .unknown: "unknown" }
            // Round the change time to whole seconds so tiny jitter doesn't cause updates.
            let end = g.secondsLeft.map { Date(timeIntervalSince1970: (Date().timeIntervalSince1970 + Double($0)).rounded()) }
            return .init(mode: .signal, title: g.state.label,
                         subtitle: "\(Int(a.distanceToStopLine.rounded() / 5) * 5) m bis zur Haltelinie · \(a.intersection)",
                         phase: phase, countdownEnd: end, advisoryKmh: g.advisoryKmh, packets: packets, stations: stations)
        }
        if let w = model.warnings.values.filter({ $0.denm.expires > Date() }).max(by: { $0.lastSeen < $1.lastSeen }) {
            return .init(mode: .warning, title: w.denm.causeLabel,
                         subtitle: [w.denm.subCauseLabel, "gültig bis \(w.denm.expires.formatted(date: .omitted, time: .shortened))"]
                            .compactMap { $0 }.joined(separator: " · "),
                         phase: nil, countdownEnd: nil, advisoryKmh: nil, packets: packets, stations: stations)
        }
        return .init(mode: .status, title: "Empfänger verbunden",
                     subtitle: "\(stations) Stationen gehört", phase: nil, countdownEnd: nil, advisoryKmh: nil,
                     packets: packets, stations: stations)
    }

    func end() {
        guard let act = activity else { return }
        activity = nil
        running = false
        last = nil
        Task { await act.end(nil, dismissalPolicy: .immediate) }
        model?.record("Live-Aktivität beendet")
    }
}
