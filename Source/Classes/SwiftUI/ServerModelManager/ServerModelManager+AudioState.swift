//
//  ServerModelManager+AudioState.swift
//  Mumble
//

import Foundation
#if os(iOS)
import AVFAudio
#endif

extension ServerModelManager {
    func setupSystemMute() {
        systemMuteManager.onSystemMuteChanged = { [weak self] isSystemMuted in
            guard let self = self, let user = self.serverModel?.connectedUser() else { return }

            // 如果正在恢复状态（路由切换中），忽略系统的“自动开麦”通知
            if self.isRestoringMuteState {
                print("🔒 Route changing: Ignoring system mute notification (\(isSystemMuted)) to preserve App state.")
                return
            }

            // 只有当 Mumble 内部状态不一致时才更新
            if user.isSelfMuted() != isSystemMuted {
                print("🔄 Sync: System(\(isSystemMuted)) -> App")
                self.serverModel?.setSelfMuted(isSystemMuted, andSelfDeafened: user.isSelfDeafened())
                self.updateUserBySession(user.session())
                self.updateLiveActivity()
            }
        }

        systemMuteManager.activate()
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
        guard serverModel != nil else { return }

        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            return
        }

        print("🎧 Audio Route Changed. Reason: \(reason.rawValue)")

        switch reason {
        case .newDeviceAvailable:
            // 立即上锁，防止重启期间系统发出的“开麦”通知把 App 状态带偏
            self.isRestoringMuteState = true

            print("🎧 New Device Detected. Scheduling Full Reactivation...")

            Task { @MainActor in
                // 等待蓝牙握手
                try? await Task.sleep(nanoseconds: 1_500_000_000)

                self.systemMuteManager.cleanup()
                self.systemMuteManager.activate()

                // 强制把 App 的状态“刷”给新耳机
                if let user = self.serverModel?.connectedUser() {
                    let targetState = user.isSelfMuted()
                    print("🔄 Syncing App State (\(targetState)) to New Hardware...")
                    self.systemMuteManager.setSystemMute(targetState)
                }

                try? await Task.sleep(nanoseconds: 500_000_000)
                self.isRestoringMuteState = false
            }

        case .oldDeviceUnavailable:
            self.isRestoringMuteState = true
            print("🎧 Device Removed. Restoring mute state...")

            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 500_000_000)

                self.systemMuteManager.cleanup()
                self.systemMuteManager.activate()

                if let user = self.serverModel?.connectedUser() {
                    let targetState = user.isSelfMuted()
                    print("🔄 Syncing App State (\(targetState)) to Speaker after device removal...")
                    self.systemMuteManager.setSystemMute(targetState)
                }

                try? await Task.sleep(nanoseconds: 500_000_000)
                self.isRestoringMuteState = false
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

        let shouldBeMuted = user.isSelfMuted()
        print("🔄 Route changed. Locking state and enforcing: \(shouldBeMuted)...")

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)

            if self.serverModel?.connectedUser() != nil {
                self.systemMuteManager.setSystemMute(shouldBeMuted)
                print("✅ Enforced state to System: \(shouldBeMuted)")
            }

            try? await Task.sleep(nanoseconds: 500_000_000)
            self.isRestoringMuteState = false
            print("🔓 Route change handling complete. State lock released.")
        }
    }

    /// 音频设置即将变更（MumblePreferencesChanged），在 restart 之前或之后同步保存当前状态
    /// 注意：使用 selector-based observer 确保在同一次 NotificationCenter.post 中同步执行
    @objc func handlePreferencesAboutToChange() {
        guard let user = serverModel?.connectedUser() else { return }
        savedMuteBeforeRestart = user.isSelfMuted()
        savedDeafenBeforeRestart = user.isSelfDeafened()
        isRestoringMuteState = true
        print("🔒 Preferences changing - saved mute state: muted=\(savedMuteBeforeRestart ?? false), deafened=\(savedDeafenBeforeRestart ?? false)")
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

        print("🔄 Audio restarted - restoring mute state: muted=\(targetMuted), deafened=\(targetDeafened)")

        if user.isSelfMuted() != targetMuted || user.isSelfDeafened() != targetDeafened {
            print("⚠️ State drifted during restart! Forcing correct state back to server.")
            serverModel?.setSelfMuted(targetMuted, andSelfDeafened: targetDeafened)
            updateUserBySession(user.session())
        }

        // 在 iOS 上同步系统层面的闭麦状态（macOS 上 SystemMuteManager 是 no-op）
        systemMuteManager.setSystemMute(targetMuted || targetDeafened)

        savedMuteBeforeRestart = nil
        savedDeafenBeforeRestart = nil

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            self.isRestoringMuteState = false
            print("🔓 Audio restart state lock released.")
        }
    }

    func toggleSelfMute() {
        guard let user = serverModel?.connectedUser() else { return }

        // 当用户听障时，不允许单独取消静音
        if user.isSelfDeafened() { return }

        let newMuteState = !user.isSelfMuted()
        serverModel?.setSelfMuted(newMuteState, andSelfDeafened: user.isSelfDeafened())

        updateUserBySession(user.session())
        systemMuteManager.setSystemMute(newMuteState)
        updateLiveActivity()
    }

    func toggleSelfDeafen() {
        guard let user = serverModel?.connectedUser() else { return }

        let currentlyDeafened = user.isSelfDeafened()

        if currentlyDeafened {
            // 取消听障 -> 恢复旧状态
            serverModel?.setSelfMuted(self.muteStateBeforeDeafen, andSelfDeafened: false)
            systemMuteManager.setSystemMute(self.muteStateBeforeDeafen)
        } else {
            // 开启听障 -> 强制静音
            self.muteStateBeforeDeafen = user.isSelfMuted()
            serverModel?.setSelfMuted(true, andSelfDeafened: true)
            systemMuteManager.setSystemMute(true)
        }

        updateUserBySession(user.session())
        updateLiveActivity()
    }
}
