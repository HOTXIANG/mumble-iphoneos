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
        MumbleLogger.certificate.info("Generating self-signed certificate for '\(name)'")
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let certRef = MUCertificateController.generateSelfSignedCertificate(withName: name, email: email)
                if let certRef = certRef {
                    MumbleLogger.certificate.info("Certificate generated successfully")
                    continuation.resume(returning: certRef)
                } else {
                    MumbleLogger.certificate.error("Certificate generation failed")
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
        MumbleLogger.certificate.info("Importing PKCS12 certificate (\(data.count) bytes)")
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let certRef = try MUCertificateController.importPKCS12Data(data, password: password)
                    MumbleLogger.certificate.info("Certificate imported successfully")
                    continuation.resume(returning: certRef)
                } catch {
                    MumbleLogger.certificate.error("Certificate import failed: \(error.localizedDescription)")
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
        MumbleLogger.certificate.info("Exporting certificate as PKCS12")
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                if let exportData = MUCertificateController.exportPKCS12Data(forPersistentRef: persistentRef, password: password) {
                    MumbleLogger.certificate.info("Certificate exported (\(exportData.count) bytes)")
                    continuation.resume(returning: exportData)
                } else {
                    MumbleLogger.certificate.error("Certificate export failed")
                    continuation.resume(throwing: MumbleError.certificateExportFailed(reason: "Export failed"))
                }
            }
        }
    }

    /// 异步删除证书
    /// - Parameter persistentRef: 证书持久化引用
    static func delete(persistentRef: Data) async throws {
        MumbleLogger.certificate.info("Deleting certificate")
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let status = MUCertificateController.deleteCertificate(withPersistentRef: persistentRef)
                if status == errSecSuccess {
                    MumbleLogger.certificate.info("Certificate deleted successfully")
                    continuation.resume()
                } else {
                    MumbleLogger.certificate.error("Certificate deletion failed with status: \(status)")
                    continuation.resume(throwing: MumbleError.unknown(underlying: NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: nil)))
                }
            }
        }
    }
}
