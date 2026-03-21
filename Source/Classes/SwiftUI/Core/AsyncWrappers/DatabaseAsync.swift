//
//  DatabaseAsync.swift
//  Mumble
//
//  Created by Claude on 2026/3/4.
//

import Foundation

// MARK: - Database Async Operations

/// 数据库异步操作
enum DatabaseAsync {
    // MARK: - Favourite Servers

    /// 异步获取所有收藏服务器
    static func fetchAllFavourites() async throws -> [MUFavouriteServer] {
        MumbleLogger.database.debug("Fetching all favourites")
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                if let favourites = MUDatabase.fetchAllFavourites() as? [MUFavouriteServer] {
                    MumbleLogger.database.debug("Fetched \(favourites.count) favourites")
                    continuation.resume(returning: favourites)
                } else {
                    MumbleLogger.database.error("fetchAllFavourites: failed to cast results")
                    continuation.resume(throwing: MumbleError.databaseError(operation: "fetchAllFavourites", reason: "Failed to cast results"))
                }
            }
        }
    }

    /// 异步获取可见的收藏服务器
    static func fetchVisibleFavourites() async throws -> [MUFavouriteServer] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                if let favourites = MUDatabase.fetchVisibleFavourites() as? [MUFavouriteServer] {
                    continuation.resume(returning: favourites)
                } else {
                    continuation.resume(throwing: MumbleError.databaseError(operation: "fetchVisibleFavourites", reason: "Failed to cast results"))
                }
            }
        }
    }

    /// 异步保存收藏服务器
    static func storeFavourite(_ server: MUFavouriteServer) async {
        MumbleLogger.database.info("Storing favourite server")
        await withCheckedContinuation { continuation in
            struct UncheckedSendable<T>: @unchecked Sendable {
                let value: T
            }
            let wrapped = UncheckedSendable(value: server)

            DispatchQueue.global(qos: .userInitiated).async {
                MUDatabase.storeFavourite(wrapped.value)
                continuation.resume()
            }
        }
    }

    /// 异步删除收藏服务器
    static func deleteFavourite(_ server: MUFavouriteServer) async {
        MumbleLogger.database.info("Deleting favourite server")
        await withCheckedContinuation { continuation in
            struct UncheckedSendable<T>: @unchecked Sendable {
                let value: T
            }
            let wrapped = UncheckedSendable(value: server)

            DispatchQueue.global(qos: .userInitiated).async {
                MUDatabase.deleteFavourite(wrapped.value)
                continuation.resume()
            }
        }
    }

    // MARK: - Username Storage

    /// 异步获取用户名
    static func usernameForServer(hostname: String, port: Int) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let username = MUDatabase.usernameForServer(withHostname: hostname, port: port)
                continuation.resume(returning: username)
            }
        }
    }

    /// 异步保存用户名
    static func storeUsername(_ username: String, hostname: String, port: Int) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                MUDatabase.storeUsername(username, forServerWithHostname: hostname, port: port)
                continuation.resume()
            }
        }
    }

    // MARK: - Access Tokens

    /// 异步获取访问令牌
    static func accessTokensForServer(hostname: String, port: Int) async -> [String]? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let tokens = MUDatabase.accessTokensForServer(withHostname: hostname, port: port)
                continuation.resume(returning: tokens as? [String])
            }
        }
    }

    /// 异步保存访问令牌
    static func storeAccessTokens(_ tokens: [String], hostname: String, port: Int) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                MUDatabase.storeAccessTokens(tokens, forServerWithHostname: hostname, port: port)
                continuation.resume()
            }
        }
    }

    // MARK: - Server Digest

    /// 异步保存服务器摘要
    static func storeDigest(_ hash: String, hostname: String, port: Int) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                MUDatabase.storeDigest(hash, forServerWithHostname: hostname, port: port)
                continuation.resume()
            }
        }
    }

    /// 异步获取服务器摘要
    static func digestForServer(hostname: String, port: Int) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let digest = MUDatabase.digestForServer(withHostname: hostname, port: port)
                continuation.resume(returning: digest)
            }
        }
    }
}