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
    @available(*, deprecated, message: "Use async/await version")
    func connectAsync(
        to hostname: String,
        port: UInt16,
        username: String,
        password: String? = nil,
        certificateRef: Data? = nil,
        displayName: String? = nil
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connect(
                toHostname: hostname,
                port: port,
                withUsername: username,
                andPassword: password,
                certificateRef: certificateRef,
                displayName: displayName
            )

            // 监听连接结果
            var observer: NSObjectProtocol?
            observer = NotificationCenter.default.addObserver(
                forName: .muConnectionOpened,
                object: nil,
                queue: .main
            ) { _ in
                if let obs = observer {
                    NotificationCenter.default.removeObserver(obs)
                }
                continuation.resume()
            }

            // 监听连接错误
            var errorObserver: NSObjectProtocol?
            errorObserver = NotificationCenter.default.addObserver(
                forName: .muConnectionError,
                object: nil,
                queue: .main
            ) { notification in
                if let obs = errorObserver {
                    NotificationCenter.default.removeObserver(obs)
                }
                if let userInfo = notification.userInfo,
                   let message = userInfo["message"] as? String {
                    continuation.resume(throwing: MumbleError.connectionFailed(reason: message))
                } else {
                    continuation.resume(throwing: MumbleError.connectionFailed(reason: "Unknown error"))
                }
            }
        }
    }

    /// 异步断开连接
    func disconnectAsync() async {
        await withCheckedContinuation { continuation in
            disconnectFromServer()
            continuation.resume()
        }
    }
}