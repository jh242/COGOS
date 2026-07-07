import Foundation

struct AgentRunResult: Sendable {
    let userText: String
    let assistantText: String
}

/// Agent runtime: routes normalized events through durable memory, context
/// compilation, the LLM backend, the tool loop, and the renderer.
@MainActor
final class AgentRuntime {
    /// Maximum tool-call iterations per voice turn. Hard cap to prevent
    /// run-away loops; agents that need more than this are doing it wrong.
    private static let maxToolIterations = 3

    private let memoryStore: AgentMemoryStore
    private let contextCompiler: ContextCompiler
    private let compactor = MemoryCompactor()
    private let renderer: EvenTextRenderer
    private let makeBackend: () -> LLMBackend?
    private let toolRegistry: ToolRegistry
    private let makeToolContext: @MainActor () -> ToolContext?
    private var isHandling = false

    init(
        memoryStore: AgentMemoryStore = AgentMemoryStore(),
        contextCompiler: ContextCompiler = ContextCompiler(),
        renderer: EvenTextRenderer,
        toolRegistry: ToolRegistry = ToolRegistry(),
        makeToolContext: @escaping @MainActor () -> ToolContext? = { nil },
        makeBackend: @escaping () -> LLMBackend?
    ) {
        self.memoryStore = memoryStore
        self.contextCompiler = contextCompiler
        self.renderer = renderer
        self.toolRegistry = toolRegistry
        self.makeToolContext = makeToolContext
        self.makeBackend = makeBackend
    }

    func handle(
        _ event: AgentEvent,
        shouldContinue: @escaping @MainActor () async -> Bool
    ) async -> AgentRunResult? {
        // Single-flight guard: drop overlapping events instead of racing the
        // memory store. Voice gestures are gated upstream, but resets and
        // future event sources should not be able to interleave a save.
        if isHandling {
            print("AgentRuntime: dropping event while another is in flight: \(event)")
            return nil
        }
        isHandling = true
        defer { isHandling = false }

        switch event {
        case .voiceTranscriptFinal(let query):
            return await answerVoiceQuery(query, event: event, shouldContinue: shouldContinue)
        case .resetRequested:
            do {
                try await memoryStore.reset()
                await renderer.pushReply("Session reset")
            } catch {
                await renderer.pushReply("Reset failed: \(error.localizedDescription)")
            }
            return nil
        case .appLaunched, .userCancelled:
            return nil
        }
    }

    private func answerVoiceQuery(
        _ query: String,
        event: AgentEvent,
        shouldContinue: @escaping @MainActor () async -> Bool
    ) async -> AgentRunResult? {
        guard let backend = makeBackend() else {
            await renderer.pushReply("No API key set. Add key in Settings.")
            return nil
        }

        let memory = await memoryStore.load()
        var messages = contextCompiler.compile(event: event, memory: memory)

        let specs = toolRegistry.specs()
        let toolContext = makeToolContext()
        var toolsForRequest: [ToolSpec]? = (specs.isEmpty || toolContext == nil) ? nil : specs
        let runner: ToolRunner? = toolContext.map { ToolRunner(registry: toolRegistry, context: $0) }

        var finalAnswer: String? = nil
        var lastTurnText: String = ""

        for iteration in 0..<Self.maxToolIterations {
            let request = LLMRequest(messages: messages, tools: toolsForRequest)
            let turn: TurnOutput
            do {
                turn = try await consumeTurn(backend.stream(request))
            } catch {
                // A backend that rejects the `tools` parameter would otherwise
                // fail every voice query. On the first request of a turn (no
                // tool messages in history yet), degrade to text-only once
                // instead of surfacing the error.
                guard iteration == 0,
                      toolsForRequest != nil,
                      let http = error as? LLMHTTPError,
                      http.suggestsUnsupportedRequestShape else {
                    await renderer.pushReply("API error: \(error.localizedDescription)")
                    return nil
                }
                print("AgentRuntime: request with tools failed (HTTP \(http.statusCode)); retrying without tools")
                toolsForRequest = nil
                do {
                    turn = try await consumeTurn(backend.stream(LLMRequest(messages: messages, tools: nil)))
                } catch {
                    await renderer.pushReply("API error: \(error.localizedDescription)")
                    return nil
                }
            }

            lastTurnText = turn.textChunks.joined()

            if turn.toolCalls.isEmpty {
                finalAnswer = lastTurnText
                break
            }

            // Tool-call turn: do not render text deltas (Phase 4 streaming
            // policy). Append the assistant turn as-is, run the tools, and
            // loop with the appended results.
            guard let runner else {
                // Tools requested but no context — bail with a graceful error.
                await renderer.pushReply("Tool unavailable.")
                return nil
            }

            messages.append(ChatMessage.assistantToolCalls(turn.toolCalls, content: lastTurnText.isEmpty ? nil : lastTurnText))
            let results = await runner.run(turn.toolCalls)
            messages.append(contentsOf: results.map { $0.asChatMessage() })

            // If this was the last allowed iteration and we still produced
            // tool calls instead of an answer, fall out and surface an
            // exhaustion message after the loop.
            if iteration == Self.maxToolIterations - 1 {
                break
            }
        }

        let answer: String
        if let finalAnswer, !finalAnswer.isEmpty {
            await replayThroughRenderer(finalAnswer, shouldContinue: shouldContinue)
            answer = finalAnswer
        } else {
            let exhausted = "Tool loop limit reached."
            await renderer.pushReply(exhausted)
            answer = lastTurnText.isEmpty ? exhausted : lastTurnText
        }

        var updated = memory
        updated.addTurn(userText: query, assistantText: answer)
        do {
            try await memoryStore.save(updated)
        } catch {
            print("AgentRuntime: failed to persist turn — \(error)")
        }

        // Phase 6: fold older turns into the rolling summary once the recent
        // window overflows. The turn above is already persisted, so a failed
        // or interrupted compaction loses nothing; the next turn retries.
        // Runs inside the single-flight guard so it cannot race a save.
        if compactor.needsCompaction(updated) {
            do {
                let compacted = try await compactor.compact(updated, using: backend)
                try await memoryStore.save(compacted)
            } catch {
                print("AgentRuntime: memory compaction failed — \(error)")
            }
        }

        return AgentRunResult(userText: query, assistantText: answer)
    }

    // MARK: - Turn consumption

    private struct TurnOutput {
        var textChunks: [String]
        var toolCalls: [ToolCall]
    }

    private func consumeTurn(
        _ events: AsyncThrowingStream<LLMBackendEvent, Error>
    ) async throws -> TurnOutput {
        var output = TurnOutput(textChunks: [], toolCalls: [])
        for try await event in events {
            switch event {
            case .textDelta(let chunk):
                output.textChunks.append(chunk)
            case .toolCallsFinal(let calls):
                output.toolCalls = calls
            case .final:
                return output
            }
        }
        return output
    }

    private func replayThroughRenderer(
        _ text: String,
        shouldContinue: @escaping @MainActor () async -> Bool
    ) async {
        // Replay the final-turn text through streamAndDisplay so the renderer
        // emits prepare → cumulative text → complete (0x64) the same way it
        // does for streamed turns. We replay as one chunk because the
        // OpenRouter non-streaming path no longer fake-streams when tools
        // are involved.
        let stream = AsyncThrowingStream<String, Error> { continuation in
            continuation.yield(text)
            continuation.finish()
        }
        do {
            _ = try await renderer.streamAndDisplay(stream, shouldContinue: shouldContinue)
        } catch {
            print("AgentRuntime: renderer replay failed — \(error)")
        }
    }
}
