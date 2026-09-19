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
    private var liveActivityStaleDate: Date {
        Date().addingTimeInterval(45)
    }

    private var liveActivityServerName: String {
        let name = (serverName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Mumble" : name
    }

    private func restartLiveActivityKeepAliveTimer() {
        keepAliveTimer?.invalidate()
        let timer = Timer(timeInterval: 20.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                // A heartbeat only extends freshness; audio preferences already
                // have their own event-driven Handoff synchronization.
                self?.queueLiveActivityUpdate(forceRefresh: true)
            }
        }
        timer.tolerance = 2.0
        RunLoop.main.add(timer, forMode: .common)
        keepAliveTimer = timer
    }

    private func liveActivityContentState() -> MumbleActivityAttributes.ContentState? {
        guard isConnected, let connectedUser = serverModel?.connectedUser() else { return nil }
        let users = connectedUser.channel()?.users() as? [MKUser] ?? []
        let speakers = users
            .filter {
                $0.talkState().rawValue > 0 && !$0.isMuted()
                    && !$0.isSelfMuted() && !$0.isSelfDeafened()
            }
            .sorted { $0.session() < $1.session() }
            .map { displayName(for: $0) }

        return MumbleActivityAttributes.ContentState(
            speakers: speakers,
            userCount: users.count,
            channelName: currentNotificationTitle,
            isSelfMuted: connectedUser.isSelfMuted(),
            isSelfDeafened: connectedUser.isSelfDeafened()
        )
    }

    private func resetLiveActivityUpdates() {
        liveActivityUpdateGeneration &+= 1
        pendingLiveActivityUpdateTask?.cancel()
        pendingLiveActivityUpdateTask = nil
        pendingLiveActivityContent = nil
        lastLiveActivityContentState = nil
    }

    private func queueLiveActivityUpdate(forceRefresh: Bool = false) {
        guard let activity = liveActivity,
              activity.activityState == .active || activity.activityState == .stale,
              activity.attributes.serverName == liveActivityServerName,
              liveActivitySessionScope == boundListeningSessionScope,
              let contentState = liveActivityContentState() else { return }

        guard forceRefresh || pendingLiveActivityUpdateTask != nil
                || contentState != lastLiveActivityContentState else { return }

        pendingLiveActivityContent = (
            state: contentState,
            forceRefresh: forceRefresh || pendingLiveActivityContent?.forceRefresh == true
        )
        guard pendingLiveActivityUpdateTask == nil else { return }

        let generation = liveActivityUpdateGeneration
        nonisolated(unsafe) let activityToUpdate = activity
        pendingLiveActivityUpdateTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.liveActivityUpdateGeneration == generation {
                    self.pendingLiveActivityUpdateTask = nil
                }
            }

            // Merge bursts from talking, mute and channel model callbacks. A
            // single worker keeps async ActivityKit writes in their event order.
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 150_000_000)
                } catch {
                    return
                }
                guard self.liveActivityUpdateGeneration == generation,
                      self.liveActivity?.id == activityToUpdate.id,
                      self.isConnected,
                      self.liveActivitySessionScope == self.boundListeningSessionScope,
                      let pending = self.pendingLiveActivityContent else { return }
                self.pendingLiveActivityContent = nil

                if pending.forceRefresh || pending.state != self.lastLiveActivityContentState {
                    await activityToUpdate.update(
                        ActivityContent(state: pending.state, staleDate: self.liveActivityStaleDate)
                    )
                    guard self.liveActivityUpdateGeneration == generation else { return }
                    self.lastLiveActivityContentState = pending.state
                }

                if self.pendingLiveActivityContent == nil { return }
            }
        }
    }
    #endif

    // MARK: - Handoff User Preferences Restore

    @objc func handleHandoffRestoreUserPreferences() {
        restoreAllUserPreferences()
    }

    // MARK: - Handoff (接力)

    func schedulePostConnectionActivities() {
        pendingPostConnectionActivitiesTask?.cancel()
        pendingPostConnectionActivitiesTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard let self, !Task.isCancelled, self.isConnected else { return }

            self.startLiveActivity()
            self.publishHandoffActivity()
            self.pendingPostConnectionActivitiesTask = nil
        }
    }

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
        guard ActivityAuthorizationInfo().areActivitiesEnabled,
              let initialContentState = liveActivityContentState() else { return }

        let targetServerName = liveActivityServerName
        if let activity = liveActivity,
           activity.attributes.serverName == targetServerName,
           liveActivitySessionScope == boundListeningSessionScope,
           activity.activityState == .active || activity.activityState == .stale {
            // Reconnect cleanup invalidates the timer while preserving the activity.
            restartLiveActivityKeepAliveTimer()
            updateHandoffAudioState()
            queueLiveActivityUpdate(forceRefresh: true)
            return
        }

        if liveActivity != nil {
            endLiveActivity()
        }

        // 重连或后台恢复时优先复用系统已存在的活动，避免强制结束导致灵动岛闪断/丢失。
        // 静态服务器名称无法更新，只能复用同一服务器且尚未结束的活动。
        let existing = Activity<MumbleActivityAttributes>.activities.first {
            $0.attributes.serverName == targetServerName
                && !liveActivitiesBeingEnded.contains($0.id)
                && ($0.activityState == .active || $0.activityState == .stale)
        }

        if let existing {
            resetLiveActivityUpdates()
            self.liveActivity = existing
            liveActivitySessionScope = boundListeningSessionScope
            restartLiveActivityKeepAliveTimer()
            updateLiveActivity()
            return
        }

        let attributes = MumbleActivityAttributes(serverName: targetServerName)

        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: .init(state: initialContentState, staleDate: liveActivityStaleDate),
                pushType: nil
            )
            resetLiveActivityUpdates()
            self.liveActivity = activity
            liveActivitySessionScope = boundListeningSessionScope
            lastLiveActivityContentState = initialContentState
            MumbleLogger.handoff.info("Live Activity Started")

            restartLiveActivityKeepAliveTimer()
        } catch {
            MumbleLogger.handoff.error("Failed to start Live Activity: \(error)")
        }
        #endif
    }

    func updateLiveActivity(syncHandoffAudioState: Bool = true) {
        // Handoff exists on both iOS and macOS. Keep its audio state fresh even
        // when there is no iOS Live Activity to update.
        if syncHandoffAudioState {
            updateHandoffAudioState()
        }

        #if os(iOS)
        queueLiveActivityUpdate()
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
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
        let pendingUpdate = pendingLiveActivityUpdateTask
        resetLiveActivityUpdates()
        liveActivitySessionScope = nil
        guard let activity = liveActivity else { return }
        // Detach synchronously so an old end operation cannot clear a newly
        // created activity or let a reconnect reuse the one being dismissed.
        liveActivity = nil
        liveActivitiesBeingEnded.insert(activity.id)

        let finalContentState = MumbleActivityAttributes.ContentState(
            speakers: [],
            userCount: 0,
            channelName: NSLocalizedString("Disconnected", comment: ""),
            isSelfMuted: false,
            isSelfDeafened: false
        )

        nonisolated(unsafe) let activityToEnd = activity
        Task { @MainActor [weak self] in
            await pendingUpdate?.value
            await activityToEnd.end(
                ActivityContent(state: finalContentState, staleDate: nil),
                dismissalPolicy: .immediate
            )
            self?.liveActivitiesBeingEnded.remove(activityToEnd.id)
        }
        #endif
    }
}
