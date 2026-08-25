import Foundation
import Combine

/// Coordinates glasses voice capture, model transport, and G1 text rendering.
@MainActor
final class EvenAISession: ObservableObject {
    // MARK: - Published

    @Published var isRunning = false
    @Published var isReceivingAudio = false
    @Published var isSyncing = false
    @Published var dynamicText: String = "Hold the left TouchBar to ask COGOS a question."

    var isScrollViewerActive: Bool { renderer.isScrollViewerActive }
    var isViewerActive: Bool { renderer.isViewerActive }

    // MARK: - Collaborators

    private let voice: VoiceCaptureController
    private let renderer: EvenTextRenderer
    private let settings: Settings
    private let location: NativeLocation
    weak var historyStore: HistoryStore?

    // MARK: - State

    private var lastStartMs: Int = 0
    private let startTimeGap = 500
    private var activeResponseTask: Task<String?, Never>?
    private var activeTurnID: UUID?
    private var isStartingCapture = false
    private var spokenAgent: OpenRouterSpokenAgent?

    init(
        proto: Proto,
        speech: SpeechStreamRecognizer,
        settings: Settings,
        location: NativeLocation
    ) {
        let renderer = EvenTextRenderer(proto: proto)
        self.voice = VoiceCaptureController(proto: proto, speech: speech, settings: settings)
        self.renderer = renderer
        self.settings = settings
        self.location = location
    }

    // MARK: - Lifecycle

    func toStartEvenAIByOS() async {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        if now - lastStartMs < startTimeGap { return }
        lastStartMs = now

        isStartingCapture = true
        await cancelActiveResponse()
        guard isStartingCapture else { return }
        isStartingCapture = false
        clear()
        isReceivingAudio = true
        isRunning = true
        isSyncing = true

        await voice.start(
            onSilenceDetected: { [weak self] in
                await self?.recordOverByOS()
            },
            onRecordingTimeout: { [weak self] in
                await self?.recordOverByOS()
            }
        )
    }

    func recordOverByOS() async {
        guard isReceivingAudio else {
            isStartingCapture = false
            return
        }
        isReceivingAudio = false
        let query = await voice.stop()

        if query.isEmpty {
            dynamicText = "No speech recognized. Try asking again."
            isSyncing = false
            await pushOneShot(dynamicText)
            return
        }

        switch settings.spokenBackend {
        case .hermes:
            await runHermesTurn(query: query)
        case .openRouter:
            await runOpenRouterTurn(query: query)
        }
    }

    func stopEvenAIByOS() async {
        isRunning = false
        isStartingCapture = false
        await cancelActiveResponse()
        clear()
        await voice.cancel()
    }

    func exitAll() {
        Task { await stopEvenAIByOS() }
    }

    func advanceScrollPage(arm: String) async {
        await renderer.navigate(arm: arm)
    }

    func exitViewer() async {
        if isSyncing {
            await cancelActiveResponse()
            return
        }
        await renderer.exitViewer()
    }

    func clear() {
        isReceivingAudio = false
        isRunning = false
    }

    private func runHermesTurn(query: String) async {
        guard let client = settings.makeHermesClient() else {
            dynamicText = "Set a valid HTTPS Hermes endpoint and token in Settings."
            isSyncing = false
            await pushOneShot(dynamicText)
            return
        }

        await runTurn(query: query, waitingMessage: "Waiting for Hermes…") { [weak self] shouldContinue in
            guard let self else { return nil }
            return try await self.renderer.streamAndDisplay(
                client.streamResponse(to: query),
                onSnapshot: { [weak self] snapshot in
                    self?.dynamicText = "\(query)\n\n\(snapshot)"
                },
                shouldContinue: shouldContinue
            )
        }
    }

    private func runOpenRouterTurn(query: String) async {
        guard let agent = resolveSpokenAgent() else {
            dynamicText = "Set an OpenRouter API key in Settings."
            isSyncing = false
            await pushOneShot(dynamicText)
            return
        }

        await runTurn(query: query, waitingMessage: "Thinking…") { [weak self] shouldContinue in
            guard let self else { return nil }
            guard await shouldContinue() else { return nil }
            _ = await self.renderer.pushReply("Thinking…", shouldContinue: shouldContinue)
            guard await shouldContinue() else { return nil }
            let answer = try await agent.respond(to: query)
            guard await shouldContinue() else { return nil }
            _ = await self.renderer.pushReply(answer, shouldContinue: shouldContinue)
            return answer
        }
    }

    private func runTurn(
        query: String,
        waitingMessage: String,
        work: @escaping (@escaping () async -> Bool) async throws -> String?
    ) async {
        let turnID = UUID()
        activeTurnID = turnID
        dynamicText = "\(query)\n\n\(waitingMessage)"
        let task = Task { @MainActor [weak self] () -> String? in
            guard let self else { return nil }
            do {
                return try await work { [weak self] in
                    guard let self else { return false }
                    return self.activeTurnID == turnID
                }
            } catch is CancellationError {
                return nil
            } catch {
                guard self.activeTurnID == turnID else { return nil }
                let message = error.localizedDescription
                self.dynamicText = "\(query)\n\n\(message)"
                print("Even AI response failed: \(message)")
                await self.renderer.reset()
                return nil
            }
        }
        activeResponseTask = task
        let answer = await task.value

        guard activeTurnID == turnID else { return }
        activeResponseTask = nil
        activeTurnID = nil
        isSyncing = false
        if let answer, !answer.isEmpty {
            historyStore?.addItem(title: query, content: answer)
            dynamicText = "\(query)\n\n\(answer)"
        }
    }

    private func resolveSpokenAgent() -> OpenRouterSpokenAgent? {
        guard let credentials = settings.openRouterAgentCredentials() else {
            spokenAgent = nil
            return nil
        }
        if let spokenAgent, spokenAgent.matches(apiKey: credentials.apiKey, model: credentials.model) {
            return spokenAgent
        }
        let agent = OpenRouterSpokenAgent(
            apiKey: credentials.apiKey,
            model: credentials.model,
            sessionID: settings.hermesConversationID,
            location: location
        )
        spokenAgent = agent
        return agent
    }

    private func cancelActiveResponse() async {
        activeTurnID = nil
        let task = activeResponseTask
        activeResponseTask = nil
        task?.cancel()
        _ = await task?.value
        await renderer.reset()
        isSyncing = false
    }

    private func pushOneShot(_ text: String) async {
        let turnID = UUID()
        activeTurnID = turnID
        let task = Task { @MainActor [weak self] () -> String? in
            guard let self else { return nil }
            _ = await renderer.pushReply(
                text,
                shouldContinue: { [weak self] in
                    guard let self else { return false }
                    return self.activeTurnID == turnID
                }
            )
            return nil
        }
        activeResponseTask = task
        _ = await task.value
        guard activeTurnID == turnID else { return }
        activeResponseTask = nil
        activeTurnID = nil
    }
}
