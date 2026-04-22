import Foundation
import Combine

/// Session orchestrator: mic on/off, STT, silence detect, LLM stream,
/// glasses display.
///
/// Display path uses the firmware-native 0x54 streaming TEXT command —
/// phone emits a `prepare` packet at the start of a reply, then cumulative
/// text updates as tokens arrive. Firmware owns pagination and scroll.
@MainActor
final class EvenAISession: ObservableObject {
    // MARK: - Published

    @Published var isRunning = false
    @Published var isReceivingAudio = false
    @Published var isSyncing = false
    @Published var dynamicText: String = "Press and hold left TouchBar to engage Even AI."
    @Published var mode: SessionMode = .chat

    // MARK: - Collaborators

    private let proto: Proto
    private let speech: SpeechStreamRecognizer
    private let settings: Settings
    weak var historyStore: HistoryStore?

    // MARK: - State

    private let session = ClaudeSession()
    private var combinedText: String = ""
    private var lastTranscriptChange: Date = Date()
    private var silenceTask: Task<Void, Never>?
    private var recordingTimeoutTask: Task<Void, Never>?
    private var sttTask: Task<Void, Never>?

    private var lastStartMs: Int = 0
    private var lastStopMs: Int = 0
    private let startTimeGap = 500
    private let stopTimeGap = 500
    private let maxRecordingDuration = 30

    init(proto: Proto, speech: SpeechStreamRecognizer, settings: Settings) {
        self.proto = proto
        self.speech = speech
        self.settings = settings
    }

    // MARK: - Lifecycle

    func toStartEvenAIByOS() async {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        if now - lastStartMs < startTimeGap { return }
        lastStartMs = now

        combinedText = ""
        lastTranscriptChange = Date()
        startSTT()

        clear()
        isReceivingAudio = true
        isRunning = true
        isSyncing = true

        _ = await proto.micOn(lr: "R")
        startSilenceTimer()
        startRecordingTimer()
    }

    private func startSTT() {
        sttTask?.cancel()
        let stream = speech.startRecognition()
        sttTask = Task { [weak self] in
            for await text in stream {
                guard let self = self else { return }
                if text != self.combinedText {
                    self.combinedText = text
                    self.lastTranscriptChange = Date()
                }
            }
        }
    }

    private func startSilenceTimer() {
        silenceTask?.cancel()
        silenceTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self = self, self.isReceivingAudio else { return }
                let elapsed = Date().timeIntervalSince(self.lastTranscriptChange)
                if elapsed >= Double(self.settings.silenceThreshold) && !self.combinedText.isEmpty {
                    await self.recordOverByOS()
                    return
                }
            }
        }
    }

    private func startRecordingTimer() {
        recordingTimeoutTask?.cancel()
        recordingTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(self?.maxRecordingDuration ?? 30) * 1_000_000_000)
            guard let self = self else { return }
            if self.isReceivingAudio {
                await self.shutdownMic()
                self.clear()
            }
        }
    }

    private func shutdownMic() async {
        _ = speech.stopRecognition()
        _ = await proto.micOff(lr: "R")
    }

    func recordOverByOS() async {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        if now - lastStopMs < stopTimeGap { return }
        lastStopMs = now

        isReceivingAudio = false
        silenceTask?.cancel(); silenceTask = nil
        recordingTimeoutTask?.cancel(); recordingTimeoutTask = nil

        await shutdownMic()
        try? await Task.sleep(nanoseconds: 2_000_000_000)

        if combinedText.isEmpty {
            dynamicText = "No Speech Recognized"
            isSyncing = false
            await pushReply("No Speech Recognized")
            return
        }

        let query = combinedText
        var fullAnswer = ""

        guard let client = settings.makeChatClient() else {
            isSyncing = false
            await pushReply("No API key set. Add key in Settings.")
            return
        }

        do {
            fullAnswer = try await streamAndDisplay(client.stream(message: query, session: session))
        } catch {
            isSyncing = false
            await pushReply("API error: \(error.localizedDescription)")
            return
        }

        isSyncing = false
        session.addUser(query)
        session.addAssistant(fullAnswer)
        session.lastQuery = query
        session.lastAnswer = fullAnswer
        historyStore?.addItem(title: query, content: fullAnswer)
        dynamicText = "\(query)\n\n\(fullAnswer)"
    }

    // MARK: - Streaming display

    /// Prepare + cumulative 0x54 updates. Firmware owns pagination, so we
    /// just feed it the full answer-so-far on every tick. Backpressure is
    /// natural: each `sendEvenAIText` awaits L+R C9 before returning.
    private func streamAndDisplay(_ stream: AsyncThrowingStream<String, Error>) async throws -> String {
        _ = await proto.sendEvenAITextPrepare()
        _ = await proto.sendEvenAIText(format("Thinking"))

        let keepalive = Task { [proto] in
            let frames = ["Thinking.", "Thinking..", "Thinking..."]
            var i = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                if Task.isCancelled { return }
                _ = await proto.sendEvenAIText("\n\n" + frames[i % frames.count])
                i += 1
            }
        }

        var accumulated = ""
        var lastSent = ""
        do {
            for try await chunk in stream {
                if !isRunning { break }
                if keepalive.isCancelled == false { keepalive.cancel() }
                accumulated += chunk
                if accumulated != lastSent {
                    _ = await proto.sendEvenAIText(format(accumulated))
                    lastSent = accumulated
                }
            }
        } catch {
            keepalive.cancel()
            throw error
        }
        keepalive.cancel()
        if accumulated != lastSent && isRunning {
            _ = await proto.sendEvenAIText(format(accumulated))
        }
        // Match OEM reply shape: close the channel with a sub=0x01 packet.
        if isRunning && !accumulated.isEmpty {
            _ = await proto.sendEvenAIClose()
        }
        return accumulated
    }

    /// One-shot reply (errors, "no speech", reset messages). Uses the same
    /// prepare+text pair so the firmware accepts it as a fresh message.
    private func pushReply(_ text: String) async {
        _ = await proto.sendEvenAITextPrepare()
        _ = await proto.sendEvenAIText(format(text))
    }

    /// Two leading newlines push the first line below the dashboard header,
    /// matching the official app's framing. Trailing newline mirrors the
    /// Even app's per-update terminator — without it, firmware renders the
    /// first ~3 lines and stops advancing the viewport as new tokens arrive.
    private func format(_ text: String) -> String { "\n\n\(text)\n" }

    func resetSession() {
        session.reset()
        Task { await pushReply("Session reset") }
    }

    func stopEvenAIByOS() async {
        isRunning = false
        clear()
        await shutdownMic()
    }

    func exitAll() {
        Task { await stopEvenAIByOS() }
    }

    func clear() {
        isReceivingAudio = false
        isRunning = false
        recordingTimeoutTask?.cancel(); recordingTimeoutTask = nil
        silenceTask?.cancel(); silenceTask = nil
    }
}
