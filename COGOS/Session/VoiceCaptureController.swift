import Foundation

/// Owns the glasses mic + iOS speech-recognition capture lifecycle.
///
/// Phase 1 keeps the existing behavior: start STT, enable the right mic,
/// stop on release/silence/timeout, and surface a final transcript to the
/// session facade. LLM calls and rendering intentionally stay outside here.
@MainActor
final class VoiceCaptureController {
    private let proto: Proto
    private let speech: SpeechStreamRecognizer
    private let settings: Settings

    private var combinedText: String = ""
    private var lastTranscriptChange: Date = Date()
    private var silenceTask: Task<Void, Never>?
    private var recordingTimeoutTask: Task<Void, Never>?
    private var sttTask: Task<Void, Never>?

    private let maxRecordingDuration = 30

    private(set) var isReceivingAudio = false
    var currentTranscript: String { combinedText }

    init(proto: Proto, speech: SpeechStreamRecognizer, settings: Settings) {
        self.proto = proto
        self.speech = speech
        self.settings = settings
    }

    func start(
        onSilenceDetected: @escaping @MainActor () async -> Void,
        onRecordingTimeout: @escaping @MainActor () async -> Void
    ) async {
        resetCaptureState()
        startSTT()
        isReceivingAudio = true

        _ = await proto.micOn(lr: "R")
        startSilenceTimer(onSilenceDetected: onSilenceDetected)
        startRecordingTimer(onRecordingTimeout: onRecordingTimeout)
    }

    /// Stop capture and return the best final transcript available.
    @discardableResult
    func stop() async -> String {
        isReceivingAudio = false
        silenceTask?.cancel(); silenceTask = nil
        recordingTimeoutTask?.cancel(); recordingTimeoutTask = nil
        return await shutdownMic()
    }

    /// Cancel capture without treating the transcript as a user query.
    func cancel() async {
        isReceivingAudio = false
        silenceTask?.cancel(); silenceTask = nil
        recordingTimeoutTask?.cancel(); recordingTimeoutTask = nil
        _ = await shutdownMic()
        resetCaptureState()
    }

    private func resetCaptureState() {
        combinedText = ""
        lastTranscriptChange = Date()
        silenceTask?.cancel(); silenceTask = nil
        recordingTimeoutTask?.cancel(); recordingTimeoutTask = nil
        sttTask?.cancel(); sttTask = nil
    }

    private func startSTT() {
        sttTask?.cancel()
        let stream = speech.startRecognition()
        sttTask = Task { @MainActor [weak self] in
            for await text in stream {
                guard let self = self else { return }
                if text != self.combinedText {
                    self.combinedText = text
                    self.lastTranscriptChange = Date()
                }
            }
        }
    }

    private func startSilenceTimer(onSilenceDetected: @escaping @MainActor () async -> Void) {
        silenceTask?.cancel()
        silenceTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self = self, self.isReceivingAudio else { return }
                let elapsed = Date().timeIntervalSince(self.lastTranscriptChange)
                if elapsed >= Double(self.settings.silenceThreshold) && !self.combinedText.isEmpty {
                    await onSilenceDetected()
                    return
                }
            }
        }
    }

    private func startRecordingTimer(onRecordingTimeout: @escaping @MainActor () async -> Void) {
        recordingTimeoutTask?.cancel()
        recordingTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(self?.maxRecordingDuration ?? 30) * 1_000_000_000)
            guard let self = self, self.isReceivingAudio else { return }
            await self.stop()
            await onRecordingTimeout()
        }
    }

    private func shutdownMic() async -> String {
        let finalTranscript = speech.stopRecognition()
        if !finalTranscript.isEmpty {
            combinedText = finalTranscript
        }
        sttTask?.cancel(); sttTask = nil
        _ = await proto.micOff(lr: "R")
        return combinedText
    }
}
