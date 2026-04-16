import Foundation

final class WeatherSource: GlanceSource {
    let name = "weather"
    var enabled = true
    var cacheDuration: TimeInterval = 900
    var tier: GlanceTier = .fixed

    let location: NativeLocation

    /// Structured weather data from the last successful fetch.
    private(set) var lastWeather: (temp: String, condition: String)?

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
        } else {
            lastWeather = (temp: "", condition: body)
        }

        return "Weather: \(body)"
    }
}
