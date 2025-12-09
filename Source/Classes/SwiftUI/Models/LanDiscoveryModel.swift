//
//  LanDiscoveryModel.swift
//  Mumble
//
//  Created by 王梓田 on 12/9/25.
//

import SwiftUI
import Network

struct DiscoveredServer: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let hostname: String
    let port: Int
}

private struct SendableService: @unchecked Sendable {
    let service: NetService
}

@MainActor
class LanDiscoveryModel: NSObject, ObservableObject, NetServiceBrowserDelegate, NetServiceDelegate {
    @Published var servers: [DiscoveredServer] = []
    
    private var netServiceBrowser = NetServiceBrowser()
    private var pendingServices: [NetService] = []
    
    override init() {
        super.init()
        netServiceBrowser.delegate = self
        // Mumble 使用 _mumble._tcp 服务类型
        netServiceBrowser.searchForServices(ofType: "_mumble._tcp.", inDomain: "local.")
    }
    
    func start() {
        netServiceBrowser.stop()
        servers.removeAll()
        netServiceBrowser.searchForServices(ofType: "_mumble._tcp.", inDomain: "local.")
    }
    
    func stop() {
        netServiceBrowser.stop()
        pendingServices.removeAll()
    }
    
    // MARK: - NetServiceBrowserDelegate
    
    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        // 使用包装器包裹 service
        let safeService = SendableService(service: service)
        
        Task { @MainActor in
            // 解包使用
            let srv = safeService.service
            
            // 需要解析服务以获取 IP 和端口
            self.pendingServices.append(srv)
            srv.delegate = self
            srv.resolve(withTimeout: 5.0)
        }
    }
    
    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        // 使用包装器包裹 service
        let safeService = SendableService(service: service)
        
        Task { @MainActor in
            let srv = safeService.service
            self.servers.removeAll { $0.name == srv.name }
        }
    }
    
    // MARK: - NetServiceDelegate
    
    nonisolated func netService(_ sender: NetService, didNotResolve errorDict: [String : NSNumber]) {
        // 解析失败，忽略
    }
    
    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        // 对于 resolve，我们需要先提取值类型数据，再包裹 sender
        // 提取值类型（String, Int 是 Sendable 的，可以直接传）
        let hostName = sender.hostName
        let port = sender.port
        let name = sender.name
        
        // 包裹 sender 用于后续的移除操作
        let safeSender = SendableService(service: sender)
        
        Task { @MainActor in
            guard let host = hostName else { return }
            
            // 避免重复添加
            if !self.servers.contains(where: { $0.name == name }) {
                let newServer = DiscoveredServer(name: name, hostname: host, port: port)
                self.servers.append(newServer)
            }
            
            // 解析完成后，不再持有该 service 引用
            let srv = safeSender.service
            if let index = self.pendingServices.firstIndex(of: srv) {
                self.pendingServices.remove(at: index)
            }
        }
    }
}
