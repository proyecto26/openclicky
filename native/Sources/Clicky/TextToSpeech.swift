//
//  TextToSpeech.swift
//  Speaks Claude's reply. Two backends, picked automatically at init:
//
//    1. ElevenLabs — if ElevenLabsConfig.load() returns a key (env var
//       or JSON file). Streams MP3 from the text-to-speech API and
//       plays via AVAudioPlayer. Falls back to AVSpeech on any error.
//    2. AVSpeechSynthesizer — default, zero-config, uses the user's
//       Spoken Content system voice.
//
//  Backend selection is sticky for the lifetime of the process; users
//  who add/remove the key need to quit + relaunch (same shape as the
//  Screen Recording TCC quit-and-relaunch requirement).
//

import AVFoundation
import Foundation
import os

@MainActor
final class TextToSpeech: NSObject {
    private let logger = Logger(subsystem: "com.proyecto26.clicky", category: "TextToSpeech")
    private let elevenLabsConfig: ElevenLabsConfig?

    @Published private(set) var isSpeaking: Bool = false

    // System speech path
    private let synthesizer = AVSpeechSynthesizer()
    private var synthContinuation: CheckedContinuation<Void, Never>?

    // ElevenLabs playback path
    private var audioPlayer: AVAudioPlayer?
    private var audioPlayerDelegate: AudioPlayerCompletionBridge?
    private var playerContinuation: CheckedContinuation<Void, Never>?

    /// Human-readable label for the footer / diagnostics. Honest about
    /// which backend is actually active so users can tell without
    /// wading through logs.
    var activeBackendDisplayName: String {
        elevenLabsConfig == nil ? "macOS Speech" : "ElevenLabs (\(elevenLabsConfig!.voiceId.prefix(8))…)"
    }

    override init() {
        self.elevenLabsConfig = ElevenLabsConfig.load()
        super.init()
        synthesizer.delegate = self
        logger.info("TTS backend: \(self.activeBackendDisplayName, privacy: .public)")
    }

    /// Speaks `text` and returns when playback finishes (or is cancelled
    /// via `stop()`). Concurrent calls replace the in-flight utterance.
    func speak(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        stop() // replace any in-flight utterance

        if let config = elevenLabsConfig {
            do {
                try await speakViaElevenLabs(trimmed, config: config)
                return
            } catch {
                // Network / API / playback error. Don't leave the user
                // in silence — fall back to the system voice.
                logger.warning("ElevenLabs TTS failed, falling back to AVSpeech: \(error.localizedDescription, privacy: .public)")
            }
        }
        await speakViaSystem(trimmed)
    }

    /// Cancels any in-flight utterance.
    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
            resume(&synthContinuation)
        }
        if audioPlayer?.isPlaying == true {
            audioPlayer?.stop()
            resume(&playerContinuation)
        }
        isSpeaking = false
    }

    // MARK: - System speech path

    private func speakViaSystem(_ text: String) async {
        let utterance = AVSpeechUtterance(string: text)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            synthContinuation = cont
            isSpeaking = true
            synthesizer.speak(utterance)
        }
    }

    // MARK: - ElevenLabs path

    private func speakViaElevenLabs(_ text: String, config: ElevenLabsConfig) async throws {
        let mp3Data = try await fetchElevenLabsAudio(text: text, config: config)
        try await playAudio(mp3Data)
    }

    private func fetchElevenLabsAudio(text: String, config: ElevenLabsConfig) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(config.voiceId)")!)
        request.httpMethod = "POST"
        request.setValue(config.apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "accept")

        let body: [String: Any] = [
            "text": text,
            "model_id": "eleven_flash_v2_5",
            "voice_settings": [
                "stability": 0.5,
                "similarity_boost": 0.75,
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "ElevenLabs", code: -1, userInfo: [NSLocalizedDescriptionKey: "no HTTP response"])
        }
        guard (200...299).contains(http.statusCode) else {
            let preview = String(data: data.prefix(400), encoding: .utf8) ?? "<binary>"
            throw NSError(
                domain: "ElevenLabs",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(preview)"]
            )
        }
        return data
    }

    private func playAudio(_ mp3Data: Data) async throws {
        let player = try AVAudioPlayer(data: mp3Data)
        let bridge = AudioPlayerCompletionBridge { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.isSpeaking = false
                self.resume(&self.playerContinuation)
            }
        }
        player.delegate = bridge
        self.audioPlayer = player
        self.audioPlayerDelegate = bridge
        player.prepareToPlay()

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            playerContinuation = cont
            isSpeaking = true
            player.play()
        }
    }

    // MARK: - Helpers

    private func resume(_ continuation: inout CheckedContinuation<Void, Never>?) {
        guard let c = continuation else { return }
        continuation = nil
        c.resume()
    }
}

// MARK: - AVSpeechSynthesizer delegate

extension TextToSpeech: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
            self.resume(&self.synthContinuation)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
            self.resume(&self.synthContinuation)
        }
    }
}

// MARK: - AVAudioPlayer completion bridge

/// NSObject subclass that implements AVAudioPlayerDelegate with a
/// closure-style completion. Separated from TextToSpeech so the
/// delegate doesn't need @MainActor isolation negotiation.
private final class AudioPlayerCompletionBridge: NSObject, AVAudioPlayerDelegate {
    private let onFinish: () -> Void

    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinish()
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        onFinish()
    }
}
