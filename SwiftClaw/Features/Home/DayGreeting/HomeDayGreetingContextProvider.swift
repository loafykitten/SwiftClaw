import CoreLocation
import Foundation
import os

@MainActor
final class HomeDayGreetingContextProvider {
    private let locationProvider = HomeDayGreetingLocationProvider()
    private let weatherClient = HomeOpenMeteoClient()
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.caffeineplz.SwiftClaw",
        category: "HomeDayGreeting"
    )

    func loadContext(now: Date = Date()) async -> HomeDayGreetingContext {
        do {
            let location = try await locationProvider.currentLocation()
            let weather = try await weatherClient.weather(for: location)
            let sunrise = weather.sunrise
            let sunset = weather.sunset
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = weather.timeZone

            return HomeDayGreetingContext(
                now: now,
                timeZoneIdentifier: weather.timeZoneIdentifier,
                phase: HomeDayPhase.calculate(
                    now: now,
                    sunrise: sunrise,
                    sunset: sunset,
                    calendar: calendar
                ),
                sunrise: sunrise,
                sunset: sunset,
                daylightSummary: HomeDaylightSummary.describe(
                    now: now,
                    sunrise: sunrise,
                    sunset: sunset
                ),
                weatherSummary: weather.weatherSummary
            )
        } catch {
            logger.error("Greeting context load failed: \(String(describing: error), privacy: .public)")
            return .localOnly(now: now)
        }
    }
}

private enum HomeDayGreetingLocationError: LocalizedError {
    case locationServicesDisabled
    case authorizationDenied
    case requestAlreadyRunning
    case locationUnavailable

    var errorDescription: String? {
        switch self {
        case .locationServicesDisabled:
            "Location services are disabled."
        case .authorizationDenied:
            "Location permission was denied."
        case .requestAlreadyRunning:
            "A location request is already running."
        case .locationUnavailable:
            "No location was returned."
        }
    }
}

@MainActor
private final class HomeDayGreetingLocationProvider: NSObject, CLLocationManagerDelegate {
    private var manager: CLLocationManager?
    private var continuation: CheckedContinuation<CLLocation, Error>?

    func currentLocation() async throws -> CLLocation {
        guard CLLocationManager.locationServicesEnabled() else {
            throw HomeDayGreetingLocationError.locationServicesDisabled
        }

        guard continuation == nil else {
            throw HomeDayGreetingLocationError.requestAlreadyRunning
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation

            let manager = CLLocationManager()
            manager.delegate = self
            manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
            self.manager = manager

            handleAuthorizationStatus(manager.authorizationStatus)
        }
    }

    private func handleAuthorizationStatus(_ status: CLAuthorizationStatus) {
        guard let manager else {
            finish(with: .failure(HomeDayGreetingLocationError.locationUnavailable))
            return
        }

        switch status {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        case .denied, .restricted:
            finish(with: .failure(HomeDayGreetingLocationError.authorizationDenied))
        @unknown default:
            finish(with: .failure(HomeDayGreetingLocationError.authorizationDenied))
        }
    }

    private func finish(with result: Result<CLLocation, Error>) {
        let continuation = continuation
        self.continuation = nil
        manager?.delegate = nil
        manager = nil

        switch result {
        case .success(let location):
            continuation?.resume(returning: location)
        case .failure(let error):
            continuation?.resume(throwing: error)
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus

        Task { @MainActor in
            self.handleAuthorizationStatus(status)
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        guard let location = locations.last else {
            Task { @MainActor in
                self.finish(with: .failure(HomeDayGreetingLocationError.locationUnavailable))
            }
            return
        }

        let latitude = location.coordinate.latitude
        let longitude = location.coordinate.longitude
        let altitude = location.altitude
        let horizontalAccuracy = location.horizontalAccuracy
        let verticalAccuracy = location.verticalAccuracy
        let timestamp = location.timestamp

        Task { @MainActor in
            let copiedLocation = CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                altitude: altitude,
                horizontalAccuracy: horizontalAccuracy,
                verticalAccuracy: verticalAccuracy,
                timestamp: timestamp
            )

            self.finish(with: .success(copiedLocation))
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.finish(with: .failure(error))
        }
    }
}
