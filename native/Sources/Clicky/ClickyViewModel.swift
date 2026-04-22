//
//  ClickyViewModel.swift
//  Observable state for the panel. Probes the `claude` CLI on launch,
//  orchestrates the push-to-talk flow (hotkey → dictation → Claude →
//  TTS → POINT tag), and persists session IDs across launches.
//

import Combine
import Foundation
import SwiftUI
import os

/// Coarse state for the panel UI — idle / listening / thinking / speaking.
enum CompanionState: Equatable {
    case idle
    case listening
    case thinking
    case speaking
}

@MainActor
final class ClickyViewModel: ObservableObject {
    // MARK: - Claude CLI + session

    @Published var isClaudeCLIAvailable: Bool = true
    @Published var claudeBinaryPath: String?
    @Published var claudeVersion: String?
    @Published var isRunningTurn: Bool = false
    @Published var streamingText: String = ""
    @Published var lastError: String?
    @Published var lastSessionId: String?

    // MARK: - Screen Recording permission

    let screenRecordingPermission = ScreenRecordingPermission()
    @Published var hasScreenRecordingPermission: Bool
    @Published var requiresRelaunchForScreenRecording: Bool = false

    // MARK: - Push-to-talk (hotkey + mic + STT + TTS)

    let pushToTalkMonitor = PushToTalkMonitor()
    let dictationManager = DictationManager()
    let accessibilityPermission = AccessibilityPermission()
    let textToSpeech = TextToSpeech()
    let overlayManager = OverlayManager()

    @Published var hasAccessibilityPermission: Bool
    @Published var state: CompanionState = .idle
    @Published var currentAudioLevel: CGFloat = 0
    @Published var lastPointTag: PointTag? = nil
    @Published var dictationPermissionProblem: DictationPermissionProblem? = nil

    // MARK: - Private

    private let logger = Logger(subsystem: "com.proyecto26.clicky", category: "ClickyViewModel")
    private var currentTask: Task<Void, Never>?
    private var observations: Set<AnyCancellable> = []

