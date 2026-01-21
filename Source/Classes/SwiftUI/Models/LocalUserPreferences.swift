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
    
    func save(volume: Float, isLocalMuted: Bool, for userName: String, on serverHost: String) {
        let k = key(for: userName, on: serverHost)
        let data: [String: Any] = [
            "volume": volume,
            "isLocalMuted": isLocalMuted
        ]
        defaults.set(data, forKey: k)
        defaults.synchronize() // 强制写入，防止意外丢失
        print("💾 Saved Prefs for [\(userName)]: Vol=\(volume), Mute=\(isLocalMuted)")
    }
    
    func load(for userName: String, on serverHost: String) -> (volume: Float, isLocalMuted: Bool) {
        let k = key(for: userName, on: serverHost)
        if let data = defaults.dictionary(forKey: k) {
            let volume = data["volume"] as? Float ?? 1.0
            let muted = data["isLocalMuted"] as? Bool ?? false
            print("📖 Loaded Prefs for [\(userName)]: Vol=\(volume)")
            return (volume, muted)
        }
        return (1.0, false)
    }
}
