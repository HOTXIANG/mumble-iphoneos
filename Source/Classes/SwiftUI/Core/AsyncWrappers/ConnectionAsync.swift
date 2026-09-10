//
//  ConnectionAsync.swift
//  Mumble
//
//  Created by Claude on 2026/3/4.
//

import Foundation

// MARK: - MUConnectionController Async Extensions

extension MUConnectionController {
    /// 异步连接到服务器
    /// - Parameters:
    ///   - hostname: 服务器主机名
    ///   - port: 端口号
    ///   - username: 用户名
    ///   - password: 密码（可选）
    ///   - certificateRef: 证书引用（可选）
    ///   - displayName: 显示名称（可选）
    @MainActor func connectAsync(
        to hostname: String,
        port: UInt16,
        username: String,
        password: String? = nil,
        certificateRef: Data? = nil,
        displayName: String? = nil
    ) async throws {
        MumbleLogger.connection.info("Connecting async to \(hostname):\(port) as \(username)")
        try Task.checkCancellation()
        // 手动请求的身份跨自动重试保持不变；取消旧 Task 不能拆掉后来建立的连接。
        let state = ConnectionObserverState(controller: self, requestGeneration: connectionRequestGeneration &+ 1)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                state.begin(continuation: continuation)
                guard !Task.isCancelled else {
                    state.cancel()
                    return
                }
                state.start {
                    self.connect(
                        toHostname: hostname,
                        port: UInt(port),
                        withUsername: username,
                        andPassword: password,
                        certificateRef: certificateRef,
                        displayName: displayName
                    )
                }
            }
        } onCancel: {
            Task { @MainActor in state.cancel() }
        }
    }

    /// 异步断开连接
    @MainActor func disconnectAsync() async {
        self.disconnectFromServer()
    }

    /// 检查是否已连接（同步访问）
    var isConnectedAsync: Bool {
        self.isConnected()
    }
}

// MARK: - Helper Class

/// 由 await 的取消处理器持有，所有完成路径在主线程上只消费一次 continuation。
@MainActor
private final class ConnectionObserverState {
    private weak var controller: MUConnectionController?
    private let requestGeneration: UInt
    private var observers: [NSObjectProtocol] = []
    private var continuation: CheckedContinuation<Void, Error>?
    private var didStart = false

    init(controller: MUConnectionController, requestGeneration: UInt) {
        self.controller = controller
        self.requestGeneration = requestGeneration
    }

    func begin(continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func start(_ connect: () -> Void) {
        guard continuation != nil, let controller else { return }
        let names: [Notification.Name] = [
            .muConnectionOpened, .muConnectionError, .muConnectionClosed, .muConnectionConnecting
        ]
        for name in names {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: controller, queue: .main) { [weak self] notification in
                guard let generation = (notification.userInfo?["requestGeneration"] as? NSNumber)?.uintValue else { return }
                let message = notification.userInfo?["message"] as? String
                Task { @MainActor [weak self] in
                    self?.handle(name: name, generation: generation, message: message)
                }
            })
        }
        didStart = true
        connect()
    }

    private func handle(name: Notification.Name, generation: UInt, message: String?) {
        guard continuation != nil else { return }
        if name == .muConnectionConnecting && generation != requestGeneration {
            if controller?.connectionRequestGeneration != requestGeneration {
                finish(.failure(CancellationError()))
            }
            return
        }
        guard generation == requestGeneration else { return }
        guard controller?.connectionRequestGeneration == requestGeneration else {
            finish(.failure(CancellationError()))
            return
        }
        switch name {
        case .muConnectionOpened:
            MumbleLogger.connection.info("Async connection succeeded")
            finish(.success(()))
        case .muConnectionError:
            let reason = message ?? "Unknown error"
            MumbleLogger.connection.error("Async connection failed: \(reason)")
            finish(.failure(MumbleError.connectionFailed(reason: reason)))
        case .muConnectionClosed:
            finish(.failure(CancellationError()))
        default:
            break
        }
    }

    func cancel() {
        guard continuation != nil else { return }
        let shouldDisconnect = didStart && controller?.connectionRequestGeneration == requestGeneration
        finish(.failure(CancellationError()))
        if shouldDisconnect {
            controller?.disconnectFromServer()
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        continuation.resume(with: result)
    }
}
