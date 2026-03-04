//
//  MumbleError.swift
//  Mumble
//
//  Created by Claude on 2026/3/4.
//

import Foundation

// MARK: - Mumble Error

/// 统一的错误类型定义
enum MumbleError: Error {
    // MARK: - Connection Errors

    /// 连接失败
    case connectionFailed(reason: String)
    /// 连接超时
    case connectionTimeout
    /// 已断开连接
    case disconnected
    /// 网络错误
    case networkError(underlying: Error)

    // MARK: - Certificate Errors

    /// 证书创建失败
    case certificateCreationFailed
    /// 证书未找到
    case certificateNotFound
    /// 证书导入失败
    case certificateImportFailed(reason: String)
    /// 证书导出失败
    case certificateExportFailed(reason: String)

    // MARK: - Database Errors

    /// 数据库错误
    case databaseError(operation: String, reason: String)
    /// 数据未找到
    case dataNotFound

    // MARK: - Server Errors

    /// 服务器错误
    case serverError(code: Int, message: String)
    /// 权限被拒绝
    case permissionDenied(permission: String)
    /// 频道加入失败
    case channelJoinFailed(channelName: String, reason: String)

    // MARK: - Authentication Errors

    /// 认证失败
    case authenticationFailed
    /// 无效凭据
    case invalidCredentials
    /// 用户名已被占用
    case usernameTaken

    // MARK: - Audio Errors

    /// 音频初始化失败
    case audioInitializationFailed
    /// 麦克风权限被拒绝
    case microphonePermissionDenied

    // MARK: - Unknown

    /// 未知错误
    case unknown(underlying: Error?)
}

// MARK: - Error Conversion

extension MumbleError {
    /// 从 NSError 转换
    static func from(_ error: NSError) -> MumbleError {
        // 根据域名和错误码进行映射
        switch error.domain {
        case NSPOSIXErrorDomain:
            return .networkError(underlying: error)
        case NSURLErrorDomain:
            return .networkError(underlying: error)
        default:
            return .unknown(underlying: error)
        }
    }
}

// MARK: - Equatable

extension MumbleError: Equatable {
    static func == (lhs: MumbleError, rhs: MumbleError) -> Bool {
        switch (lhs, rhs) {
        case (.connectionFailed(let l), .connectionFailed(let r)):
            return l == r
        case (.connectionTimeout, .connectionTimeout):
            return true
        case (.disconnected, .disconnected):
            return true
        case (.certificateCreationFailed, .certificateCreationFailed):
            return true
        case (.certificateNotFound, .certificateNotFound):
            return true
        case (.certificateImportFailed(let l), .certificateImportFailed(let r)):
            return l == r
        case (.certificateExportFailed(let l), .certificateExportFailed(let r)):
            return l == r
        case (.databaseError(let lOp, let lReason), .databaseError(let rOp, let rReason)):
            return lOp == rOp && lReason == rReason
        case (.dataNotFound, .dataNotFound):
            return true
        case (.serverError(let lCode, let lMsg), .serverError(let rCode, let rMsg)):
            return lCode == rCode && lMsg == rMsg
        case (.permissionDenied(let l), .permissionDenied(let r)):
            return l == r
        case (.channelJoinFailed(let lName, let lReason), .channelJoinFailed(let rName, let rReason)):
            return lName == rName && lReason == rReason
        case (.authenticationFailed, .authenticationFailed):
            return true
        case (.invalidCredentials, .invalidCredentials):
            return true
        case (.usernameTaken, .usernameTaken):
            return true
        case (.audioInitializationFailed, .audioInitializationFailed):
            return true
        case (.microphonePermissionDenied, .microphonePermissionDenied):
            return true
        case (.unknown, .unknown):
            return true
        default:
            return false
        }
    }
}