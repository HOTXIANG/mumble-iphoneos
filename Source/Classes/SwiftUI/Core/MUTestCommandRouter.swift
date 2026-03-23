//
//  MUTestCommandRouter.swift
//  Mumble
//
//  JSON command router for the WebSocket test server.
//  Routes "domain.command" actions to appropriate app module handlers.
//  Only compiled in DEBUG builds.
//

#if DEBUG

import Foundation
import Network
#if os(macOS)
import AppKit
#endif

// MARK: - Error Type

struct TestCommandError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { self.errorDescription = message }
}

struct MUTestCommandContext {
    let connectionID: ObjectIdentifier
}

struct NotificationSnapshot: @unchecked Sendable {
    let name: Notification.Name
    let userInfo: [AnyHashable: Any]?
}

// MARK: - Command Router

@MainActor
final class MUTestCommandRouter {
    weak var serverManager: ServerModelManager?
    weak var testServer: MUTestServer?

    func handle(action: String, params: [String: Any], context: MUTestCommandContext? = nil) async throws -> Any? {
        let parts = action.split(separator: ".", maxSplits: 1)
        guard parts.count == 2 else {
            throw TestCommandError("Invalid action format '\(action)'. Use 'domain.command'")
        }

        let domain = String(parts[0])
        let command = String(parts[1])

        switch domain {
        case "connection": return try handleConnection(command, params)
        case "audio":      return try handleAudio(command, params)
        case "channel":    return try await handleChannel(command, params)
        case "message":    return try await handleMessage(command, params)
        case "plugin":     return try await handlePlugin(command, params)
        case "user":       return try await handleUser(command, params)
        case "favourite":  return try handleFavourite(command, params)
        case "settings":   return try handleSettings(command, params)
        case "state":      return try handleState(command, params)
        case "app":        return try handleApp(command, params)
        case "ui":         return try handleUI(command, params)
        case "server":     return try await handleServer(command, params)
        case "certificate": return try handleCertificate(command, params)
        case "log":        return try handleLog(command, params, context: context)
        case "help":       return try handleHelp(command, params)
        default:
            throw TestCommandError("Unknown domain '\(domain)'. Use help.actions for available commands")
        }
    }

    // MARK: - Connection

    private func handleConnection(_ cmd: String, _ params: [String: Any]) throws -> Any? {
        let ctrl = MUConnectionController.shared()

        switch cmd {
        case "connect":
            guard let hostname = params["hostname"] as? String else {
                throw TestCommandError("Missing 'hostname'")
            }
            let port = intValue(params["port"]) ?? 64738
            let username = params["username"] as? String ?? "TestUser"
            let password = params["password"] as? String ?? ""
            let displayName = params["displayName"] as? String ?? hostname

            AppState.shared.serverDisplayName = displayName
            ctrl?.connect(toHostname: hostname, port: UInt(port),
                          withUsername: username, andPassword: password,
                          certificateRef: nil, displayName: displayName)
            return ["status": "connecting"]

        case "disconnect":
            ctrl?.disconnectFromServer()
            return nil

        case "acceptCert":
            guard AppState.shared.pendingCertTrust != nil else {
                return ["status": "no pending certificate trust"]
            }
            ctrl?.acceptCertificateTrust()
            AppState.shared.pendingCertTrust = nil
            return ["status": "accepted"]

        case "rejectCert":
            guard AppState.shared.pendingCertTrust != nil else {
                return ["status": "no pending certificate trust"]
            }
            ctrl?.rejectCertificateTrust()
            AppState.shared.pendingCertTrust = nil
            return ["status": "rejected"]

        case "status":
            let connected = ctrl?.isConnected() ?? false
            var data: [String: Any] = [
                "connected": connected,
                "isConnecting": AppState.shared.isConnecting,
                "isReconnecting": AppState.shared.isReconnecting,
                "hasPendingCertTrust": AppState.shared.pendingCertTrust != nil
            ]
            if connected, let conn = ctrl?.connection {
                data["hostname"] = conn.hostname() ?? ""
                data["port"] = conn.port()
                data["serverName"] = serverManager?.serverName ?? ""
            }
            return data

        default:
            throw TestCommandError("Unknown connection.\(cmd). Available: connect, disconnect, acceptCert, rejectCert, status")
        }
    }

    // MARK: - Audio

    private func handleAudio(_ cmd: String, _ params: [String: Any]) throws -> Any? {
        switch cmd {
        case "mute":
            guard let model = MUConnectionController.shared()?.serverModel,
                  let user = model.connectedUser() else {
                throw TestCommandError("Not connected")
            }
            model.setSelfMuted(true, andSelfDeafened: user.isSelfDeafened())
            return nil

        case "unmute":
            guard let model = MUConnectionController.shared()?.serverModel,
                  let user = model.connectedUser() else {
                throw TestCommandError("Not connected")
            }
            model.setSelfMuted(false, andSelfDeafened: user.isSelfDeafened())
            return nil

        case "deafen":
            guard let model = MUConnectionController.shared()?.serverModel else {
                throw TestCommandError("Not connected")
            }
            model.setSelfMuted(true, andSelfDeafened: true)
            return nil

        case "undeafen":
            guard let model = MUConnectionController.shared()?.serverModel else {
                throw TestCommandError("Not connected")
            }
            model.setSelfMuted(false, andSelfDeafened: false)
            return nil

        case "toggleMute":
            guard let sm = serverManager else {
                throw TestCommandError("ServerModelManager not available")
            }
            sm.toggleSelfMute()
            return nil

        case "toggleDeafen":
            guard let sm = serverManager else {
                throw TestCommandError("ServerModelManager not available")
            }
            sm.toggleSelfDeafen()
            return nil

        case "startTest":
            guard let sm = serverManager else {
                throw TestCommandError("ServerModelManager not available")
            }
            sm.startAudioTest()
            return ["localAudioTestRunning": sm.isLocalAudioTestRunning]

        case "stopTest":
            guard let sm = serverManager else {
                throw TestCommandError("ServerModelManager not available")
            }
            sm.stopAudioTest()
            return ["localAudioTestRunning": sm.isLocalAudioTestRunning]

        case "restart":
            guard MUConnectionController.shared()?.isConnected() == true else {
                throw TestCommandError("Not connected — audio engine not active")
            }
            MKAudio.shared()?.restart()
            return nil

        case "forceTransmit":
            guard let enabled = boolValue(params["enabled"]) else {
                throw TestCommandError("Missing 'enabled'")
            }
            guard MUConnectionController.shared()?.isConnected() == true || serverManager?.isLocalAudioTestRunning == true else {
                throw TestCommandError("Audio engine not active")
            }
            MKAudio.shared()?.setForceTransmit(enabled)
            return ["forceTransmit": MKAudio.shared()?.forceTransmit() ?? enabled]

        case "status":
            // Only access MKAudio when connected to avoid blocking main thread
            let connected = MUConnectionController.shared()?.isConnected() == true
            let localAudioTestRunning = serverManager?.isLocalAudioTestRunning ?? false
            if connected || localAudioTestRunning {
                let connUser = MUConnectionController.shared()?.serverModel?.connectedUser()
                return [
                    "running": MKAudio.shared()?.isRunning() ?? false,
                    "forceTransmit": MKAudio.shared()?.forceTransmit() ?? false,
                    "selfMuted": connUser?.isSelfMuted() ?? false,
                    "selfDeafened": connUser?.isSelfDeafened() ?? false,
                    "localAudioTestRunning": localAudioTestRunning
                ] as [String: Any]
            } else {
                return [
                    "running": false,
                    "forceTransmit": false,
                    "selfMuted": false,
                    "selfDeafened": false,
                    "localAudioTestRunning": false,
                    "note": "Not connected — audio engine not initialized"
                ] as [String: Any]
            }

        default:
            throw TestCommandError("Unknown audio.\(cmd). Available: mute, unmute, deafen, undeafen, toggleMute, toggleDeafen, startTest, stopTest, restart, forceTransmit, status")
        }
    }

    // MARK: - Channel

