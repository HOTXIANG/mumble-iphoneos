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
    func connectAsync(
        to hostname: String,
        port: UInt16,
        username: String,
        password: String? = nil,
        certificateRef: Data? = nil,
        displayName: String? = nil
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let state = ConnectionObserverState()

            // 监听连接成功
            state.successObserver = NotificationCenter.default.addObserver(
                forName: .muConnectionOpened,
                object: nil,
                queue: .main
            ) { [weak state] _ in
                state?.cleanup()
                continuation.resume()
            }

            // 监听连接错误
            state.errorObserver = NotificationCenter.default.addObserver(
                forName: .muConnectionError,
                object: nil,
                queue: .main
            ) { [weak state] notification in
                state?.cleanup()

                if let userInfo = notification.userInfo,
                   let message = userInfo["message"] as? String {
                    continuation.resume(throwing: MumbleError.connectionFailed(reason: message))
                } else {
                    continuation.resume(throwing: MumbleError.connectionFailed(reason: "Unknown error"))
                }
            }

            // 发起连接
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

/// 观察者状态管理类，用于安全地管理 NotificationCenter 观察者
private final class ConnectionObserverState: @unchecked Sendable {
    var successObserver: NSObjectProtocol?
    var errorObserver: NSObjectProtocol?
    private let lock = NSLock()

    func cleanup() {
        lock.lock()
        defer { lock.unlock() }

        if let observer = successObserver {
            NotificationCenter.default.removeObserver(observer)
            successObserver = nil
        }
        if let observer = errorObserver {
            NotificationCenter.default.removeObserver(observer)
            errorObserver = nil
        }
    }
}
