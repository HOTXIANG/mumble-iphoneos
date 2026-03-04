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
            var successObserver: NSObjectProtocol?
            var errorObserver: NSObjectProtocol?

            // 监听连接成功
            successObserver = NotificationCenter.default.addObserver(
                forName: .muConnectionOpened,
                object: nil,
                queue: .main
            ) { _ in
                if let observer = successObserver {
                    NotificationCenter.default.removeObserver(observer)
                }
                if let observer = errorObserver {
                    NotificationCenter.default.removeObserver(observer)
                }
                continuation.resume()
            }

            // 监听连接错误
            errorObserver = NotificationCenter.default.addObserver(
                forName: .muConnectionError,
                object: nil,
                queue: .main
            ) { notification in
                if let observer = successObserver {
                    NotificationCenter.default.removeObserver(observer)
                }
                if let observer = errorObserver {
                    NotificationCenter.default.removeObserver(observer)
                }

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
    func disconnectAsync() async {
        await MainActor.run {
            self.disconnectFromServer()
        }
    }

    /// 检查是否已连接（同步访问）
    var isConnectedAsync: Bool {
        self.isConnected()
    }
}
