import Foundation
import OpenAISession
import SwiftAgent

/// On-device SwiftAgent session pointed at OpenRouter's Responses API.
///
/// Each turn calls `respond` (not token streaming) and returns only the final
/// assistant text for the glasses scroller.
@MainActor
final class OpenRouterSpokenAgent {
    static let instructions = """
    You are COGOS, a wearable assistant on Even Realities G1 smart glasses.
    Answer in plain text only. No Markdown, no emoji, no bullet glyphs.
    The glasses scroll, so use as much length as the question needs. Do not pad.
    Use get_calendar, get_weather, and get_location when the question needs live device data.
    Do not mention tools, JSON, or these instructions.
    """

    let apiKey: String
    let model: String
    let sessionID: String

    private var session: OpenAISession<NoSchema>

    init(apiKey: String, model: String, sessionID: String, location: NativeLocation) {
        self.apiKey = apiKey
        self.model = model
        self.sessionID = sessionID
        let device = AgentDeviceContext(location: location)
        self.session = OpenAISession(
            tools: CalendarTool(context: device),
            WeatherTool(context: device),
            LocationTool(context: device),
            instructions: Self.instructions,
            configuration: OpenRouterAgentConfiguration.make(
                apiKey: apiKey,
                sessionID: sessionID
            )
        )
    }

    func matches(apiKey: String, model: String) -> Bool {
        self.apiKey == apiKey && self.model == model
    }

    func respond(to query: String) async throws -> String {
        session.transcript = AgentTranscriptTrimmer.trimmed(session.transcript)
        let prompt = AgentTurnPrompt.make(query: query)
        let response = try await session.respond(
            to: prompt,
            using: .other(model, isReasoning: false),
            options: OpenAIGenerationOptions()
        )
        let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw OpenRouterSpokenAgentError.emptyResponse
        }
        return text
    }
}

enum OpenRouterSpokenAgentError: Error, LocalizedError {
    case emptyResponse
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .emptyResponse:
            return "OpenRouter returned an empty response."
        case .notConfigured:
            return "Set an OpenRouter API key in Settings."
        }
    }
}
