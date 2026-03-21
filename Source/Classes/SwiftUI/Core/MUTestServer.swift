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

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private let port: UInt16 = 54296
    private let router = MUTestCommandRouter()
    private var observers: [Any] = []

    private init() {}

    // MARK: - Lifecycle

    @MainActor
    func start(serverManager: ServerModelManager) {
        router.serverManager = serverManager

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
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }

    // MARK: - Connection Management

    private func acceptConnection(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connections[id] = connection

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                MumbleLogger.general.debug("TestServer: client connected")
            case .failed, .cancelled:
                self?.connections.removeValue(forKey: id)
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

            if error != nil {
                return
            }

            if let data = data, !data.isEmpty {
                self.processMessage(data, from: connection)
            }

            // Continue receiving if still connected
            if self.connections[id] != nil {
                self.receiveLoop(connection, id: id)
            }
        }
    }

    // MARK: - Message Processing

    private func processMessage(_ data: Data, from connection: NWConnection) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = json["action"] as? String else {
            sendJSON(["success": false, "error": "Invalid JSON or missing 'action' field"], to: connection)
            return
        }

        let requestID = json["id"] as? String
        let params = json["params"] as? [String: Any] ?? [:]

        Task { @MainActor in
            do {
                let result = try await self.router.handle(action: action, params: params)
                var response: [String: Any] = ["success": true]
                if let id = requestID { response["id"] = id }
                if let result = result { response["data"] = result }
                self.sendJSON(response, to: connection)
            } catch {
                var response: [String: Any] = ["success": false, "error": error.localizedDescription]
                if let id = requestID { response["id"] = id }
                self.sendJSON(response, to: connection)
            }
        }
    }

    // MARK: - Sending

    private func sendJSON(_ object: [String: Any], to connection: NWConnection) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "ws", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true,
                        completion: .contentProcessed({ _ in }))
    }

    func broadcastEvent(_ event: String, data: [String: Any] = [:]) {
        let payload: [String: Any] = ["event": event, "data": data]
        for connection in connections.values {
            sendJSON(payload, to: connection)
        }
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
    }
}

#endif
