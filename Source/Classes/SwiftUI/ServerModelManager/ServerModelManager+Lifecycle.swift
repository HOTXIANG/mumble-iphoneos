//
//  ServerModelManager+Lifecycle.swift
//  Mumble
//

import Foundation
import OSLog
#if os(iOS)
import AVFAudio
#endif

extension ServerModelManager {
    func setupServerModel() {
        guard let connectionController = MUConnectionController.existingShared(),
              let model = connectionController.serverModel,
              model.connectedUser() != nil else {
            return
        }

        let newModel = model

        if self.serverModel === newModel {
            MumbleLogger.connection.debug("ServerModel identity match. Skipping setup to prevent duplicates.")
            // 兜底：如果界面是空的，强制刷新一下
            if self.modelItems.isEmpty { rebuildModelArray(reason: "setup_same_model_empty") }
            return
        }

        if self.serverModel != nil {
            MumbleLogger.connection.info("Switching Server Model. Performing cleanup...")
            self.cleanup(preserveSessionActivities: true)
        }

        MumbleLogger.connection.info("Binding new ServerModel...")
        self.serverModel = newModel
        boundListeningSessionScope = listeningSessionScope(for: newModel)
        if savedListeningSessionScope != boundListeningSessionScope {
            savedListeningChannelIds.removeAll()
            savedListeningSessionScope = nil
        }

        let wrapper = ServerModelDelegateWrapper()
        newModel.addDelegate(wrapper)
        self.delegateToken = DelegateToken(model: model, wrapper: wrapper)

        isConnected = true

        let currentHost = model.hostname() ?? ""
        let currentPort = Int(model.port())

        if let savedName = RecentServerManager.shared.getDisplayName(hostname: currentHost, port: currentPort) {
            MumbleLogger.connection.debug("Resolved name from Recents: '\(savedName)'")
            self.serverName = savedName
        } else {
            self.serverName = currentHost
        }

        if let welcomeText = connectionController.lastWelcomeMessage, !welcomeText.isEmpty {
            let lastMsg = self.messages.last?.attributedMessage.description
            if lastMsg == nil || !lastMsg!.contains(welcomeText) {
                let welcomeMsg = ChatMessage(
                    id: UUID(),
                    type: .notification,
                    senderName: "Server",
                    attributedMessage: self.attributedString(from: welcomeText),
                    images: [],
                    timestamp: Date(),
                    isSentBySelf: false
                )
                self.messages.append(welcomeMsg)
            }
        } else if messages.isEmpty {
            // 兜底显示
            let hostDisplayName = serverName ?? currentHost
            addSystemNotification("Connected to \(hostDisplayName)")
        }

        if let connectedUser = newModel.connectedUser() {
            updateAvatarCache(for: connectedUser)
        }

        rebuildModelArray(reason: "setup_server_model_bound")
        schedulePostConnectionActivities()

        // 服务器模型绑定成功后，才激活音频相关的监听
        setupSystemMute()
        #if os(iOS)
        setupAudioRouteObservation()
        #endif

        // 监听 Handoff 恢复用户音频偏好的通知
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleHandoffRestoreUserPreferences),
            name: MumbleHandoffRestoreUserPreferencesNotification,
            object: nil
        )
    }

    func cleanup(preserveSessionActivities: Bool = false) {
        MumbleLogger.connection.info("ServerModelManager: CLEANUP (Data Only)")
        pendingConnectionRestoreTask?.cancel()
        pendingConnectionRestoreTask = nil
        pendingModelRebuildWorkItem?.cancel()
        pendingModelRebuildWorkItem = nil
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
        pendingAvatarRefreshTask?.cancel()
        pendingAvatarRefreshTask = nil
        pendingPostConnectionActivitiesTask?.cancel()
        pendingPostConnectionActivitiesTask = nil
        pendingPermissionScanFlushWorkItem?.cancel()
        pendingPermissionScanFlushWorkItem = nil

        userVolumes.removeAll()
        localNicknames.removeAll()
        previousMuteStates.removeAll()
        wasMutedBeforeServerDeafen.removeAll()
        currentAccessTokens.removeAll()
        pendingPasswordChannelId = nil
        userInitiatedJoinChannelId = nil
        passwordJoinSequence &+= 1
        userInitiatedJoinSequence &+= 1
        audioRouteChangeSequence &+= 1
        appDrivenSystemMuteSequence &+= 1
        isScanningACLs = false
        isRestoringMuteState = false
        isApplyingAppDrivenSystemMute = false
        savedMuteBeforeRestart = nil
        savedDeafenBeforeRestart = nil
        isInputSettingsPreviewOverrideActive = false
        inputSettingsRestoreSystemMute = nil
        serverImageMessageLengthBytes = nil
        pendingOutgoingMessages.removeAll()
        channelsWithPassword.removeAll()
        channelsUserCanEnter.removeAll()
        channelPermissions.removeAll()
        pendingPermissionScanResults.removeAll()
        pendingPasswordStatusUpdates.removeAll()
        aclUserNamesById.removeAll()
        pendingACLUserNameQueries.removeAll()
        userAvatars.removeAll()
        userAvatarFingerprints.removeAll()
        pendingAvatarFetchSessions.removeAll()
        // 将尚未确认的 add/remove 也算入用户意图，断线发生在回包前仍可正确恢复。
        if let scope = boundListeningSessionScope {
            let desired = listeningChannels.union(pendingListeningAdds).subtracting(pendingListeningRemoves)
            if savedListeningSessionScope != scope || !listeningChannels.isEmpty || !pendingListeningAdds.isEmpty || !pendingListeningRemoves.isEmpty {
                savedListeningChannelIds = desired
                savedListeningSessionScope = scope
                MumbleLogger.connection.debug("Saved \(savedListeningChannelIds.count) listening channels for reconnect")
            }
        }
        listeningChannels.removeAll()
        channelListeners.removeAll()
        pendingListeningAdds.removeAll()
        pendingListeningRemoves.removeAll()
        movingUser = nil
        passwordPromptChannel = nil
        pendingPasswordInput = ""

        self.delegateToken = nil
        self.serverModel = nil
        boundListeningSessionScope = nil
        modelItems = []
        userIndexMap = [:]
        channelIndexMap = [:]
        lastKnownChannelIdByUserSession.removeAll()
        isConnected = false
        serverName = nil

        systemMuteManager.cleanup()
        #if os(iOS)
        NotificationCenter.default.removeObserver(self, name: AVAudioSession.routeChangeNotification, object: nil)
        #endif
        NotificationCenter.default.removeObserver(self, name: MumbleHandoffRestoreUserPreferencesNotification, object: nil)
        if preserveSessionActivities {
            MumbleLogger.connection.debug("Preserving Live Activity/Handoff during reconnect cleanup")
        } else {
            endLiveActivity()

            // 停止广播 Handoff Activity
            HandoffManager.shared.invalidateActivity()
        }
    }

    func isCurrentServerModel(_ model: MKServerModel) -> Bool {
        isConnected && serverModel === model && MUConnectionController.existingShared()?.serverModel === model
    }

    func listeningSessionScope(for model: MKServerModel) -> ListeningSessionScope {
        ListeningSessionScope(
            hostname: (model.hostname() ?? "").lowercased(),
            port: UInt(model.port()),
            username: model.connectedUser()?.userName() ?? ""
        )
    }
}
