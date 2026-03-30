//
//  IgnoreManager.swift
//  Mumble
//

import Foundation

@MainActor
final class IgnoreManager: ObservableObject {
    static let shared = IgnoreManager()
    
    @Published private(set) var ignoredHashes: Set<String> = []
    
    private let defaults = UserDefaults.standard
    private let ignoreKey = "mumble_ignored_hashes"
    
    private init() {
        if let array = defaults.array(forKey: ignoreKey) as? [String] {
            ignoredHashes = Set(array)
        }
    }
    
    func ignoreUser(userHash: String) {
        MumbleLogger.model.info("Ignoring user: \(userHash.prefix(8))...")
        ignoredHashes.insert(userHash)
        save()
    }

    func unignoreUser(userHash: String) {
        MumbleLogger.model.info("Unignoring user: \(userHash.prefix(8))...")
        ignoredHashes.remove(userHash)
        save()
    }
    
    func isIgnored(userHash: String?) -> Bool {
        guard let hash = userHash else { return false }
        return ignoredHashes.contains(hash)
    }
    
    func toggleIgnore(userHash: String) {
        if isIgnored(userHash: userHash) {
            unignoreUser(userHash: userHash)
        } else {
            ignoreUser(userHash: userHash)
        }
    }
    
    private func save() {
        defaults.set(Array(ignoredHashes), forKey: ignoreKey)
        defaults.synchronize()
    }
}
