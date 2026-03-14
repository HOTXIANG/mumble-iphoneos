//
//  FriendsManager.swift
//  Mumble
//

import Foundation

@MainActor
final class FriendsManager: ObservableObject {
    static let shared = FriendsManager()
    
    @Published private(set) var friends: Set<String> = []
    
    private let defaults = UserDefaults.standard
    private let friendsKey = "mumble_friends_hashes"
    
    private init() {
        if let array = defaults.array(forKey: friendsKey) as? [String] {
            friends = Set(array)
        }
    }
    
    func addFriend(userHash: String) {
        friends.insert(userHash)
        save()
    }
    
    func removeFriend(userHash: String) {
        friends.remove(userHash)
        save()
    }
    
    func isFriend(userHash: String?) -> Bool {
        guard let hash = userHash else { return false }
        return friends.contains(hash)
    }
    
    func toggleFriend(userHash: String) {
        if isFriend(userHash: userHash) {
            removeFriend(userHash: userHash)
        } else {
            addFriend(userHash: userHash)
        }
    }
    
    private func save() {
        defaults.set(Array(friends), forKey: friendsKey)
        defaults.synchronize()
    }
}
