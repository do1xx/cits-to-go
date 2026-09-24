import SwiftUI
import UIKit

/// Keeps the display on while the app is in the foreground, like navigation apps do.
/// iOS only honours this while the app is active; background reception works regardless.
enum KeepAwakeMode: String, CaseIterable, Identifiable {
    case off, charging, always
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: "Aus"
        case .charging: "Nur beim Laden"
        case .always: "Immer"
        }
    }
}

@MainActor
@Observable
final class ScreenAwake {
    var mode: KeepAwakeMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "screen.keepAwake"); update() }
    }
    var onlyWhenConnected: Bool {
        didSet { UserDefaults.standard.set(onlyWhenConnected, forKey: "screen.onlyWhenConnected"); update() }
    }
    private(set) var isCharging = false
    private(set) var active = false

    @ObservationIgnored private var receiverConnected = false
    @ObservationIgnored private var observer: NSObjectProtocol?

    init() {
        let d = UserDefaults.standard
        mode = KeepAwakeMode(rawValue: d.string(forKey: "screen.keepAwake") ?? "") ?? .charging
        onlyWhenConnected = d.object(forKey: "screen.onlyWhenConnected") as? Bool ?? true
        UIDevice.current.isBatteryMonitoringEnabled = true
        readBattery()
        observer = NotificationCenter.default.addObserver(
            forName: UIDevice.batteryStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.readBattery(); self?.update() }
        }
        update()
    }

    func setReceiverConnected(_ connected: Bool) {
        guard connected != receiverConnected else { return }
        receiverConnected = connected
        update()
    }

    /// Re-apply when the app comes back to the foreground (iOS resets the flag on some transitions).
    func update() {
        let wanted: Bool
        switch mode {
        case .off: wanted = false
        case .charging: wanted = isCharging
        case .always: wanted = true
        }
        active = wanted && (!onlyWhenConnected || receiverConnected)
        UIApplication.shared.isIdleTimerDisabled = active
    }

    private func readBattery() {
        let s = UIDevice.current.batteryState
        isCharging = s == .charging || s == .full
    }
}
