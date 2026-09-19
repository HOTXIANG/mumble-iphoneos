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
    
    nonisolated(unsafe) private var pinger: MKServerPinger?
    private var startTask: Task<Void, Never>?
    private var pingGeneration: UUID?
    let hostname: String
    let port: UInt
    
    init(hostname: String, port: UInt) {
        self.hostname = hostname
        self.port = port
        super.init()
    }

    deinit {
        startTask?.cancel()
        pinger?.stop()
    }
    
    func startPinging() {
        guard !hostname.isEmpty, pingGeneration == nil else { return }
        MumbleLogger.network.debug("Start pinging \(hostname):\(port)")
        let generation = UUID()
        pingGeneration = generation

        // 关键：MKServerPinger 的 init 会同步 getaddrinfo，可能阻塞主线程。
        // 这里把创建挪到后台，创建完成后再回到 MainActor 绑定 delegate。
        let host = hostname
        let portString = String(port)
        startTask = Task.detached(priority: .utility) { [weak self] in
            guard !Task.isCancelled else { return }
            // DNS 完成不等于页面仍在。先创建未启动实例，验证本轮仍有效后才发包。
            let created = MKServerPinger(hostname: host, port: portString, startImmediately: false)

            await MainActor.run { [weak self] in
                guard let self, self.pingGeneration == generation, !Task.isCancelled else {
                    created?.stop()
                    return
                }
                self.startTask = nil
                created?.setDelegate(self)
                self.pinger = created
                created?.start()
            }
        }
    }
    
    func stopPinging() {
        pingGeneration = nil
        MumbleLogger.network.debug("Stop pinging \(hostname):\(port)")
        startTask?.cancel()
        startTask = nil
        pinger?.stop()
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

        // MKServerPinger 在主队列同步通知；不要再排一个可能跨越退出/重入的 UI 任务。
        MainActor.assumeIsolated {
            guard self.pingGeneration != nil, self.pinger != nil else { return }
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
