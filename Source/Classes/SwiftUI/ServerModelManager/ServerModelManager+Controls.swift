//
//  ServerModelManager+Controls.swift
//  Mumble
//

import SwiftUI
#if os(iOS) || os(macOS)
import AVFoundation
#endif

extension ServerModelManager {
    // MARK: - Audio Control for Settings / Audio Wizard

    /// 进入设置界面时调用：临时开启麦克风
    func startAudioTest() {
        // 如果当前已经连接了服务器，说明麦克风本来就开着，不需要做任何事
        if self.isConnected || isLocalAudioTestRunning {
            return
        }

        #if os(macOS)
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            startLocalAudioEngineForSettings()
        case .notDetermined:
            if isRequestingMicrophonePermission { return }
            isRequestingMicrophonePermission = true
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor in
                    guard let self = self else { return }
                    self.isRequestingMicrophonePermission = false
                    guard granted, !self.isConnected, !self.isLocalAudioTestRunning else { return }
                    self.startLocalAudioEngineForSettings()
                }
            }
        case .denied, .restricted:
            print("🎤 Microphone permission denied/restricted. Skip local audio test.")
        @unknown default:
            print("🎤 Unknown microphone permission status. Skip local audio test.")
        }
        #else
        startLocalAudioEngineForSettings()
        #endif
    }

    /// 退出设置界面时调用：关闭麦克风
    func stopAudioTest() {
        // 如果当前连接着服务器，绝对不能关麦，否则通话断了
        if self.isConnected {
            print("🎤 Connected to server, keeping audio active.")
            return
        }

        if !isLocalAudioTestRunning {
            return
        }

        print("🎤 Stopping Local Audio (Settings closed)...")
        isLocalAudioTestRunning = false
        // 关闭引擎并释放 AudioSession
        Task.detached(priority: .userInitiated) {
            MKAudio.shared().stop()

            #if os(iOS)
            // 显式停用 Session 以消除橙色点
            do {
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            } catch {
                print("⚠️ Failed to deactivate session: \(error)")
            }
            #endif
        }
    }

    private func startLocalAudioEngineForSettings() {
        print("🎤 Starting Local Audio for Settings/Testing...")
        isLocalAudioTestRunning = true
        Task.detached(priority: .userInitiated) {
            MKAudio.shared().start()
        }
    }

    // MARK: - Local User Audio Control

    func setLocalUserVolume(session: UInt, volume: Float) {
        guard let user = getUserBySession(session) else { return }
        guard let serverHost = serverModel?.hostname() else { return }

        // 1. 更新内存中的状态
        userVolumes[session] = volume
        user.localVolume = volume

        // 2. 持久化保存 (同时保存当前的静音状态)
        let isMuted = user.isLocalMuted()
        LocalUserPreferences.shared.save(
            volume: volume,
            isLocalMuted: isMuted,
            for: user.userName() ?? "",
            on: serverHost
        )

        if let connection = MUConnectionController.shared()?.connection {
            print("🔊 Setting volume for \(session): \(volume) on output: \(String(describing: connection.audioOutput))")
            connection.audioOutput?.setVolume(volume, forSession: session)
        }

        // 3. 通知 UI 刷新
        objectWillChange.send()
    }

    /// 切换某个用户的本地屏蔽状态 (Local Mute / Ignore)
    func toggleLocalUserMute(session: UInt) {
        guard let user = getUserBySession(session) else { return }
        guard let serverHost = serverModel?.hostname() else { return }

        let newMuteState = !user.isLocalMuted()
        user.setLocalMuted(newMuteState)

        if let connection = MUConnectionController.shared()?.connection {
            connection.audioOutput?.setMuted(newMuteState, forSession: session)
        }

        let currentVol = userVolumes[session] ?? 1.0

        // 持久化
        LocalUserPreferences.shared.save(
            volume: currentVol,
            isLocalMuted: newMuteState,
            for: user.userName() ?? "",
            on: serverHost
        )

        // 通知 UI
        objectWillChange.send()
    }

    func restoreAllUserPreferences() {
        print("🔄 Restoring preferences for ALL users...")
        guard let root = serverModel?.rootChannel() else { return }
        Task { @MainActor in
            await recursiveRestore(channel: root)
        }
    }

    // MARK: - Permission Helpers

    /// 检查当前用户在指定频道是否拥有某权限
    func hasPermission(_ permission: MKPermission, forChannelId channelId: UInt) -> Bool {
        guard let perms = channelPermissions[channelId] else { return false }
        return (perms & UInt32(permission.rawValue)) != 0
    }

    /// 检查当前用户在根频道（全局）是否拥有某权限
    func hasRootPermission(_ permission: MKPermission) -> Bool {
        return hasPermission(permission, forChannelId: 0)
    }

    /// 连接后扫描所有频道的权限，检测哪些频道限制进入
    /// 使用 PermissionQuery（所有用户可用），而非 ACL 查询（仅管理员可用）
    func scanAllChannelPermissions() {
        guard let root = serverModel?.rootChannel() else {
            print("🔐 scanAllChannelPermissions: No root channel available")
            return
        }
        var count = 0
        recursiveRequestPermission(channel: root, count: &count)
        print("🔐 scanAllChannelPermissions: Requested permissions for \(count) channels")

        // 只有拥有 Write 权限的用户（管理员）才额外请求 ACL 来区分密码频道和纯权限限制频道
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self = self else { return }
            if self.hasRootPermission(MKPermissionWrite) {
                var aclCount = 0
                self.recursiveRequestACL(channel: root, count: &aclCount)
                print("🔐 scanAllChannelPermissions: Also requested ACL for \(aclCount) channels (admin)")
            } else {
                print("🔐 scanAllChannelPermissions: Skipping ACL requests (no Write permission)")
            }
        }

        // 延迟后关闭扫描标记（给服务器足够时间响应）
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            self?.isScanningACLs = false
        }
    }

    // 辅助：通过 Session 找 User
    func getUserBySession(_ session: UInt) -> MKUser? {
        guard let index = userIndexMap[session], index < modelItems.count else { return nil }
        return modelItems[index].object as? MKUser
    }

    private func recursiveRequestPermission(channel: MKChannel, count: inout Int) {
        serverModel?.requestPermission(for: channel)
        count += 1
        if let subs = channel.channels() as? [MKChannel] {
            for sub in subs {
                recursiveRequestPermission(channel: sub, count: &count)
            }
        }
    }

    private func recursiveRequestACL(channel: MKChannel, count: inout Int) {
        serverModel?.requestAccessControl(for: channel)
        count += 1
        if let subs = channel.channels() as? [MKChannel] {
            for sub in subs {
                recursiveRequestACL(channel: sub, count: &count)
            }
        }
    }

    private func recursiveRestore(channel: MKChannel) async {
        if let users = channel.users() as? [MKUser] {
            for user in users {
                applySavedUserPreferences(user: user)
            }
        }

        await Task.yield()

        if let subs = channel.channels() as? [MKChannel] {
            for sub in subs {
                await recursiveRestore(channel: sub)
            }
        }
    }

    func applySavedUserPreferences(user: MKUser) {
        guard let serverHost = serverModel?.hostname(),
              let name = user.userName() else { return }

        let prefs = LocalUserPreferences.shared.load(for: name, on: serverHost)
        userVolumes[user.session()] = prefs.volume
        user.localVolume = prefs.volume

        if user.isLocalMuted() != prefs.isLocalMuted {
            user.setLocalMuted(prefs.isLocalMuted)
        }

        if let connection = MUConnectionController.shared()?.connection {
            connection.audioOutput?.setVolume(prefs.volume, forSession: user.session())
            connection.audioOutput?.setMuted(prefs.isLocalMuted, forSession: user.session())
        }
    }
}
