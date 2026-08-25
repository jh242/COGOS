import Foundation
import Combine
import Security

struct CommuteLocation: Codable, Equatable, Identifiable {
    var id: UUID
    var label: String
    var latitude: Double
    var longitude: Double

    init(id: UUID = UUID(), label: String, latitude: Double, longitude: Double) {
        self.id = id
        self.label = label
        self.latitude = latitude
        self.longitude = longitude
    }

    // Entries saved before `id` existed decode with a fresh UUID; it becomes
    // stable once the array is next re-encoded.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.label = try c.decode(String.self, forKey: .label)
        self.latitude = try c.decode(Double.self, forKey: .latitude)
        self.longitude = try c.decode(Double.self, forKey: .longitude)
    }
}

/// UserDefaults-backed app settings (replaces SharedPreferences).
@MainActor
final class Settings: ObservableObject {
    private let defaults = UserDefaults.standard
    private let hermesCredentials = KeychainCredentialStore(account: "hermes_api_token")
    private let openRouterCredentials = KeychainCredentialStore(account: "openrouter_api_key")

    @Published var hermesURL: String { didSet { defaults.set(hermesURL, forKey: "hermes_api_url") } }
    @Published var hermesToken: String {
        didSet {
            let status = hermesCredentials.write(hermesToken)
            hermesCredentialError = status == errSecSuccess ? nil : "Could not save token to Keychain (\(status))."
        }
    }
    @Published private(set) var hermesCredentialError: String?
    @Published var openRouterAPIKey: String {
        didSet {
            let status = openRouterCredentials.write(openRouterAPIKey)
            openRouterCredentialError = status == errSecSuccess ? nil : "Could not save OpenRouter key to Keychain (\(status))."
        }
    }
    @Published private(set) var openRouterCredentialError: String?
    @Published var openRouterModel: String { didSet { defaults.set(openRouterModel, forKey: "openrouter_model") } }
    @Published var newsTopic: NewsTopic {
        didSet { defaults.set(newsTopic.rawValue, forKey: "news_topic") }
    }
    @Published var silenceThreshold: Int { didSet { defaults.set(silenceThreshold, forKey: "silence_threshold") } }
    @Published var headUpAngle: Int { didSet { defaults.set(headUpAngle, forKey: "head_up_angle") } }
    @Published var brightness: Int { didSet { defaults.set(brightness, forKey: "display_brightness") } }
    @Published var autoBrightness: Bool { didSet { defaults.set(autoBrightness, forKey: "display_auto_brightness") } }
    @Published var silentMode: Bool { didSet { defaults.set(silentMode, forKey: "app_silent_mode") } }
    @Published var commuteLocations: [CommuteLocation] {
        didSet {
            let trimmed = Array(commuteLocations.prefix(5))
            if trimmed.count != commuteLocations.count {
                commuteLocations = trimmed
                return
            }
            if let data = try? JSONEncoder().encode(trimmed) {
                defaults.set(data, forKey: "commute_locations")
            }
        }
    }
    let hermesConversationID: String

    init() {
        self.hermesURL = defaults.string(forKey: "hermes_api_url") ?? ""
        self.hermesToken = hermesCredentials.read()
        self.openRouterAPIKey = openRouterCredentials.read()
        let storedModel = defaults.string(forKey: "openrouter_model")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.openRouterModel = storedModel.isEmpty ? OpenRouterClient.defaultModel : storedModel
        if let raw = defaults.string(forKey: "news_topic"), let topic = NewsTopic(rawValue: raw) {
            self.newsTopic = topic
        } else {
            self.newsTopic = .top
        }
        if let existing = defaults.string(forKey: "hermes_conversation_id") {
            self.hermesConversationID = existing
        } else {
            let generated = "cogos-glasses-\(UUID().uuidString.lowercased())"
            defaults.set(generated, forKey: "hermes_conversation_id")
            self.hermesConversationID = generated
        }
        self.silenceThreshold = defaults.object(forKey: "silence_threshold") as? Int ?? 2
        self.headUpAngle = defaults.object(forKey: "head_up_angle") as? Int ?? 30
        self.brightness = defaults.object(forKey: "display_brightness") as? Int ?? 21
        self.autoBrightness = defaults.object(forKey: "display_auto_brightness") as? Bool ?? true
        self.silentMode = defaults.object(forKey: "app_silent_mode") as? Bool ?? false
        if let data = defaults.data(forKey: "commute_locations"),
           let decoded = try? JSONDecoder().decode([CommuteLocation].self, from: data) {
            self.commuteLocations = Array(decoded.prefix(5))
        } else {
            self.commuteLocations = []
        }
        defaults.removeObject(forKey: "openweather_api_key")
        defaults.removeObject(forKey: "news_api_key")
        defaults.removeObject(forKey: "use_firmware_dashboard")
        defaults.removeObject(forKey: "anthropic_agent_id")
        defaults.removeObject(forKey: "anthropic_environment_id")
        defaults.removeObject(forKey: "anthropic_session_id")
        defaults.removeObject(forKey: "anthropic_api_key")
        defaults.removeObject(forKey: "llm_api_key")
        defaults.removeObject(forKey: "llm_base_url")
        defaults.removeObject(forKey: "llm_model")
        defaults.removeObject(forKey: "llm_use_streaming")
        defaults.removeObject(forKey: "llm_max_output_tokens")
    }

    func makeHermesClient(session: URLSession = .shared) -> HermesClient? {
        let env = ProcessInfo.processInfo.environment
        let envURL = env["HERMES_API_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let envToken = env["HERMES_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let urlString = envURL.isEmpty ? hermesURL.trimmingCharacters(in: .whitespacesAndNewlines) : envURL
        let token = envToken.isEmpty ? hermesToken.trimmingCharacters(in: .whitespacesAndNewlines) : envToken
        guard !token.isEmpty,
              let url = URL(string: urlString),
              url.scheme?.lowercased() == "https",
              url.host?.isEmpty == false else { return nil }
        return HermesClient(
            baseURL: url,
            accessToken: token,
            conversationID: hermesConversationID,
            sessionKey: hermesConversationID,
            session: session
        )
    }

    func makeOpenRouterClient(session: URLSession = .shared) -> OpenRouterClient? {
        let env = ProcessInfo.processInfo.environment
        let envKey = env["OPENROUTER_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let envModel = env["OPENROUTER_MODEL"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let token = envKey.isEmpty ? openRouterAPIKey.trimmingCharacters(in: .whitespacesAndNewlines) : envKey
        let model = envModel.isEmpty ? openRouterModel.trimmingCharacters(in: .whitespacesAndNewlines) : envModel
        guard !token.isEmpty else { return nil }
        return OpenRouterClient(
            apiKey: token,
            model: model.isEmpty ? OpenRouterClient.defaultModel : model,
            session: session
        )
    }
}
