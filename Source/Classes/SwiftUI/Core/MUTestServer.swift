//
//  MUTestServer.swift
//  Mumble
//
//  WebSocket-based automated testing server for AI agent integration.
//  Listens on ws://localhost:54296, accepts JSON commands, returns JSON responses.
//  Only compiled in DEBUG builds.
//
//  Usage with websocat:
//    websocat ws://localhost:54296
//    {"action": "help.actions"}
//    {"action": "connection.status"}
//

#if DEBUG

import Foundation
import Network

final class MUTestServer: @unchecked Sendable {
    static let shared = MUTestServer()

    struct LogStreamSubscription {
        var isEnabled: Bool
        var minimumLevelRaw: Int?
        var categories: Set<String>

        static let disabled = LogStreamSubscription(isEnabled: false, minimumLevelRaw: nil, categories: [])
    }

    private struct RequestEnvelope: @unchecked Sendable {
        let id: Any?
        let idDescription: String
        let action: String
        let params: [String: Any]
    }

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var logSubscriptions: [ObjectIdentifier: LogStreamSubscription] = [:]
    private let port: UInt16 = 54296
    private let router = MUTestCommandRouter()
    private var observers: [Any] = []

    private init() {}

    // MARK: - Lifecycle

    @MainActor
    func start(serverManager: ServerModelManager) {
        guard listener == nil else {
            MumbleLogger.general.debug("TestServer: start ignored because listener is already active")
            router.serverManager = serverManager
            router.testServer = self
            return
        }

        router.serverManager = serverManager
        router.testServer = self

        let parameters = NWParameters.tcp
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        do {
            listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        } catch {
            MumbleLogger.general.error("TestServer: failed to create listener: \(error)")
            return
        }

        listener?.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                MumbleLogger.general.info("TestServer: listening on ws://localhost:\(self.port)")
            case .failed(let error):
                MumbleLogger.general.error("TestServer: listener failed: \(error)")
                self.stop()
            default:
                break
            }
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.acceptConnection(connection)
        }

        listener?.start(queue: .main)
        setupEventForwarding()
    }

    func stop() {
        listener?.cancel()
        listener = nil
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
        logSubscriptions.removeAll()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        MumbleLogger.general.info("TestServer: stopped")
    }

    @MainActor
    func setLogStream(enabled: Bool,
                      minimumLevel: LogLevel?,
                      categories: [String]?,
                      for connectionID: ObjectIdentifier) -> [String: Any] {
        let normalizedCategories = Set((categories ?? []).compactMap { raw in
            LogCategory(rawValue: raw) ?? LogCategory.allCases.first(where: { $0.rawValue.lowercased() == raw.lowercased() })
        }.map(\.rawValue))

        let subscription = LogStreamSubscription(
            isEnabled: enabled,
            minimumLevelRaw: minimumLevel?.rawValue,
            categories: normalizedCategories
        )
        logSubscriptions[connectionID] = subscription

        MumbleLogger.general.info("TestServer: log stream \(enabled ? "enabled" : "disabled") for client=\(connectionID) minLevel=\(minimumLevel?.apiValue ?? "none") categories=\(normalizedCategories.sorted().joined(separator: ","))")

        return serializeLogSubscription(subscription)
    }

    @MainActor
    func getLogStreamStatus(for connectionID: ObjectIdentifier) -> [String: Any] {
        let subscription = logSubscriptions[connectionID] ?? .disabled
        return serializeLogSubscription(subscription)
    }

    // MARK: - Connection Management

    private func acceptConnection(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        logSubscriptions[id] = .disabled

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                MumbleLogger.general.info("TestServer: client connected id=\(id) activeClients=\(self?.connections.count ?? 0)")
            case .failed, .cancelled:
                self?.connections.removeValue(forKey: id)
                self?.logSubscriptions.removeValue(forKey: id)
                MumbleLogger.general.debug("TestServer: client disconnected")
            default:
                break
            }
        }

        connection.start(queue: .main)
        receiveLoop(connection, id: id)
    }

    private func receiveLoop(_ connection: NWConnection, id: ObjectIdentifier) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self = self else { return }

            if let error {
                MumbleLogger.general.warning("TestServer: receive failed for client=\(id): \(error)")
                return
            }

            if let data = data, !data.isEmpty {
                self.processMessage(data, from: connection, connectionID: id)
            }

            // Continue receiving if still connected
            if self.connections[id] != nil {
                self.receiveLoop(connection, id: id)
            }
        }
    }

    // MARK: - Message Processing

    private func processMessage(_ data: Data, from connection: NWConnection, connectionID: ObjectIdentifier) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = json["action"] as? String else {
            sendJSON(["success": false, "error": "Invalid JSON or missing 'action' field"], to: connection)
            return
        }

        let request = RequestEnvelope(
            id: json["id"],
            idDescription: json["id"].map { String(describing: $0) } ?? "-",
            action: action,
            params: json["params"] as? [String: Any] ?? [:]
        )
        let startedAt = CFAbsoluteTimeGetCurrent()
        let sanitizedParams = sanitizeParamsForLogging(request.params)

        MumbleLogger.general.info("TestServer: request start client=\(connectionID) id=\(request.idDescription) action=\(request.action) params=\(sanitizedParams)")

        Task { @MainActor in
            do {
                let context = MUTestCommandContext(connectionID: connectionID)
                let result = try await self.router.handle(action: request.action, params: request.params, context: context)
                var response: [String: Any] = ["success": true]
                if let id = request.id { response["id"] = id }
                if let result = result { response["data"] = result }
                self.sendJSON(response, to: connection)
                let elapsedMs = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000.0
                MumbleLogger.general.info("TestServer: request success client=\(connectionID) id=\(request.idDescription) action=\(request.action) elapsed_ms=\(String(format: "%.2f", elapsedMs))")
            } catch {
                var response: [String: Any] = ["success": false, "error": error.localizedDescription]
                if let id = request.id { response["id"] = id }
                self.sendJSON(response, to: connection)
                let elapsedMs = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000.0
                MumbleLogger.general.error("TestServer: request failed client=\(connectionID) id=\(request.idDescription) action=\(request.action) elapsed_ms=\(String(format: "%.2f", elapsedMs)) error=\(error.localizedDescription)")
            }
        }
    }

    // MARK: - Sending

    private func sendJSON(_ object: [String: Any], to connection: NWConnection) {
        let sanitized = sanitizeForJSON(object)
        guard JSONSerialization.isValidJSONObject(sanitized),
              let data = try? JSONSerialization.data(withJSONObject: sanitized) else {
            // Fallback: send error response
            let fallback = "{\"success\":false,\"error\":\"Response contained non-serializable values\"}".data(using: .utf8)!
            let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
            let context = NWConnection.ContentContext(identifier: "ws", metadata: [metadata])
            connection.send(content: fallback, contentContext: context, isComplete: true,
                            completion: .contentProcessed({ _ in }))
            return
        }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "ws", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true,
                        completion: .contentProcessed({ _ in }))
    }

    /// Recursively convert values to JSON-safe types
    private func sanitizeForJSON(_ value: Any) -> Any {
        if let dict = value as? [String: Any] {
            return dict.mapValues { sanitizeForJSON($0) }
        } else if let array = value as? [Any] {
            return array.map { sanitizeForJSON($0) }
        } else if let str = value as? String {
            return str
        } else if let num = value as? NSNumber {
            return num
        } else if let bool = value as? Bool {
            return bool
        } else if value is NSNull {
            return value
        } else {
            // Non-serializable: convert to string description
            return String(describing: value)
        }
    }

    func broadcastEvent(_ event: String, data: [String: Any] = [:]) {
        let payload: [String: Any] = ["event": event, "data": data]
        for connection in connections.values {
            sendJSON(payload, to: connection)
        }
    }

    private func broadcastLogEntry(_ entry: [String: Any]) {
        for (connectionID, connection) in connections {
            let subscription = logSubscriptions[connectionID] ?? .disabled
            guard shouldDeliverLog(entry, subscription: subscription) else { continue }
            sendJSON(["event": "log.entry", "data": entry], to: connection)
        }
    }

    private func stringUserInfo(_ userInfo: [AnyHashable: Any]?) -> [String: Any] {
        guard let userInfo else { return [:] }
        var result: [String: Any] = [:]
        for (key, value) in userInfo {
            if let stringKey = key as? String {
                result[stringKey] = value
            } else {
                result[String(describing: key)] = value
            }
        }
        return result
    }

    // MARK: - Event Forwarding

    private func setupEventForwarding() {
        let nc = NotificationCenter.default

        observers.append(nc.addObserver(forName: .muConnectionOpened, object: nil, queue: .main) { [weak self] _ in
            self?.broadcastEvent("connection.opened", data: ["connected": true])
        })

        observers.append(nc.addObserver(forName: .muConnectionClosed, object: nil, queue: .main) { [weak self] _ in
            self?.broadcastEvent("connection.closed", data: ["connected": false])
        })

        observers.append(nc.addObserver(forName: .muConnectionConnecting, object: nil, queue: .main) { [weak self] _ in
            self?.broadcastEvent("connection.connecting")
        })

        observers.append(nc.addObserver(forName: .muConnectionError, object: nil, queue: .main) { [weak self] notification in
            let title = notification.userInfo?["title"] as? String ?? ""
            let msg = notification.userInfo?["message"] as? String ?? ""
            self?.broadcastEvent("connection.error", data: ["title": title, "message": msg])
        })

        observers.append(nc.addObserver(forName: .mkAudioDidRestart, object: nil, queue: .main) { [weak self] _ in
            self?.broadcastEvent("audio.restarted")
        })

        observers.append(nc.addObserver(forName: .mkAudioError, object: nil, queue: .main) { [weak self] notification in
            let error = notification.userInfo?["error"] as? String ?? ""
            self?.broadcastEvent("audio.error", data: ["error": error])
        })

        observers.append(nc.addObserver(forName: .muConnectionUDPTransportStatus, object: nil, queue: .main) { [weak self] notification in
            let stateName = notification.userInfo?["stateName"] as? String ?? "unknown"
            self?.broadcastEvent("connection.udpStatus", data: ["state": stateName])
        })

        observers.append(nc.addObserver(forName: .muAppShowMessage, object: nil, queue: .main) { [weak self] notification in
            var payload: [String: Any] = [:]
            if let message = notification.userInfo?["message"] as? String {
                payload["message"] = message
            }
            if let type = notification.userInfo?["type"] as? String {
                payload["type"] = type
            }
            if let jump = notification.userInfo?["jumpToMessages"] as? Bool {
                payload["jumpToMessages"] = jump
            }
            self?.broadcastEvent("app.toast", data: payload)
        })

        observers.append(nc.addObserver(forName: .muMessageSendFailed, object: nil, queue: .main) { [weak self] notification in
            let reason = notification.userInfo?["reason"] as? String ?? "unknown"
            self?.broadcastEvent("message.sendFailed", data: ["reason": reason])
        })

        observers.append(nc.addObserver(forName: .mkListeningChannelAdd, object: nil, queue: .main) { [weak self] notification in
            let channels = (notification.userInfo?["addChannels"] as? [NSNumber])?.map(\.uintValue) ?? []
            self?.broadcastEvent("channel.listeningAdded", data: ["channelIds": channels])
        })

        observers.append(nc.addObserver(forName: .mkListeningChannelRemove, object: nil, queue: .main) { [weak self] notification in
            let channels = (notification.userInfo?["removeChannels"] as? [NSNumber])?.map(\.uintValue) ?? []
            self?.broadcastEvent("channel.listeningRemoved", data: ["channelIds": channels])
        })

        observers.append(nc.addObserver(forName: .mumbleLogEntryAdded, object: nil, queue: .main) { [weak self] notification in
            self?.broadcastLogEntry(self?.stringUserInfo(notification.userInfo) ?? [:])
        })

        observers.append(nc.addObserver(forName: .muAutomationUIStateChanged, object: nil, queue: .main) { [weak self] notification in
            self?.broadcastEvent("ui.changed", data: self?.stringUserInfo(notification.userInfo) ?? [:])
        })
    }

    private func shouldDeliverLog(_ entry: [String: Any], subscription: LogStreamSubscription) -> Bool {
        guard subscription.isEnabled else { return false }

        if !subscription.categories.isEmpty,
           let category = entry["category"] as? String,
           !subscription.categories.contains(category) {
            return false
        }

        if let minimumLevelRaw = subscription.minimumLevelRaw,
           let levelRaw = entry["levelRaw"] as? Int,
           levelRaw < minimumLevelRaw {
            return false
        }

        return true
    }

    private func serializeLogSubscription(_ subscription: LogStreamSubscription) -> [String: Any] {
        [
            "enabled": subscription.isEnabled,
            "minimumLevel": subscription.minimumLevelRaw.flatMap(LogLevel.init(rawValue:))?.apiValue ?? NSNull(),
            "categories": subscription.categories.sorted()
        ]
    }

    private func sanitizeParamsForLogging(_ params: [String: Any]) -> [String: Any] {
        var sanitized: [String: Any] = [:]
        for (key, value) in params {
            if key.lowercased().contains("password") {
                sanitized[key] = "<redacted>"
            } else if key.lowercased().contains("token"), let stringValue = value as? String, !stringValue.isEmpty {
                sanitized[key] = "<redacted-token>"
            } else {
                sanitized[key] = sanitizeForJSON(value)
            }
        }
        return sanitized
    }
}

#endif