    private func handleChannel(_ cmd: String, _ params: [String: Any]) async throws -> Any? {
        guard let model = MUConnectionController.shared()?.serverModel else {
            throw TestCommandError("Not connected")
        }

        switch cmd {
        case "list":
            guard let root = model.rootChannel() else { return [] }
            return serializeChannel(root)

        case "info":
            let channelId = try requireUInt(params["channelId"], name: "channelId")
            guard let channel = findChannel(id: channelId, in: model.rootChannel()) else {
                throw TestCommandError("Channel \(channelId) not found")
            }
            return serializeChannel(channel)

        case "join":
            let channelId = try requireUInt(params["channelId"], name: "channelId")
            guard let channel = findChannel(id: channelId, in: model.rootChannel()) else {
                throw TestCommandError("Channel \(channelId) not found")
            }
            serverManager?.joinChannel(channel)
            return nil

        case "create":
            guard let name = params["name"] as? String else {
                throw TestCommandError("Missing 'parentId' or 'name'")
            }
            let parentId = try requireUInt(params["parentId"], name: "parentId")
            let temporary = params["temporary"] as? Bool ?? false
            guard let parent = findChannel(id: parentId, in: model.rootChannel()) else {
                throw TestCommandError("Parent channel \(parentId) not found")
            }
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasExtraSettings =
                (params["description"] as? String)?.isEmpty == false
                || intValue(params["position"]) != nil
                || intValue(params["maxUsers"]) != nil
                || (params["password"] as? String)?.isEmpty == false

            guard hasExtraSettings else {
                serverManager?.createChannel(name: trimmedName, parent: parent, temporary: temporary)
                return ["status": "created", "name": trimmedName]
            }

            let notification = try await awaitNotification(name: ServerModelNotificationManager.channelAddedNotification) { [weak serverManager] in
                serverManager?.createChannel(name: trimmedName, parent: parent, temporary: temporary)
            }
            guard let newChannel = notification.userInfo?["channel"] as? MKChannel,
                  newChannel.channelName() == trimmedName,
                  newChannel.parent()?.channelId() == parentId else {
                throw TestCommandError("Created channel could not be resolved")
            }

            let description = params["description"] as? String
            let position = intValue(params["position"]).map { NSNumber(value: $0) }
            let maxUsers = intValue(params["maxUsers"]).map { NSNumber(value: $0) }
            let password = params["password"] as? String ?? ""

            if description != nil || position != nil || maxUsers != nil {
                serverManager?.editChannel(newChannel, name: nil, description: description, position: position, maxUsers: maxUsers)
            }
            if !password.isEmpty, let serverManager {
                CreateChannelView.setupPasswordACLForChannel(newChannel, password: password, serverManager: serverManager)
            }

            return serializeChannel(newChannel)

        case "edit":
            let channelId = try requireUInt(params["channelId"], name: "channelId")
            guard let channel = findChannel(id: channelId, in: model.rootChannel()) else {
                throw TestCommandError("Channel \(channelId) not found")
            }
            let name = params["name"] as? String
            let description = params["description"] as? String
            let position = intValue(params["position"]).map { NSNumber(value: $0) }
            let maxUsers = intValue(params["maxUsers"]).map { NSNumber(value: $0) }
            serverManager?.editChannel(channel, name: name, description: description, position: position, maxUsers: maxUsers)
            return nil

        case "move":
            let channelId = try requireUInt(params["channelId"], name: "channelId")
            let parentId = try requireUInt(params["parentId"], name: "parentId")
            guard let channel = findChannel(id: channelId, in: model.rootChannel()) else {
                throw TestCommandError("Channel \(channelId) not found")
            }
            guard let parent = findChannel(id: parentId, in: model.rootChannel()) else {
                throw TestCommandError("Parent channel \(parentId) not found")
            }
            serverManager?.moveChannel(channel, to: parent)
            return nil

        case "remove":
            let channelId = try requireUInt(params["channelId"], name: "channelId")
            guard let channel = findChannel(id: channelId, in: model.rootChannel()) else {
                throw TestCommandError("Channel \(channelId) not found")
            }
            serverManager?.removeChannel(channel)
            return nil

        case "listen":
            let channelId = try requireUInt(params["channelId"], name: "channelId")
            guard let channel = findChannel(id: channelId, in: model.rootChannel()) else {
                throw TestCommandError("Channel \(channelId) not found")
            }
            serverManager?.startListening(to: channel)
            return nil

        case "unlisten":
            let channelId = try requireUInt(params["channelId"], name: "channelId")
            guard let channel = findChannel(id: channelId, in: model.rootChannel()) else {
                throw TestCommandError("Channel \(channelId) not found")
            }
            serverManager?.stopListening(to: channel)
            return nil

        case "toggleCollapse":
            let channelId = try requireUInt(params["channelId"], name: "channelId")
            serverManager?.toggleChannelCollapse(Int(channelId))
            return nil

        case "togglePinned":
            let channelId = try requireUInt(params["channelId"], name: "channelId")
            guard let channel = findChannel(id: channelId, in: model.rootChannel()) else {
                throw TestCommandError("Channel \(channelId) not found")
            }
            serverManager?.toggleChannelPinned(channel)
            return nil

        case "toggleHidden":
            let channelId = try requireUInt(params["channelId"], name: "channelId")
            guard let channel = findChannel(id: channelId, in: model.rootChannel()) else {
                throw TestCommandError("Channel \(channelId) not found")
            }
            serverManager?.toggleChannelHidden(channel)
            return nil

        case "requestACL":
            let channelId = try requireUInt(params["channelId"], name: "channelId")
            guard let channel = findChannel(id: channelId, in: model.rootChannel()) else {
                throw TestCommandError("Channel \(channelId) not found")
            }
            serverManager?.requestACL(for: channel)
            return nil

        case "getACL":
            let channelId = try requireUInt(params["channelId"], name: "channelId")
            guard let channel = findChannel(id: channelId, in: model.rootChannel()) else {
                throw TestCommandError("Channel \(channelId) not found")
            }
            let notification = try await awaitNotification(name: ServerModelNotificationManager.aclReceivedNotification) { [weak serverManager] in
                serverManager?.requestACL(for: channel)
            }
            guard let accessControl = notification.userInfo?["accessControl"] as? MKAccessControl else {
                throw TestCommandError("ACL payload missing")
            }
            return serializeAccessControl(accessControl, channelId: channel.channelId())

        case "setACL":
            let channelId = try requireUInt(params["channelId"], name: "channelId")
            guard let channel = findChannel(id: channelId, in: model.rootChannel()) else {
                throw TestCommandError("Channel \(channelId) not found")
            }
            let accessControl = try parseAccessControl(params)
            serverManager?.setACL(accessControl, for: channel)
            return ["channelId": channel.channelId()]

        case "setAccessTokens":
            guard let tokens = stringArrayValue(params["tokens"]) else {
                throw TestCommandError("Missing 'tokens'")
            }
            serverManager?.currentAccessTokens = tokens
            model.setAccessTokens(tokens)
            return ["tokens": tokens]

        case "submitPassword":
            let channelId = try requireUInt(params["channelId"], name: "channelId")
            guard let password = params["password"] as? String else {
                throw TestCommandError("Missing 'password'")
            }
            guard let channel = findChannel(id: channelId, in: model.rootChannel()) else {
                throw TestCommandError("Channel \(channelId) not found")
            }
            serverManager?.submitPasswordAndJoin(channel: channel, password: password)
            return nil

        case "scanPermissions":
            serverManager?.scanAllChannelPermissions()
            return nil

        case "link":
            let channelId = try requireUInt(params["channelId"], name: "channelId")
            let targetId = try requireUInt(params["targetChannelId"], name: "targetChannelId")
            guard let channel = findChannel(id: channelId, in: model.rootChannel()),
                  let target = findChannel(id: targetId, in: model.rootChannel()) else {
                throw TestCommandError("Channel or targetChannel not found")
            }
            serverManager?.linkChannel(channel, to: target)
            return nil

        case "unlink":
            let channelId = try requireUInt(params["channelId"], name: "channelId")
            let targetId = try requireUInt(params["targetChannelId"], name: "targetChannelId")
            guard let channel = findChannel(id: channelId, in: model.rootChannel()),
                  let target = findChannel(id: targetId, in: model.rootChannel()) else {
                throw TestCommandError("Channel or targetChannel not found")
            }
            serverManager?.unlinkChannel(channel, from: target)
            return nil

        case "unlinkAll":
            let channelId = try requireUInt(params["channelId"], name: "channelId")
            guard let channel = findChannel(id: channelId, in: model.rootChannel()) else {
                throw TestCommandError("Channel \(channelId) not found")
            }
            serverManager?.unlinkAllForChannel(channel)
            return nil

        case "getAccessTokens":
            return ["tokens": serverManager?.currentAccessTokens ?? []]

        case "current":
            let connUser = model.connectedUser()
            let ch = connUser?.channel()
            return [
                "channelId": ch?.channelId() ?? 0,
                "channelName": ch?.channelName() ?? "",
                "canEnter": ch?.canEnter() ?? false,
                "isEnterRestricted": ch?.isEnterRestricted() ?? false
            ] as [String: Any]

        default:
            throw TestCommandError("Unknown channel.\(cmd). Available: list, info, join, create, edit, move, remove, listen, unlisten, toggleCollapse, togglePinned, toggleHidden, requestACL, getACL, setACL, setAccessTokens, getAccessTokens, submitPassword, scanPermissions, link, unlink, unlinkAll, current")
        }
    }

    // MARK: - Message

    private func handleMessage(_ cmd: String, _ params: [String: Any]) async throws -> Any? {
        guard let sm = serverManager else {
            throw TestCommandError("ServerModelManager not available")
        }

        switch cmd {
        case "send":
            guard let text = params["text"] as? String else {
                throw TestCommandError("Missing 'text'")
            }
            sm.sendTextMessage(text)
            return nil

        case "sendTree":
            guard let text = params["text"] as? String else {
                throw TestCommandError("Missing 'text'")
            }
            sm.sendTextMessageToTree(text)
            return nil

        case "sendPrivate":
            guard let text = params["text"] as? String else {
                throw TestCommandError("Missing 'text' or 'session'")
            }
            let session = try requireUInt(params["session"], name: "session")
            guard let user = sm.getUserBySession(session) else {
                throw TestCommandError("User with session \(session) not found")
            }
            sm.sendPrivateMessage(text, to: user)
            return nil

        case "history":
            let limit = intValue(params["limit"]) ?? 50
            let messages = Array(sm.messages.suffix(limit))
            return messages.map { msg -> [String: Any] in
                var dict: [String: Any] = [
                    "id": msg.id.uuidString,
                    "senderName": msg.senderName,
                    "message": msg.plainTextMessage,
                    "timestamp": msg.timestamp.timeIntervalSince1970,
                    "isSentBySelf": msg.isSentBySelf,
                    "hasImages": !msg.images.isEmpty
                ]
                switch msg.type {
                case .userMessage:    dict["type"] = "userMessage"
                case .notification:   dict["type"] = "notification"
                case .privateMessage: dict["type"] = "privateMessage"
                }
                if let session = msg.senderSession { dict["senderSession"] = session }
                if let peer = msg.privatePeerName { dict["privatePeerName"] = peer }
                return dict
            }

        case "markRead":
            sm.markAsRead()
            return ["unreadMessageCount": AppState.shared.unreadMessageCount]

        case "sendImage":
            let image = try loadPlatformImage(from: params)
            await sm.sendImageMessage(image: image)
            return ["status": "sent"]

        case "sendPrivateImage":
            let session = try requireUInt(params["session"], name: "session")
            guard let user = sm.getUserBySession(session) else {
                throw TestCommandError("User with session \(session) not found")
            }
            let image = try loadPlatformImage(from: params)
            await sm.sendPrivateImageMessage(image: image, to: user)
            return ["status": "sent", "session": session]

        case "listImages":
            let messages = sm.messages.filter { !$0.images.isEmpty }
            return [
                "messages": messages.map { msg in
                    [
                        "id": msg.id.uuidString,
                        "senderName": msg.senderName,
                        "timestamp": msg.timestamp.timeIntervalSince1970,
                        "type": messageTypeName(msg.type),
                        "imageCount": msg.images.count,
                        "text": msg.plainTextMessage
                    ] as [String: Any]
                }
            ]

        case "exportImage":
            let (message, imageIndex) = try requireMessageImage(params, messages: sm.messages)
            let data = try encodePlatformImage(message.images[imageIndex])
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("mumble-message-\(message.id.uuidString)-\(imageIndex).jpg")
            try data.write(to: url, options: .atomic)
            return [
                "messageID": message.id.uuidString,
                "imageIndex": imageIndex,
                "path": url.path
            ]

        case "previewImage":
            let (message, imageIndex) = try requireMessageImage(params, messages: sm.messages)
            let preview = MessageImagePreviewItem(
                id: "ws-\(message.id.uuidString)-\(imageIndex)",
                image: message.images[imageIndex],
                sourceFrame: nil
            )
            #if os(iOS)
            AppState.shared.activeImagePreview = preview
            #else
            AppState.shared.activeMacImagePreview = preview
            #endif
            return [
                "messageID": message.id.uuidString,
                "imageIndex": imageIndex,
                "ui": buildUISnapshot()
            ]

        default:
            throw TestCommandError("Unknown message.\(cmd). Available: send, sendTree, sendPrivate, sendImage, sendPrivateImage, listImages, exportImage, previewImage, history, markRead")
        }
    }

    // MARK: - Plugin

