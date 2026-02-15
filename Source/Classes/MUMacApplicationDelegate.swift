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
    private var lastAudioRestartSignature: String?
    
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
            "AudioFollowSystemInputDevice": true,
            "AudioPreferredInputDeviceUID": "",
            "AudioOpusCodecForceCELTMode": true,
            // Network
            "NetworkForceTCP": false,
            "DefaultUserName": "MumbleUser",
            // Notifications
            "NotifyUserJoinedSameChannel": true,
            "NotifyUserLeftSameChannel": true,
            "NotifyUserJoinedOtherChannels": false,
            "NotifyUserLeftOtherChannels": false,
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
        
        // 设置窗口最小尺寸约束（仅设置 minSize，不强制修改当前 frame）
        applyMinSizeToAllWindows()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWindowDidBecomeMain(_:)),
            name: NSWindow.didBecomeMainNotification,
            object: nil
        )
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
    
    func applicationDidBecomeActive(_ notification: Notification) {
        // macOS 分栏模式下，窗口重新激活时自动清除堆积的系统通知和未读徽章
        AppState.shared.unreadMessageCount = 0
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        statusBarController.teardown()
        MUDatabase.teardown()
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - Handoff (接力)
    
    /// 当系统准备接收 Handoff 活动时调用，返回 true 表示本应用可以处理该活动类型
    func application(_ application: NSApplication, willContinueUserActivityWithType userActivityType: String) -> Bool {
        print("📲 MUMacApplicationDelegate: willContinueUserActivityWithType → \(userActivityType)")
        return userActivityType == MumbleHandoffActivityType
    }
    
    /// 当系统成功接收到 Handoff 活动后调用，这是 macOS 上处理 Handoff 的核心入口
    /// 在 SwiftUI 的 .onContinueUserActivity 不可靠的场景下（冷启动、后台唤醒），
    /// 由 NSApplicationDelegate 保底处理
    func application(_ application: NSApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        guard userActivity.activityType == MumbleHandoffActivityType else {
            print("⚠️ MUMacApplicationDelegate: Unknown activity type: \(userActivity.activityType)")
            return false
        }
        
        print("📲 MUMacApplicationDelegate: Received Handoff activity via NSApplicationDelegate")
        HandoffManager.shared.handleIncomingActivity(userActivity)
        return true
    }
    
    /// Handoff 活动接收失败时调用
    func application(_ application: NSApplication, didFailToContinueUserActivityWithType userActivityType: String, error: any Error) {
        print("⚠️ MUMacApplicationDelegate: Failed to continue activity type \(userActivityType): \(error.localizedDescription)")
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
        let restartSignature = audioRestartSignature(defaults: defaults)
        
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
        let shouldRestart = (connectionActive || (audio?.isRunning() ?? false))
            && (lastAudioRestartSignature != nil)
            && (lastAudioRestartSignature != restartSignature)
        audio?.update(&settings)
        if shouldRestart {
            audio?.restart()
        }
        lastAudioRestartSignature = restartSignature
    }

    private func audioRestartSignature(defaults: UserDefaults) -> String {
        [
            defaults.string(forKey: "AudioTransmitMethod") ?? "vad",
            defaults.string(forKey: "AudioVADKind") ?? "amplitude",
            String(defaults.double(forKey: "AudioVADBelow")),
            String(defaults.double(forKey: "AudioVADAbove")),
            defaults.string(forKey: "AudioQualityKind") ?? "balanced",
            String(defaults.double(forKey: "AudioMicBoost")),
            String(defaults.bool(forKey: "AudioPreprocessor")),
            String(defaults.bool(forKey: "AudioEchoCancel")),
            String(defaults.bool(forKey: "AudioSidetone")),
            String(defaults.double(forKey: "AudioSidetoneVolume")),
            String(defaults.bool(forKey: "AudioSpeakerPhoneMode")),
            String(defaults.bool(forKey: "AudioOpusCodecForceCELTMode")),
            String(defaults.bool(forKey: "AudioMixerDebug")),
            String(defaults.bool(forKey: "AudioFollowSystemInputDevice")),
            defaults.string(forKey: "AudioPreferredInputDeviceUID") ?? ""
        ].joined(separator: "|")
    }

    // MARK: - 窗口最小尺寸约束
    
    /// 对所有已存在的窗口设置 minSize
    private func applyMinSizeToAllWindows() {
        for window in NSApp.windows {
            window.minSize = minimumWindowSize
        }
    }

    /// 当新窗口成为 main window 时，确保它也有 minSize 约束
    /// 注意：只设置 minSize，不强制修改当前 frame，避免窗口获焦时尺寸被重置
    @objc private func handleWindowDidBecomeMain(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window.minSize.width < minimumWindowSize.width || window.minSize.height < minimumWindowSize.height {
            window.minSize = minimumWindowSize
        }
    }
}
#endif
