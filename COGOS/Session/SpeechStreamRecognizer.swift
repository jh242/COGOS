import Foundation
import AVFoundation
import Speech

/// Streaming speech recognizer using on-device SFSpeechRecognizer.
/// Un-Flutterized version of `ios/Runner/SpeechStreamRecognizer.swift`.
/// Exposes an async stream of partial transcripts.
final class SpeechStreamRecognizer {
    static let languageMap: [String: String] = [
        "CN": "zh-CN", "EN": "en-US", "RU": "ru-RU", "KR": "ko-KR",
        "JP": "ja-JP", "ES": "es-ES", "FR": "fr-FR", "DE": "de-DE",
        "NL": "nl-NL", "NB": "nb-NO", "DA": "da-DK", "SV": "sv-SE",
        "FI": "fi-FI", "IT": "it-IT"
    ]

    private var recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var lastRecognizedText = ""
    private var lastTranscription: SFTranscription?
    private var cacheString = ""

    private var transcriptContinuation: AsyncStream<String>.Continuation?

    init() {
        Task {
            _ = await SpeechStreamRecognizer.requestAuthorization()
        }
    }

    static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
    }

    /// Starts recognition. Returns an async stream of partial/accumulated transcripts.
    func startRecognition(identifier: String = "EN") -> AsyncStream<String> {
        lastTranscription = nil
        lastRecognizedText = ""
        cacheString = ""

        let locale = Locale(identifier: Self.languageMap[identifier] ?? "en-US")
        recognizer = SFSpeechRecognizer(locale: locale)
        guard let recognizer = recognizer, recognizer.isAvailable else {
            print("SpeechStreamRecognizer: recognizer not available")
            return AsyncStream { $0.finish() }
        }

        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playback, options: .mixWithOthers)
            try audioSession.setActive(true)
        } catch {
            print("SpeechStreamRecognizer: audio session error \(error)")
        }

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let req = recognitionRequest else { return AsyncStream { $0.finish() } }
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = true

        let stream = AsyncStream<String> { continuation in
            self.transcriptContinuation = continuation
        }

        recognitionTask = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self = self else { return }
            if let error = error as NSError? {
                // 1110 = "No speech detected" — expected when task is cancelled
                if error.code != 1110 {
                    print("SpeechStreamRecognizer: recognition error \(error)")
                }
                return
            }
            guard let result = result else { return }
            let current = result.bestTranscription
            if self.lastTranscription == nil {
                self.cacheString = current.formattedString
            } else {
                let lastCount = self.lastTranscription?.segments.count ?? 1
                if current.segments.count < lastCount || current.segments.count == 1 {
                    self.lastRecognizedText += self.cacheString
                    self.cacheString = ""
                } else {
                    self.cacheString = current.formattedString
                }
            }
            self.lastTranscription = current

            let combined = self.lastRecognizedText + self.cacheString
            self.transcriptContinuation?.yield(combined)
        }

        return stream
    }

    /// Stops recognition. Returns final combined transcript.
    @discardableResult
    func stopRecognition() -> String {
        lastRecognizedText += cacheString
        recognitionTask?.cancel()
        do {
            try AVAudioSession.sharedInstance().setActive(false)
        } catch {
            print("SpeechStreamRecognizer: stop audio error \(error)")
        }
        recognitionRequest = nil
        recognitionTask = nil
        recognizer = nil
        transcriptContinuation?.finish()
        transcriptContinuation = nil
        return lastRecognizedText
    }

    /// Appends 16-bit/16 kHz PCM bytes from the glasses mic.
    func appendPCMData(_ pcmData: Data) {
        guard let req = recognitionRequest else { return }
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false)!
        let frameCount = AVAudioFrameCount(pcmData.count) / format.streamDescription.pointee.mBytesPerFrame
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        buffer.frameLength = buffer.frameCapacity
        pcmData.withUnsafeBytes { bp in
            guard let src = bp.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
            let dst = buffer.int16ChannelData?.pointee
            dst?.initialize(from: src, count: pcmData.count / MemoryLayout<Int16>.size)
        }
        req.append(buffer)
    }
}
