//
//  TTSManager.swift
//  Mumble
//

import Foundation
import AVFoundation
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

final class TTSManager: NSObject, ObservableObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    static let shared = TTSManager()
    private let synthesizer = AVSpeechSynthesizer()
    private let enableTTSKey = "EnableTTS"
    #if os(iOS)
    private enum SpeechAudioTransition {
        case none
        case sessionOnly
        case pausedVPIO
    }
    private var speechAudioTransition: SpeechAudioTransition = .none
    private var savedSelfMutedStateBeforeSpeech: Bool?
    private var savedSelfDeafenedStateBeforeSpeech: Bool?
    #endif
    
    override private init() {
        super.init()
        synthesizer.delegate = self
    }
    
    func speak(_ text: String) {
        // Must run on main thread if accessed from different threads
        DispatchQueue.main.async {
            guard UserDefaults.standard.bool(forKey: self.enableTTSKey), !text.isEmpty else { return }
            MumbleLogger.audio.debug("TTS speaking: \(text.prefix(50))")

            #if os(iOS)
            self.prepareAudioSessionForSpeech()
            #endif

            let utterance = AVSpeechUtterance(string: text)
            // default is AVSpeechUtteranceDefaultSpeechRate which is around 0.5
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate
            utterance.voice = self.preferredVoice(for: text)
            
            self.synthesizer.speak(utterance)
        }
    }
    
    func stopSpeaking() {
        DispatchQueue.main.async {
            if self.synthesizer.isSpeaking {
                self.synthesizer.stopSpeaking(at: .immediate)
            }
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        MumbleLogger.audio.debug("TTS finished speaking")
        #if os(iOS)
        restoreAudioAfterSpeechIfNeeded()
        #endif
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        MumbleLogger.audio.debug("TTS cancelled")
        #if os(iOS)
        restoreAudioAfterSpeechIfNeeded()
        #endif
    }

    #if os(iOS)
    private func activateSpeechSession(_ session: AVAudioSession) {
        do {
            try session.setCategory(
                .playback,
                mode: .default,
                options: [.duckOthers, .mixWithOthers]
            )
            try session.setActive(true, options: [])
        } catch {
            MumbleLogger.audio.error("TTS audio session setup failed: \(error)")
        }
    }

    private func restoreVoiceChatSessionIfNeeded() {
        guard let audio = MKAudio.shared(), audio.isRunning() else { return }
        var settings = MKAudioSettings()
        audio.read(&settings)

        var options: AVAudioSession.CategoryOptions = [.allowBluetoothHFP, .allowBluetoothA2DP, .mixWithOthers]
        if !settings.preferReceiverOverSpeaker.boolValue {
            options.insert(.defaultToSpeaker)
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: options)
            try session.setActive(true, options: [])
        } catch {
            MumbleLogger.audio.error("TTS voice chat session restore failed: \(error)")
        }
    }

    private func prepareAudioSessionForSpeech() {
        guard speechAudioTransition == .none else { return }

        let session = AVAudioSession.sharedInstance()
        let audio = MKAudio.shared()
        let mumbleAudioRunning = audio?.isRunning() ?? false
        let connectedUser = MUConnectionController.shared()?.serverModel?.connectedUser()
        let isSelfMutedOrDeafened = (connectedUser?.isSelfMuted() ?? false) || (connectedUser?.isSelfDeafened() ?? false)

        // 如果本来就闭麦/闭听，则不做 stop/start，避免误触发麦克风自动开启；
        // 但仍需切到可播报的会话，否则首次连接时可能无声。
        if mumbleAudioRunning && !isSelfMutedOrDeafened {
            MumbleLogger.audio.debug("TTS: pausing VPIO for speech")
            savedSelfMutedStateBeforeSpeech = connectedUser?.isSelfMuted()
            savedSelfDeafenedStateBeforeSpeech = connectedUser?.isSelfDeafened()
            audio?.stop()
            speechAudioTransition = .pausedVPIO
        } else {
            MumbleLogger.audio.debug("TTS: session-only transition for speech")
            speechAudioTransition = .sessionOnly
        }

        activateSpeechSession(session)
    }

    private func restoreAudioAfterSpeechIfNeeded() {
        guard !synthesizer.isSpeaking else { return }
        let transition = speechAudioTransition
        guard transition != .none else { return }
        speechAudioTransition = .none

        let serverModel = MUConnectionController.shared()?.serverModel
        let targetMuted = savedSelfMutedStateBeforeSpeech
        let targetDeafened = savedSelfDeafenedStateBeforeSpeech
        savedSelfMutedStateBeforeSpeech = nil
        savedSelfDeafenedStateBeforeSpeech = nil

        if transition == .pausedVPIO {
            MKAudio.shared()?.start()
        } else if transition == .sessionOnly {
            restoreVoiceChatSessionIfNeeded()
        }

        if let serverModel, let user = serverModel.connectedUser(),
           let targetMuted, let targetDeafened,
           user.isSelfMuted() != targetMuted || user.isSelfDeafened() != targetDeafened {
            serverModel.setSelfMuted(targetMuted, andSelfDeafened: targetDeafened)
        }
    }
    #endif

    private func preferredVoice(for text: String) -> AVSpeechSynthesisVoice? {
        let languageCode = preferredLanguageCode(for: text)
        if let voice = AVSpeechSynthesisVoice(language: languageCode) {
            return voice
        }

        let prefix = String(languageCode.prefix(2))
        if let fallback = AVSpeechSynthesisVoice.speechVoices().first(where: { $0.language.hasPrefix(prefix) }) {
            return fallback
        }

        if let localeVoice = AVSpeechSynthesisVoice(language: Locale.preferredLanguages.first ?? "en-US") {
            return localeVoice
        }

        return AVSpeechSynthesisVoice(language: "en-US")
    }

    private func preferredLanguageCode(for text: String) -> String {
        if text.range(of: "\\p{Han}", options: .regularExpression) != nil {
            return "zh-CN"
        }

        #if canImport(NaturalLanguage)
        if #available(iOS 12.0, macOS 10.14, *),
           let detected = NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue,
           !detected.isEmpty {
            if detected.hasPrefix("zh") { return "zh-CN" }
            if detected.hasPrefix("ja") { return "ja-JP" }
            if detected.hasPrefix("ko") { return "ko-KR" }
            return detected
        }
        #endif

        return Locale.preferredLanguages.first ?? "en-US"
    }
}