    private func handlePlugin(_ cmd: String, _ params: [String: Any]) async throws -> Any? {
        let manager = AudioPluginRackManager.shared

        switch cmd {
        case "listTracks":
            return [
                "tracks": manager.currentTrackKeys().map { trackKey in
                    buildPluginTrackSnapshot(trackKey: trackKey)
                }
            ]

        case "get":
            let trackKey = try requirePluginTrackKey(params)
            return buildPluginTrackSnapshot(trackKey: trackKey)

        case "available":
            return [
                "plugins": manager.availablePlugins().map(serializeDiscoveredPlugin),
                "scanPaths": manager.customScanPaths()
            ]

        case "scanPaths":
            return ["paths": manager.customScanPaths()]

        case "addScanPath":
            guard let path = params["path"] as? String, !path.isEmpty else {
                throw TestCommandError("Missing 'path'")
            }
            manager.addCustomScanPath(path)
            return ["paths": manager.customScanPaths()]

        case "removeScanPath":
            guard let path = params["path"] as? String, !path.isEmpty else {
                throw TestCommandError("Missing 'path'")
            }
            manager.removeCustomScanPath(path)
            return ["paths": manager.customScanPaths()]

        case "buffer":
            return ["frames": manager.currentHostBufferFrames()]

        case "setBuffer":
            let frames = try requireInt(params["frames"], name: "frames")
            manager.setHostBufferFrames(frames)
            return ["frames": manager.currentHostBufferFrames()]

        case "add":
            let trackKey = try requirePluginTrackKey(params)
            let discovery = try requireDiscoveredPlugin(params)
            let index = intValue(params["index"])
            let plugin = await manager.addPlugin(discovery, to: trackKey, at: index)
            return [
                "track": buildPluginTrackSnapshot(trackKey: trackKey),
                "plugin": serializeTrackPlugin(trackKey: trackKey, plugin: plugin)
            ]

        case "remove":
            let selection = try requireTrackPlugin(params)
            guard let plugin = manager.removePlugin(trackKey: selection.trackKey, pluginID: selection.plugin.id) else {
                throw TestCommandError("Plugin not found")
            }
            return [
                "removed": serializeTrackPlugin(trackKey: selection.trackKey, plugin: plugin),
                "track": buildPluginTrackSnapshot(trackKey: selection.trackKey)
            ]

        case "move":
            let selection = try requireTrackPlugin(params)
            let targetIndex = try requireInt(params["toIndex"], name: "toIndex")
            manager.movePlugin(trackKey: selection.trackKey, pluginID: selection.plugin.id, to: targetIndex)
            return buildPluginTrackSnapshot(trackKey: selection.trackKey)

        case "setBypass":
            let selection = try requireTrackPlugin(params)
            let bypassed = boolValue(params["bypassed"]) ?? true
            manager.setPluginBypassed(trackKey: selection.trackKey, pluginID: selection.plugin.id, bypassed: bypassed)
            return serializeTrackPlugin(trackKey: selection.trackKey, plugin: selection.plugin.id, from: manager)

        case "setGain":
            let selection = try requireTrackPlugin(params)
            guard let gain = floatValue(params["gain"]) else {
                throw TestCommandError("Missing 'gain'")
            }
            manager.setPluginStageGain(trackKey: selection.trackKey, pluginID: selection.plugin.id, stageGain: gain)
            return serializeTrackPlugin(trackKey: selection.trackKey, plugin: selection.plugin.id, from: manager)

        case "load":
            let selection = try requireTrackPlugin(params)
            let loaded = await manager.loadPlugin(trackKey: selection.trackKey, pluginID: selection.plugin.id)
            return [
                "loaded": loaded,
                "plugin": serializeTrackPlugin(trackKey: selection.trackKey, plugin: selection.plugin.id, from: manager)
            ]

        case "unload":
            let selection = try requireTrackPlugin(params)
            manager.unloadPlugin(trackKey: selection.trackKey, pluginID: selection.plugin.id)
            return serializeTrackPlugin(trackKey: selection.trackKey, plugin: selection.plugin.id, from: manager)

        case "parameters":
            let selection = try requireTrackPlugin(params)
            return [
                "trackKey": selection.trackKey,
                "pluginID": selection.plugin.id,
                "parameters": manager.parameters(trackKey: selection.trackKey, pluginID: selection.plugin.id).map(serializePluginParameter)
            ]

        case "setParameter":
            let selection = try requireTrackPlugin(params)
            let parameterID = try requireUInt64(params["parameterID"], name: "parameterID")
            guard let value = floatValue(params["value"]) else {
                throw TestCommandError("Missing 'value'")
            }
            manager.setParameter(trackKey: selection.trackKey, pluginID: selection.plugin.id, parameterID: parameterID, value: value)
            return [
                "trackKey": selection.trackKey,
                "pluginID": selection.plugin.id,
                "parameters": manager.parameters(trackKey: selection.trackKey, pluginID: selection.plugin.id).map(serializePluginParameter)
            ]

        case "presets":
            let selection = try requireTrackPlugin(params)
            return [
                "pluginID": selection.plugin.id,
                "identifier": selection.plugin.identifier,
                "presets": manager.listPresets(for: selection.plugin.identifier).map(serializePluginPreset)
            ]

        case "savePreset":
            let selection = try requireTrackPlugin(params)
            guard let name = params["name"] as? String, !name.isEmpty else {
                throw TestCommandError("Missing 'name'")
            }
            guard let preset = manager.savePreset(name: name, trackKey: selection.trackKey, pluginID: selection.plugin.id) else {
                throw TestCommandError("Failed to save preset")
            }
            return serializePluginPreset(preset)

        case "applyPreset":
            let selection = try requireTrackPlugin(params)
            guard let presetID = params["presetID"] as? String, !presetID.isEmpty else {
                throw TestCommandError("Missing 'presetID'")
            }
            guard let preset = manager.applyPreset(trackKey: selection.trackKey, pluginID: selection.plugin.id, presetID: presetID) else {
                throw TestCommandError("Preset not found")
            }
            return [
                "preset": serializePluginPreset(preset),
                "parameters": manager.parameters(trackKey: selection.trackKey, pluginID: selection.plugin.id).map(serializePluginParameter)
            ]

        case "deletePreset":
            guard let pluginIdentifier = params["pluginIdentifier"] as? String, !pluginIdentifier.isEmpty else {
                throw TestCommandError("Missing 'pluginIdentifier'")
            }
            guard let presetID = params["presetID"] as? String, !presetID.isEmpty else {
                throw TestCommandError("Missing 'presetID'")
            }
            guard let preset = manager.deletePreset(pluginIdentifier: pluginIdentifier, presetID: presetID) else {
                throw TestCommandError("Preset not found")
            }
            return serializePluginPreset(preset)

        case "setSidechain":
            let trackKey = try requirePluginTrackKey(params)
            guard let source = params["source"] as? String else { throw TestCommandError("Missing 'source'") }
            let selection = try requireTrackPlugin(params)
            let sourceKey = source == "none" ? nil : source
            await manager.setSidechainSource(sourceKey, forPluginID: selection.plugin.id, inTrack: trackKey)
            return ["trackKey": trackKey, "pluginID": selection.plugin.id, "sidechainSource": source]

        case "getSidechain":
            let trackKey = try requirePluginTrackKey(params)
            let selection = try requireTrackPlugin(params)
            return ["trackKey": trackKey, "pluginID": selection.plugin.id, "sidechainSource": selection.plugin.sidechainSourceKey ?? "none"]

        default:
            throw TestCommandError("Unknown plugin.\(cmd). Available: listTracks, get, available, scanPaths, addScanPath, removeScanPath, buffer, setBuffer, add, remove, move, setBypass, setGain, load, unload, parameters, setParameter, presets, savePreset, applyPreset, deletePreset, setSidechain, getSidechain")
        }
    }

    // MARK: - User

