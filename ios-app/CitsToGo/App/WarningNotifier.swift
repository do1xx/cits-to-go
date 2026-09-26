import CoreLocation
import Foundation
import Observation
import UserNotifications

/// Local notification for every new, still valid DENM received live (not replayed), optionally
/// limited to a radius around the phone. Works while the app runs in the background via BLE.
@MainActor
@Observable
final class WarningNotifier: NSObject, UNUserNotificationCenterDelegate {
    var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "notify.enabled"); if enabled { requestPermission() } }
    }
    /// 0 = no distance limit
    var radiusKm: Int { didSet { UserDefaults.standard.set(radiusKm, forKey: "notify.radiusKm") } }
    private(set) var authorized = false

    @ObservationIgnored private var notified: [String: Date] = [:]
    @ObservationIgnored weak var location: LocationProvider?

    override init() {
        let d = UserDefaults.standard
        enabled = d.object(forKey: "notify.enabled") as? Bool ?? true
        radiusKm = d.object(forKey: "notify.radiusKm") as? Int ?? 5
        super.init()
        UNUserNotificationCenter.current().delegate = self
        if enabled { requestPermission() }
    }

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            Task { @MainActor in self.authorized = granted }
        }
    }

    func handleNew(_ denm: DenmInfo) {
        guard enabled, !denm.terminated, denm.expires > Date() else { return }
        let key = "\(denm.originatingStationId)-\(denm.sequenceNumber)"
        guard notified[key] == nil else { return }
        notified = notified.filter { Date().timeIntervalSince($0.value) < 3600 }

        var distanceText: String?
        if let here = location?.location, Date().timeIntervalSince(here.timestamp) < 300,
           let lat = denm.latitude, let lon = denm.longitude {
            let meters = here.distance(from: CLLocation(latitude: lat, longitude: lon))
            if radiusKm > 0, meters > Double(radiusKm) * 1000 { return }
            distanceText = meters < 1000 ? "\(Int((meters / 50).rounded()) * 50) m entfernt"
                                         : String(format: "%.1f km entfernt", meters / 1000)
        }
        notified[key] = Date()

        let content = UNMutableNotificationContent()
        content.title = "⚠️ \(denm.causeLabel)"
        content.body = [denm.subCauseLabel, distanceText, "gemeldet von \(denm.stationType.label)"]
            .compactMap { $0 }.joined(separator: " · ")
        content.sound = .default
        content.threadIdentifier = "denm"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: key, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }
}
