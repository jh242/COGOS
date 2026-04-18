import CoreLocation
import Foundation
import WeatherKit

/// Weather provider. Fetches Apple WeatherKit and publishes the result as
/// `WeatherInfo`, which `GlanceService` routes to the firmware time+weather
/// pane (not the Quick Notes slots). Does not conform to `ContextProvider`
/// because its output is a `WeatherInfo`, not a `QuickNote` — but the
/// `refresh(ctx)` lifecycle matches so the service can drive it uniformly.
final class WeatherSource {
    let name = "weather"

    private static let refreshInterval: TimeInterval = 15 * 60

    private let location: NativeLocation
    private let service = WeatherService.shared
    private var lastFetch: Date?

    /// Last-known weather snapshot shaped for the firmware pane. `nil` until
    /// the first successful WeatherKit response.
    private(set) var currentInfo: WeatherInfo?

    init(location: NativeLocation) {
        self.location = location
    }

    func refresh(_ ctx: GlanceContext) async {
        if let last = lastFetch, ctx.now.timeIntervalSince(last) < Self.refreshInterval {
            return
        }
        var loc = ctx.userLocation
        if loc == nil { loc = await location.requestLocation() }
        guard let loc = loc else {
            trace("no user location — skipping")
            return
        }

        do {
            let weather = try await service.weather(for: loc)
            let current = weather.currentWeather
            let celsius = current.temperature.converted(to: .celsius).value
            let clamped = max(Double(Int8.min), min(Double(Int8.max), celsius.rounded()))
            currentInfo = WeatherInfo(
                icon: Self.weatherId(for: current.condition),
                temperatureCelsius: Int8(clamped),
                displayFahrenheit: false,
                hour24: true
            )
            lastFetch = ctx.now
            trace("WeatherKit → \(Int(clamped))°C \(current.condition.description)")
        } catch {
            trace("WeatherKit fetch failed: \(error)")
        }
    }

    private func trace(_ msg: String) { print("[weather] \(msg)") }

    /// Map WeatherKit's `WeatherCondition` to the firmware icon set.
    static func weatherId(for condition: WeatherCondition) -> WeatherId {
        switch condition {
        case .clear, .mostlyClear, .hot: return .sunny
        case .cloudy, .mostlyCloudy, .partlyCloudy, .smoky: return .clouds
        case .drizzle: return .drizzle
        case .rain, .sunShowers: return .rain
        case .heavyRain: return .heavyRain
        case .snow, .heavySnow, .blizzard, .blowingSnow, .flurries,
             .sunFlurries, .wintryMix: return .snow
        case .freezingDrizzle, .freezingRain, .sleet, .hail: return .freezingRain
        case .thunderstorms, .scatteredThunderstorms, .isolatedThunderstorms,
             .strongStorms: return .thunderstorm
        case .tropicalStorm, .hurricane: return .tornado
        case .foggy: return .fog
        case .haze: return .mist
        case .blowingDust: return .sand
        case .windy, .breezy: return .none
        default: return .none
        }
    }
}
