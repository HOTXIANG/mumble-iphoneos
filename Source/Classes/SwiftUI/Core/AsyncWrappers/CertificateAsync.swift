//
//  CertificateAsync.swift
//  Mumble
//
//  Created by Claude on 2026/3/4.
//

import Foundation

// MARK: - Certificate Async Operations

/// 证书异步操作
enum CertificateAsync {
    /// 异步生成自签名证书
    /// - Parameters:
    ///   - name: 用户名
    ///   - email: 邮箱地址（可选）
    /// - Returns: 证书持久化引用
    static func generateSelfSigned(name: String, email: String? = nil) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let certRef = MUCertificateController.generateSelfSignedCertificate(withName: name, email: email)
                if let certRef = certRef {
                    continuation.resume(returning: certRef)
                } else {
                    continuation.resume(throwing: MumbleError.certificateCreationFailed)
                }
            }
        }
    }

    /// 异步导入 PKCS12 证书
    /// - Parameters:
    ///   - data: PKCS12 格式的证书数据
    ///   - password: 密码
    /// - Returns: 导入的证书持久化引用
    static func importPKCS12(_ data: Data, password: String = "") async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let certRef = try MUCertificateController.importPKCS12Data(data, password: password)
                    continuation.resume(returning: certRef)
                } catch {
                    continuation.resume(throwing: MumbleError.certificateImportFailed(reason: error.localizedDescription))
                }
            }
        }
    }

    /// 异步导出 PKCS12 证书
    /// - Parameters:
    ///   - persistentRef: 证书持久化引用
    ///   - password: 导出密码
    /// - Returns: PKCS12 格式的证书数据
    static func exportPKCS12(persistentRef: Data, password: String = "") async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                if let exportData = MUCertificateController.exportPKCS12Data(forPersistentRef: persistentRef, password: password) {
                    continuation.resume(returning: exportData)
                } else {
                    continuation.resume(throwing: MumbleError.certificateExportFailed(reason: "Export failed"))
                }
            }
        }
    }

    /// 异步删除证书
    /// - Parameter persistentRef: 证书持久化引用
    static func delete(persistentRef: Data) async throws {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let status = MUCertificateController.deleteCertificate(withPersistentRef: persistentRef)
                if status == errSecSuccess {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: MumbleError.unknown(underlying: NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: nil)))
                }
            }
        }
    }
}
