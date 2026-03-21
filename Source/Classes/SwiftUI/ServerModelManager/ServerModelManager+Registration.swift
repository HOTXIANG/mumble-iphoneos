//
//  ServerModelManager+Registration.swift
//  Mumble
//

import SwiftUI

extension ServerModelManager {
    func registerSelf() {
        // 1. 获取当前连接信息
        guard let connectionController = MUConnectionController.shared() else { return }
        guard let serverModel = connectionController.serverModel else { return }
        guard let user = serverModel.connectedUser() else { return }

        // 2. 检查是否已有证书 (通过 MKConnection 检查)
        // 这里我们简化逻辑：既然用户点击了“注册”，我们假设他想为这个服务器创建一个专属身份
        let currentHost = serverModel.hostname() ?? "UnknownHost"
        let userName = user.userName() ?? "User"
        let certName = "\(userName)@\(currentHost)"

        MumbleLogger.model.info("Starting registration flow for \(certName)")

        // 3. 生成新证书
        guard let newCertRef = MUCertificateController.generateSelfSignedCertificate(withName: certName, email: "") else {
            MumbleLogger.certificate.error("Failed to generate certificate during registration")
            return
        }

        DispatchQueue.main.async {
            CertificateModel.shared.refreshCertificates()
        }

        MumbleLogger.certificate.info("Certificate generated. Binding to favourite server")

        DispatchQueue.main.async {
            AppState.shared.isRegistering = true
            AppState.shared.pendingRegistration = true
        }

        // 4. 找到对应的 Favourite Server 条目并更新
        let rawFavs = MUDatabase.fetchAllFavourites() as? [Any] ?? []
        let allFavs = rawFavs.compactMap { $0 as? MUFavouriteServer }

        let currentPort = UInt(serverModel.port())
        let currentUser = user.userName()

        var targetServer: MUFavouriteServer?

        // 尝试匹配：Host + Port + Username (最精确)
        targetServer = allFavs.first {
            $0.hostName == currentHost && $0.port == currentPort && $0.userName == currentUser
        }

        // 如果没找到，尝试匹配：Host + Port (可能是匿名登录进来的)
        if targetServer == nil {
            targetServer = allFavs.first {
                $0.hostName == currentHost && $0.port == currentPort
            }
        }

        AppState.shared.pendingRegistration = true

        if let serverToUpdate = targetServer {
            serverToUpdate.certificateRef = newCertRef
            if serverToUpdate.userName == nil || serverToUpdate.userName!.isEmpty {
                serverToUpdate.userName = userName
            }
            MUDatabase.storeFavourite(serverToUpdate)

            connectionController.disconnectFromServer()

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                connectionController.connect(
                    toHostname: serverToUpdate.hostName,
                    port: UInt(serverToUpdate.port),
                    withUsername: serverToUpdate.userName,
                    andPassword: serverToUpdate.password,
                    certificateRef: serverToUpdate.certificateRef,
                    displayName: serverToUpdate.displayName
                )
            }
        } else {
            // 如果不在收藏夹，新建一个
            // 注意：这里需要 DisplayName，我们还是得从 AppState 取一下作为新建收藏的默认名
            let rawDispName = AppState.shared.serverDisplayName ?? currentHost
            let cleanDispName = rawDispName
                .replacingOccurrences(of: "Optional(\"", with: "")
                .replacingOccurrences(of: "\")", with: "")

            // 强制解包 MUFavouriteServer()! 确保非空
            let newFav = MUFavouriteServer()!
            newFav.hostName = currentHost
            newFav.port = currentPort
            newFav.userName = userName
            newFav.displayName = cleanDispName.isEmpty ? currentHost : cleanDispName
            newFav.certificateRef = newCertRef

            MUDatabase.storeFavourite(newFav)

            connectionController.disconnectFromServer()

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                connectionController.connect(
                    toHostname: newFav.hostName,
                    port: UInt(newFav.port),
                    withUsername: newFav.userName,
                    andPassword: newFav.password,
                    certificateRef: newFav.certificateRef,
                    displayName: newFav.displayName
                )
            }
        }
    }
}
