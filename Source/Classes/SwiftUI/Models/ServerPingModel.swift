//
//  ServerPingModel.swift
//  Mumble
//
//  Created by 王梓田 on 12/9/25.
//

import SwiftUI
import Combine

// 必须继承 NSObject 才能作为 ObjC 的 Delegate
@MainActor
class ServerPingModel: NSObject, ObservableObject, MKServerPingerDelegate {
    @Published var pingLabel: String = "..."
    @Published var usersLabel: String = ""
    @Published var pingColor: Color = .gray
    @Published var userCountColor: Color = .secondary
    
    private var pinger: MKServerPinger?
    private let hostname: String
    private let port: UInt
    
    init(hostname: String, port: UInt) {
        self.hostname = hostname
        self.port = port
        super.init()
    }
    
    func startPinging() {
        guard !hostname.isEmpty else { return }
        // 停止之前的（如果有）
        stopPinging()
        
        // 创建底层 Pinger
        let pingerInstance = MKServerPinger(hostname: hostname, port: String(port))
        pingerInstance?.setDelegate(self)
        self.pinger = pingerInstance
    }
    
    func stopPinging() {
        pinger?.setDelegate(nil)
        pinger = nil
    }
    
    // MARK: - MKServerPingerDelegate
    
    @objc nonisolated func serverPingerResult(_ result: UnsafeMutablePointer<MKServerPingerResult>!) {
        // 3. 立即解包并提取值类型数据 (Data Copy)
        guard let res = result?.pointee else { return }
        
        // 提取数据 (这时它们是 Double 和 UInt32)
        let pingValue = res.ping
        let curUsers = res.cur_users
        let maxUsers = res.max_users

        Task { @MainActor in
            self.updateUI(ping: pingValue, cur: curUsers, max: maxUsers)
        }
    }
    
    // 专门用于更新 UI 的私有方法 (运行在 @MainActor)
    private func updateUI(ping: Double, cur: UInt32, max: UInt32) {
        // 1. 处理延迟 (Ping)
        let pingMs = Int(ping * 1000)
        self.pingLabel = "\(pingMs) ms"
        
        if pingMs <= 125 {
            self.pingColor = .green
        } else if pingMs <= 250 {
            self.pingColor = .yellow
        } else {
            self.pingColor = .red
        }
        
        // 2. 处理人数
        self.usersLabel = "\(cur)/\(max)"
        
        if cur >= max && max > 0 {
            self.userCountColor = .red
        } else {
            self.userCountColor = .secondary
        }
    }
}
