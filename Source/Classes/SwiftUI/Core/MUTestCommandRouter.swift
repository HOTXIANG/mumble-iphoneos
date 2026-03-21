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

// MARK: - Error Type

struct TestCommandError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { self.errorDescription = message }
}

// MARK: - Command Router

@MainActor
final class MUTestCommandRouter {
    weak var serverManager: ServerModelManager?

    func handle(action: String, params: [String: Any]) async throws -> Any? {
        let parts = action.split(separator: ".", maxSplits: 1)
        guard parts.count == 2 else {
            throw TestCommandError("Invalid action format '\(action)'. Use 'domain.command'")
        }

        let domain = String(parts[0])
        let command = String(parts[1])

        switch domain {
        case "connection": return try handleConnection(command, params)
        case "audio":      return try handleAudio(command, params)
        case "channel":    return try handleChannel(command, params)
        case "message":    return try handleMessage(command, params)
        case "user":       return try handleUser(command, params)
        case "favourite":  return try handleFavourite(command, params)
        case "settings":   return try handleSettings(command, params)
        case "state":      return try handleState(command, params)
        case "log":        return try handleLog(command, params)
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
            let port = params["port"] as? Int ?? 64738
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

        case "status":
            let connected = ctrl?.isConnected() ?? false
            var data: [String: Any] = [
                "connected": connected,
                "isConnecting": AppState.shared.isConnecting,
                "isReconnecting": AppState.shared.isReconnecting
            ]
            if connected, let conn = ctrl?.connection {
                data["hostname"] = conn.hostname() ?? ""
                data["port"] = conn.port()
                data["serverName"] = serverManager?.serverName ?? ""
            }
            return data

        default:
            throw TestCommandError("Unknown connection.\(cmd). Available: connect, disconnect, status")
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

        case "restart":
            guard MUConnectionController.shared()?.isConnected() == true else {
                throw TestCommandError("Not connected — audio engine not active")
            }
            MKAudio.shared()?.restart()
            return nil

        case "status":
            // Only access MKAudio when connected to avoid blocking main thread
            let connected = MUConnectionController.shared()?.isConnected() == true
            if connected {
                let connUser = MUConnectionController.shared()?.serverModel?.connectedUser()
                return [
                    "running": MKAudio.shared()?.isRunning ?? false,
                    "selfMuted": connUser?.isSelfMuted() ?? false,
                    "selfDeafened": connUser?.isSelfDeafened() ?? false
                ] as [String: Any]
            } else {
                return [
                    "running": false,
                    "selfMuted": false,
                    "selfDeafened": false,
                    "note": "Not connected — audio engine not initialized"
                ] as [String: Any]
            }

        default:
            throw TestCommandError("Unknown audio.\(cmd). Available: mute, unmute, deafen, undeafen, restart, status")
        }
    }

    // MARK: - Channel

    private func handleChannel(_ cmd: String, _ params: [String: Any]) throws -> Any? {
        guard let model = MUConnectionController.shared()?.serverModel else {
            throw TestCommandError("Not connected")
        }

        switch cmd {
        case "list":
            guard let root = model.rootChannel() else { return [] }
            return serializeChannel(root)

        case "join":
            guard let channelId = params["channelId"] as? UInt else {
                throw TestCommandError("Missing 'channelId'")
            }
            guard let channel = findChannel(id: channelId, in: model.rootChannel()) else {
                throw TestCommandError("Channel \(channelId) not found")
            }
            model.join(channel)
            return nil

        case "create":
            guard let parentId = params["parentId"] as? UInt,
                  let name = params["name"] as? String else {
                throw TestCommandError("Missing 'parentId' or 'name'")
            }
            let temporary = params["temporary"] as? Bool ?? false
            guard let parent = findChannel(id: parentId, in: model.rootChannel()) else {
                throw TestCommandError("Parent channel \(parentId) not found")
            }
            serverManager?.createChannel(name: name, parent: parent, temporary: temporary)
            return nil

        case "remove":
            guard let channelId = params["channelId"] as? UInt else {
                throw TestCommandError("Missing 'channelId'")
            }
            guard let channel = findChannel(id: channelId, in: model.rootChannel()) else {
                throw TestCommandError("Channel \(channelId) not found")
            }
            serverManager?.removeChannel(channel)
            return nil

        case "current":
            let connUser = model.connectedUser()
            let ch = connUser?.channel()
            return [
                "channelId": ch?.channelId() ?? 0,
                "channelName": ch?.channelName() ?? ""
            ] as [String: Any]

        default:
            throw TestCommandError("Unknown channel.\(cmd). Available: list, join, create, remove, current")
        }
    }

