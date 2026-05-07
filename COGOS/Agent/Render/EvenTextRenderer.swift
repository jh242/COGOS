import Foundation

/// Semantic render events for the future agent runtime.
enum AgentRunEvent {
    case started
    case thinking(String?)
    case partialText(String)
    case toolStarted(name: String)
    case toolFinished(name: String)
    case finalText(String)
    case failed(String)
}

/// Renderer abstraction used by the agent runtime plan. Phase 1 only needs
/// the G1 implementation, but keeping the semantic boundary here prevents
/// model/session logic from owning firmware display details again.
protocol AgentRenderer {
    func render(_ event: AgentRunEvent) async
}

/// G1 0x54 TEXT renderer.
///
/// Each visible reply is one firmware text message: prepare once, send
/// cumulative streaming updates, then re-send the final cumulative text with
/// status 0x64 so native single-tap page scroll is enabled.
final class EvenTextRenderer: AgentRenderer {
    private let proto: Proto

    init(proto: Proto) {
        self.proto = proto
    }

    func render(_ event: AgentRunEvent) async {
        switch event {
        case .started:
            break
        case .thinking(let text):
            await pushReply(text ?? "Thinking")
        case .partialText(let text), .finalText(let text):
            await pushReply(text)
        case .toolStarted(let name):
            await pushReply("Working: \(name)")
        case .toolFinished:
            break
        case .failed(let message):
            await pushReply(message)
        }
    }

    /// Prepare + cumulative 0x54 updates. Firmware owns pagination, so this
    /// feeds the full answer-so-far on every tick. Backpressure is natural:
    /// each send awaits L+R ACKs before returning.
    func streamAndDisplay(
        _ stream: AsyncThrowingStream<String, Error>,
        shouldContinue: @escaping () async -> Bool
    ) async throws -> String {
        let seq = await proto.sendEvenAITextPrepare()
        _ = await proto.sendEvenAIText(format("Thinking"), seq: seq)

        let keepalive = Task { [proto] in
            let frames = ["Thinking.", "Thinking..", "Thinking..."]
            var i = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                if Task.isCancelled { return }
                _ = await proto.sendEvenAIText("\n\n" + frames[i % frames.count], seq: seq)
                i += 1
            }
        }

        var accumulated = ""
        var lastSent = ""
        do {
            for try await chunk in stream {
                if !(await shouldContinue()) { break }
                if keepalive.isCancelled == false { keepalive.cancel() }
                accumulated += chunk
                if accumulated != lastSent {
                    _ = await proto.sendEvenAIText(format(accumulated), seq: seq)
                    lastSent = accumulated
                }
            }
        } catch {
            keepalive.cancel()
            throw error
        }

        keepalive.cancel()
        if accumulated != lastSent, await shouldContinue() {
            _ = await proto.sendEvenAIText(format(accumulated), seq: seq)
        }

        // Flip firmware into scrollable mode: re-send the full answer with
        // status=0x64. Without this, the display stays pinned to the last
        // few lines and single-tap page scroll is unreliable/no-op.
        if !accumulated.isEmpty, await shouldContinue() {
            _ = await proto.sendEvenAITextComplete(format(accumulated), seq: seq)
        }
        return accumulated
    }

    /// One-shot reply (errors, "no speech", reset messages). Uses the same
    /// prepare/text/complete shape as streamed answers so multi-page messages
    /// also enter firmware scroll mode.
    func pushReply(_ text: String) async {
        let seq = await proto.sendEvenAITextPrepare()
        let formatted = format(text)
        _ = await proto.sendEvenAIText(formatted, seq: seq)
        _ = await proto.sendEvenAITextComplete(formatted, seq: seq)
    }

    /// Two leading newlines push the first line below the dashboard header,
    /// matching the official app's framing. Trailing newline mirrors the
    /// Even app's per-update terminator — without it, firmware renders the
    /// first ~3 lines and stops advancing the viewport as new tokens arrive.
    private func format(_ text: String) -> String { "\n\n\(text)\n" }
}
