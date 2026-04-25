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
              let model = connectionController.serverModel else {
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
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
        pendingAvatarRefreshTask?.cancel()
        pendingAvatarRefreshTask = nil
        pendingPostConnectionActivitiesTask?.cancel()
        pendingPostConnectionActivitiesTask = nil

        userVolumes.removeAll()
        previousMuteStates.removeAll()
        channelsWithPassword.removeAll()
        channelsUserCanEnter.removeAll()
        channelPermissions.removeAll()
        aclUserNamesById.removeAll()
        pendingACLUserNameQueries.removeAll()
        userAvatars.removeAll()
        userAvatarFingerprints.removeAll()
        pendingAvatarFetchSessions.removeAll()
        // 保存当前监听频道以便重连后恢复
        if !listeningChannels.isEmpty {
            self.savedListeningChannelIds = listeningChannels
            MumbleLogger.connection.debug("Saved \(self.savedListeningChannelIds.count) listening channels for reconnect")
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
}
