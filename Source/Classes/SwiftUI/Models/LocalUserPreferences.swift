//
//  LocalUserPreferences.swift
//  Mumble
//
//  Created by 王梓田 on 1/14/26.
//

import Foundation

@MainActor
final class LocalUserPreferences {
    static let shared = LocalUserPreferences()
    private let defaults = UserDefaults.standard
    
    private func key(for userName: String, on serverHost: String) -> String {
        return "user_pref_\(serverHost)_\(userName)"
    }
    
    // 保存音量和静音状态
    func save(volume: Float, isLocalMuted: Bool, for userName: String, on serverHost: String) {
        let k = key(for: userName, on: serverHost)
        let data: [String: Any] = [
            "volume": volume,
            "isLocalMuted": isLocalMuted
        ]
        defaults.set(data, forKey: k)
    }
    
    // 读取设置，返回 (音量, 是否静音)
    func load(for userName: String, on serverHost: String) -> (volume: Float, isLocalMuted: Bool) {
        let k = key(for: userName, on: serverHost)
        if let data = defaults.dictionary(forKey: k) {
            let volume = data["volume"] as? Float ?? 1.0
            let muted = data["isLocalMuted"] as? Bool ?? false
            return (volume, muted)
        }
        // 默认音量 1.0，默认不屏蔽
        return (1.0, false)
    }
}