    // MARK: - Message

    private func handleMessage(_ cmd: String, _ params: [String: Any]) throws -> Any? {
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
            guard let text = params["text"] as? String,
                  let session = params["session"] as? UInt else {
                throw TestCommandError("Missing 'text' or 'session'")
            }
            guard let user = sm.getUserBySession(session) else {
                throw TestCommandError("User with session \(session) not found")
            }
            sm.sendPrivateMessage(text, to: user)
            return nil

        case "history":
            let limit = params["limit"] as? Int ?? 50
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

        default:
            throw TestCommandError("Unknown message.\(cmd). Available: send, sendTree, sendPrivate, history")
        }
    }

    // MARK: - User

    private func handleUser(_ cmd: String, _ params: [String: Any]) throws -> Any? {
        guard let model = MUConnectionController.shared()?.serverModel else {
            throw TestCommandError("Not connected")
        }

        switch cmd {
        case "list":
            guard let root = model.rootChannel() else { return [] }
            var users: [[String: Any]] = []
            collectUsers(from: root, into: &users)
            return users

        case "self":
            guard let user = model.connectedUser() else { return nil }
            return serializeUser(user)

        case "info":
            guard let session = params["session"] as? UInt else {
                throw TestCommandError("Missing 'session'")
            }
            guard let user = serverManager?.getUserBySession(session) else {
                throw TestCommandError("User with session \(session) not found")
            }
            return serializeUser(user)

        case "kick":
            guard let session = params["session"] as? UInt else {
                throw TestCommandError("Missing 'session'")
            }
            guard let user = serverManager?.getUserBySession(session) else {
                throw TestCommandError("User with session \(session) not found")
            }
            serverManager?.kickUser(user, reason: params["reason"] as? String)
            return nil

        case "ban":
            guard let session = params["session"] as? UInt else {
                throw TestCommandError("Missing 'session'")
            }
            guard let user = serverManager?.getUserBySession(session) else {
                throw TestCommandError("User with session \(session) not found")
            }
            serverManager?.banUser(user, reason: params["reason"] as? String)
            return nil

        case "setVolume":
            guard let session = params["session"] as? UInt,
                  let volume = params["volume"] as? Double else {
                throw TestCommandError("Missing 'session' or 'volume'")
            }
            serverManager?.setLocalUserVolume(session: session, volume: Float(volume))
            return nil

        default:
            throw TestCommandError("Unknown user.\(cmd). Available: list, self, info, kick, ban, setVolume")
        }
    }

    // MARK: - Favourite

    private func handleFavourite(_ cmd: String, _ params: [String: Any]) throws -> Any? {
        switch cmd {
        case "list":
            let favs = MUDatabase.fetchAllFavourites() as? [MUFavouriteServer] ?? []
            return favs.map { fav -> [String: Any] in
                [
                    "displayName": fav.displayName ?? "",
                    "hostName": fav.hostName ?? "",
                    "port": fav.port,
                    "userName": fav.userName ?? ""
                ]
            }

        case "add":
            guard let hostname = params["hostname"] as? String else {
                throw TestCommandError("Missing 'hostname'")
            }
            guard let fav = MUFavouriteServer() else {
                throw TestCommandError("Failed to create MUFavouriteServer")
            }
            fav.displayName = params["displayName"] as? String ?? hostname
            fav.hostName = hostname
            fav.port = params["port"] as? UInt ?? 64738
            fav.userName = params["username"] as? String ?? "MumbleUser"
            fav.password = params["password"] as? String ?? ""
            MUDatabase.storeFavourite(fav)
            return nil

        case "remove":
            guard let hostname = params["hostname"] as? String else {
                throw TestCommandError("Missing 'hostname'")
            }
            let port = params["port"] as? UInt ?? 64738
            let favs = MUDatabase.fetchAllFavourites() as? [MUFavouriteServer] ?? []
            guard let fav = favs.first(where: { $0.hostName == hostname && $0.port == port }) else {
                throw TestCommandError("Favourite not found: \(hostname):\(port)")
            }
            MUDatabase.deleteFavourite(fav)
            return nil

        default:
            throw TestCommandError("Unknown favourite.\(cmd). Available: list, add, remove")
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
            UserDefaults.standard.set(params["value"], forKey: key)
            return nil

        default:
            throw TestCommandError("Unknown settings.\(cmd). Available: get, set")
        }
    }

    // MARK: - State

    private func handleState(_ cmd: String, _ params: [String: Any]) throws -> Any? {
        switch cmd {
        case "get":
            let appState = AppState.shared
            var state: [String: Any] = [
                "isConnected": appState.isConnected,
                "isConnecting": appState.isConnecting,
                "isReconnecting": appState.isReconnecting,
                "unreadMessageCount": appState.unreadMessageCount,
                "currentTab": appState.currentTab == .channels ? "channels" : "messages",
                "isUserAuthenticated": appState.isUserAuthenticated
            ]

            if let name = appState.serverDisplayName {
                state["serverDisplayName"] = name
            }

            if let sm = serverManager {
                state["serverName"] = sm.serverName ?? NSNull()
                state["channelCount"] = sm.modelItems.count
                state["messageCount"] = sm.messages.count
            }

            if let ctrl = MUConnectionController.shared(), ctrl.isConnected() {
                if let conn = ctrl.connection {
                    state["connectionHostname"] = conn.hostname() ?? ""
                    state["connectionPort"] = conn.port()
                }
            }

            return state

        default:
            throw TestCommandError("Unknown state.\(cmd). Available: get")
        }
    }

    // MARK: - Log

    private func handleLog(_ cmd: String, _ params: [String: Any]) throws -> Any? {
        let lm = LogManager.shared

        switch cmd {
        case "setLevel":
            guard let categoryStr = params["category"] as? String,
                  let category = LogCategory(rawValue: categoryStr) else {
                throw TestCommandError("Missing or invalid 'category'. Available: \(LogCategory.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            guard let levelStr = params["level"] as? String,
                  let level = LogLevel.allCases.first(where: { "\($0)" == levelStr }) else {
                throw TestCommandError("Missing or invalid 'level'. Available: verbose, debug, info, warning, error")
            }
            lm.setLevel(level, for: category)
            return nil

        case "setEnabled":
            guard let categoryStr = params["category"] as? String,
                  let category = LogCategory(rawValue: categoryStr) else {
                throw TestCommandError("Missing or invalid 'category'")
            }
            guard let enabled = params["enabled"] as? Bool else {
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
                    "level": "\(lm.level(for: cat))"
                ]
            }
            config["categories"] = categories
            return config

        case "setGlobalEnabled":
            guard let enabled = params["enabled"] as? Bool else {
                throw TestCommandError("Missing 'enabled'")
            }
            lm.isEnabled = enabled
            return nil

        case "reset":
            lm.resetToDefaults()
            return nil

        default:
            throw TestCommandError("Unknown log.\(cmd). Available: setLevel, setEnabled, getConfig, setGlobalEnabled, reset")
        }
    }

    // MARK: - Help

    private func handleHelp(_ cmd: String, _ params: [String: Any]) throws -> Any? {
        return [
            "domains": [
                "connection": ["connect", "disconnect", "status"],
                "audio": ["mute", "unmute", "deafen", "undeafen", "restart", "status"],
                "channel": ["list", "join", "create", "remove", "current"],
                "message": ["send", "sendTree", "sendPrivate", "history"],
                "user": ["list", "self", "info", "kick", "ban", "setVolume"],
                "favourite": ["list", "add", "remove"],
                "settings": ["get", "set"],
                "state": ["get"],
                "log": ["setLevel", "setEnabled", "getConfig", "setGlobalEnabled", "reset"],
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
                "audio.restarted", "audio.error"
            ]
        ] as [String: Any]
    }

    // MARK: - Helpers

    private func serializeChannel(_ channel: MKChannel) -> [String: Any] {
        var dict: [String: Any] = [
            "id": channel.channelId(),
            "name": channel.channelName() ?? "",
            "position": channel.position()
        ]

        if let users = channel.users() as? [MKUser] {
            dict["users"] = users.map { serializeUser($0) }
        }

        if let subChannels = channel.channels() as? [MKChannel] {
            dict["channels"] = subChannels.map { serializeChannel($0) }
        }

        return dict
    }

    private func serializeUser(_ user: MKUser) -> [String: Any] {
        [
            "session": user.session(),
            "name": user.userName() ?? "",
            "channelId": user.channel()?.channelId() ?? 0,
            "channelName": user.channel()?.channelName() ?? "",
            "muted": user.isMuted(),
            "deafened": user.isDeafened(),
            "selfMuted": user.isSelfMuted(),
            "selfDeafened": user.isSelfDeafened(),
            "suppressed": user.isSuppressed(),
            "isRecording": user.isRecording(),
            "prioritySpeaker": user.isPrioritySpeaker()
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
}

#endif
