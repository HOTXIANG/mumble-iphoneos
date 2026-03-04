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
    /// 异步获取所有收藏服务器
    static func fetchAllFavourites() async throws -> [MUFavouriteServer] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                if let favourites = MUDatabase.fetchAllFavourites() as? [MUFavouriteServer] {
                    continuation.resume(returning: favourites)
                } else {
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
    static func saveFavourite(_ server: MUFavouriteServer) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let success = MUDatabase.saveFavourite(server)
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: MumbleError.databaseError(operation: "saveFavourite", reason: "Save failed"))
                }
            }
        }
    }

    /// 异步删除收藏服务器
    static func deleteFavourite(_ server: MUFavouriteServer) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let success = MUDatabase.deleteFavourite(server)
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: MumbleError.databaseError(operation: "deleteFavourite", reason: "Delete failed"))
                }
            }
        }
    }

    /// 异步保存最近服务器
    static func saveRecent(host: String, port: Int, username: String, displayName: String?) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                MUDatabase.saveRecentServer(host, port: port, username: username, displayName: displayName)
                continuation.resume()
            }
        }
    }
}