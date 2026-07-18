import Foundation

enum HomeDayPhase: Sendable {
    case morningTwilight
    case dawn
    case morning
    case afternoon
    case evening
    case eveningTwilight
    case dusk

    var displayName: String {
        switch self {
        case .morningTwilight, .eveningTwilight:
            "Twilight"
        case .dawn:
            "Dawn"
        case .morning:
            "Morning"
        case .afternoon:
            "Afternoon"
        case .evening:
            "Evening"
        case .dusk:
            "Dusk"
        }
    }

    var promptName: String {
        switch self {
        case .morningTwilight:
            "Twilight before dawn"
        case .eveningTwilight:
            "Twilight before dusk"
        default:
            displayName
        }
    }

    var cachePhase: HomeDayCachePhase {
        switch self {
        case .morningTwilight, .dawn, .morning:
            .morning
        case .afternoon:
            .afternoon
        case .evening, .eveningTwilight, .dusk:
            .evening
        }
    }

    static func cachePhase(now: Date, calendar: Calendar = .current) -> HomeDayCachePhase {
        fallbackPhase(now: now, calendar: calendar).cachePhase
    }

    static func calculate(
        now: Date,
        sunrise: Date?,
        sunset: Date?,
        calendar: Calendar = .current
    ) -> HomeDayPhase {
        guard let sunrise, let sunset, sunset > sunrise else {
            return fallbackPhase(now: now, calendar: calendar)
        }

        let solarNoon = sunrise.addingTimeInterval(sunset.timeIntervalSince(sunrise) / 2)
        let morningTwilightStart = sunrise.addingTimeInterval(-90 * 60)
        let dawnStart = sunrise.addingTimeInterval(-30 * 60)
        let morningStart = sunrise.addingTimeInterval(5 * 60)
        let eveningStart = sunset.addingTimeInterval(-2 * 60 * 60)
        let eveningTwilightStart = sunset.addingTimeInterval(-30 * 60)
        let duskStart = sunset.addingTimeInterval(30 * 60)

        if now < morningTwilightStart {
            return .dusk
        } else if now < dawnStart {
            return .morningTwilight
        } else if now < morningStart {
            return .dawn
        } else if now < solarNoon {
            return .morning
        } else if now < eveningStart {
            return .afternoon
        } else if now < eveningTwilightStart {
            return .evening
        } else if now < duskStart {
            return .eveningTwilight
        } else {
            return .dusk
        }
    }

    private static func fallbackPhase(now: Date, calendar: Calendar) -> HomeDayPhase {
        let hour = calendar.component(.hour, from: now)

        switch hour {
        case 4..<6:
            return .morningTwilight
        case 6..<7:
            return .dawn
        case 7..<12:
            return .morning
        case 12..<17:
            return .afternoon
        case 17..<20:
            return .evening
        case 20..<22:
            return .eveningTwilight
        default:
            return .dusk
        }
    }
}

enum HomeDayCachePhase: String, Hashable, Sendable {
    case morning
    case afternoon
    case evening
}
