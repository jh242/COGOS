import Foundation

/// Folds older conversation turns into `AgentMemory.rollingSummary` so recent
/// turns stay bounded while long-lived context survives (Phase 6).
///
/// Compaction is best-effort: any failure leaves memory untouched and the
/// next turn simply retries. `AgentMemory.hardTurnCap` bounds growth in the
/// meantime.
struct MemoryCompactor: Sendable {
    static let maxSummaryCharacters = 1500

    private let systemPrompt = """
        You maintain the long-term memory of a voice assistant that lives on \
        smart glasses. Merge the previous summary and the new conversation \
        turns into one updated summary.

        Keep: stable facts about the user, preferences, decisions, open \
        questions, and anything the user asked to remember.
        Drop: small talk, one-off lookups, and anything already superseded.
        Write plain text, third person, at most \(MemoryCompactor.maxSummaryCharacters) \
        characters. Output only the summary.
        """

    func needsCompaction(_ memory: AgentMemory) -> Bool {
        memory.recentTurns.count > AgentMemory.maxRecentTurns
    }

    /// Summarizes the oldest turns beyond the retained window into the
    /// rolling summary. Throws — leaving the caller's memory unchanged — if
    /// the backend fails or returns an empty summary.
    func compact(_ memory: AgentMemory, using backend: LLMBackend) async throws -> AgentMemory {
        let turns = memory.recentTurns
        guard turns.count > AgentMemory.retainedTurnsAfterCompaction else { return memory }

        let overflow = turns.prefix(turns.count - AgentMemory.retainedTurnsAfterCompaction)
        let retained = Array(turns.suffix(AgentMemory.retainedTurnsAfterCompaction))

        var input = ""
        let previous = memory.rollingSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !previous.isEmpty {
            input += "Previous summary:\n\(previous)\n\n"
        }
        input += "New turns:\n"
        for turn in overflow {
            input += "User: \(turn.userText)\nAssistant: \(turn.assistantText)\n"
        }

        let request = LLMRequest(messages: [
            ChatMessage(role: "system", content: systemPrompt),
            ChatMessage(role: "user", content: input),
        ])

        var summary = ""
        for try await event in backend.stream(request) {
            if case .textDelta(let chunk) = event { summary += chunk }
        }
        summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { throw MemoryCompactionError.emptySummary }
        if summary.count > Self.maxSummaryCharacters {
            summary = String(summary.prefix(Self.maxSummaryCharacters))
        }

        var compacted = memory
        compacted.rollingSummary = summary
        compacted.recentTurns = retained
        return compacted
    }
}

enum MemoryCompactionError: Error, LocalizedError {
    case emptySummary

    var errorDescription: String? {
        switch self {
        case .emptySummary: return "summarizer returned no text"
        }
    }
}
