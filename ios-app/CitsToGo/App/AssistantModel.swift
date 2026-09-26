import Foundation
import Observation

/// Recomputes the signal advice twice a second while intersections are known.
/// Location updates run only while there is something to match against.
@MainActor
@Observable
final class AssistantModel {
    private(set) var advice: SignalAdvice?
    @ObservationIgnored private weak var model: BridgeModel?
    @ObservationIgnored private weak var location: LocationProvider?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var locating = false
    @ObservationIgnored var onChange: ((SignalAdvice?) -> Void)?

    func attach(model: BridgeModel, location: LocationProvider) {
        self.model = model
        self.location = location
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        guard let model, let location else { return }
        let relevant = model.intersections.contains { $0.map != nil && $0.spat != nil }
        if relevant != locating {                 // only keep GPS running while it can help
            locating = relevant
            relevant ? location.start() : location.stop()
        }
        let next = relevant ? location.location.flatMap { SignalAssistant.advice(location: $0, snapshots: model.intersections) } : nil
        if next != advice {
            advice = next
            onChange?(next)
        }
    }
}
