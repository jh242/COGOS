import Foundation
import Combine

/// UserDefaults-backed app settings (replaces SharedPreferences).
@MainActor
final class Settings: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var anthropicAPIKey: String { didSet { defaults.set(anthropicAPIKey, forKey: "anthropic_api_key") } }
    @Published var silenceThreshold: Int { didSet { defaults.set(silenceThreshold, forKey: "silence_threshold") } }
    @Published var headUpAngle: Int { didSet { defaults.set(headUpAngle, forKey: "head_up_angle") } }
    /// Phase 2 dashboard migration flag. When true, push time/weather/calendar
    /// via firmware dashboard commands instead of rendering a bitmap glance.
    /// Default off — opt-in until Quick Notes sniff lands and full migration
    /// completes. See `docs/superpowers/plans/2026-04-16-firmware-dashboard-migration.md`.
    @Published var useFirmwareDashboard: Bool { didSet { defaults.set(useFirmwareDashboard, forKey: "use_firmware_dashboard") } }

    init() {
        self.anthropicAPIKey = defaults.string(forKey: "anthropic_api_key") ?? ""
        self.silenceThreshold = defaults.object(forKey: "silence_threshold") as? Int ?? 2
        self.headUpAngle = defaults.object(forKey: "head_up_angle") as? Int ?? 30
        self.useFirmwareDashboard = defaults.object(forKey: "use_firmware_dashboard") as? Bool ?? false
        // One-time cleanup of retired API keys (OpenWeatherMap, NewsAPI).
        defaults.removeObject(forKey: "openweather_api_key")
        defaults.removeObject(forKey: "news_api_key")
    }

    /// Resolved API key: prefers compile-time env, falls back to stored value.
    var resolvedAnthropicKey: String {
        let env = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? ""
        return env.isEmpty ? anthropicAPIKey.trimmingCharacters(in: .whitespaces) : env
    }

    func makeAnthropicClient() -> AnthropicClient? {
        let k = resolvedAnthropicKey
        return k.isEmpty ? nil : AnthropicClient(apiKey: k)
    }
}
