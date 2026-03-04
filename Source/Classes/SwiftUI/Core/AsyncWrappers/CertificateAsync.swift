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
    /// 异步生成证书
    /// - Parameters:
    ///   - name: 用户名
    ///   - email: 邮箱地址
    /// - Returns: 生成的证书数据
    static func generate(name: String, email: String? = nil) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            MUCertificateController.shared().generateCertificate(withName: name, email: email) { certRef, error in
                if let error = error {
                    continuation.resume(throwing: MumbleError.certificateCreationFailed)
                } else if let certRef = certRef as Data? {
                    continuation.resume(returning: certRef)
                } else {
                    continuation.resume(throwing: MumbleError.certificateCreationFailed)
                }
            }
        }
    }

    /// 异步导入证书
    /// - Parameter data: PKCS12 格式的证书数据
    /// - Returns: 导入的证书信息
    static func `import`(data: Data, password: String = "") async throws -> CertificateInfo {
        try await withCheckedThrowingContinuation { continuation in
            MUCertificateController.shared().importCertificate(from: data, password: password) { info, error in
                if let error = error {
                    continuation.resume(throwing: MumbleError.certificateImportFailed(reason: error.localizedDescription))
                } else if let info = info {
                    continuation.resume(returning: info)
                } else {
                    continuation.resume(throwing: MumbleError.certificateImportFailed(reason: "Unknown error"))
                }
            }
        }
    }

    /// 异步导出证书
    /// - Parameters:
    ///   - certificate: 证书引用
    ///   - password: 导出密码
    /// - Returns: PKCS12 格式的证书数据
    static func `export`(certificate: Data, password: String = "") async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            MUCertificateController.shared().exportCertificate(certificate, password: password) { data, error in
                if let error = error {
                    continuation.resume(throwing: MumbleError.certificateExportFailed(reason: error.localizedDescription))
                } else if let data = data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: MumbleError.certificateExportFailed(reason: "Unknown error"))
                }
            }
        }
    }
}

// MARK: - Certificate Info

/// 证书信息结构体
struct CertificateInfo {
    let name: String
    let email: String?
    let expiryDate: Date?
    let certificateRef: Data
}