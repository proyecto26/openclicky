//
//  ElevenLabsConfig.swift
//  Locates the user's ElevenLabs API key + voice ID, if they've set one.
//
//  Two sources in priority order:
//    1. Environment variables CLICKY_ELEVENLABS_API_KEY +
//       CLICKY_ELEVENLABS_VOICE_ID. Works when the user launches Clicky
//       from a terminal that has the vars set, or has run
//       `launchctl setenv CLICKY_ELEVENLABS_API_KEY …` for GUI-wide
//       propagation.
//    2. JSON file at ~/Library/Application Support/Clicky/elevenlabs.json:
//         { "apiKey": "sk-...", "voiceId": "kPzsL2i3teMYv0FxEYQ6" }
//       No launchctl required — just drop the file.
//
//  Keychain storage is a natural v2 upgrade but adds a full Keychain API
//  dance + a panel UI for entry; env/file covers the power-user case
//  today without shipping any credentials.
//

import Foundation
import os

struct ElevenLabsConfig {
    /// Pretty default voice — "Rachel" on ElevenLabs' free tier. Users
    /// can override via env or the JSON file.
    static let defaultVoiceId = "kPzsL2i3teMYv0FxEYQ6"

    let apiKey: String
    let voiceId: String

    /// Returns nil when neither source yielded a key.
    static func load() -> ElevenLabsConfig? {
        let logger = Logger(subsystem: "com.proyecto26.clicky", category: "ElevenLabsConfig")

        if let env = loadFromEnvironment() {
            logger.info("ElevenLabs config loaded from environment")
            return env
        }
        if let file = loadFromFile() {
            logger.info("ElevenLabs config loaded from \(fileURL.path, privacy: .public)")
            return file
        }
        return nil
    }

    // MARK: - Sources

    private static func loadFromEnvironment() -> ElevenLabsConfig? {
        let env = ProcessInfo.processInfo.environment
        guard let key = env["CLICKY_ELEVENLABS_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else {
            return nil
        }
        let voice = env["CLICKY_ELEVENLABS_VOICE_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ElevenLabsConfig(apiKey: key, voiceId: voice?.isEmpty == false ? voice! : defaultVoiceId)
    }

    private static var fileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("Clicky", isDirectory: true)
            .appendingPathComponent("elevenlabs.json", isDirectory: false)
    }

    private static func loadFromFile() -> ElevenLabsConfig? {
        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        do {
            let data = try Data(contentsOf: url)
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            guard let key = (obj["apiKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !key.isEmpty else {
                return nil
            }
            let voice = (obj["voiceId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return ElevenLabsConfig(apiKey: key, voiceId: voice?.isEmpty == false ? voice! : defaultVoiceId)
        } catch {
            return nil
        }
    }
}
