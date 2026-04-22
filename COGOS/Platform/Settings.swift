import Foundation
import Combine

/// UserDefaults-backed app settings (replaces SharedPreferences).
@MainActor
final class Settings: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var apiKey: String { didSet { defaults.set(apiKey, forKey: "llm_api_key") } }
    @Published var baseURL: String { didSet { defaults.set(baseURL, forKey: "llm_base_url") } }
    @Published var model: String { didSet { defaults.set(model, forKey: "llm_model") } }
    @Published var useStreaming: Bool { didSet { defaults.set(useStreaming, forKey: "llm_use_streaming") } }
    @Published var silenceThreshold: Int { didSet { defaults.set(silenceThreshold, forKey: "silence_threshold") } }
    @Published var headUpAngle: Int { didSet { defaults.set(headUpAngle, forKey: "head_up_angle") } }
    @Published var brightness: Int { didSet { defaults.set(brightness, forKey: "display_brightness") } }
    @Published var autoBrightness: Bool { didSet { defaults.set(autoBrightness, forKey: "display_auto_brightness") } }

    init() {
        // Migrate legacy `anthropic_api_key` if present, then drop it.
        let legacy = defaults.string(forKey: "anthropic_api_key") ?? ""
        let stored = defaults.string(forKey: "llm_api_key") ?? ""
        let pickedKey = stored.isEmpty ? legacy : stored
        self.apiKey = pickedKey.isEmpty ? "local" : pickedKey
        self.baseURL = defaults.string(forKey: "llm_base_url") ?? "http://jh-workstation:8900/v1/"
        self.model = defaults.string(forKey: "llm_model") ?? "llama.cpp/gemma4:31b"
        self.useStreaming = defaults.object(forKey: "llm_use_streaming") as? Bool ?? false
        self.silenceThreshold = defaults.object(forKey: "silence_threshold") as? Int ?? 2
        self.headUpAngle = defaults.object(forKey: "head_up_angle") as? Int ?? 30
        self.brightness = defaults.object(forKey: "display_brightness") as? Int ?? 21
        self.autoBrightness = defaults.object(forKey: "display_auto_brightness") as? Bool ?? true
        if !legacy.isEmpty {
            defaults.set(self.apiKey, forKey: "llm_api_key")
            defaults.removeObject(forKey: "anthropic_api_key")
        }
        defaults.removeObject(forKey: "openweather_api_key")
        defaults.removeObject(forKey: "news_api_key")
        defaults.removeObject(forKey: "use_firmware_dashboard")
        defaults.removeObject(forKey: "anthropic_agent_id")
        defaults.removeObject(forKey: "anthropic_environment_id")
        defaults.removeObject(forKey: "anthropic_session_id")
    }

    /// Resolved API key: prefers compile-time env, falls back to stored value.
    var resolvedAPIKey: String {
        let env = ProcessInfo.processInfo.environment["LLM_API_KEY"]
            ?? ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]
            ?? ""
        return env.isEmpty ? apiKey.trimmingCharacters(in: .whitespaces) : env
    }

    func makeChatClient() -> ChatCompletionsClient? {
        let key = resolvedAPIKey
        guard !key.isEmpty, let url = URL(string: baseURL) else { return nil }
        return OpenAICompatibleClient(baseURL: url, apiKey: key, model: model, useStreaming: useStreaming)
    }
}
