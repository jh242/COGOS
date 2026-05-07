import Foundation

struct AgentRunResult: Sendable {
    let userText: String
    let assistantText: String
}

/// Agent runtime skeleton: routes normalized events through durable memory,
/// context compilation, the LLM backend, and the renderer.
@MainActor
final class AgentRuntime {
    private let memoryStore: AgentMemoryStore
    private let contextCompiler: ContextCompiler
    private let renderer: EvenTextRenderer
    private let makeBackend: () -> LLMBackend?

    init(
        memoryStore: AgentMemoryStore = AgentMemoryStore(),
        contextCompiler: ContextCompiler = ContextCompiler(),
        renderer: EvenTextRenderer,
        makeBackend: @escaping () -> LLMBackend?
    ) {
        self.memoryStore = memoryStore
        self.contextCompiler = contextCompiler
        self.renderer = renderer
        self.makeBackend = makeBackend
    }

    func handle(
        _ event: AgentEvent,
        shouldContinue: @escaping @MainActor () async -> Bool
    ) async -> AgentRunResult? {
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
        let messages = contextCompiler.compile(event: event, memory: memory)
        let request = LLMRequest(messages: messages)

        do {
            let answer = try await renderer.streamAndDisplay(
                textStream(from: backend.stream(request)),
                shouldContinue: shouldContinue
            )

            var updated = memory
            updated.addTurn(userText: query, assistantText: answer)
            try await memoryStore.save(updated)

            return AgentRunResult(userText: query, assistantText: answer)
        } catch {
            await renderer.pushReply("API error: \(error.localizedDescription)")
            return nil
        }
    }

    private func textStream(
        from events: AsyncThrowingStream<LLMBackendEvent, Error>
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    for try await event in events {
                        switch event {
                        case .textDelta(let text):
                            continuation.yield(text)
                        case .final:
                            continuation.finish()
                            return
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
