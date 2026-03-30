//
//  ServerModelManager+HandoffLiveActivity.swift
//  Mumble
//

import Foundation
#if os(iOS)
import ActivityKit
#endif

extension ServerModelManager {
    #if os(iOS)
    private func restartLiveActivityKeepAliveTimer() {
        self.keepAliveTimer?.invalidate()
        self.keepAliveTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateLiveActivity()
            }
        }
    }
    #endif

    // MARK: - Handoff User Preferences Restore

    @objc func handleHandoffRestoreUserPreferences() {
        restoreAllUserPreferences()
    }

    // MARK: - Handoff (接力)

    /// 发布 Handoff Activity，让其他设备可以接力
    func publishHandoffActivity() {
        guard let model = serverModel,
              let connectedUser = model.connectedUser() else { return }

        let shouldSyncLocalAudio = UserDefaults.standard.object(forKey: MumbleHandoffSyncLocalAudioSettingsKey) as? Bool ?? true

        let hostname = model.hostname() ?? ""
        let port = Int(model.port())
        let username = connectedUser.userName() ?? ""
        let channelId = connectedUser.channel()?.channelId()
        let channelName = connectedUser.channel()?.channelName()
        let isSelfMuted = connectedUser.isSelfMuted()
        let isSelfDeafened = connectedUser.isSelfDeafened()

        // 收集当前所有用户的本地音频设置（非默认值的）
        var audioSettings: [HandoffUserAudioSetting] = []
        if shouldSyncLocalAudio, let rootChannel = model.rootChannel() {
            collectUserAudioSettings(in: rootChannel, settings: &audioSettings)
        }

        HandoffManager.shared.publishActivity(
            hostname: hostname,
            port: port,
            username: username,
            password: nil, // 不传递密码以保安全，收藏中已有密码的服务器会自动使用
            channelId: channelId != nil ? Int(channelId!) : nil,
            channelName: channelName,
            displayName: serverName,
            isSelfMuted: isSelfMuted,
            isSelfDeafened: isSelfDeafened,
            userAudioSettings: audioSettings
        )
    }

    /// 递归收集所有用户的本地音频设置
    func collectUserAudioSettings(in channel: MKChannel, settings: inout [HandoffUserAudioSetting]) {
        if let users = channel.users() as? [MKUser] {
            for user in users {
                let volume = userVolumes[user.session()] ?? 1.0
                let isMuted = user.isLocalMuted()
                if let name = user.userName() {
                    settings.append(HandoffUserAudioSetting(
                        userName: name,
                        volume: volume,
                        isLocalMuted: isMuted
                    ))
                }
            }
        }
        if let subChannels = channel.channels() as? [MKChannel] {
            for sub in subChannels {
                collectUserAudioSettings(in: sub, settings: &settings)
            }
        }
    }

    func startLiveActivity() {
        #if os(iOS)
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        if liveActivity != nil {
            updateLiveActivity()
            return
        }

        let targetServerName = (serverName ?? "Mumble").trimmingCharacters(in: .whitespacesAndNewlines)

        // 重连或后台恢复时优先复用系统已存在的活动，避免强制结束导致灵动岛闪断/丢失。
        // 当系统中存在多个活动时，优先匹配当前 serverName，避免串到旧会话。
        let allActivities = Activity<MumbleActivityAttributes>.activities
        let matchedByServer = allActivities.first {
            $0.attributes.serverName.caseInsensitiveCompare(targetServerName) == .orderedSame
        }

        if let existing = matchedByServer ?? allActivities.first {
            self.liveActivity = existing
            restartLiveActivityKeepAliveTimer()
            updateLiveActivity()
            return
        }

        let initialContentState = MumbleActivityAttributes.ContentState(
            speakers: [],
            userCount: 0,
            channelName: NSLocalizedString("Connecting...", comment: ""),
            isSelfMuted: true,
            isSelfDeafened: false
        )

        let attributes = MumbleActivityAttributes(serverName: targetServerName)

        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: .init(state: initialContentState, staleDate: nil),
                pushType: nil
            )
            self.liveActivity = activity
            MumbleLogger.handoff.info("Live Activity Started")

            restartLiveActivityKeepAliveTimer()
            // 立即更新一次准确数据
            updateLiveActivity()
        } catch {
            MumbleLogger.handoff.error("Failed to start Live Activity: \(error)")
        }
        #endif
    }

    func updateLiveActivity() {
        #if os(iOS)
        guard let activity = liveActivity else { return }

        let channelName = currentNotificationTitle
        var userCount = 0
        var speakers: [String] = []
        var isSelfMuted = true
        var isSelfDeafened = false

        if let connectedUser = serverModel?.connectedUser() {
            isSelfMuted = connectedUser.isSelfMuted()
            isSelfDeafened = connectedUser.isSelfDeafened()

            if let currentChannel = connectedUser.channel(),
               let users = currentChannel.users() as? [MKUser] {
                userCount = users.count
                let speakingUsers = users.filter { $0.talkState().rawValue > 0 }
                speakers = speakingUsers.compactMap { $0.userName() }
            }
        }

        let contentState = MumbleActivityAttributes.ContentState(
            speakers: speakers,
            userCount: userCount,
            channelName: channelName,
            isSelfMuted: isSelfMuted,
            isSelfDeafened: isSelfDeafened
        )

        nonisolated(unsafe) let activityToUpdate = activity
        Task {
            await activityToUpdate.update(
                ActivityContent(state: contentState, staleDate: nil)
            )
        }

        // 同步更新 Handoff Activity 的音频状态
        updateHandoffAudioState()
        #endif
    }

    /// 收集当前用户音频设置并更新 Handoff Activity
    func updateHandoffAudioState() {
        guard let model = serverModel,
              let connectedUser = model.connectedUser() else { return }

        let shouldSyncLocalAudio = UserDefaults.standard.object(forKey: MumbleHandoffSyncLocalAudioSettingsKey) as? Bool ?? true

        var audioSettings: [HandoffUserAudioSetting] = []
        if shouldSyncLocalAudio, let rootChannel = model.rootChannel() {
            collectUserAudioSettings(in: rootChannel, settings: &audioSettings)
        }

        HandoffManager.shared.updateActivityAudioState(
            isSelfMuted: connectedUser.isSelfMuted(),
            isSelfDeafened: connectedUser.isSelfDeafened(),
            userAudioSettings: audioSettings
        )
    }

    func endLiveActivity() {
        #if os(iOS)
        guard let activity = liveActivity else { return }

        let finalContentState = MumbleActivityAttributes.ContentState(
            speakers: [],
            userCount: 0,
            channelName: "Disconnected",
            isSelfMuted: false,
            isSelfDeafened: false
        )

        nonisolated(unsafe) let activityToEnd = activity
        Task {
            await activityToEnd.end(
                ActivityContent(state: finalContentState, staleDate: nil),
                dismissalPolicy: .immediate
            )
            self.liveActivity = nil
        }
        #endif
    }
}
