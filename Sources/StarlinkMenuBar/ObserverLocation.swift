import CoreLocation
import Foundation
import Observation
import Orbits

/// Where the dish is, for working out which satellites it can see. Defaults to Cupertino, CA; the HUD's
/// location button asks macOS for the real position (prompting for permission the first time) and keeps it.
@MainActor
@Observable
final class ObserverLocation: NSObject, CLLocationManagerDelegate {
    static let shared = ObserverLocation()

    static let defaultLatitude = 37.3230
    static let defaultLongitude = -122.0322

    enum State: Equatable { case idle, locating, denied, failed }

    private(set) var latitude: Double
    private(set) var longitude: Double
    /// True once the position came from Location Services (otherwise it's the Cupertino default).
    private(set) var isFromSystem: Bool
    private(set) var state: State = .idle

    var observer: Observer { Observer(latitudeDeg: latitude, longitudeDeg: longitude) }

    @ObservationIgnored private var manager: CLLocationManager?
    private static let latKey = "observerLatitude", lonKey = "observerLongitude"

    override init() {
        let d = UserDefaults.standard
        if d.object(forKey: Self.latKey) != nil, d.object(forKey: Self.lonKey) != nil {
            latitude = d.double(forKey: Self.latKey)
            longitude = d.double(forKey: Self.lonKey)
            isFromSystem = true
        } else {
            latitude = Self.defaultLatitude
            longitude = Self.defaultLongitude
            isFromSystem = false
        }
        super.init()
    }

    /// One-shot location request. macOS shows its permission prompt the first time.
    func requestSystemLocation() {
        let m = manager ?? CLLocationManager()
        manager = m
        m.delegate = self
        m.desiredAccuracy = kCLLocationAccuracyKilometer   // plenty: 1 km moves a beam by ~0.1°
        state = .locating
        switch m.authorizationStatus {
        case .notDetermined: m.requestWhenInUseAuthorization()   // continues in the authorization callback
        case .denied, .restricted: state = .denied
        default: m.requestLocation()
        }
    }

    // The manager is created on the main thread, so its delegate callbacks arrive there.

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            guard state == .locating, status != .notDetermined else { return }
            if status == .denied || status == .restricted {
                state = .denied
            } else {
                self.manager?.requestLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let c = locations.last?.coordinate else { return }
        MainActor.assumeIsolated {
            latitude = c.latitude
            longitude = c.longitude
            isFromSystem = true
            state = .idle
            UserDefaults.standard.set(c.latitude, forKey: Self.latKey)
            UserDefaults.standard.set(c.longitude, forKey: Self.lonKey)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let denied = (error as? CLError)?.code == .denied
        MainActor.assumeIsolated { state = denied ? .denied : .failed }
    }
}
