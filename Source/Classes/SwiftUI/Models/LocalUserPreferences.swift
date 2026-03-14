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
        MumbleLogger.model.debug("Saved local audio prefs for \(userName)")
    }
    
    func load(for userName: String, on serverHost: String) -> (volume: Float, isLocalMuted: Bool) {
        let k = key(for: userName, on: serverHost)
        if let data = defaults.dictionary(forKey: k) {
            let volume = data["volume"] as? Float ?? 1.0
            let muted = data["isLocalMuted"] as? Bool ?? false
            MumbleLogger.model.debug("Loaded local audio prefs for \(userName)")
            return (volume, muted)
        }
        return (1.0, false)
    }
    
    // MARK: - Local Nickname

    private func nicknameKey(for userHash: String?, userName: String, on serverHost: String) -> String {
        let identifier = userHash ?? userName
        return "user_nickname_\(serverHost)_\(identifier)"
    }
    
    func saveNickname(_ nickname: String?, for userHash: String?, userName: String, on serverHost: String) {
        let k = nicknameKey(for: userHash, userName: userName, on: serverHost)
        if let nickname = nickname, !nickname.isEmpty {
            defaults.set(nickname, forKey: k)
        } else {
            defaults.removeObject(forKey: k)
        }
        defaults.synchronize()
        MumbleLogger.model.debug("Saved local nickname for \(userName)")
    }
    
    func loadNickname(for userHash: String?, userName: String, on serverHost: String) -> String? {
        let k = nicknameKey(for: userHash, userName: userName, on: serverHost)
        return defaults.string(forKey: k)
    }
}
