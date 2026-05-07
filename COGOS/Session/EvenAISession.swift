import Foundation
import Combine

/// Compatibility session facade: keeps the SwiftUI/public gesture API stable
/// while delegating voice capture and G1 text rendering to dedicated Phase 1
/// components.
@MainActor
final class EvenAISession: ObservableObject {
    // MARK: - Published

    @Published var isRunning = false
    @Published var isReceivingAudio = false
    @Published var isSyncing = false
    @Published var dynamicText: String = "Hold the left TouchBar to ask COGOS a question."
    @Published var mode: SessionMode = .chat

    // MARK: - Collaborators

    private let voice: VoiceCaptureController
    private let renderer: EvenTextRenderer
    private let runtime: AgentRuntime
    weak var historyStore: HistoryStore?

    // MARK: - State

    private var lastStartMs: Int = 0
    private var lastStopMs: Int = 0
    private let startTimeGap = 500
    private let stopTimeGap = 500

    init(proto: Proto, speech: SpeechStreamRecognizer, settings: Settings) {
        let renderer = EvenTextRenderer(proto: proto)
        self.voice = VoiceCaptureController(proto: proto, speech: speech, settings: settings)
        self.renderer = renderer
        self.runtime = AgentRuntime(renderer: renderer) { settings.makeLLMBackend() }
    }

    // MARK: - Lifecycle

    func toStartEvenAIByOS() async {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        if now - lastStartMs < startTimeGap { return }
        lastStartMs = now

        clear()
        isReceivingAudio = true
        isRunning = true
        isSyncing = true

        await voice.start(
            onSilenceDetected: { [weak self] in
                await self?.recordOverByOS()
            },
            onRecordingTimeout: { [weak self] in
                self?.handleRecordingTimeout()
            }
        )
    }

    func recordOverByOS() async {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        if now - lastStopMs < stopTimeGap { return }
        lastStopMs = now

        isReceivingAudio = false
        let query = await voice.stop()
        try? await Task.sleep(nanoseconds: 2_000_000_000)

        if query.isEmpty {
            dynamicText = "No speech recognized. Try asking again."
            isSyncing = false
            await renderer.pushReply("No speech recognized. Try asking again.")
            return
        }

        let result = await runtime.handle(
            .voiceTranscriptFinal(query),
            shouldContinue: { [weak self] in
                await MainActor.run { self?.isRunning ?? false }
            }
        )

        isSyncing = false
        if let result {
            historyStore?.addItem(title: result.userText, content: result.assistantText)
            dynamicText = "\(result.userText)\n\n\(result.assistantText)"
        }
    }

    func resetSession() {
        Task { await runtime.handle(.resetRequested, shouldContinue: { true }) }
    }

    func stopEvenAIByOS() async {
        isRunning = false
        clear()
        await voice.cancel()
    }

    func exitAll() {
        Task { await stopEvenAIByOS() }
    }

    func clear() {
        isReceivingAudio = false
        isRunning = false
    }

    private func handleRecordingTimeout() {
        clear()
    }
}
