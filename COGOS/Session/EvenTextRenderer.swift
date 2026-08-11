import Foundation

enum EvenTextRendererError: Error, LocalizedError {
    case prepareFailed
    case transportFailed

    var errorDescription: String? {
        switch self {
        case .prepareFailed:
            return "Glasses did not acknowledge the reply."
        case .transportFailed:
            return "The reply could not be sent to the glasses."
        }
    }
}

/// G1 0x54 TEXT renderer. Network snapshots contain the full answer-so-far;
/// firmware updates are cumulative and finish with status 0x64 for scrolling.
final class EvenTextRenderer {
    private let proto: Proto

    init(proto: Proto) {
        self.proto = proto
    }

    func streamAndDisplay(
        _ snapshots: AsyncThrowingStream<String, Error>,
        shouldContinue: @escaping () async -> Bool
    ) async throws -> String {
        guard let seq = await proto.sendEvenAITextPrepare() else {
            throw EvenTextRendererError.prepareFailed
        }
        try Task.checkCancellation()
        guard await proto.sendEvenAIText(format("Thinking"), seq: seq) else {
            throw EvenTextRendererError.transportFailed
        }
        try Task.checkCancellation()

        let keepalive = Task { [proto] in
            let frames = ["Thinking.", "Thinking..", "Thinking..."]
            var index = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                if Task.isCancelled { return }
                _ = await proto.sendEvenAIText("\n\n" + frames[index % frames.count], seq: seq)
                index += 1
            }
        }

        var latest = ""
        var lastSent = ""
        do {
            for try await snapshot in snapshots {
                try Task.checkCancellation()
                guard await shouldContinue() else { break }
                keepalive.cancel()
                latest = snapshot
                if latest != lastSent {
                    guard await proto.sendEvenAIText(format(latest), seq: seq) else {
                        throw EvenTextRendererError.transportFailed
                    }
                    lastSent = latest
                }
            }
        } catch {
            keepalive.cancel()
            throw error
        }

        keepalive.cancel()
        if latest != lastSent, await shouldContinue() {
            guard await proto.sendEvenAIText(format(latest), seq: seq) else {
                throw EvenTextRendererError.transportFailed
            }
        }
        if !latest.isEmpty, await shouldContinue() {
            guard await proto.sendEvenAITextComplete(format(latest), seq: seq) else {
                throw EvenTextRendererError.transportFailed
            }
        }
        return latest
    }

    func pushReply(
        _ text: String,
        shouldContinue: @escaping () async -> Bool
    ) async -> Bool {
        guard let seq = await proto.sendEvenAITextPrepare(),
              !Task.isCancelled,
              await shouldContinue() else { return false }
        let formatted = format(text)
        guard await proto.sendEvenAIText(formatted, seq: seq),
              !Task.isCancelled,
              await shouldContinue() else { return false }
        return await proto.sendEvenAITextComplete(formatted, seq: seq)
    }

    private func format(_ text: String) -> String {
        let data = text.utf8Truncated(max: EvenAIText54.maxTextPayload - 3)
        let bounded = String(data: data, encoding: .utf8) ?? ""
        return "\n\n\(bounded)\n"
    }
}
