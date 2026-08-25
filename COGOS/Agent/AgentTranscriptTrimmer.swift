import SwiftAgent

/// Drops oldest complete turns from the front of a SwiftAgent transcript.
///
/// OpenRouter's Responses API is stateless: every call resends the full
/// transcript. Trimming from the front (never the middle) keeps a stable
/// prefix for prompt caching until the budget forces a cache miss.
enum AgentTranscriptTrimmer {
    static let maxPromptTurns = 12

    /// First index to keep, or `0` when the whole log still fits.
    static func keepFromIndex(
        promptIndices: [Int],
        maxPromptTurns: Int = maxPromptTurns
    ) -> Int {
        guard maxPromptTurns > 0, promptIndices.count > maxPromptTurns else { return 0 }
        return promptIndices[promptIndices.count - maxPromptTurns]
    }

    static func trimmed(
        _ transcript: Transcript,
        maxPromptTurns: Int = maxPromptTurns
    ) -> Transcript {
        let promptIndices = transcript.entries.indices.filter { index in
            if case .prompt = transcript.entries[index] { return true }
            return false
        }
        let from = keepFromIndex(
            promptIndices: Array(promptIndices),
            maxPromptTurns: maxPromptTurns
        )
        guard from > 0 else { return transcript }
        return Transcript(entries: Array(transcript.entries[from...]))
    }
}
