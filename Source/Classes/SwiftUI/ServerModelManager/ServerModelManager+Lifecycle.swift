//
//  ServerModelManager+Lifecycle.swift
//  Mumble
//

import Foundation
#if os(iOS)
import AVFAudio
#endif

extension ServerModelManager {
    func setupServerModel() {
        guard let connectionController = MUConnectionController.shared(),
              let model = connectionController.serverModel else {
            return
        }

        guard let newModel = connectionController.serverModel else {
            print("⚠️ ServerModel not ready. Retrying in 0.5s...")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.setupServerModel()
            }
            return
        }

        if self.serverModel === newModel {
            print("✅ ServerModel identity match. Skipping setup to prevent duplicates.")
            // 兜底：如果界面是空的，强制刷新一下
            if self.modelItems.isEmpty { rebuildModelArray() }
            return
        }

        if self.serverModel != nil {
            print("🔄 Switching Server Model. Performing cleanup...")
            self.cleanup()
        }

        print("🔗 Binding new ServerModel...")
        self.serverModel = newModel

        let wrapper = ServerModelDelegateWrapper()
        newModel.addDelegate(wrapper)
        self.delegateToken = DelegateToken(model: model, wrapper: wrapper)

        isConnected = true

        let currentHost = model.hostname() ?? ""
        let currentPort = Int(model.port())

        if let savedName = RecentServerManager.shared.getDisplayName(hostname: currentHost, port: currentPort) {
            print("📖 ServerModelManager: Resolved name from Recents: '\(savedName)'")
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

        rebuildModelArray()
        startLiveActivity()

        // 发布 Handoff Activity，让其他设备可以接力
        publishHandoffActivity()

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

    func cleanup() {
        print("🧹 ServerModelManager: CLEANUP (Data Only)")
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil

        userVolumes.removeAll()
        previousMuteStates.removeAll()
        channelsWithPassword.removeAll()
        channelsUserCanEnter.removeAll()
        channelPermissions.removeAll()
        aclUserNamesById.removeAll()
        pendingACLUserNameQueries.removeAll()
        // 保存当前监听频道以便重连后恢复
        if !listeningChannels.isEmpty {
            savedListeningChannelIds = listeningChannels
            print("💾 Saved \(savedListeningChannelIds.count) listening channels for reconnect")
        }
        listeningChannels.removeAll()
        channelListeners.removeAll()
        movingUser = nil
        passwordPromptChannel = nil
        pendingPasswordInput = ""

        self.delegateToken = nil
        self.serverModel = nil
        modelItems = []
        userIndexMap = [:]
        channelIndexMap = [:]
        isConnected = false
        serverName = nil

        systemMuteManager.cleanup()
        #if os(iOS)
        NotificationCenter.default.removeObserver(self, name: AVAudioSession.routeChangeNotification, object: nil)
        #endif
        NotificationCenter.default.removeObserver(self, name: MumbleHandoffRestoreUserPreferencesNotification, object: nil)
        endLiveActivity()

        // 停止广播 Handoff Activity
        HandoffManager.shared.invalidateActivity()
    }
}
