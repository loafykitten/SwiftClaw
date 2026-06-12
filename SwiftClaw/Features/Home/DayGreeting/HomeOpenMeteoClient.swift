import CoreLocation
import Foundation

struct HomeOpenMeteoWeather: Sendable {
    let timeZoneIdentifier: String
    let sunrise: Date?
    let sunset: Date?
    let weatherSummary: String

    var timeZone: TimeZone {
        TimeZone(identifier: timeZoneIdentifier) ?? .current
    }
}

struct HomeOpenMeteoClient: Sendable {
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

        let (data, response) = try await URLSession.shared.data(from: url)

        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else {
            throw HomeOpenMeteoError.badResponse
        }

        let forecast = try JSONDecoder().decode(OpenMeteoForecastResponse.self, from: data)
        return forecast.weather
    }

    private static var temperatureUnit: String {
        Locale.current.measurementSystem == .metric ? "celsius" : "fahrenheit"
    }
}

private enum HomeOpenMeteoError: LocalizedError {
    case invalidURL
    case badResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Open-Meteo URL could not be built."
        case .badResponse:
            "Open-Meteo returned an unsuccessful response."
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
        let sunrise = daily.sunrise.first.flatMap { Self.localDate(from: $0, timeZone: timeZone) }
        let sunset = daily.sunset.first.flatMap { Self.localDate(from: $0, timeZone: timeZone) }
        let temperatureUnit = currentUnits?.temperature ?? "F"
        let temperature = Int(current.temperature.rounded())

        return HomeOpenMeteoWeather(
            timeZoneIdentifier: timezone,
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
