import CoreLocation
import Observation

/// Foreground location for the intersection view (your position dot, distance sorting).
@MainActor
@Observable
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    private(set) var location: CLLocation?
    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var users = 0

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func start() {
        users += 1
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        manager.startUpdatingLocation()
    }

    func stop() {
        users = max(0, users - 1)
        if users == 0 { manager.stopUpdatingLocation() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        Task { @MainActor in self.location = last }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in if self.users > 0 { self.manager.startUpdatingLocation() } }
    }
}
