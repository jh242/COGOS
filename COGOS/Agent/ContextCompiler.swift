import Foundation

/// Builds model-facing chat messages from normalized events and app-owned
/// memory. The chat transport should not decide what context belongs in the
/// request.
struct ContextCompiler: Sendable {
    static let maxMessages = 40

    private let systemPrompt = """
        You are a wearable assistant on smart glasses. Voice in, five-line display out.

        Plain UTF-8 only — no markdown, no bullets, no emoji.
        Metric units always (°C, km, m).
        Answer in five lines or fewer. Short sentences; numbers over words when it saves room.
        No preambles, no trailing offers, no echoing the question.
        Current time and location are ambient context.
        Voice input may have STT errors — be charitable with homophones and fragments.
        If truly ambiguous, ask one short clarifying question. Otherwise answer.
        Tone: direct, dry, confident.
        """

    func compile(event: AgentEvent, memory: AgentMemory) -> [ChatMessage] {
        var messages: [ChatMessage] = [ChatMessage(role: "system", content: systemPrompt)]

        if !memory.rollingSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.append(ChatMessage(role: "system", content: "Conversation summary:\n\(memory.rollingSummary)"))
        }

        for turn in memory.recentTurns {
            messages.append(ChatMessage(role: "user", content: turn.userText))
            messages.append(ChatMessage(role: "assistant", content: turn.assistantText))
        }

        switch event {
        case .voiceTranscriptFinal(let text):
            messages.append(ChatMessage(role: "user", content: text))
        case .appLaunched, .userCancelled, .resetRequested:
            break
        }

        if messages.count > Self.maxMessages {
            let preservedSystem = messages.prefix(1)
            let recent = messages.dropFirst().suffix(Self.maxMessages - preservedSystem.count)
            messages = Array(preservedSystem + recent)
        }

        return messages
    }
}
