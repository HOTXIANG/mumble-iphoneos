//
//  MumbleError+Localized.swift
//  Mumble
//
//  Created by Claude on 2026/3/4.
//

import Foundation

// MARK: - LocalizedError

extension MumbleError: LocalizedError {
    /// 错误描述
    var errorDescription: String? {
        switch self {
        // Connection Errors
        case .connectionFailed(let reason):
            return String(format: NSLocalizedString("Connection failed: %@", comment: "Connection failed error"), reason)
        case .connectionTimeout:
            return NSLocalizedString("Connection timed out", comment: "Connection timeout error")
        case .disconnected:
            return NSLocalizedString("Disconnected from server", comment: "Disconnected error")
        case .networkError(let underlying):
            return String(format: NSLocalizedString("Network error: %@", comment: "Network error"), underlying.localizedDescription)

        // Certificate Errors
        case .certificateCreationFailed:
            return NSLocalizedString("Failed to create certificate", comment: "Certificate creation failed error")
        case .certificateNotFound:
            return NSLocalizedString("Certificate not found", comment: "Certificate not found error")
        case .certificateImportFailed(let reason):
            return String(format: NSLocalizedString("Failed to import certificate: %@", comment: "Certificate import failed error"), reason)
        case .certificateExportFailed(let reason):
            return String(format: NSLocalizedString("Failed to export certificate: %@", comment: "Certificate export failed error"), reason)

        // Database Errors
        case .databaseError(let operation, let reason):
            return String(format: NSLocalizedString("Database error during %@: %@", comment: "Database error"), operation, reason)
        case .dataNotFound:
            return NSLocalizedString("Data not found", comment: "Data not found error")

        // Server Errors
        case .serverError(let code, let message):
            return String(format: NSLocalizedString("Server error (%d): %@", comment: "Server error"), code, message)
        case .permissionDenied(let permission):
            return String(format: NSLocalizedString("Permission denied: %@", comment: "Permission denied error"), permission)
        case .channelJoinFailed(let channelName, let reason):
            return String(format: NSLocalizedString("Failed to join channel '%@': %@", comment: "Channel join failed error"), channelName, reason)

        // Authentication Errors
        case .authenticationFailed:
            return NSLocalizedString("Authentication failed", comment: "Authentication failed error")
        case .invalidCredentials:
            return NSLocalizedString("Invalid username or password", comment: "Invalid credentials error")
        case .usernameTaken:
            return NSLocalizedString("Username is already taken", comment: "Username taken error")

        // Audio Errors
        case .audioInitializationFailed:
            return NSLocalizedString("Failed to initialize audio system", comment: "Audio initialization failed error")
        case .microphonePermissionDenied:
            return NSLocalizedString("Microphone permission denied", comment: "Microphone permission denied error")

        // Unknown
        case .unknown(let underlying):
            if let error = underlying {
                return String(format: NSLocalizedString("Unknown error: %@", comment: "Unknown error with underlying"), error.localizedDescription)
            }
            return NSLocalizedString("Unknown error", comment: "Unknown error")
        }
    }

    /// 恢复建议
    var recoverySuggestion: String? {
        switch self {
        case .connectionFailed, .connectionTimeout:
            return NSLocalizedString("Please check your network connection and try again.", comment: "Connection recovery suggestion")
        case .disconnected:
            return NSLocalizedString("You can try to reconnect to the server.", comment: "Disconnected recovery suggestion")
        case .certificateNotFound:
            return NSLocalizedString("Please create or import a certificate in Settings.", comment: "Certificate not found recovery suggestion")
        case .microphonePermissionDenied:
            return NSLocalizedString("Please grant microphone permission in System Settings.", comment: "Microphone permission recovery suggestion")
        case .usernameTaken:
            return NSLocalizedString("Please try a different username.", comment: "Username taken recovery suggestion")
        default:
            return nil
        }
    }

    /// 失败原因
    var failureReason: String? {
        switch self {
        case .connectionFailed, .connectionTimeout:
            return NSLocalizedString("Could not establish connection to the server.", comment: "Connection failure reason")
        case .authenticationFailed, .invalidCredentials:
            return NSLocalizedString("The server rejected the authentication credentials.", comment: "Authentication failure reason")
        default:
            return nil
        }
    }
}

// MARK: - NSError Conversion

extension MumbleError {
    /// 转换为 NSError
    var nsError: NSError {
        let userInfo: [String: Any] = [
            NSLocalizedDescriptionKey: errorDescription ?? "Unknown error",
            NSLocalizedRecoverySuggestionErrorKey: recoverySuggestion as Any,
            NSLocalizedFailureReasonErrorKey: failureReason as Any
        ].compactMapValues { $0 }

        return NSError(domain: "com.mumble.Mumble.MumbleError", code: errorCode, userInfo: userInfo)
    }

    /// 错误码
    var errorCode: Int {
        switch self {
        case .connectionFailed: return 1001
        case .connectionTimeout: return 1002
        case .disconnected: return 1003
        case .networkError: return 1004
        case .certificateCreationFailed: return 2001
        case .certificateNotFound: return 2002
        case .certificateImportFailed: return 2003
        case .certificateExportFailed: return 2004
        case .databaseError: return 3001
        case .dataNotFound: return 3002
        case .serverError: return 4001
        case .permissionDenied: return 4002
        case .channelJoinFailed: return 4003
        case .authenticationFailed: return 5001
        case .invalidCredentials: return 5002
        case .usernameTaken: return 5003
        case .audioInitializationFailed: return 6001
        case .microphonePermissionDenied: return 6002
        case .unknown: return 9999
        }
    }
}