    init() {
        self.hasScreenRecordingPermission = screenRecordingPermission.isGranted
        self.hasAccessibilityPermission = accessibilityPermission.isGranted

        screenRecordingPermission.$isGranted
            .receive(on: DispatchQueue.main)
            .sink { [weak self] granted in self?.hasScreenRecordingPermission = granted }
            .store(in: &observations)

        screenRecordingPermission.$requiresRelaunch
            .receive(on: DispatchQueue.main)
            .sink { [weak self] req in self?.requiresRelaunchForScreenRecording = req }
            .store(in: &observations)

        accessibilityPermission.$isGranted
            .receive(on: DispatchQueue.main)
            .sink { [weak self] granted in
                self?.hasAccessibilityPermission = granted
                if granted {
                    self?.pushToTalkMonitor.start()
                }
            }
            .store(in: &observations)

        dictationManager.$currentAudioLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] level in self?.currentAudioLevel = level }
            .store(in: &observations)

        dictationManager.$currentPermissionProblem
            .receive(on: DispatchQueue.main)
            .sink { [weak self] problem in self?.dictationPermissionProblem = problem }
            .store(in: &observations)

        pushToTalkMonitor.transitions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleHotkeyTransition(transition)
            }
            .store(in: &observations)

        if !hasScreenRecordingPermission {
            screenRecordingPermission.startWatching()
        }
        if hasAccessibilityPermission {
            pushToTalkMonitor.start()
        } else {
            accessibilityPermission.startWatching()
        }
    }

    /// System prompt derived from the upstream Clicky persona. Kept tight so
    /// the CLI's input tokens stay low while still carrying the POINT tag
    /// contract the panel parses on every reply.
    static let systemPrompt: String = """
    you're clicky, a friendly screen-aware companion. the user is looking at their mac screen. \
    reply in one or two sentences, lowercase, warm, conversational. no emojis, no bullet lists, \
    no markdown. reference specific things on screen when relevant. if you want to flag a ui \
    element, append a tag `[POINT:x,y:label]` at the end where x,y are pixel coordinates in the \
    screenshot's pixel space and label is 1-3 words. if pointing wouldn't help, omit the tag.
    """

    // MARK: - Claude CLI probe

    func refreshClaudeCLIStatus() async {
        do {
            let binary = try ClaudeCLIRunner.locate()
            let version = await ClaudeCLIRunner.probeVersion(at: binary)
            isClaudeCLIAvailable = true
            claudeBinaryPath = binary.path
            claudeVersion = version
        } catch {
            isClaudeCLIAvailable = false
            claudeBinaryPath = nil
            claudeVersion = nil
        }
    }

    // MARK: - Permission helpers

    func requestScreenRecordingPermission() { screenRecordingPermission.request() }
    func openScreenRecordingSettings() { screenRecordingPermission.openSystemSettings() }
    func requestAccessibilityPermission() { accessibilityPermission.request() }
    func openAccessibilitySettings() { accessibilityPermission.openSystemSettings() }

    func openMicrophoneSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else { return }
        NSWorkspace.shared.open(url)
    }
    func openSpeechRecognitionSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition") else { return }
        NSWorkspace.shared.open(url)
    }

    func retryPermissions() {
        Task { await dictationManager.requestPermissions() }
    }

    // MARK: - Push-to-talk

    private func handleHotkeyTransition(_ transition: PushToTalkShortcut.Transition) {
        switch transition {
        case .pressed:
            guard !isRunningTurn, state == .idle else { return }
            startListening()
        case .released:
            guard state == .listening else { return }
            finishListening()
        case .none:
            break
        }
    }

    private func startListening() {
        state = .listening
        lastError = nil
        streamingText = ""
        lastPointTag = nil
        Task { @MainActor in
            await dictationManager.startListening { [weak self] transcript in
                self?.runTurnFromVoice(userPrompt: transcript)
            }
        }
    }

    private func finishListening() {
        state = .thinking
        dictationManager.stopListening()
        // dictationManager will call onFinalTranscript once the STT pipeline
        // delivers; that callback fires runTurnFromVoice below.
    }

    private func runTurnFromVoice(userPrompt: String) {
        runTurn(userPrompt: userPrompt, thenSpeak: true)
    }

    // MARK: - Turn execution

    /// Captures ALL displays, dispatches a single turn to Claude,
    /// streams the reply. When `thenSpeak` is true, plays TTS and then
    /// drives the overlay cursor to any POINT target Claude emitted.
    func runTurn(userPrompt: String, thenSpeak: Bool = false) {
        guard !isRunningTurn else { return }
        currentTask?.cancel()
        isRunningTurn = true
        state = thenSpeak ? .thinking : state
        streamingText = ""
        lastError = nil
        lastPointTag = nil

        currentTask = Task { @MainActor in
            defer { isRunningTurn = false }
            do {
                let manifest = try await ScreenCapture.captureAllDisplays()
                let binary = try ClaudeCLIRunner.locate()
                let runner = ClaudeCLIRunner(binaryURL: binary)
                let resume = SessionPersistence.shared.load()

                // Build one ClaudeCLIMessage containing every display's
                // JPEG + its labeled dimensions, so Claude can reason
                // about multi-monitor layouts and emit :screenN.
                let contentImages = manifest.screens.map {
                    ClaudeCLIMessage.Image(
                        mediaType: "image/jpeg",
                        base64: $0.jpegData.base64EncodedString()
                    )
                }
                let labelText = manifest.screens
                    .map { "\($0.label) (image dimensions: \($0.widthPx)x\($0.heightPx) pixels)" }
                    .joined(separator: "\n")

                let message = ClaudeCLIMessage(
                    role: .user,
                    text: "\(labelText)\n\(userPrompt)",
                    images: contentImages
                )

                let result = try await runner.ask(
                    messages: [message],
                    systemPrompt: Self.systemPrompt,
                    model: "claude-sonnet-4-6",
                    resumeSessionId: resume
                ) { [weak self] chunk in
                    Task { @MainActor [weak self] in
                        self?.streamingText = chunk.accumulatedText
                    }
                }

                if let sessionId = result.sessionId {
                    lastSessionId = sessionId
                    SessionPersistence.shared.save(sessionId: sessionId)
                }

                // Parse POINT tag + strip it before TTS.
                let parsed = PointTagParser.parse(result.text)
                lastPointTag = parsed.point
                streamingText = parsed.spokenText

                // Map the tag's screenshot-pixel coords to a global
                // AppKit CGPoint using the freshly-captured manifest.
                let mapped = PointCoordinateMapper.map(point: parsed.point, manifest: manifest)

                if thenSpeak {
                    state = .speaking
                    await textToSpeech.speak(parsed.spokenText)
                }

                // Fire the overlay AFTER TTS so the user hears
                // "look at the save button" *before* the cursor moves —
                // matches upstream Clicky's timing.
                if let mapped {
                    overlayManager.flyTo(BlueCursorTarget(
                        globalLocation: mapped.globalLocation,
                        displayFrame: mapped.displayFrame,
                        label: mapped.label
                    ))
                }

                state = .idle
            } catch is CancellationError {
                lastError = "Cancelled."
                state = .idle
            } catch let error as ClaudeCLIError {
                lastError = error.description
                state = .idle
            } catch let error as ScreenCaptureError {
                if isTCCDeclinedError(error) {
                    lastError = nil
                    screenRecordingPermission.handleRuntimeTCCDenial()
                } else {
                    lastError = error.description
                }
                state = .idle
            } catch {
                lastError = error.localizedDescription
                state = .idle
            }
        }
    }

    /// Text-input entry point kept for debugging + users without a mic.
    /// The name preserves the v0.1 "Test Claude" button wiring.
    func runTestTurn(userPrompt: String) {
        runTurn(userPrompt: userPrompt, thenSpeak: false)
    }

    func cancelCurrentTurn() {
        currentTask?.cancel()
        textToSpeech.stop()
        dictationManager.cancelListening()
        state = .idle
    }

    func clearConversation() {
        SessionPersistence.shared.clear()
        lastSessionId = nil
        streamingText = ""
        lastError = nil
        lastPointTag = nil
    }

    func openClaudeCodeInstallPage() {
        guard let url = URL(string: "https://claude.com/claude-code") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - ElevenLabs settings

    /// Saves the user's ElevenLabs credentials to Keychain and hot-swaps
    /// the TTS backend. The next reply will play through the new voice
    /// without needing a relaunch.
    func saveElevenLabsSettings(apiKey: String, voiceId: String?) {
        _ = ElevenLabsConfig.saveToKeychain(apiKey: apiKey, voiceId: voiceId)
        textToSpeech.reloadConfiguration()
    }

    /// Removes ElevenLabs credentials from Keychain. Env vars + JSON
    /// file sources are left alone — only the Keychain slot is cleared.
    func clearElevenLabsSettings() {
        ElevenLabsConfig.clearKeychain()
        textToSpeech.reloadConfiguration()
    }

    // MARK: - Private

    private func isTCCDeclinedError(_ error: ScreenCaptureError) -> Bool {
        let text = String(describing: error).lowercased()
        return text.contains("declined tcc")
            || text.contains("not authorized")
            || text.contains("screen recording")
            || text.contains("could not create image")
    }
}
