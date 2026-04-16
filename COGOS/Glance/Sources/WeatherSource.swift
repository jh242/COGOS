import Foundation

final class WeatherSource: GlanceSource {
    let name = "weather"
    var enabled = true
    var cacheDuration: TimeInterval = 900
    var tier: GlanceTier = .fixed

    let location: NativeLocation

    /// Structured weather data from the last successful fetch.
    private(set) var lastWeather: (temp: String, condition: String)?

    /// Firmware-dashboard-ready snapshot. Populated alongside `lastWeather`
    /// when the wttr.in response parses cleanly.
    private(set) var lastWeatherInfo: WeatherInfo?

    init(location: NativeLocation) {
        self.location = location
    }

    func fetch(context: GlanceContext) async -> String? {
        var loc = context.userLocation
        if loc == nil { loc = await location.requestLocation() }
        guard let loc = loc else { return nil }

        let lat = loc.coordinate.latitude
        let lon = loc.coordinate.longitude
        // wttr.in keyless weather: %t = temperature, %C = condition.
        // Default units are metric (Celsius); append &m to be explicit.
        guard let url = URL(string: "https://wttr.in/\(lat),\(lon)?format=%t+%C&m") else { return nil }

        var req = URLRequest(url: url)
        req.timeoutInterval = 5
        // wttr.in serves ASCII-art HTML to browser UAs; a curl-like UA gets the short text form.
        req.setValue("curl/cogos", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: req) else { return nil }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
        guard let body = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !body.isEmpty else { return nil }

        // Parse "+8°C Partly cloudy" into temperature + condition.
        if let degRange = body.range(of: "°C") ?? body.range(of: "°F") {
            let temp = String(body[..<degRange.upperBound]).trimmingCharacters(in: .whitespaces)
            let condition = String(body[degRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            lastWeather = (temp: temp, condition: condition)

            if let tempC = Self.parseCelsius(temp) {
                lastWeatherInfo = WeatherInfo(
                    icon: Self.weatherId(forCondition: condition),
                    temperatureCelsius: tempC,
                    displayFahrenheit: false,
                    hour24: true
                )
            }
        } else {
            lastWeather = (temp: "", condition: body)
        }

        return "Weather: \(body)"
    }

    // MARK: - Parsing helpers

    /// Parse a wttr.in temperature string like "+8°C" or "-3°C" into a
    /// signed Int8 Celsius. Returns nil on anything unexpected.
    static func parseCelsius(_ s: String) -> Int8? {
        // Strip the "°C"/"°F" suffix and any whitespace.
        let digits = s
            .replacingOccurrences(of: "°C", with: "")
            .replacingOccurrences(of: "°F", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard let value = Int(digits), value >= Int(Int8.min), value <= Int(Int8.max) else {
            return nil
        }
        return Int8(value)
    }

    /// Map a wttr.in condition phrase to the firmware's `WeatherId` enum.
    /// Rough heuristic — the firmware icon set is small so we lose nuance.
    static func weatherId(forCondition condition: String) -> WeatherId {
        let s = condition.lowercased()
        if s.contains("thunder") { return s.contains("storm") ? .thunderstorm : .thunder }
        if s.contains("freezing rain") || s.contains("sleet") { return .freezingRain }
        if s.contains("heavy rain") { return .heavyRain }
        if s.contains("rain") || s.contains("shower") { return .rain }
        if s.contains("heavy drizzle") { return .heavyDrizzle }
        if s.contains("drizzle") { return .drizzle }
        if s.contains("snow") || s.contains("blizzard") { return .snow }
        if s.contains("mist") { return .mist }
        if s.contains("fog") { return .fog }
        if s.contains("sand") || s.contains("dust") { return .sand }
        if s.contains("squall") { return .squalls }
        if s.contains("tornado") { return .tornado }
        if s.contains("cloud") || s.contains("overcast") { return .clouds }
        if s.contains("clear") || s.contains("sunny") { return .sunny }
        return .none
    }
}