    private func handleUser(_ cmd: String, _ params: [String: Any]) async throws -> Any? {
        guard let model = MUConnectionController.shared()?.serverModel else {
            throw TestCommandError("Not connected")
        }

        switch cmd {
        case "list":
            guard let root = model.rootChannel() else { return ["users": []] as [String: Any] }
            var users: [[String: Any]] = []
            collectUsers(from: root, into: &users)
            return ["users": users] as [String: Any]

        case "self":
            guard let user = model.connectedUser() else { return nil }
            return serializeUser(user)

        case "registerSelf":
            serverManager?.registerSelf()
            return ["status": "registering"]

        case "info":
            let session = try requireUInt(params["session"], name: "session")
            guard let user = serverManager?.getUserBySession(session) else {
                throw TestCommandError("User with session \(session) not found")
            }
            return serializeUser(user)

        case "setNickname":
            let user = try requireUser(from: params)
            let nickname = (params["nickname"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            serverManager?.setLocalNickname((nickname?.isEmpty == true) ? nil : nickname, for: user)
            return serializeUser(user)

        case "getComment":
            let user = try requireUser(from: params)
            if let comment = user.comment(), !comment.isEmpty {
                return ["session": user.session(), "comment": comment]
            }
            if user.commentHash() != nil {
                let session = user.session()
                let notification = try await awaitNotification(name: ServerModelNotificationManager.userCommentChangedNotification) {
                    MUConnectionController.shared()?.serverModel?.requestComment(for: user)
                }
                let changedSession = uintValue(notification.userInfo?["userSession"])
                guard changedSession == session else {
                    throw TestCommandError("Received comment update for unexpected user")
                }
            }
            return ["session": user.session(), "comment": user.comment() ?? ""]

        case "setSelfComment":
            guard let connectedUser = model.connectedUser() else {
                throw TestCommandError("Not connected")
            }
            let comment = params["comment"] as? String ?? ""
            model.setSelfComment(comment)
            return ["session": connectedUser.session(), "comment": comment]

        case "setAvatar":
            guard let connectedUser = model.connectedUser() else {
                throw TestCommandError("Not connected")
            }
            guard let path = params["path"] as? String, !path.isEmpty else {
                throw TestCommandError("Missing 'path'")
            }
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            serverManager?.setSelfTexture(data)
            return ["session": connectedUser.session(), "path": path]

        case "removeAvatar":
            guard let connectedUser = model.connectedUser() else {
                throw TestCommandError("Not connected")
            }
            serverManager?.removeSelfTexture()
            return ["session": connectedUser.session(), "removed": true]

        case "kick":
            let session = try requireUInt(params["session"], name: "session")
            guard let user = serverManager?.getUserBySession(session) else {
                throw TestCommandError("User with session \(session) not found")
            }
            serverManager?.kickUser(user, reason: params["reason"] as? String)
            return nil

        case "ban":
            let session = try requireUInt(params["session"], name: "session")
            guard let user = serverManager?.getUserBySession(session) else {
                throw TestCommandError("User with session \(session) not found")
            }
            serverManager?.banUser(user, reason: params["reason"] as? String)
            return nil

        case "setVolume":
            let session = try requireUInt(params["session"], name: "session")
            guard let volume = doubleValue(params["volume"]) else {
                throw TestCommandError("Missing 'session' or 'volume'")
            }
            serverManager?.setLocalUserVolume(session: session, volume: Float(volume))
            return nil

        case "setLocalMute":
            let session = try requireUInt(params["session"], name: "session")
            guard let sm = serverManager, let user = sm.getUserBySession(session) else {
                throw TestCommandError("User with session \(session) not found")
            }
            if let muted = boolValue(params["muted"]) {
                if user.isLocalMuted() != muted {
                    sm.toggleLocalUserMute(session: session)
                }
            } else {
                sm.toggleLocalUserMute(session: session)
            }
            return serializeUser(user)

        case "move":
            let session = try requireUInt(params["session"], name: "session")
            let channelId = try requireUInt(params["channelId"], name: "channelId")
            serverManager?.moveUser(session: session, toChannelId: channelId)
            return nil

        case "serverMute":
            let session = try requireUInt(params["session"], name: "session")
            guard let enabled = boolValue(params["enabled"]) else {
                throw TestCommandError("Missing 'enabled'")
            }
            guard let user = serverManager?.getUserBySession(session) else {
                throw TestCommandError("User with session \(session) not found")
            }
            serverManager?.setServerMuted(enabled, for: user)
            return nil

        case "serverDeafen":
            let session = try requireUInt(params["session"], name: "session")
            guard let enabled = boolValue(params["enabled"]) else {
                throw TestCommandError("Missing 'enabled'")
            }
            guard let user = serverManager?.getUserBySession(session) else {
                throw TestCommandError("User with session \(session) not found")
            }
            serverManager?.setServerDeafened(enabled, for: user)
            return nil

        case "prioritySpeaker":
            let user = try requireUser(from: params)
            guard let enabled = boolValue(params["enabled"]) else {
                throw TestCommandError("Missing 'enabled'")
            }
            serverManager?.setPrioritySpeaker(enabled, for: user)
            return nil

        case "stats":
            let session = try requireUInt(params["session"], name: "session")
            guard let user = serverManager?.getUserBySession(session) else {
                throw TestCommandError("User with session \(session) not found")
            }
            let notification = try await awaitNotification(name: ServerModelNotificationManager.userStatsReceivedNotification) { [weak serverManager] in
                serverManager?.requestUserStats(for: user)
            }
            guard let stats = notification.userInfo?["stats"] else {
                throw TestCommandError("User stats payload missing")
            }
            return serializeUserStats(stats, expectedSession: session)

        default:
            throw TestCommandError("Unknown user.\(cmd). Available: list, self, registerSelf, info, setNickname, getComment, setSelfComment, setAvatar, removeAvatar, kick, ban, setVolume, setLocalMute, move, serverMute, serverDeafen, prioritySpeaker, stats")
        }
    }

    // MARK: - Favourite

    private func handleFavourite(_ cmd: String, _ params: [String: Any]) throws -> Any? {
        switch cmd {
        case "list":
            let favs = MUDatabase.fetchAllFavourites() as? [MUFavouriteServer] ?? []
            return favs
                .sorted { ($0.displayName ?? "").localizedCaseInsensitiveCompare($1.displayName ?? "") == .orderedAscending }
                .map { serializeFavourite($0) }

        case "info":
            return serializeFavourite(try requireFavourite(from: params))

        case "add":
            let favourite = try buildFavourite(existing: nil, params: params)
            MUDatabase.storeFavourite(favourite)
            return serializeFavourite(favourite)

        case "update":
            let existing = try requireFavourite(from: params)
            let updated = try buildFavourite(existing: existing, params: params)
            MUDatabase.storeFavourite(updated)
            return serializeFavourite(updated)

        case "remove":
            let fav = try requireFavourite(from: params)
            MUDatabase.deleteFavourite(fav)
            return ["removed": true, "primaryKey": fav.primaryKey]

        case "connect":
            let fav = try requireFavourite(from: params)
            AppState.shared.serverDisplayName = fav.displayName
            MUConnectionController.shared()?.connect(
                toHostname: fav.hostName,
                port: UInt(fav.port),
                withUsername: fav.userName,
                andPassword: fav.password,
                certificateRef: fav.certificateRef,
                displayName: fav.displayName
            )
            return ["status": "connecting", "favourite": serializeFavourite(fav)]

        case "pinWidget":
            let fav = try requireFavourite(from: params)
            let item = WidgetServerItem(
                id: WidgetServerItem.makeId(
                    hostname: fav.hostName ?? "",
                    port: Int(fav.port),
                    username: fav.userName ?? ""
                ),
                displayName: fav.displayName ?? fav.hostName ?? "Unknown",
                hostname: fav.hostName ?? "",
                port: Int(fav.port),
                username: fav.userName ?? "",
                hasCertificate: fav.certificateRef != nil,
                lastConnected: nil
            )
            WidgetDataManager.shared.pinServer(item)
            return ["pinned": true]

        case "unpinWidget":
            let fav = try requireFavourite(from: params)
            let id = WidgetServerItem.makeId(
                hostname: fav.hostName ?? "",
                port: Int(fav.port),
                username: fav.userName ?? ""
            )
            WidgetDataManager.shared.unpinServer(id: id)
            return ["pinned": false]

        default:
            throw TestCommandError("Unknown favourite.\(cmd). Available: list, info, add, update, remove, connect, pinWidget, unpinWidget")
        }
    }

    // MARK: - Settings

    private func handleSettings(_ cmd: String, _ params: [String: Any]) throws -> Any? {
        switch cmd {
        case "get":
            guard let key = params["key"] as? String else {
                throw TestCommandError("Missing 'key'")
            }
            let value = UserDefaults.standard.object(forKey: key)
            return ["key": key, "value": value ?? NSNull()] as [String: Any]

        case "set":
            guard let key = params["key"] as? String else {
                throw TestCommandError("Missing 'key'")
            }
            let value = params["value"]
            let appliedValue = try applySetting(key: key, value: value)
            return ["key": key, "value": appliedValue]

        case "list":
            let prefix = params["prefix"] as? String
            let entries = UserDefaults.standard.dictionaryRepresentation()
                .filter { prefix == nil || $0.key.hasPrefix(prefix!) }
                .sorted { $0.key < $1.key }
                .map { ["key": $0.key, "value": $0.value] as [String: Any] }
            return ["entries": entries]

        default:
            throw TestCommandError("Unknown settings.\(cmd). Available: get, set, list")
        }
    }

    // MARK: - State

    private func handleState(_ cmd: String, _ params: [String: Any]) throws -> Any? {
        switch cmd {
        case "get", "snapshot":
            return buildStateSnapshot()

        default:
            throw TestCommandError("Unknown state.\(cmd). Available: get, snapshot")
        }
    }

    // MARK: - App

    private func handleApp(_ cmd: String, _ params: [String: Any]) throws -> Any? {
        let appState = AppState.shared

        switch cmd {
        case "get":
            return buildAppSnapshot()

        case "setTab":
            guard let tab = params["tab"] as? String else {
                throw TestCommandError("Missing 'tab'")
            }
            switch tab {
            case "channels":
                appState.currentTab = .channels
            case "messages":
                appState.currentTab = .messages
            default:
                throw TestCommandError("Invalid 'tab'. Available: channels, messages")
            }
            return buildAppSnapshot()

        case "setViewMode":
            guard let mode = params["mode"] as? String else {
                throw TestCommandError("Missing 'mode'")
            }
            guard let sm = serverManager else {
                throw TestCommandError("ServerModelManager not available")
            }
            switch mode {
            case "server":
                sm.viewMode = .server
            case "channel":
                sm.viewMode = .channel
            default:
                throw TestCommandError("Invalid 'mode'. Available: server, channel")
            }
            sm.requestModelRebuild(reason: "websocket_set_view_mode", debounce: 0)
            return buildAppSnapshot()

        case "clearError":
            appState.activeError = nil
            return nil

        case "clearToast":
            appState.activeToast = nil
            return nil

        case "dismissCert":
            appState.pendingCertTrust = nil
            return nil

        case "cancelConnection":
            appState.cancelConnection()
            return buildAppSnapshot()

        case "refreshModel":
            serverManager?.requestModelRebuild(reason: "websocket_refresh_model", debounce: 0)
            return buildStateSnapshot()

        default:
            throw TestCommandError("Unknown app.\(cmd). Available: get, setTab, setViewMode, clearError, clearToast, dismissCert, cancelConnection, refreshModel")
        }
    }

    // MARK: - UI

    private func handleUI(_ cmd: String, _ params: [String: Any]) throws -> Any? {
        switch cmd {
        case "get":
            return buildUISnapshot()

        case "open":
            guard let target = params["target"] as? String else {
                throw TestCommandError("Missing 'target'")
            }
            #if os(macOS)
            if target == "preferences" {
                _ = NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                _ = NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
            }
            #endif
            NotificationCenter.default.post(name: .muAutomationOpenUI, object: nil, userInfo: params)
            return ["target": target, "state": buildUISnapshot()]

        case "dismiss":
            NotificationCenter.default.post(name: .muAutomationDismissUI, object: nil, userInfo: params)
            return buildUISnapshot()

        case "back":
            NotificationCenter.default.post(name: .muAutomationNavigate, object: nil, userInfo: ["command": "back"])
            return buildUISnapshot()

        case "root":
            NotificationCenter.default.post(name: .muAutomationNavigate, object: nil, userInfo: ["command": "root"])
            return buildUISnapshot()

        default:
            throw TestCommandError("Unknown ui.\(cmd). Available: get, open, dismiss, back, root")
        }
    }

    // MARK: - Server

    private func handleServer(_ cmd: String, _ params: [String: Any]) async throws -> Any? {
        guard let serverManager else {
            throw TestCommandError("ServerModelManager not available")
        }

        switch cmd {
        case "getBanList":
            let notification = try await awaitNotification(name: ServerModelNotificationManager.banListReceivedNotification) { [weak serverManager] in
                serverManager?.requestBanList()
            }
            return ["entries": parseBanList(notification.userInfo?["banList"])]

        case "setBanList":
            guard let entries = params["entries"] as? [Any] else {
                throw TestCommandError("Missing 'entries'")
            }
            let models = try parseBanEntriesForSubmission(entries)
            serverManager.sendBanList(models.map { $0 as Any })
            return ["count": models.count]

        case "addBan":
            let notification = try await awaitNotification(name: ServerModelNotificationManager.banListReceivedNotification) { [weak serverManager] in
                serverManager?.requestBanList()
            }
            var existing = try parseBanEntriesForSubmission(parseBanList(notification.userInfo?["banList"]))
            existing.append(try parseBanEntryForSubmission(params))
            serverManager.sendBanList(existing.map { $0 as Any })
            return ["count": existing.count]

        case "removeBan":
            let notification = try await awaitNotification(name: ServerModelNotificationManager.banListReceivedNotification) { [weak serverManager] in
                serverManager?.requestBanList()
            }
            var existing = try parseBanEntriesForSubmission(parseBanList(notification.userInfo?["banList"]))
            if let index = intValue(params["index"]), existing.indices.contains(index) {
                existing.remove(at: index)
            } else if let address = params["address"] as? String {
                existing.removeAll { $0.addressString == address }
            } else {
                throw TestCommandError("Missing 'index' or 'address'")
            }
            serverManager.sendBanList(existing.map { $0 as Any })
            return ["count": existing.count]

        case "getRegisteredUsers":
            let notification = try await awaitNotification(name: ServerModelNotificationManager.userListReceivedNotification) { [weak serverManager] in
                serverManager?.requestRegisteredUserList()
            }
            return ["users": parseRegisteredUsers(notification.userInfo?["userList"])]

        default:
            throw TestCommandError("Unknown server.\(cmd). Available: getBanList, setBanList, addBan, removeBan, getRegisteredUsers")
        }
    }

    // MARK: - Certificate

    private func handleCertificate(_ cmd: String, _ params: [String: Any]) throws -> Any? {
        let model = CertificateModel.shared

        switch cmd {
        case "list":
            model.refreshCertificates()
            return [
                "certificates": model.certificates
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                    .map(serializeCertificate)
            ]

        case "generate":
            guard let name = params["name"] as? String, !name.isEmpty else {
                throw TestCommandError("Missing 'name'")
            }
            let email = params["email"] as? String ?? ""
            model.generateNewCertificate(name: name, email: email)
            model.refreshCertificates()
            return [
                "certificates": model.certificates
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                    .map(serializeCertificate)
            ]

        case "delete":
            let item = try requireCertificate(from: params)
            model.deleteCertificate(item)
            return ["deleted": true, "name": item.name]

        case "import":
            guard let path = params["path"] as? String, !path.isEmpty else {
                throw TestCommandError("Missing 'path'")
            }
            let password = params["password"] as? String ?? ""
            let url = URL(fileURLWithPath: path)
            let success = model.importCertificate(from: url, password: password)
            if !success {
                throw TestCommandError(model.importError ?? "Certificate import failed")
            }
            return ["imported": true]

        case "export":
            let item = try requireCertificate(from: params)
            let password = params["password"] as? String ?? ""
            guard let url = model.exportCertificate(item, password: password) else {
                throw TestCommandError("Certificate export failed")
            }
            return ["path": url.path, "name": item.name]

        case "currentSession":
            if let ref = MUConnectionController.shared()?.currentCertificateRef,
               let cert = MUCertificateController.certificate(withPersistentRef: ref) {
                return [
                    "anonymous": false,
                    "name": cert.commonName() ?? "Unknown",
                    "hash": cert.hexDigest() ?? "",
                    "id": ref.base64EncodedString()
                ]
            }
            return [
                "anonymous": true
            ]

        default:
            throw TestCommandError("Unknown certificate.\(cmd). Available: list, generate, delete, import, export, currentSession")
        }
    }

    // MARK: - Log

    private func handleLog(_ cmd: String, _ params: [String: Any], context: MUTestCommandContext?) throws -> Any? {
        let lm = LogManager.shared

        switch cmd {
        case "setLevel":
            let category = try parseCategory(params["category"])
            let level = try parseLevel(params["level"], fieldName: "level")
            lm.setLevel(level, for: category)
            return nil

        case "setEnabled":
            let category = try parseCategory(params["category"])
            guard let enabled = boolValue(params["enabled"]) else {
                throw TestCommandError("Missing 'enabled'")
            }
            lm.setEnabled(enabled, for: category)
            return nil

        case "getConfig":
            var config: [String: Any] = [
                "isEnabled": lm.isEnabled,
                "isFilePersistenceEnabled": lm.isFilePersistenceEnabled
            ]
            var categories: [String: Any] = [:]
            for cat in LogCategory.allCases {
                categories[cat.rawValue] = [
                    "enabled": lm.isEnabled(category: cat),
                    "level": lm.level(for: cat).apiValue
                ]
            }
            config["categories"] = categories
            return config

        case "setGlobalEnabled":
            guard let enabled = boolValue(params["enabled"]) else {
                throw TestCommandError("Missing 'enabled'")
            }
            lm.isEnabled = enabled
            return nil

        case "setFilePersistence":
            guard let enabled = boolValue(params["enabled"]) else {
                throw TestCommandError("Missing 'enabled'")
            }
            lm.isFilePersistenceEnabled = enabled
            return ["isFilePersistenceEnabled": lm.isFilePersistenceEnabled]

        case "recent":
            let limit = intValue(params["limit"]) ?? 200
            let category = try parseOptionalCategory(params["category"])
            let minimumLevel = try parseOptionalLevel(params["minimumLevel"] ?? params["level"])
            return [
                "entries": lm.getRecentEntries(limit: limit, category: category, minimumLevel: minimumLevel)
            ]

        case "clearRecent":
            lm.clearRecentEntries()
            return nil

        case "marker":
            let message = (params["message"] as? String) ?? "websocket-marker"
            let category = try parseOptionalCategory(params["category"]) ?? .general
            let level = try parseOptionalLevel(params["level"]) ?? .info
            lm.log(level, category: category, message: message, file: "MUTestCommandRouter", function: "log.marker", line: 0)
            return nil

        case "stream":
            guard let context else {
                throw TestCommandError("Log stream control requires connection context")
            }
            let enabled = boolValue(params["enabled"]) ?? true
            let minimumLevel = try parseOptionalLevel(params["minimumLevel"] ?? params["level"])
            let categories = stringArrayValue(params["categories"])
            return testServer?.setLogStream(enabled: enabled, minimumLevel: minimumLevel, categories: categories, for: context.connectionID)

        case "streamStatus":
            guard let context else {
                throw TestCommandError("Log stream status requires connection context")
            }
            return testServer?.getLogStreamStatus(for: context.connectionID)

        case "files":
            let files = lm.fileWriter.allLogFileURLs.map { url in
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                return [
                    "path": url.path,
                    "name": url.lastPathComponent,
                    "size": size
                ] as [String: Any]
            }
            return [
                "current": lm.fileWriter.currentLogFileURL?.path as Any? ?? NSNull(),
                "files": files
            ]

        case "export":
            let url = try exportCombinedLogs()
            return [
                "path": url.path,
                "name": url.lastPathComponent
            ]

        case "reset":
            lm.resetToDefaults()
            return nil

        default:
            throw TestCommandError("Unknown log.\(cmd). Available: setLevel, setEnabled, getConfig, setGlobalEnabled, setFilePersistence, recent, clearRecent, marker, stream, streamStatus, files, export, reset")
        }
    }

    // MARK: - Help

    private func handleHelp(_ cmd: String, _ params: [String: Any]) throws -> Any? {
        return [
            "domains": [
                "connection": ["connect", "disconnect", "acceptCert", "rejectCert", "status"],
                "audio": ["mute", "unmute", "deafen", "undeafen", "toggleMute", "toggleDeafen", "startTest", "stopTest", "restart", "forceTransmit", "status"],
                "channel": ["list", "info", "join", "create", "edit", "move", "remove", "listen", "unlisten", "toggleCollapse", "togglePinned", "toggleHidden", "requestACL", "getACL", "setACL", "setAccessTokens", "getAccessTokens", "submitPassword", "scanPermissions", "link", "unlink", "unlinkAll", "current"],
                "message": ["send", "sendTree", "sendPrivate", "sendImage", "sendPrivateImage", "listImages", "exportImage", "previewImage", "history", "markRead"],
                "plugin": ["listTracks", "get", "available", "scanPaths", "addScanPath", "removeScanPath", "buffer", "setBuffer", "add", "remove", "move", "setBypass", "setGain", "load", "unload", "parameters", "setParameter", "presets", "savePreset", "applyPreset", "deletePreset", "setSidechain", "getSidechain"],
                "user": ["list", "self", "registerSelf", "info", "setNickname", "getComment", "setSelfComment", "setAvatar", "removeAvatar", "kick", "ban", "setVolume", "setLocalMute", "move", "serverMute", "serverDeafen", "prioritySpeaker", "stats"],
                "favourite": ["list", "info", "add", "update", "remove", "connect", "pinWidget", "unpinWidget"],
                "settings": ["get", "set", "list"],
                "state": ["get", "snapshot"],
                "app": ["get", "setTab", "setViewMode", "clearError", "clearToast", "dismissCert", "cancelConnection", "refreshModel"],
                "ui": ["get", "open", "dismiss", "back", "root"],
                "server": ["getBanList", "setBanList", "addBan", "removeBan", "getRegisteredUsers"],
                "certificate": ["list", "generate", "delete", "import", "export", "currentSession"],
                "log": ["setLevel", "setEnabled", "getConfig", "setGlobalEnabled", "setFilePersistence", "recent", "clearRecent", "marker", "stream", "streamStatus", "files", "export", "reset"],
                "help": ["actions"]
            ],
            "protocol": [
                "request": "{\"id\": \"optional-uuid\", \"action\": \"domain.command\", \"params\": {...}}",
                "response": "{\"id\": \"...\", \"success\": true/false, \"data\": {...}, \"error\": \"...\"}",
                "event_push": "{\"event\": \"event.name\", \"data\": {...}}"
            ],
            "events": [
                "connection.opened", "connection.closed", "connection.connecting",
                "connection.error", "connection.udpStatus",
                "audio.restarted", "audio.error",
                "app.toast", "message.sendFailed",
                "channel.listeningAdded", "channel.listeningRemoved",
                "log.entry", "ui.changed"
            ]
        ] as [String: Any]
    }

    // MARK: - Helpers

    private func serializeChannel(_ channel: MKChannel) -> [String: Any] {
        var dict: [String: Any] = [
            "id": channel.channelId(),
            "name": channel.channelName() ?? "",
            "position": channel.position(),
            "parentId": channel.parent()?.channelId() ?? 0,
            "description": channel.channelDescription() ?? "",
            "temporary": channel.isTemporary(),
            "maxUsers": channel.maxUsers(),
            "isEnterRestricted": channel.isEnterRestricted(),
            "canEnter": channel.canEnter()
        ]

        if let sm = serverManager {
            dict["isCollapsed"] = sm.collapsedChannelIds.contains(Int(channel.channelId()))
            dict["isPinned"] = sm.isChannelPinned(channel)
            dict["isHidden"] = sm.isChannelHidden(channel)
            dict["isListening"] = sm.listeningChannels.contains(channel.channelId())
            dict["listenerSessions"] = Array(sm.channelListeners[channel.channelId()] ?? []).sorted()
        }

        if let users = channel.users() as? [MKUser] {
            dict["users"] = users.map { serializeUser($0) }
        }

        if let subChannels = channel.channels() as? [MKChannel] {
            dict["channels"] = subChannels.map { serializeChannel($0) }
        }

        return dict
    }

    private func serializeUser(_ user: MKUser) -> [String: Any] {
        let talkState: String = switch user.talkState().rawValue {
        case MKTalkStateTalking.rawValue: "talking"
        case MKTalkStateWhispering.rawValue: "whispering"
        case MKTalkStateShouting.rawValue: "shouting"
        default: "passive"
        }

        return [
            "userId": user.userId(),
            "session": user.session(),
            "name": user.userName() ?? "",
            "displayName": serverManager?.displayName(for: user) ?? user.userName() ?? "",
            "localNickname": serverManager?.localNicknames[user.session()] ?? NSNull(),
            "hashPrefix": String((user.userHash() ?? "").prefix(8)),
            "channelId": user.channel()?.channelId() ?? 0,
            "channelName": user.channel()?.channelName() ?? "",
            "authenticated": user.isAuthenticated(),
            "isFriend": user.isFriend(),
            "muted": user.isMuted(),
            "deafened": user.isDeafened(),
            "localMuted": user.isLocalMuted(),
            "localVolume": user.localVolume,
            "selfMuted": user.isSelfMuted(),
            "selfDeafened": user.isSelfDeafened(),
            "suppressed": user.isSuppressed(),
            "isRecording": user.isRecording(),
            "prioritySpeaker": user.isPrioritySpeaker(),
            "talkState": talkState
        ] as [String: Any]
    }

    private func findChannel(id: UInt, in root: MKChannel?) -> MKChannel? {
        guard let root = root else { return nil }
        if root.channelId() == id { return root }
        if let subChannels = root.channels() as? [MKChannel] {
            for sub in subChannels {
                if let found = findChannel(id: id, in: sub) { return found }
            }
        }
        return nil
    }

    private func collectUsers(from channel: MKChannel, into users: inout [[String: Any]]) {
        if let channelUsers = channel.users() as? [MKUser] {
            users.append(contentsOf: channelUsers.map { serializeUser($0) })
        }
        if let subChannels = channel.channels() as? [MKChannel] {
            for sub in subChannels {
                collectUsers(from: sub, into: &users)
            }
        }
    }

    private func buildStateSnapshot() -> [String: Any] {
        let appState = AppState.shared
        var state: [String: Any] = [
            "isConnected": appState.isConnected,
            "isConnecting": appState.isConnecting,
            "isReconnecting": appState.isReconnecting,
            "reconnectAttempt": appState.reconnectAttempt,
            "reconnectMaxAttempts": appState.reconnectMaxAttempts,
            "reconnectReason": appState.reconnectReason ?? NSNull(),
            "unreadMessageCount": appState.unreadMessageCount,
            "currentTab": appState.currentTab == .channels ? "channels" : "messages",
            "isUserAuthenticated": appState.isUserAuthenticated,
            "activeError": serializeAppError(appState.activeError),
            "activeToast": serializeToast(appState.activeToast),
            "pendingCertTrust": serializePendingCert(appState.pendingCertTrust),
            "ui": buildUISnapshot()
        ]

        if let name = appState.serverDisplayName {
            state["serverDisplayName"] = name
        }

        if let sm = serverManager {
            state["serverName"] = sm.serverName ?? NSNull()
            state["channelCount"] = sm.channelIndexMap.count
            state["messageCount"] = sm.messages.count
            state["modelItemCount"] = sm.modelItems.count
            state["viewMode"] = sm.viewMode == .server ? "server" : "channel"
            state["localAudioTestRunning"] = sm.isLocalAudioTestRunning
            state["collapsedChannelIds"] = Array(sm.collapsedChannelIds).sorted()
            state["listeningChannels"] = Array(sm.listeningChannels).sorted()
        }

        if let ctrl = MUConnectionController.shared(), ctrl.isConnected(), let conn = ctrl.connection {
            state["connectionHostname"] = conn.hostname() ?? ""
            state["connectionPort"] = conn.port()
        }

        if let connectedUser = MUConnectionController.shared()?.serverModel?.connectedUser() {
            state["connectedUser"] = serializeUser(connectedUser)
            if let channel = connectedUser.channel() {
                state["currentChannel"] = serializeChannelSummary(channel)
            }
        }

        return state
    }

    private func buildAppSnapshot() -> [String: Any] {
        let appState = AppState.shared
        return [
            "currentTab": appState.currentTab == .channels ? "channels" : "messages",
            "isInChannelView": appState.isInChannelView,
            "isChannelSplitLayout": appState.isChannelSplitLayout,
            "activeError": serializeAppError(appState.activeError),
            "activeToast": serializeToast(appState.activeToast),
            "pendingCertTrust": serializePendingCert(appState.pendingCertTrust),
            "viewMode": serverManager?.viewMode == .channel ? "channel" : "server",
            "ui": buildUISnapshot()
        ]
    }

    private func buildUISnapshot() -> [String: Any] {
        AppState.shared.automationUISnapshot()
    }

    private func buildPluginTrackSnapshot(trackKey: String) -> [String: Any] {
        let manager = AudioPluginRackManager.shared
        let plugins = manager.plugins(for: trackKey).map { serializeTrackPlugin(trackKey: trackKey, plugin: $0) }
        return [
            "trackKey": trackKey,
            "plugins": plugins,
            "bufferFrames": manager.currentHostBufferFrames()
        ]
    }

    private func serializeDiscoveredPlugin(_ plugin: AudioPluginDiscovery) -> [String: Any] {
        [
            "id": plugin.id,
            "name": plugin.name,
            "subtitle": plugin.subtitle,
            "source": plugin.source.rawValue
        ]
    }

    private func serializeTrackPlugin(trackKey: String, plugin: TrackPlugin) -> [String: Any] {
        let manager = AudioPluginRackManager.shared
        let loadedKey = "\(trackKey):\(plugin.id)"
        let isLoaded = manager.loadedAudioUnits[loadedKey] != nil || manager.loadedVST3Hosts[loadedKey] != nil
        return [
            "id": plugin.id,
            "trackKey": trackKey,
            "name": plugin.name,
            "subtitle": plugin.subtitle,
            "identifier": plugin.identifier,
            "source": plugin.source.rawValue,
            "bypassed": plugin.bypassed,
            "stageGain": plugin.stageGain,
            "autoLoad": plugin.autoLoad,
            "isLoaded": isLoaded,
            "isLoading": manager.loadingPluginIDs.contains(plugin.id),
            "error": manager.lastLoadErrorByPlugin[plugin.id] ?? NSNull(),
            "parameterCount": manager.parameterStateByPlugin[plugin.id]?.count ?? 0,
            "sidechainSource": plugin.sidechainSourceKey ?? "none"
        ]
    }

    private func serializeTrackPlugin(trackKey: String, plugin pluginID: String, from manager: AudioPluginRackManager) -> [String: Any] {
        guard let plugin = manager.plugins(for: trackKey).first(where: { $0.id == pluginID }) else {
            return [
                "id": pluginID,
                "trackKey": trackKey,
                "missing": true
            ]
        }
        return serializeTrackPlugin(trackKey: trackKey, plugin: plugin)
    }

    private func serializePluginParameter(_ parameter: AudioPluginParameterInfo) -> [String: Any] {
        [
            "id": String(parameter.id),
            "name": parameter.name,
            "minValue": parameter.minValue,
            "maxValue": parameter.maxValue,
            "value": parameter.value
        ]
    }

    private func serializePluginPreset(_ preset: AudioPluginPresetInfo) -> [String: Any] {
        [
            "id": preset.id,
            "name": preset.name,
            "createdAt": preset.createdAt.timeIntervalSince1970,
            "parameterCount": preset.parameterValues.count
        ]
    }

    private func messageTypeName(_ type: ChatMessageType) -> String {
        switch type {
        case .userMessage:
            return "userMessage"
        case .notification:
            return "notification"
        case .privateMessage:
            return "privateMessage"
        }
    }

    private func serializeChannelSummary(_ channel: MKChannel) -> [String: Any] {
        [
            "id": channel.channelId(),
            "name": channel.channelName() ?? ""
        ]
    }

    private func serializeAppError(_ error: AppError?) -> Any {
        guard let error else { return NSNull() }
        return [
            "title": error.title,
            "message": error.message
        ] as [String: Any]
    }

    private func serializeToast(_ toast: AppToast?) -> Any {
        guard let toast else { return NSNull() }
        let type: String
        switch toast.type {
        case .info: type = "info"
        case .error: type = "error"
        case .success: type = "success"
        }
        return [
            "message": toast.message,
            "type": type,
            "jumpToMessagesOnTap": toast.jumpToMessagesOnTap,
            "senderName": toast.senderName ?? NSNull(),
            "bodyText": toast.bodyText ?? NSNull(),
            "isSystemMessageBanner": toast.isSystemMessageBanner
        ] as [String: Any]
    }

    private func serializePendingCert(_ cert: CertTrustInfo?) -> Any {
        guard let cert else { return NSNull() }
        return [
            "hostname": cert.hostname,
            "port": cert.port,
            "subjectName": cert.subjectName,
            "issuerName": cert.issuerName,
            "fingerprint": cert.fingerprint,
            "notBefore": cert.notBefore,
            "notAfter": cert.notAfter,
            "isChanged": cert.isChanged
        ] as [String: Any]
    }

    private func serializeAccessControl(_ accessControl: MKAccessControl, channelId: UInt) -> [String: Any] {
        let aclEntries = (accessControl.acls as? [MKChannelACL] ?? []).map { acl in
            [
                "applyHere": acl.applyHere,
                "applySubs": acl.applySubs,
                "inherited": acl.inherited,
                "userId": Int(acl.userID),
                "group": acl.group ?? NSNull(),
                "grant": acl.grant.rawValue,
                "deny": acl.deny.rawValue
            ] as [String: Any]
        }

        let groups = (accessControl.groups as? [MKChannelGroup] ?? []).map { group in
            [
                "name": group.name ?? "",
                "inherited": group.inherited,
                "inherit": group.inherit,
                "inheritable": group.inheritable,
                "members": ((group.members as? [NSNumber]) ?? []).map(\.intValue),
                "excludedMembers": ((group.excludedMembers as? [NSNumber]) ?? []).map(\.intValue),
                "inheritedMembers": ((group.inheritedMembers as? [NSNumber]) ?? []).map(\.intValue)
            ] as [String: Any]
        }

        return [
            "channelId": channelId,
            "inheritACLs": accessControl.inheritACLs,
            "acls": aclEntries,
            "groups": groups
        ]
    }

    private func parseAccessControl(_ params: [String: Any]) throws -> MKAccessControl {
        let accessControl = MKAccessControl()
        accessControl.inheritACLs = boolValue(params["inheritACLs"]) ?? true

        let aclArray = NSMutableArray()
        if let aclEntries = params["acls"] as? [[String: Any]] {
            for entry in aclEntries {
                let acl = MKChannelACL()
                acl.applyHere = boolValue(entry["applyHere"]) ?? true
                acl.applySubs = boolValue(entry["applySubs"]) ?? true
                acl.inherited = boolValue(entry["inherited"]) ?? false
                let userID = intValue(entry["userId"]) ?? -1
                acl.userID = NSInteger(userID)
                if userID < 0 {
                    acl.group = entry["group"] as? String
                } else {
                    acl.group = nil
                }
                acl.grant = MKPermission(rawValue: UInt32(max(0, intValue(entry["grant"]) ?? 0)))
                acl.deny = MKPermission(rawValue: UInt32(max(0, intValue(entry["deny"]) ?? 0)))
                aclArray.add(acl)
            }
        }
        accessControl.acls = aclArray

        let groupArray = NSMutableArray()
        if let groups = params["groups"] as? [[String: Any]] {
            for entry in groups {
                let group = MKChannelGroup()
                group.name = entry["name"] as? String ?? ""
                group.inherited = boolValue(entry["inherited"]) ?? false
                group.inherit = boolValue(entry["inherit"]) ?? true
                group.inheritable = boolValue(entry["inheritable"]) ?? true
                group.members = NSMutableArray(array: intArrayValue(entry["members"]).map { NSNumber(value: $0) })
                group.excludedMembers = NSMutableArray(array: intArrayValue(entry["excludedMembers"]).map { NSNumber(value: $0) })
                group.inheritedMembers = NSMutableArray(array: intArrayValue(entry["inheritedMembers"]).map { NSNumber(value: $0) })
                groupArray.add(group)
            }
        }
        accessControl.groups = groupArray

        return accessControl
    }

    private func serializeFavourite(_ favourite: MUFavouriteServer) -> [String: Any] {
        let certificateRef = favourite.certificateRef
        let certificateName: String? = {
            guard let certificateRef,
                  let cert = MUCertificateController.certificate(withPersistentRef: certificateRef) else {
                return nil
            }
            return cert.commonName()
        }()

        return [
            "primaryKey": favourite.primaryKey,
            "displayName": favourite.displayName ?? "",
            "hostName": favourite.hostName ?? "",
            "port": favourite.port,
            "userName": favourite.userName ?? "",
            "hasPassword": !(favourite.password ?? "").isEmpty,
            "certificateRefBase64": certificateRef?.base64EncodedString() ?? NSNull(),
            "certificateName": certificateName ?? NSNull(),
            "isPinnedToWidget": WidgetDataManager.shared.isPinned(
                hostname: favourite.hostName ?? "",
                port: Int(favourite.port),
                username: favourite.userName ?? ""
            )
        ]
    }

    private func buildFavourite(existing: MUFavouriteServer?, params: [String: Any]) throws -> MUFavouriteServer {
        guard let source = existing ?? MUFavouriteServer() else {
            throw TestCommandError("Unable to allocate favourite model")
        }
        let favourite = (source.copy() as? MUFavouriteServer) ?? source

        let existingHost = favourite.hostName ?? ""
        let existingDisplayName = favourite.displayName ?? ""
        let existingUser = favourite.userName ?? ""

        let hostName = (params["hostname"] as? String)
            ?? (params["hostName"] as? String)
            ?? existingHost
        if hostName.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty {
            throw TestCommandError("Missing 'hostname'")
        }

        let port = uintValue(params["port"]) ?? favourite.port
        let userName = (params["username"] as? String) ?? (params["userName"] as? String) ?? existingUser
        let password = (params["password"] as? String) ?? (existing?.password ?? "")
        let displayName = (params["displayName"] as? String)
            ?? (existingDisplayName.isEmpty ? hostName : existingDisplayName)

        favourite.hostName = hostName
        favourite.port = port == 0 ? 64738 : port
        favourite.userName = userName.isEmpty ? nil : userName
        favourite.password = password.isEmpty ? nil : password
        favourite.displayName = displayName.isEmpty ? hostName : displayName

        if let certificateBase64 = params["certificateRefBase64"] as? String {
            favourite.certificateRef = Data(base64Encoded: certificateBase64)
                .flatMap { MUCertificateController.normalizedIdentityPersistentRef(forPersistentRef: $0) ?? $0 }
        } else if boolValue(params["clearCertificate"]) == true {
            favourite.certificateRef = nil
        }

        if favourite.certificateRef == nil,
           let user = favourite.userName,
           let host = favourite.hostName {
            CertificateModel.shared.refreshCertificates()
            favourite.certificateRef = CertificateModel.shared.findCertificateReference(name: "\(user)@\(host)")
        }

        return favourite
    }

    private func requireFavourite(from params: [String: Any]) throws -> MUFavouriteServer {
        let favourites = MUDatabase.fetchAllFavourites() as? [MUFavouriteServer] ?? []

        if let primaryKey = intValue(params["primaryKey"]),
           let favourite = favourites.first(where: { $0.primaryKey == primaryKey }) {
            return favourite
        }

        if let hostname = (params["hostname"] as? String) ?? (params["hostName"] as? String) {
            let port = uintValue(params["port"]) ?? 64738
            let username = (params["username"] as? String) ?? (params["userName"] as? String)
            if let favourite = favourites.first(where: {
                $0.hostName == hostname
                && $0.port == port
                && (username == nil || $0.userName == username)
            }) {
                return favourite
            }
            throw TestCommandError("Favourite not found: \(hostname):\(port)")
        }

        throw TestCommandError("Missing favourite selector. Provide 'primaryKey' or ('hostname' and optional 'port'/'username')")
    }

    private func requireUser(from params: [String: Any]) throws -> MKUser {
        let session = try requireUInt(params["session"], name: "session")
        guard let user = serverManager?.getUserBySession(session) else {
            throw TestCommandError("User with session \(session) not found")
        }
        return user
    }

    private func requireCertificate(from params: [String: Any]) throws -> CertificateItem {
        CertificateModel.shared.refreshCertificates()
        let certificates = CertificateModel.shared.certificates

        if let id = params["id"] as? String,
           let ref = Data(base64Encoded: id),
           let item = certificates.first(where: { $0.id == ref }) {
            return item
        }

        if let name = params["name"] as? String,
           let item = certificates.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return item
        }

        throw TestCommandError("Certificate not found. Provide 'id' or 'name'")
    }

    private func serializeCertificate(_ item: CertificateItem) -> [String: Any] {
        [
            "id": item.id.base64EncodedString(),
            "name": item.name,
            "hash": item.hash,
            "expiry": item.expiry?.timeIntervalSince1970 ?? NSNull()
        ]
    }

    private func applySetting(key: String, value: Any?) throws -> Any {
        switch key {
        case AppLanguageManager.storageKey:
            guard let raw = value as? String else {
                throw TestCommandError("Setting '\(key)' requires a string value")
            }
            AppLanguageManager.shared.setLanguage(rawValue: raw)
            return AppLanguageManager.shared.selectedRawValue

        default:
            UserDefaults.standard.set(value, forKey: key)

            if key == "ShowHiddenChannels" {
                NotificationCenter.default.post(name: ServerModelNotificationManager.rebuildModelNotification, object: nil)
            }

            if key.hasPrefix("Audio") {
                PreferencesModel.shared.notifySettingsChanged()
            }

            return UserDefaults.standard.object(forKey: key) ?? NSNull()
        }
    }

    private func awaitNotification(name: Notification.Name,
                                   timeout: TimeInterval = 5.0,
                                   trigger: @escaping @MainActor () -> Void) async throws -> NotificationSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            let center = NotificationCenter.default
            final class WaitState: @unchecked Sendable {
                var observer: NSObjectProtocol?
                var timeoutTimer: Timer?
                var finished = false
            }
            let state = WaitState()

            let finish: @Sendable (NotificationSnapshot?, String?) -> Void = { snapshot, errorMessage in
                guard !state.finished else { return }
                state.finished = true
                if let observer = state.observer {
                    center.removeObserver(observer)
                }
                state.timeoutTimer?.invalidate()

                if let snapshot {
                    continuation.resume(returning: snapshot)
                } else {
                    continuation.resume(throwing: TestCommandError(errorMessage ?? "Timed out waiting for \(name.rawValue)"))
                }
            }

            state.observer = center.addObserver(forName: name, object: nil, queue: .main) { notification in
                let snapshot = NotificationSnapshot(name: notification.name, userInfo: notification.userInfo)
                finish(snapshot, nil)
            }

            state.timeoutTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { _ in
                finish(nil, "Timed out waiting for \(name.rawValue)")
            }

            trigger()
        }
    }

    private func parseBanList(_ raw: Any?) -> [[String: Any]] {
        guard let list = raw as? NSObject else { return [] }
        let bansSelector = NSSelectorFromString("bans")
        guard list.responds(to: bansSelector),
              let bansArray = list.perform(bansSelector)?.takeUnretainedValue() else {
            return []
        }

        let countSelector = NSSelectorFromString("count")
        guard let countObject = (bansArray as AnyObject).perform(countSelector) else { return [] }
        let count = Int(bitPattern: countObject.toOpaque())
        let objectAtIndexSelector = NSSelectorFromString("objectAtIndex:")

        var entries: [[String: Any]] = []
        for index in 0..<count {
            guard let entryObject = (bansArray as AnyObject).perform(objectAtIndexSelector, with: index as AnyObject)?.takeUnretainedValue() as? NSObject else {
                continue
            }

            let address = (entryObject.value(forKey: "address") as? Data) ?? Data()
            let mask = (entryObject.value(forKey: "mask") as? NSNumber)?.uint32Value ?? 0
            let username = (entryObject.value(forKey: "name") as? String) ?? ""
            let certHash = (entryObject.value(forKey: "certHash") as? String) ?? ""
            let reason = (entryObject.value(forKey: "reason") as? String) ?? ""
            let start = (entryObject.value(forKey: "start") as? String) ?? ""
            let duration = (entryObject.value(forKey: "duration") as? NSNumber)?.uint32Value ?? 0

            let model = BanEntryModel(
                addressData: address,
                mask: mask,
                username: username,
                certHash: certHash,
                reason: reason,
                start: start,
                duration: duration
            )

            entries.append([
                "address": model.addressString,
                "mask": model.mask,
                "username": model.username,
                "certHash": model.certHash,
                "reason": model.reason,
                "start": model.start,
                "duration": model.duration
            ])
        }

        return entries
    }

    private func parseBanEntriesForSubmission(_ entries: [Any]) throws -> [BanEntryModel] {
        try entries.map { raw in
            if let model = raw as? BanEntryModel {
                return model
            }
            if let dict = raw as? [String: Any] {
                return try parseBanEntryForSubmission(dict)
            }
            throw TestCommandError("Invalid ban entry payload")
        }
    }

    private func parseBanEntryForSubmission(_ params: [String: Any]) throws -> BanEntryModel {
        guard let addressString = params["address"] as? String,
              let addressData = parseIPAddressData(addressString) else {
            throw TestCommandError("Missing or invalid ban 'address'")
        }

        let defaultMask = addressData.count == 4 ? 32 : 128
        let mask = UInt32(max(0, intValue(params["mask"]) ?? defaultMask))

        return BanEntryModel(
            addressData: addressData,
            mask: mask,
            username: params["username"] as? String ?? "",
            certHash: params["certHash"] as? String ?? "",
            reason: params["reason"] as? String ?? "",
            start: params["start"] as? String ?? "",
            duration: UInt32(max(0, intValue(params["duration"]) ?? 0))
        )
    }

    private func parseIPAddressData(_ raw: String) -> Data? {
        if let address = IPv4Address(raw) {
            return Data(address.rawValue)
        }
        if let address = IPv6Address(raw) {
            return Data(address.rawValue)
        }
        return nil
    }

    private func parseRegisteredUsers(_ raw: Any?) -> [[String: Any]] {
        guard let raw else { return [] }

        if let entries = raw as? [[String: Any]] {
            return entries.compactMap { entry in
                guard let userId = uintValue(entry["userId"]) else { return nil }
                return [
                    "userId": userId,
                    "name": (entry["name"] as? String) ?? "User #\(userId)"
                ]
            }
        }

        if let entries = raw as? [NSDictionary] {
            return entries.compactMap { entry in
                guard let userId = uintValue(entry["userId"]) else { return nil }
                return [
                    "userId": userId,
                    "name": (entry["name"] as? String) ?? "User #\(userId)"
                ]
            }
        }

        if let entries = raw as? NSArray {
            return entries.compactMap { entry in
                if let dict = entry as? [String: Any], let userId = uintValue(dict["userId"]) {
                    return [
                        "userId": userId,
                        "name": (dict["name"] as? String) ?? "User #\(userId)"
                    ]
                }
                if let obj = entry as? NSObject, let userId = uintValue(obj.value(forKey: "userId")) {
                    return [
                        "userId": userId,
                        "name": (obj.value(forKey: "name") as? String) ?? "User #\(userId)"
                    ]
                }
                return nil
            }
        }

        return []
    }

    private func serializeUserStats(_ raw: Any, expectedSession: UInt) -> [String: Any] {
        guard let stats = raw as? NSObject else {
            return [:]
        }

        var result: [String: Any] = ["session": expectedSession]
        if let session = uintValue(stats.value(forKey: "session")) {
            result["session"] = session
        }
        if let version = stats.value(forKey: "version") as? NSObject {
            result["release"] = (version.value(forKey: "release") as? String) ?? ""
            result["os"] = (version.value(forKey: "os") as? String) ?? ""
            result["osVersion"] = (version.value(forKey: "osVersion") as? String) ?? ""
        }
        if let value = uintValue(stats.value(forKey: "onlinesecs")) { result["onlineSeconds"] = value }
        if let value = uintValue(stats.value(forKey: "idlesecs")) { result["idleSeconds"] = value }
        if let value = uintValue(stats.value(forKey: "bandwidth")) { result["bandwidth"] = value }
        if let value = uintValue(stats.value(forKey: "tcpPackets")) { result["tcpPackets"] = value }
        if let value = uintValue(stats.value(forKey: "udpPackets")) { result["udpPackets"] = value }
        if let value = floatValue(stats.value(forKey: "tcpPingAvg")) { result["tcpPingAvg"] = value }
        if let value = floatValue(stats.value(forKey: "tcpPingVar")) { result["tcpPingVar"] = value }
        if let value = floatValue(stats.value(forKey: "udpPingAvg")) { result["udpPingAvg"] = value }
        if let value = floatValue(stats.value(forKey: "udpPingVar")) { result["udpPingVar"] = value }
        if let value = boolValue(stats.value(forKey: "opus")) { result["opus"] = value }
        if let value = boolValue(stats.value(forKey: "strongCertificate")) { result["strongCertificate"] = value }
        return result
    }

    private func parseCategory(_ value: Any?) throws -> LogCategory {
        guard let category = try parseOptionalCategory(value) else {
            throw TestCommandError("Missing or invalid 'category'. Available: \(LogCategory.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        return category
    }

    private func parseOptionalCategory(_ value: Any?) throws -> LogCategory? {
        guard let raw = value as? String else { return nil }
        if let category = LogCategory(rawValue: raw) ?? LogCategory.allCases.first(where: { $0.rawValue.lowercased() == raw.lowercased() }) {
            return category
        }
        throw TestCommandError("Invalid 'category'. Available: \(LogCategory.allCases.map(\.rawValue).joined(separator: ", "))")
    }

    private func parseLevel(_ value: Any?, fieldName: String) throws -> LogLevel {
        guard let level = try parseOptionalLevel(value) else {
            throw TestCommandError("Missing or invalid '\(fieldName)'. Available: verbose, debug, info, warning, error")
        }
        return level
    }

    private func parseOptionalLevel(_ value: Any?) throws -> LogLevel? {
        guard let raw = value as? String else { return nil }
        if let level = LogLevel.allCases.first(where: { $0.apiValue == raw.lowercased() }) {
            return level
        }
        throw TestCommandError("Invalid 'level'. Available: verbose, debug, info, warning, error")
    }

    private func requireUInt(_ value: Any?, name: String) throws -> UInt {
        guard let parsed = uintValue(value) else {
            throw TestCommandError("Missing '\(name)'")
        }
        return parsed
    }

    private func requireUInt64(_ value: Any?, name: String) throws -> UInt64 {
        switch value {
        case let v as UInt64:
            return v
        case let v as UInt:
            return UInt64(v)
        case let v as Int where v >= 0:
            return UInt64(v)
        case let v as NSNumber:
            return v.uint64Value
        case let v as String:
            if let parsed = UInt64(v) { return parsed }
        default:
            break
        }
        throw TestCommandError("Missing '\(name)'")
    }

    private func requireInt(_ value: Any?, name: String) throws -> Int {
        guard let parsed = intValue(value) else {
            throw TestCommandError("Missing '\(name)'")
        }
        return parsed
    }

    private func requirePluginTrackKey(_ params: [String: Any]) throws -> String {
        if let trackKey = params["trackKey"] as? String, !trackKey.isEmpty {
            return trackKey
        }
        if let userHash = params["userHash"] as? String, !userHash.isEmpty {
            return "remoteUser:\(userHash)"
        }
        throw TestCommandError("Missing 'trackKey' or 'userHash'")
    }

    private func requireTrackPlugin(_ params: [String: Any]) throws -> (trackKey: String, plugin: TrackPlugin) {
        let manager = AudioPluginRackManager.shared
        let trackKey = try requirePluginTrackKey(params)
        let plugins = manager.plugins(for: trackKey)

        if let pluginID = params["pluginID"] as? String,
           let plugin = plugins.first(where: { $0.id == pluginID }) {
            return (trackKey, plugin)
        }
        if let index = intValue(params["index"]), plugins.indices.contains(index) {
            return (trackKey, plugins[index])
        }
        throw TestCommandError("Missing plugin selector. Provide 'pluginID' or valid 'index'")
    }

    private func requireDiscoveredPlugin(_ params: [String: Any]) throws -> AudioPluginDiscovery {
        let manager = AudioPluginRackManager.shared
        if let identifier = params["identifier"] as? String,
           let plugin = manager.availablePlugins().first(where: { $0.id == identifier }) {
            return plugin
        }

        guard let identifier = params["identifier"] as? String,
              let name = params["name"] as? String,
              let sourceRaw = params["source"] as? String,
              let source = PluginSource(rawValue: sourceRaw) else {
            throw TestCommandError("Missing plugin selector. Provide 'identifier' from plugin.available, or explicit 'identifier' + 'name' + 'source'")
        }
        return AudioPluginDiscovery(
            id: identifier,
            name: name,
            subtitle: params["subtitle"] as? String ?? "",
            source: source,
            categorySeedText: params["categorySeedText"] as? String ?? name
        )
    }

    private func loadPlatformImage(from params: [String: Any]) throws -> PlatformImage {
        if let path = params["path"] as? String, !path.isEmpty {
            let url = URL(fileURLWithPath: path)
            guard let data = try? Data(contentsOf: url),
                  let image = PlatformImage(data: data) else {
                throw TestCommandError("Unable to load image from path")
            }
            return image
        }
        if let base64 = params["base64"] as? String, !base64.isEmpty,
           let data = Data(base64Encoded: base64),
           let image = PlatformImage(data: data) {
            return image
        }
        throw TestCommandError("Missing image payload. Provide 'path' or 'base64'")
    }

    private func encodePlatformImage(_ image: PlatformImage) throws -> Data {
        if let data = image.jpegData(compressionQuality: 0.95) {
            return data
        }
        throw TestCommandError("Unable to encode image")
    }

    private func requireMessageImage(_ params: [String: Any], messages: [ChatMessage]) throws -> (ChatMessage, Int) {
        let message: ChatMessage
        if let id = params["messageID"] as? String,
           let found = messages.first(where: { $0.id.uuidString == id }) {
            message = found
        } else if let index = intValue(params["messageIndex"]), messages.indices.contains(index) {
            message = messages[index]
        } else {
            throw TestCommandError("Missing message selector. Provide 'messageID' or valid 'messageIndex'")
        }

        guard !message.images.isEmpty else {
            throw TestCommandError("Selected message has no images")
        }

        let imageIndex = intValue(params["imageIndex"]) ?? 0
        guard message.images.indices.contains(imageIndex) else {
            throw TestCommandError("Invalid 'imageIndex'")
        }
        return (message, imageIndex)
    }

    private func exportCombinedLogs() throws -> URL {
        let files = LogManager.shared.fileWriter.allLogFileURLs
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mumble-logs-\(UUID().uuidString).log")
        var combined = Data()
        for file in files {
            if let data = try? Data(contentsOf: file) {
                combined.append("=== \(file.lastPathComponent) ===\n".data(using: .utf8)!)
                combined.append(data)
                combined.append("\n\n".data(using: .utf8)!)
            }
        }
        try combined.write(to: url, options: .atomic)
        return url
    }

    private func uintValue(_ value: Any?) -> UInt? {
        switch value {
        case let v as UInt:
            return v
        case let v as Int where v >= 0:
            return UInt(v)
        case let v as NSNumber:
            return v.uintValue
        case let v as String:
            return UInt(v)
        default:
            return nil
        }
    }

    private func intValue(_ value: Any?) -> Int? {
        switch value {
        case let v as Int:
            return v
        case let v as UInt:
            return Int(v)
        case let v as NSNumber:
            return v.intValue
        case let v as String:
            return Int(v)
        default:
            return nil
        }
    }

    private func doubleValue(_ value: Any?) -> Double? {
        switch value {
        case let v as Double:
            return v
        case let v as Float:
            return Double(v)
        case let v as NSNumber:
            return v.doubleValue
        case let v as String:
            return Double(v)
        default:
            return nil
        }
    }

    private func floatValue(_ value: Any?) -> Float? {
        switch value {
        case let v as Float:
            return v
        case let v as Double:
            return Float(v)
        case let v as NSNumber:
            return v.floatValue
        case let v as String:
            return Float(v)
        default:
            return nil
        }
    }

    private func boolValue(_ value: Any?) -> Bool? {
        switch value {
        case let v as Bool:
            return v
        case let v as NSNumber:
            return v.boolValue
        case let v as String:
            switch v.lowercased() {
            case "true", "1", "yes", "on":
                return true
            case "false", "0", "no", "off":
                return false
            default:
                return nil
            }
        default:
            return nil
        }
    }

    private func stringArrayValue(_ value: Any?) -> [String]? {
        if let strings = value as? [String] {
            return strings
        }
        if let values = value as? [Any] {
            return values.compactMap { $0 as? String }
        }
        return nil
    }

    private func intArrayValue(_ value: Any?) -> [Int] {
        if let values = value as? [Int] {
            return values
        }
        if let values = value as? [NSNumber] {
            return values.map(\.intValue)
        }
        if let values = value as? [Any] {
            return values.compactMap { intValue($0) }
        }
        return []
    }
}

#endif
