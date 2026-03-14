//
//  ChannelFilterManager.swift
//  Mumble
//

import Foundation

final class ChannelFilterManager: @unchecked Sendable {
    static let shared = ChannelFilterManager()
    
    private let hiddenKeyPrefix = "HiddenChannels_"
    private let pinnedKeyPrefix = "PinnedChannels_"
    
    private init() {}
    
    // MARK: - Hidden Channels
    
    func hideChannel(id: UInt, serverHost: String) {
        var hidden = getHiddenChannels(serverHost: serverHost)
        hidden.insert(id)
        saveHiddenChannels(hidden, serverHost: serverHost)
    }
    
    func unhideChannel(id: UInt, serverHost: String) {
        var hidden = getHiddenChannels(serverHost: serverHost)
        hidden.remove(id)
        saveHiddenChannels(hidden, serverHost: serverHost)
    }
    
    func isHidden(id: UInt, serverHost: String) -> Bool {
        return getHiddenChannels(serverHost: serverHost).contains(id)
    }
    
    func toggleHidden(id: UInt, serverHost: String) {
        if isHidden(id: id, serverHost: serverHost) {
            unhideChannel(id: id, serverHost: serverHost)
        } else {
            hideChannel(id: id, serverHost: serverHost)
        }
    }
    
    func getHiddenChannels(serverHost: String) -> Set<UInt> {
        let key = hiddenKeyPrefix + serverHost
        let array = (UserDefaults.standard.array(forKey: key) as? [NSNumber])?.map { UInt($0.uintValue) } ?? []
        return Set(array)
    }
    
    private func saveHiddenChannels(_ channels: Set<UInt>, serverHost: String) {
        let key = hiddenKeyPrefix + serverHost
        UserDefaults.standard.set(Array(channels), forKey: key)
    }
    
    // MARK: - Pinned Channels
    
    func pinChannel(id: UInt, serverHost: String) {
        var pinned = getPinnedChannels(serverHost: serverHost)
        pinned.insert(id)
        savePinnedChannels(pinned, serverHost: serverHost)
    }
    
    func unpinChannel(id: UInt, serverHost: String) {
        var pinned = getPinnedChannels(serverHost: serverHost)
        pinned.remove(id)
        savePinnedChannels(pinned, serverHost: serverHost)
    }
    
    func isPinned(id: UInt, serverHost: String) -> Bool {
        return getPinnedChannels(serverHost: serverHost).contains(id)
    }
    
    func togglePinned(id: UInt, serverHost: String) {
        if isPinned(id: id, serverHost: serverHost) {
            unpinChannel(id: id, serverHost: serverHost)
        } else {
            pinChannel(id: id, serverHost: serverHost)
        }
    }
    
    func getPinnedChannels(serverHost: String) -> Set<UInt> {
        let key = pinnedKeyPrefix + serverHost
        let array = (UserDefaults.standard.array(forKey: key) as? [NSNumber])?.map { UInt($0.uintValue) } ?? []
        return Set(array)
    }
    
    private func savePinnedChannels(_ channels: Set<UInt>, serverHost: String) {
        let key = pinnedKeyPrefix + serverHost
        UserDefaults.standard.set(Array(channels), forKey: key)
    }
}
