//
//  RecentServerManager.swift
//  Mumble
//
//  Created by 王梓田 on 12/9/25.
//

import Foundation

struct RecentServer: Identifiable, Codable, Equatable {
    var id: String { "\(hostname):\(port)" } // 唯一标识
    let displayName: String
    let hostname: String
    let port: Int
    let username: String
}

@objc @MainActor
class RecentServerManager: NSObject, ObservableObject {
    @objc static let shared = RecentServerManager()
    
    @Published var recents: [RecentServer] = []
    
    private let storageKey = "MumbleRecentServers"
    private let maxRecents = 10 // 只保留最近10个
    
    override init() {
        super.init()
        loadRecents()
    }
    
    @objc func addRecent(hostname: String, port: Int, username: String, displayName: String?) {
        // 1. 确定要保存的名字
        // 如果传入了有效的 displayName，就用它；否则用 hostname
        let nameToSave = (displayName?.isEmpty == false) ? displayName! : hostname
        
        let newEntry = RecentServer(
            displayName: nameToSave,
            hostname: hostname,
            port: port,
            username: username
        )
        
        // 2. 如果已存在，先删除旧的
        // 这样不仅能把服务器移到顶部，还能确保我们保存了最新的名字 (nameToSave)
        recents.removeAll { $0.id == newEntry.id }
        
        // 3. 插入新的（包含最新名字的）记录到头部
        recents.insert(newEntry, at: 0)
        
        // 4. 限制数量
        if recents.count > maxRecents {
            recents = Array(recents.prefix(maxRecents))
        }
        
        saveRecents()
    }
    
    @objc func getDisplayName(hostname: String, port: Int) -> String? {
        // 1. 遍历最近列表查找匹配项
        if let match = recents.first(where: { $0.hostname == hostname && $0.port == port }) {
            return match.displayName
        }
        return nil
    }
    
    private func saveRecents() {
        if let data = try? JSONEncoder().encode(recents) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
    
    private func loadRecents() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let list = try? JSONDecoder().decode([RecentServer].self, from: data) {
            recents = list
        }
    }
}
