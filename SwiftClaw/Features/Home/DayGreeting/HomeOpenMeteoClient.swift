import CoreLocation
import Foundation
import os

struct HomeOpenMeteoWeather: Sendable {
    let timeZoneIdentifier: String
    let rawSunrise: String?
    let rawSunset: String?
    let sunrise: Date?
    let sunset: Date?
    let weatherSummary: String

    var timeZone: TimeZone {
        TimeZone(identifier: timeZoneIdentifier) ?? .current
    }
}

struct HomeOpenMeteoClient: Sendable {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.caffeineplz.SwiftClaw",
        category: "HomeDayGreeting"
    )

    func weather(for location: CLLocation) async throws -> HomeOpenMeteoWeather {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.open-meteo.com"
        components.path = "/v1/forecast"
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(location.coordinate.latitude)),
            URLQueryItem(name: "longitude", value: String(location.coordinate.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code"),
            URLQueryItem(name: "daily", value: "sunrise,sunset"),
            URLQueryItem(name: "temperature_unit", value: Self.temperatureUnit),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "1"),
        ]

        guard let url = components.url else {
            throw HomeOpenMeteoError.invalidURL
        }

        Self.logger.notice("Fetching Open-Meteo home greeting weather.")
        let (data, response) = try await URLSession.shared.data(from: url)

        guard let response = response as? HTTPURLResponse else {
            throw HomeOpenMeteoError.badResponse(statusCode: nil)
        }

        guard (200..<300).contains(response.statusCode) else {
            throw HomeOpenMeteoError.badResponse(statusCode: response.statusCode)
        }

        do {
            let forecast = try JSONDecoder().decode(OpenMeteoForecastResponse.self, from: data)
            return forecast.weather
        } catch {
            Self.logger.error("Open-Meteo response decode failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    private static var temperatureUnit: String {
        Locale.current.measurementSystem == .metric ? "celsius" : "fahrenheit"
    }
}

private enum HomeOpenMeteoError: LocalizedError {
    case invalidURL
    case badResponse(statusCode: Int?)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Open-Meteo URL could not be built."
        case .badResponse(let statusCode):
            if let statusCode {
                "Open-Meteo returned HTTP \(statusCode)."
            } else {
                "Open-Meteo returned a non-HTTP response."
            }
        }
    }
}

private struct OpenMeteoForecastResponse: Decodable, Sendable {
    let timezone: String
    let current: Current
    let currentUnits: CurrentUnits?
    let daily: Daily

    var weather: HomeOpenMeteoWeather {
        let timeZone = TimeZone(identifier: timezone) ?? .current
        let rawSunrise = daily.sunrise.first
        let rawSunset = daily.sunset.first
        let sunrise = rawSunrise.flatMap { Self.localDate(from: $0, timeZone: timeZone) }
        let sunset = rawSunset.flatMap { Self.localDate(from: $0, timeZone: timeZone) }
        let temperatureUnit = currentUnits?.temperature ?? "F"
        let temperature = Int(current.temperature.rounded())

        return HomeOpenMeteoWeather(
            timeZoneIdentifier: timezone,
            rawSunrise: rawSunrise,
            rawSunset: rawSunset,
            sunrise: sunrise,
            sunset: sunset,
            weatherSummary: "\(Self.conditionDescription(for: current.weatherCode)), \(temperature) \(temperatureUnit)"
        )
    }

    private static func localDate(from string: String, timeZone: TimeZone) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return formatter.date(from: string)
    }

    private static func conditionDescription(for code: Int) -> String {
        switch code {
        case 0:
            "Clear"
        case 1:
            "Mostly clear"
        case 2:
            "Partly cloudy"
        case 3:
            "Cloudy"
        case 45, 48:
            "Foggy"
        case 51, 53, 55:
            "Drizzle"
        case 56, 57:
            "Freezing drizzle"
        case 61, 63, 65:
            "Rain"
        case 66, 67:
            "Freezing rain"
        case 71, 73, 75:
            "Snow"
        case 77:
            "Snow grains"
        case 80, 81, 82:
            "Rain showers"
        case 85, 86:
            "Snow showers"
        case 95:
            "Thunderstorms"
        case 96, 99:
            "Thunderstorms with hail"
        default:
            "Unknown conditions"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case timezone
        case current
        case currentUnits = "current_units"
        case daily
    }

    struct Current: Decodable, Sendable {
        let temperature: Double
        let weatherCode: Int

        private enum CodingKeys: String, CodingKey {
            case temperature = "temperature_2m"
            case weatherCode = "weather_code"
        }
    }

    struct CurrentUnits: Decodable, Sendable {
        let temperature: String

        private enum CodingKeys: String, CodingKey {
            case temperature = "temperature_2m"
        }
    }

    struct Daily: Decodable, Sendable {
        let sunrise: [String]
        let sunset: [String]
    }
}
