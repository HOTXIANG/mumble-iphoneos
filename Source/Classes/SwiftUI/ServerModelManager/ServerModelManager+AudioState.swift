//
//  ServerModelManager+AudioState.swift
//  Mumble
//

import Foundation
import OSLog
#if os(iOS)
import AVFAudio
#endif

extension ServerModelManager {
    private func hasCurrentActiveConnectionForAudioState() -> Bool {
        guard let controller = MUConnectionController.existingShared(),
              controller.isConnected(),
              let currentModel = controller.serverModel,
              currentModel === serverModel else {
            return false
        }
        return true
    }

    func setupSystemMute() {
        systemMuteManager.onSystemMuteChanged = { [weak self] isSystemMuted in
            guard let self = self, let user = self.serverModel?.connectedUser() else { return }
            guard self.hasCurrentActiveConnectionForAudioState() else {
                MumbleLogger.audio.debug("Ignoring system mute notification because no current active connection is bound.")
                return
            }

            // 如果正在恢复状态（路由切换/启动同步）或输入设置临时预览中，忽略系统回调
            if self.isRestoringMuteState || self.isApplyingAppDrivenSystemMute {
                MumbleLogger.audio.debug("Ignoring system mute notification (\(isSystemMuted)) while App is enforcing mute state.")
                return
            }

            if self.isInputSettingsPreviewOverrideActive {
                MumbleLogger.audio.debug("Input settings preview override active: ignoring system mute notification (\(isSystemMuted)).")
                return
            }

            // 只有当 Mumble 内部状态不一致时才更新
            if user.isSelfMuted() != isSystemMuted {
                MumbleLogger.audio.info("Sync: System(\(isSystemMuted)) -> App")
                self.serverModel?.setSelfMuted(isSystemMuted, andSelfDeafened: user.isSelfDeafened())
                self.updateUserBySession(user.session())
                self.updateLiveActivity()
            }
        }

        systemMuteManager.activate()
        #if os(iOS)
        syncCurrentAppMuteStateToSystem(reason: "system_mute_activation")
        #endif
    }

    #if os(iOS)
    func setupAudioRouteObservation() {
        // 先移除旧的，防止重复注册
        NotificationCenter.default.removeObserver(self, name: AVAudioSession.routeChangeNotification, object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioRouteChanged),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
    }

    @objc func handleAudioRouteChanged(_ notification: Notification) {
        // 未连接到服务器时不处理音频路由变化
        guard hasCurrentActiveConnectionForAudioState() else { return }

        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            return
        }

        MumbleLogger.audio.info("Audio Route Changed. Reason: \(reason.rawValue)")

        switch reason {
        case .newDeviceAvailable:
            // 立即上锁，防止重启期间系统发出的"开麦"通知把 App 状态带偏
            audioRouteChangeSequence &+= 1
            let routeSequence = audioRouteChangeSequence
            self.isRestoringMuteState = true

            MumbleLogger.audio.info("New Device Detected. Scheduling Full Reactivation...")

            Task { @MainActor in
                // 等待蓝牙握手
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard self.audioRouteChangeSequence == routeSequence,
                      self.hasCurrentActiveConnectionForAudioState() else {
                    if self.audioRouteChangeSequence == routeSequence {
                        self.isRestoringMuteState = false
                    }
                    return
                }

                self.systemMuteManager.cleanup()
                self.systemMuteManager.activate()

                // 强制把 App 的状态"刷"给新耳机
                if let user = self.serverModel?.connectedUser() {
                    let targetState = user.isSelfMuted()
                    MumbleLogger.audio.debug("Syncing App State (\(targetState)) to New Hardware...")
                    self.setSystemMuteFromApp(targetState, reason: "route_new_device")
                }

                try? await Task.sleep(nanoseconds: 500_000_000)
                if self.audioRouteChangeSequence == routeSequence {
                    self.isRestoringMuteState = false
                }
            }

        case .oldDeviceUnavailable:
            audioRouteChangeSequence &+= 1
            let routeSequence = audioRouteChangeSequence
            self.isRestoringMuteState = true
            MumbleLogger.audio.info("Device Removed. Restoring mute state...")

            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard self.audioRouteChangeSequence == routeSequence,
                      self.hasCurrentActiveConnectionForAudioState() else {
                    if self.audioRouteChangeSequence == routeSequence {
                        self.isRestoringMuteState = false
                    }
                    return
                }

                self.systemMuteManager.cleanup()
                self.systemMuteManager.activate()

                if let user = self.serverModel?.connectedUser() {
                    let targetState = user.isSelfMuted()
                    MumbleLogger.audio.debug("Syncing App State (\(targetState)) to Speaker after device removal...")
                    self.setSystemMuteFromApp(targetState, reason: "route_old_device")
                }

                try? await Task.sleep(nanoseconds: 500_000_000)
                if self.audioRouteChangeSequence == routeSequence {
                    self.isRestoringMuteState = false
                }
            }

