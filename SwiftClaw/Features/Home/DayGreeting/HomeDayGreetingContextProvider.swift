import CoreLocation
import Foundation
import os

@MainActor
final class HomeDayGreetingContextProvider {
    private let locationProvider = HomeDayGreetingLocationProvider()
    private let weatherClient = HomeOpenMeteoClient()
    private let logger = AppLog.make("HomeDayGreeting")

    func loadContext(now: Date = Date()) async -> HomeDayGreetingContext {
        do {
            logger.notice("Loading home greeting context.")

            let location = try await locationProvider.currentLocation()
            logger.notice("Home greeting location loaded. horizontalAccuracy=\(location.horizontalAccuracy, privacy: .public)")

            let weather = try await weatherClient.weather(for: location)
            let sunrise = weather.sunrise
            let sunset = weather.sunset
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = weather.timeZone
            logger.notice(
                """
                Home greeting weather loaded. timeZone=\(weather.timeZoneIdentifier, privacy: .public) \
                hasSunrise=\(sunrise != nil, privacy: .public) hasSunset=\(sunset != nil, privacy: .public) \
                rawSunrise=\(weather.rawSunrise ?? "none", privacy: .public) rawSunset=\(weather.rawSunset ?? "none", privacy: .public) \
                weather=\(weather.weatherSummary, privacy: .public)
                """
            )

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
            logger.error("Greeting context load failed: \(error.localizedDescription, privacy: .public)")
            return .localOnly(now: now)
        }
    }
}

private enum HomeDayGreetingLocationError: LocalizedError {
    case authorizationDenied
    case requestAlreadyRunning
    case locationUnavailable
    case timedOut

    var errorDescription: String? {
        switch self {
        case .authorizationDenied:
            "Location permission was denied."
        case .requestAlreadyRunning:
            "A location request is already running."
        case .locationUnavailable:
            "No location was returned."
        case .timedOut:
            "The location request timed out."
        }
    }
}

@MainActor
private final class HomeDayGreetingLocationProvider: NSObject, CLLocationManagerDelegate {
    private let logger = AppLog.make("HomeDayGreeting")

    private var manager: CLLocationManager?
    private var continuation: CheckedContinuation<CLLocation, Error>?
    private var timeoutTask: Task<Void, Never>?

    func currentLocation() async throws -> CLLocation {
        // We deliberately don't gate on `CLLocationManager.locationServicesEnabled()`:
        // it can block the main thread (Apple flags it as a UI-responsiveness hazard).
        // When services are off the authorization status resolves to `.denied` /
        // `.restricted` and `handleAuthorizationStatus` finishes the request for us.
        guard continuation == nil else {
            logger.error("Home greeting location request skipped because another request is already running.")
            throw HomeDayGreetingLocationError.requestAlreadyRunning
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation

            let manager = CLLocationManager()
            manager.delegate = self
            manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
            self.manager = manager

            logger.notice("Starting home greeting location request. authorizationStatus=\(manager.authorizationStatus.logName, privacy: .public)")
            handleAuthorizationStatus(manager.authorizationStatus)
            startTimeout()
        }
    }

    private func handleAuthorizationStatus(_ status: CLAuthorizationStatus) {
        guard let manager else {
            finish(with: .failure(HomeDayGreetingLocationError.locationUnavailable))
            return
        }

        logger.notice("Handling home greeting location authorization. status=\(status.logName, privacy: .public)")

        switch status {
        case .notDetermined:
            logger.notice("Requesting home greeting location authorization.")
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            logger.notice("Requesting home greeting location update.")
            manager.requestLocation()
        case .denied, .restricted:
            logger.error("Home greeting location authorization is \(status.logName, privacy: .public).")
            finish(with: .failure(HomeDayGreetingLocationError.authorizationDenied))
        @unknown default:
            logger.error("Home greeting location authorization has unknown status.")
            finish(with: .failure(HomeDayGreetingLocationError.authorizationDenied))
        }
    }

    private func finish(with result: Result<CLLocation, Error>) {
        let continuation = continuation
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        manager?.delegate = nil
        manager = nil

        switch result {
        case .success(let location):
            logger.notice("Home greeting location request finished. horizontalAccuracy=\(location.horizontalAccuracy, privacy: .public)")
            continuation?.resume(returning: location)
        case .failure(let error):
            logger.error("Home greeting location request failed: \(error.localizedDescription, privacy: .public)")
            continuation?.resume(throwing: error)
        }
    }

    private func startTimeout() {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))

            guard !Task.isCancelled else {
                return
            }

            self?.finish(with: .failure(HomeDayGreetingLocationError.timedOut))
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
                self.logger.error("Home greeting location update contained no locations.")
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
            self.logger.error("Home greeting location manager failed: \(error.localizedDescription, privacy: .public)")
            self.finish(with: .failure(error))
        }
    }
}

private extension CLAuthorizationStatus {
    var logName: String {
        switch self {
        case .notDetermined:
            "notDetermined"
        case .restricted:
            "restricted"
        case .denied:
            "denied"
        case .authorizedAlways:
            "authorizedAlways"
        case .authorizedWhenInUse:
            "authorizedWhenInUse"
        @unknown default:
            "unknown"
        }
    }
}
