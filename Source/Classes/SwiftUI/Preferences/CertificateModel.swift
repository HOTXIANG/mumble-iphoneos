//
//  CertificateModel.swift
//  Mumble
//
//  Created by 王梓田 on 1/2/26.
//

import SwiftUI
import Combine

struct CertificateItem: Identifiable, Hashable {
    let id: Data // Persistent Ref (Keychain ID)
    let name: String
    let hash: String
    let expiry: Date?
}

@MainActor
class CertificateModel: ObservableObject {
    static let shared = CertificateModel()
    
    // 不再是单一证书，而是证书列表
    @Published var certificates: [CertificateItem] = []
    
    @Published var importError: String?
    
    private init() {
        refreshCertificates()
    }
    
    func refreshCertificates() {
        // 1. 获取所有身份的 Persistent Refs
        guard let refs = MUCertificateController.persistentRefsForIdentities() as? [Data] else {
            self.certificates = []
            return
        }
        
        var items: [CertificateItem] = []
        
        // 2. 遍历并加载详情
        for ref in refs {
            if let cert = MUCertificateController.certificate(withPersistentRef: ref) {
                let name = cert.commonName() ?? "Unknown Identity"
                let hash = cert.hexDigest() ?? "Unknown Hash"
                let expiry = cert.notAfter() // 获取过期时间
                
                items.append(CertificateItem(id: ref, name: name, hash: hash, expiry: expiry))
            }
        }
        
        self.certificates = items
    }
    
    func findCertificateReference(name: String) -> Data? {
        // 遍历缓存的证书列表寻找匹配项
        // 注意：证书的 Common Name (CN) 通常就是我们生成的 "User@Host"
        if let match = certificates.first(where: { $0.name == name }) {
            return match.id
        }
        return nil
    }
    
    func isCertificateValid(_ ref: Data) -> Bool {
        return certificates.contains(where: { $0.id == ref })
    }
    
    func generateNewCertificate(name: String, email: String) {
        print("🔐 Generating certificate for \(name) <\(email)>")
        
        // 调用 OC 控制器生成 (生成后会自动存入 Keychain)
        if let _ = MUCertificateController.generateSelfSignedCertificate(withName: name, email: email) {
            print("✅ Certificate generated successfully.")
            // 生成成功后刷新列表，界面上就会出现新证书
            refreshCertificates()
        } else {
            print("❌ Failed to generate certificate.")
        }
    }
    
    func deleteCertificate(_ item: CertificateItem) {
        MUCertificateController.deleteCertificate(withPersistentRef: item.id)
        refreshCertificates()
    }
    
    // --- 新增：导入逻辑 ---
    func importCertificate(from url: URL, password: String) -> Bool {
        guard let data = try? Data(contentsOf: url) else {
            self.importError = "Failed to read file."
            return false
        }

        do {
            // 在 Swift 中，importPKCS12Data(data, password, error) 变成了 importPKCS12Data(_:password:) throws
            let _ = try MUCertificateController.importPKCS12Data(data, password: password)
            refreshCertificates()
            return true
        } catch {
            // 将捕获到的具体错误信息 (例如 "Incorrect password" 或 "Certificate already exists") 显示给用户
            print("Import Error: \(error.localizedDescription)")
            self.importError = error.localizedDescription
            return false
        }
    }
    
    // --- 新增：导出逻辑 ---
    // 返回临时文件的 URL
    func exportCertificate(_ item: CertificateItem, password: String) -> URL? {
        // 调用 OC 方法导出数据
        guard let p12Data = MUCertificateController.exportPKCS12Data(forPersistentRef: item.id, password: password) else {
            return nil
        }
        
        // 写入临时目录
        let fileName = "\(item.name).p12".replacingOccurrences(of: "/", with: "_")
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        
        do {
            try p12Data.write(to: tempURL)
            return tempURL
        } catch {
            print("Export write error: \(error)")
            return nil
        }
    }
}