        case .categoryChange:
            break

        default:
            break
        }
    }
    #endif

    func enforceAppMuteStateToSystem() {
        guard let user = serverModel?.connectedUser() else {
            self.isRestoringMuteState = false
            return
        }
        guard hasCurrentActiveConnectionForAudioState() else {
            self.isRestoringMuteState = false
            return
        }

        let shouldBeMuted = user.isSelfMuted()
        MumbleLogger.audio.debug("Route changed. Locking state and enforcing: \(shouldBeMuted)...")
        audioRouteChangeSequence &+= 1
        let routeSequence = audioRouteChangeSequence

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard self.audioRouteChangeSequence == routeSequence,
                  self.hasCurrentActiveConnectionForAudioState() else {
                if self.audioRouteChangeSequence == routeSequence {
                    self.isRestoringMuteState = false
                }
                return
            }

            if self.serverModel?.connectedUser() != nil {
                self.setSystemMuteFromApp(shouldBeMuted, reason: "route_enforce")
                MumbleLogger.audio.debug("Enforced state to System: \(shouldBeMuted)")
            }

            try? await Task.sleep(nanoseconds: 500_000_000)
            if self.audioRouteChangeSequence == routeSequence {
                self.isRestoringMuteState = false
                MumbleLogger.audio.debug("Route change handling complete. State lock released.")
            }
        }
    }

    /// 音频设置即将变更（MumblePreferencesChanged），在 restart 之前或之后同步保存当前状态
    /// 注意：使用 selector-based observer 确保在同一次 NotificationCenter.post 中同步执行
    @objc func handlePreferencesAboutToChange() {
        guard let user = serverModel?.connectedUser() else { return }
        savedMuteBeforeRestart = user.isSelfMuted()
        savedDeafenBeforeRestart = user.isSelfDeafened()
        isRestoringMuteState = true
        MumbleLogger.audio.debug("Preferences changing - saved mute state: muted=\(self.savedMuteBeforeRestart ?? false), deafened=\(self.savedDeafenBeforeRestart ?? false)")
    }

    /// 音频引擎重启后恢复闭麦/不听状态
    func restoreMuteDeafenStateAfterAudioRestart() {
        guard let user = serverModel?.connectedUser() else {
            isRestoringMuteState = false
            savedMuteBeforeRestart = nil
            savedDeafenBeforeRestart = nil
            return
        }

        let targetMuted = savedMuteBeforeRestart ?? user.isSelfMuted()
        let targetDeafened = savedDeafenBeforeRestart ?? user.isSelfDeafened()

        MumbleLogger.audio.info("Audio restarted - restoring mute state: muted=\(targetMuted), deafened=\(targetDeafened)")

        if user.isSelfMuted() != targetMuted || user.isSelfDeafened() != targetDeafened {
            MumbleLogger.audio.warning("State drifted during restart! Forcing correct state back to server.")
            serverModel?.setSelfMuted(targetMuted, andSelfDeafened: targetDeafened)
            updateUserBySession(user.session())
        }

        // 在 iOS 上同步系统层面的闭麦状态（macOS 上 SystemMuteManager 是 no-op）
        setSystemMuteFromApp(targetMuted || targetDeafened, reason: "audio_restart_restore")

        savedMuteBeforeRestart = nil
        savedDeafenBeforeRestart = nil

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            self.isRestoringMuteState = false
            MumbleLogger.audio.debug("Audio restart state lock released.")
        }
    }

    #if os(iOS)
    @discardableResult
    private func beginAppDrivenSystemMuteSync(reason: String) -> UInt {
        appDrivenSystemMuteSequence &+= 1
        let sequence = appDrivenSystemMuteSequence
        isApplyingAppDrivenSystemMute = true
        MumbleLogger.audio.debug("App-driven system mute sync started reason=\(reason) sequence=\(sequence)")
        return sequence
    }

    private func finishAppDrivenSystemMuteSync(sequence: UInt, reason: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            guard self.appDrivenSystemMuteSequence == sequence else { return }
            self.isApplyingAppDrivenSystemMute = false
            MumbleLogger.audio.debug("App-driven system mute sync finished reason=\(reason) sequence=\(sequence)")
        }
    }

    func setSystemMuteFromApp(_ targetState: Bool, reason: String) {
        let sequence = beginAppDrivenSystemMuteSync(reason: reason)
        if setSystemMuteIfSessionReady(targetState, reason: reason) {
            finishAppDrivenSystemMuteSync(sequence: sequence, reason: reason)
        } else {
            applySystemMuteWithRetry(targetState, reason: reason, attemptsRemaining: 8, sequence: sequence)
        }
    }

    private func setSystemMuteIfSessionReady(_ targetState: Bool, reason: String) -> Bool {
        guard #available(iOS 17.0, *) else { return false }

        let session = AVAudioSession.sharedInstance()
        guard session.category == .playAndRecord else {
            MumbleLogger.audio.debug("Deferring system input mute sync (\(reason)) because session category is \(session.category.rawValue)")
            return false
        }

        MumbleLogger.audio.debug("Applying system input mute=\(targetState) (\(reason))")
        systemMuteManager.setSystemMute(targetState)
        return true
    }

    private func applySystemMuteWithRetry(_ targetState: Bool, reason: String, attemptsRemaining: Int = 8, sequence existingSequence: UInt? = nil) {
        let sequence = existingSequence ?? beginAppDrivenSystemMuteSync(reason: reason)
        if setSystemMuteIfSessionReady(targetState, reason: reason) {
            finishAppDrivenSystemMuteSync(sequence: sequence, reason: reason)
            return
        }

        guard attemptsRemaining > 0 else {
            MumbleLogger.audio.warning("Failed to apply system input mute=\(targetState) after retries (\(reason))")
            finishAppDrivenSystemMuteSync(sequence: sequence, reason: reason)
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.applySystemMuteWithRetry(targetState, reason: reason, attemptsRemaining: attemptsRemaining - 1, sequence: sequence)
        }
    }

    func syncCurrentAppMuteStateToSystem(reason: String) {
        guard hasCurrentActiveConnectionForAudioState() else { return }
        guard let user = serverModel?.connectedUser() else { return }
        applySystemMuteWithRetry(user.isSelfMuted() || user.isSelfDeafened(), reason: reason)
    }

    func captureLocalAudioTestSystemMuteStateIfNeeded() {
        guard #available(iOS 17.0, *) else { return }
        guard localAudioTestRestoreSystemMute == nil else { return }

        localAudioTestRestoreSystemMute = AVAudioApplication.shared.isInputMuted
        MumbleLogger.audio.debug("Captured local audio test system mute state: \(localAudioTestRestoreSystemMute ?? false)")
    }

    func applyLocalAudioTestSystemMuteOverrideIfNeeded() {
        guard #available(iOS 17.0, *) else { return }
        guard localAudioTestRestoreSystemMute != nil else { return }

        applySystemMuteWithRetry(false, reason: "local_audio_test_start")
    }

    func restoreLocalAudioTestSystemMuteIfNeeded() {
        guard #available(iOS 17.0, *) else { return }
        guard let restoreState = localAudioTestRestoreSystemMute else { return }

        localAudioTestRestoreSystemMute = nil
        setSystemMuteFromApp(restoreState, reason: "local_audio_test_stop")
    }
    #else
    func setSystemMuteFromApp(_ targetState: Bool, reason: String) {
        systemMuteManager.setSystemMute(targetState)
    }
    #endif

    func toggleSelfMute() {
        guard let user = serverModel?.connectedUser() else { return }

        // 当用户听障时，不允许单独取消静音
        if user.isSelfDeafened() { return }

        let newMuteState = !user.isSelfMuted()
        serverModel?.setSelfMuted(newMuteState, andSelfDeafened: user.isSelfDeafened())

        updateUserBySession(user.session())
        setSystemMuteFromApp(newMuteState, reason: "toggle_self_mute")
        updateLiveActivity()
    }

    func toggleSelfDeafen() {
        guard let user = serverModel?.connectedUser() else { return }

        let currentlyDeafened = user.isSelfDeafened()

        if currentlyDeafened {
            // 取消听障 -> 恢复旧状态
            serverModel?.setSelfMuted(self.muteStateBeforeDeafen, andSelfDeafened: false)
            setSystemMuteFromApp(self.muteStateBeforeDeafen, reason: "toggle_self_deafen_off")
        } else {
            // 开启听障 -> 强制静音
            self.muteStateBeforeDeafen = user.isSelfMuted()
            serverModel?.setSelfMuted(true, andSelfDeafened: true)
            setSystemMuteFromApp(true, reason: "toggle_self_deafen_on")
        }

        updateUserBySession(user.session())
        updateLiveActivity()
    }
}
