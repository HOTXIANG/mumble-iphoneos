//
//  MUMacApplicationDelegate.swift
//  Mumble
//
//  macOS App Delegate — performs the same initialization as MUApplicationDelegate (iOS)
//

#if os(macOS)
import AppKit
import UserNotifications

@MainActor
class MUMacApplicationDelegate: NSObject, NSApplicationDelegate {
    private let minimumWindowSize = NSSize(width: 980, height: 680)
    private var connectionActive = false
    private let statusBarController = MUStatusBarController()
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Disable automatic window tabbing (removes "Show Tab Bar" / "Show All Tabs" from View menu)
        NSWindow.allowsAutomaticWindowTabbing = false
        
        // Listen for connection state changes
        NotificationCenter.default.addObserver(self, selector: #selector(connectionOpened), name: NSNotification.Name("MUConnectionOpenedNotification"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(connectionClosed), name: NSNotification.Name("MUConnectionClosedNotification"), object: nil)
        
        // Set MumbleKit release string
        let version = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        MKVersion.shared().setOverrideRelease("Mumble for macOS \(version)")
        
        // Enable Opus unconditionally — critical for connecting to modern Mumble servers
        MKVersion.shared().setOpusEnabled(true)
        
        // Register default settings (same as iOS MUApplicationDelegate)
        UserDefaults.standard.register(defaults: [
            // Audio
            "AudioOutputVolume": 1.0,
            "AudioVADAbove": 0.6,
            "AudioVADBelow": 0.3,
            "AudioVADKind": "amplitude",
            "AudioTransmitMethod": "vad",
            "AudioPreprocessor": true,
            "AudioEchoCancel": true,
            "AudioMicBoost": 1.0,
            "AudioQualityKind": "balanced",
            "AudioSidetone": false,
            "AudioSidetoneVolume": 0.2,
            "AudioSpeakerPhoneMode": true,
            "AudioOpusCodecForceCELTMode": true,
            // Network
            "NetworkForceTCP": false,
            "DefaultUserName": "MumbleUser",
        ])
        
        // Disable mixer debugging
        UserDefaults.standard.set(false, forKey: "AudioMixerDebug")
        
        // Listen for preferences changes
        NotificationCenter.default.addObserver(self, selector: #selector(reloadPreferences), name: NSNotification.Name("MumblePreferencesChanged"), object: nil)
        
        // Initialize audio settings
        reloadPreferences()
        
        // Initialize database
        MUDatabase.initializeDatabase()
        
        print("🖥️ MUMacApplicationDelegate: Initialization complete (Opus enabled, database initialized)")
        
        // Setup macOS menu bar status item
        statusBarController.setup()
        
        applyMinimumWindowSizeToAllWindows()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWindowDidBecomeMain(_:)),
            name: NSWindow.didBecomeMainNotification,
            object: nil
        )
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        statusBarController.teardown()
        MUDatabase.teardown()
        NotificationCenter.default.removeObserver(self)
    }
    
    @objc private func reloadPreferences() {
        setupAudio()
    }
    
    @objc private func connectionOpened() {
        connectionActive = true
    }
    
    @objc private func connectionClosed() {
        connectionActive = false
    }
    
    private func setupAudio() {
        let defaults = UserDefaults.standard
        
        var settings = MKAudioSettings()
        
        // Transmit type
        let transmitMethod = defaults.string(forKey: "AudioTransmitMethod") ?? "vad"
        switch transmitMethod {
        case "vad":
            settings.transmitType = MKTransmitTypeVAD
        case "continuous":
            settings.transmitType = MKTransmitTypeContinuous
        case "ptt":
            settings.transmitType = MKTransmitTypeToggle
        default:
            settings.transmitType = MKTransmitTypeVAD
        }
        
        // VAD kind
        let vadKind = defaults.string(forKey: "AudioVADKind") ?? "amplitude"
        settings.vadKind = (vadKind == "snr") ? MKVADKindSignalToNoise : MKVADKindAmplitude
        
        settings.vadMin = defaults.float(forKey: "AudioVADBelow")
        settings.vadMax = defaults.float(forKey: "AudioVADAbove")
        
        // Quality
        let quality = defaults.string(forKey: "AudioQualityKind") ?? "balanced"
        switch quality {
        case "low":
            settings.codec = MKCodecFormatOpus
            settings.quality = 60000
            settings.audioPerPacket = 4
        case "balanced":
            settings.codec = MKCodecFormatOpus
            settings.quality = 100000
            settings.audioPerPacket = 2
        case "high", "opus":
            settings.codec = MKCodecFormatOpus
            settings.quality = 192000
            settings.audioPerPacket = 1
        default:
            settings.codec = MKCodecFormatOpus
            settings.quality = 100000
            settings.audioPerPacket = 2
        }
        
        settings.noiseSuppression = -42
        settings.amplification = 20.0
        settings.jitterBufferSize = 0
        settings.volume = defaults.float(forKey: "AudioOutputVolume")
        settings.outputDelay = 0
        settings.micBoost = defaults.float(forKey: "AudioMicBoost")
        settings.enablePreprocessor = ObjCBool(defaults.bool(forKey: "AudioPreprocessor"))
        settings.enableEchoCancellation = ObjCBool(settings.enablePreprocessor.boolValue && defaults.bool(forKey: "AudioEchoCancel"))
        settings.enableSideTone = ObjCBool(defaults.bool(forKey: "AudioSidetone"))
        settings.sidetoneVolume = defaults.float(forKey: "AudioSidetoneVolume")
        settings.preferReceiverOverSpeaker = ObjCBool(!defaults.bool(forKey: "AudioSpeakerPhoneMode"))
        settings.opusForceCELTMode = ObjCBool(defaults.bool(forKey: "AudioOpusCodecForceCELTMode"))
        settings.audioMixerDebug = ObjCBool(defaults.bool(forKey: "AudioMixerDebug"))
        
        let audio = MKAudio.shared()
        audio?.update(&settings)
        if connectionActive || (audio?.isRunning() ?? false) {
            audio?.restart()
        }
    }

    private func applyMinimumWindowSizeToAllWindows() {
        for window in NSApp.windows {
            applyMinimumWindowSize(to: window)
        }
    }

    @objc private func handleWindowDidBecomeMain(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        applyMinimumWindowSize(to: window)
    }

    private func applyMinimumWindowSize(to window: NSWindow) {
        window.minSize = minimumWindowSize
        if window.frame.width < minimumWindowSize.width || window.frame.height < minimumWindowSize.height {
            var frame = window.frame
            frame.size.width = max(frame.size.width, minimumWindowSize.width)
            frame.size.height = max(frame.size.height, minimumWindowSize.height)
            window.setFrame(frame, display: true, animate: false)
        }
    }
}
#endif
