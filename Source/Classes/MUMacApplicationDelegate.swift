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
        NotificationCenter.default.addObserver(self, selector: #selector(connectionOpened), name: .muConnectionOpened, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(connectionClosed), name: .muConnectionClosed, object: nil)
        
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
            "AudioVADHoldSeconds": 0.1,
            "AudioVADKind": "amplitude",
            "AudioTransmitMethod": "vad",
            "AudioStereoInput": false,
            "AudioStereoOutput": true,
            "AudioMicBoost": 1.0,
            "AudioQualityKind": "balanced",
            "AudioSidetone": false,
            "AudioSidetoneVolume": 0.2,
            "ShowPTTButton": false,
            "PTTHotkeyCode": 49,
            "AudioSpeakerPhoneMode": true,
            "AudioFollowSystemInputDevice": true,
            "AudioPreferredInputDeviceUID": "",
            "AudioCaptureAllInputChannels": false,
            "AudioSelectedInputChannel": 1,
            "AudioSelectedInputChannelLeft": 1,
            "AudioSelectedInputChannelRight": 2,
            "AudioOpusCodecForceCELTMode": true,
            "AudioPluginInputTrackEnabled": false,
            "AudioPluginInputTrackGain": 1.0,
            "AudioPluginRemoteBusEnabled": false,
            "AudioPluginRemoteBusGain": 1.0,
            "AudioPluginHostBufferFrames": 256,
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
        NotificationCenter.default.addObserver(self, selector: #selector(reloadPreferences), name: .muPreferencesChanged, object: nil)
        
        NotificationCenter.default.addObserver(self, selector: #selector(handleVPIOToHALTransition), name: .muMacAudioVPIOToHALTransition, object: nil)
        
        // Initialize audio settings
        reloadPreferences()
        
        // Initialize database
        MUDatabase.initializeDatabase()
        
        MumbleLogger.general.info("MUMacApplicationDelegate: Initialization complete (Opus enabled, database initialized)")
        
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
        
        // 系统重启后自动恢复应用时，窗口可能存在但不可见。
        // 延迟执行以等待 SwiftUI WindowGroup 完成窗口创建，然后强制激活并显示。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.ensureMainWindowVisible()
        }
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
    
    func applicationDidBecomeActive(_ notification: Notification) {
        // macOS 分栏模式下，窗口重新激活时自动清除堆积的系统通知和未读徽章
        AppState.shared.unreadMessageCount = 0
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        
        ensureMainWindowVisible()
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        AudioPluginRackManager.shared.markCleanExit()
        statusBarController.teardown()
        MUDatabase.teardown()
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - Handoff (接力)
    
    /// 当系统准备接收 Handoff 活动时调用，返回 true 表示本应用可以处理该活动类型
    func application(_ application: NSApplication, willContinueUserActivityWithType userActivityType: String) -> Bool {
        MumbleLogger.handoff.info("MUMacApplicationDelegate: willContinueUserActivityWithType: \(userActivityType)")
        return userActivityType == MumbleHandoffActivityType
    }
    
    /// 当系统成功接收到 Handoff 活动后调用，这是 macOS 上处理 Handoff 的核心入口
    /// 在 SwiftUI 的 .onContinueUserActivity 不可靠的场景下（冷启动、后台唤醒），
    /// 由 NSApplicationDelegate 保底处理
    func application(_ application: NSApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        guard userActivity.activityType == MumbleHandoffActivityType else {
            MumbleLogger.handoff.warning("MUMacApplicationDelegate: Unknown activity type: \(userActivity.activityType)")
            return false
        }
        
        MumbleLogger.handoff.info("MUMacApplicationDelegate: Received Handoff activity via NSApplicationDelegate")
        HandoffManager.shared.handleIncomingActivity(userActivity)
        return true
    }
    
    /// Handoff 活动接收失败时调用
    func application(_ application: NSApplication, didFailToContinueUserActivityWithType userActivityType: String, error: any Error) {
        MumbleLogger.handoff.error("MUMacApplicationDelegate: Failed to continue activity type \(userActivityType): \(error.localizedDescription)")
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
        let snrModeEnabled = (vadKind == "snr")
        
        settings.vadMin = defaults.float(forKey: "AudioVADBelow")
        settings.vadMax = defaults.float(forKey: "AudioVADAbove")
        let vadHoldSeconds = min(max(defaults.double(forKey: "AudioVADHoldSeconds"), 0.0), 0.3)
        settings.enableVadGate = ObjCBool(vadHoldSeconds > 0.0)
        settings.vadGateTimeSeconds = vadHoldSeconds
        
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
        // Keep preprocessing internal-only for SNR mode so SNR meter/VAD remain functional
        settings.enablePreprocessor = ObjCBool(snrModeEnabled)
        settings.enableStereoInput = ObjCBool(defaults.bool(forKey: "AudioStereoInput"))
        settings.enableStereoOutput = ObjCBool(defaults.bool(forKey: "AudioStereoOutput"))
        settings.enableEchoCancellation = ObjCBool(false)
        settings.enableDenoise = ObjCBool(false)
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
        audio?.setPluginHostBufferFrames(UInt(defaults.integer(forKey: "AudioPluginHostBufferFrames")))
        audio?.setInputTrackPreviewGain(
            defaults.float(forKey: "AudioPluginInputTrackGain"),
            enabled: defaults.bool(forKey: "AudioPluginInputTrackEnabled")
        )
        audio?.setRemoteBusPreviewGain(
            defaults.float(forKey: "AudioPluginRemoteBusGain"),
            enabled: defaults.bool(forKey: "AudioPluginRemoteBusEnabled")
        )
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
            String(defaults.double(forKey: "AudioVADHoldSeconds")),
            defaults.string(forKey: "AudioQualityKind") ?? "balanced",
            String(defaults.double(forKey: "AudioMicBoost")),
            String(defaults.bool(forKey: "AudioStereoInput")),
            String(defaults.bool(forKey: "AudioStereoOutput")),
            String(defaults.bool(forKey: "AudioSpeakerPhoneMode")),
            String(defaults.bool(forKey: "AudioOpusCodecForceCELTMode")),
            String(defaults.bool(forKey: "AudioMixerDebug")),
            String(defaults.bool(forKey: "AudioFollowSystemInputDevice")),
            defaults.string(forKey: "AudioPreferredInputDeviceUID") ?? "",
            String(defaults.bool(forKey: "AudioCaptureAllInputChannels")),
            String(defaults.integer(forKey: "AudioSelectedInputChannel")),
            String(defaults.integer(forKey: "AudioSelectedInputChannelLeft")),
            String(defaults.integer(forKey: "AudioSelectedInputChannelRight")),
            String(defaults.bool(forKey: "AudioPluginInputTrackEnabled")),
            String(defaults.double(forKey: "AudioPluginInputTrackGain")),
            String(defaults.bool(forKey: "AudioPluginRemoteBusEnabled")),
            String(defaults.double(forKey: "AudioPluginRemoteBusGain"))
        ].joined(separator: "|")
    }

    // MARK: - VPIO→HALOutput 过渡通知
    
    @objc private func handleVPIOToHALTransition() {
        Task { @MainActor in
            AppState.shared.activeToast = AppToast(
                message: NSLocalizedString("Switched to external mic. Re-select Voice Isolation mode, then restart app for it to take effect.", comment: ""),
                type: .info
            )
        }
    }
    
    // MARK: - 窗口可见性保障
    
    /// 确保至少有一个主窗口可见（应对系统重启后自动恢复时窗口不显示的问题）
    private func ensureMainWindowVisible() {
        NSApp.activate(ignoringOtherApps: true)
        
        let contentWindows = NSApp.windows.filter {
            !($0.className.contains("StatusBar") || $0.className.contains("_NSPopover"))
                && $0.level == .normal
        }
        let hasVisible = contentWindows.contains { $0.isVisible && !$0.isMiniaturized }
        if !hasVisible {
            if let window = contentWindows.first {
                window.deminiaturize(nil)
                window.makeKeyAndOrderFront(nil)
            }
        }
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
