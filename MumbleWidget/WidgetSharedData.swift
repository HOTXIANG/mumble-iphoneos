// 文件: WidgetSharedData.swift
// Widget 和主 App 之间共享的数据模型
// 通过 App Group UserDefaults 传递收藏服务器列表

import Foundation
import WidgetKit

// MARK: - App Group 常量

let MumbleAppGroupIdentifier = "group.cn.hotxiang.Mumble"

// MARK: - Widget 服务器数据模型

/// Widget 中展示的服务器信息（轻量级, Codable）
struct WidgetServerItem: Codable, Identifiable, Hashable {
    let id: String           // 唯一标识 (hostname:port:username)
    let displayName: String  // 显示名称
    let hostname: String     // 服务器地址
    let port: Int            // 端口
    let username: String     // 用户名
    let hasCertificate: Bool // 是否有绑定的证书（注册用户）
    let lastConnected: Date? // 最近连接时间 (nil = 从未连接)
    
    /// 用于构造 deep link URL
    var deepLinkURL: URL {
        var components = URLComponents()
        components.scheme = "mumble"
        components.host = hostname
        components.port = port
        components.user = username
        return components.url ?? URL(string: "mumble://\(hostname):\(port)")!
    }
    
    static func makeId(hostname: String, port: Int, username: String) -> String {
        return "\(hostname):\(port):\(username)"
    }
}

// MARK: - Widget 数据管理器

/// 负责在主 App 和 Widget 之间同步服务器数据
/// 两种数据源：
/// - pinned: 用户手动选择「添加到 Widget」的服务器（favourites 模式）
/// - recent: 从 RecentServerManager 自动同步的最近连接（recent 模式）
final class WidgetDataManager: Sendable {
    static let shared = WidgetDataManager()
    
    private let pinnedKey = "widget_pinned_servers"
    private let recentKey = "widget_recent_servers"
    
    private var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: MumbleAppGroupIdentifier)
    }
    
    private init() {}
    
    // MARK: - Pinned Servers (用户手动添加到 Widget 的)
    
    /// 添加一个服务器到 Widget 固定列表
    func pinServer(_ server: WidgetServerItem) {
        var pinned = loadPinnedServers()
        pinned.removeAll { $0.id == server.id }
        pinned.append(server)
        savePinnedServers(pinned)
        WidgetCenter.shared.reloadAllTimelines()
    }
    
    /// 从 Widget 固定列表移除
    func unpinServer(id: String) {
        var pinned = loadPinnedServers()
        pinned.removeAll { $0.id == id }
        savePinnedServers(pinned)
        WidgetCenter.shared.reloadAllTimelines()
    }
    
    /// 检查服务器是否已固定到 Widget
    func isPinned(hostname: String, port: Int, username: String) -> Bool {
        let id = WidgetServerItem.makeId(hostname: hostname, port: port, username: username)
        return loadPinnedServers().contains { $0.id == id }
    }
    
    /// 加载固定的服务器列表
    func loadPinnedServers(limit: Int = 8) -> [WidgetServerItem] {
        guard let defaults = sharedDefaults,
              let data = defaults.data(forKey: pinnedKey) else {
            return []
        }
        let servers = (try? JSONDecoder().decode([WidgetServerItem].self, from: data)) ?? []
        return Array(servers.prefix(limit))
    }
    
    private func savePinnedServers(_ servers: [WidgetServerItem]) {
        guard let defaults = sharedDefaults else { return }
        if let data = try? JSONEncoder().encode(servers) {
            defaults.set(data, forKey: pinnedKey)
            defaults.synchronize()
        }
    }
    
    // MARK: - Recent Servers (从 RecentServerManager 同步)
    
    /// 同步最近连接列表到 Widget
    func syncRecentServers(_ servers: [WidgetServerItem]) {
        guard let defaults = sharedDefaults else { return }
        if let data = try? JSONEncoder().encode(servers) {
            defaults.set(data, forKey: recentKey)
            defaults.synchronize()
        }
        WidgetCenter.shared.reloadAllTimelines()
    }
    
    /// 加载最近连接的服务器
    func loadRecentServers(limit: Int = 4) -> [WidgetServerItem] {
        guard let defaults = sharedDefaults,
              let data = defaults.data(forKey: recentKey) else {
            return []
        }
        let servers = (try? JSONDecoder().decode([WidgetServerItem].self, from: data)) ?? []
        return Array(servers.prefix(limit))
    }
    
    /// 通知 Widget 刷新
    func reloadWidgets() {
        WidgetCenter.shared.reloadAllTimelines()
    }
}
