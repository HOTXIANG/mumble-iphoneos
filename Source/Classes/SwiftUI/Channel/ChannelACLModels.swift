//
//  ChannelACLModels.swift
//  Mumble
//

import SwiftUI

// MARK: - Permission Definition

/// 将 MKPermission 的位标志映射到可读名称
struct PermissionItem: Identifiable {
    let id: MKPermission
    let name: String
    let icon: String

    /// 对于 ACL 编辑中可选的所有权限类型
    static let allPermissions: [PermissionItem] = [
        PermissionItem(id: MKPermissionWrite, name: "Write", icon: "pencil"),
        PermissionItem(id: MKPermissionTraverse, name: "Traverse", icon: "arrow.triangle.branch"),
        PermissionItem(id: MKPermissionEnter, name: "Enter", icon: "arrow.right.to.line"),
        PermissionItem(id: MKPermissionSpeak, name: "Speak", icon: "mic"),
        PermissionItem(id: MKPermissionMuteDeafen, name: "Mute/Deafen", icon: "mic.slash"),
        PermissionItem(id: MKPermissionMove, name: "Move", icon: "arrow.left.arrow.right"),
        PermissionItem(id: MKPermissionMakeChannel, name: "Make Channel", icon: "plus.rectangle"),
        PermissionItem(id: MKPermissionLinkChannel, name: "Link Channel", icon: "link"),
        PermissionItem(id: MKPermissionWhisper, name: "Whisper", icon: "ear"),
        PermissionItem(id: MKPermissionTextMessage, name: "Text Message", icon: "text.bubble"),
        PermissionItem(id: MKPermissionMakeTempChannel, name: "Make Temp Channel", icon: "clock"),
        PermissionItem(id: MKPermissionKick, name: "Kick", icon: "xmark.circle"),
        PermissionItem(id: MKPermissionBan, name: "Ban", icon: "nosign"),
        PermissionItem(id: MKPermissionRegister, name: "Register", icon: "person.badge.plus"),
        PermissionItem(id: MKPermissionSelfRegister, name: "Self-Register", icon: "person.crop.circle.badge.checkmark"),
    ]
}

// MARK: - ACL Entry Model (SwiftUI-friendly wrapper)

/// SwiftUI 友好的 ACL 条目包装
class ACLEntryModel: ObservableObject, Identifiable {
    let id = UUID()
    @Published var applyHere: Bool
    @Published var applySubs: Bool
    @Published var isInherited: Bool
    @Published var userID: Int  // -1 表示基于组
    @Published var group: String
    @Published var grant: UInt32
    @Published var deny: UInt32

    var isGroupBased: Bool { userID < 0 }

    var displayName: String {
        if isGroupBased {
            return "@\(group)"
        } else {
            return "User #\(userID)"
        }
    }

    init(from acl: MKChannelACL) {
        self.applyHere = acl.applyHere
        self.applySubs = acl.applySubs
        self.isInherited = acl.inherited
        self.userID = Int(acl.userID)
        self.group = acl.group ?? ""
        self.grant = UInt32(acl.grant.rawValue)
        self.deny = UInt32(acl.deny.rawValue)
    }

    init() {
        self.applyHere = true
        self.applySubs = true
        self.isInherited = false
        self.userID = -1
        self.group = "all"
        self.grant = 0
        self.deny = 0
    }

    /// 创建一个可编辑副本（用于弹窗草稿）
    func clone() -> ACLEntryModel {
        let copy = ACLEntryModel()
        copy.applyHere = applyHere
        copy.applySubs = applySubs
        copy.isInherited = isInherited
        copy.userID = userID
        copy.group = group
        copy.grant = grant
        copy.deny = deny
        return copy
    }

    /// 将草稿内容回写到当前对象（保留原对象 identity）
    func apply(from draft: ACLEntryModel) {
        applyHere = draft.applyHere
        applySubs = draft.applySubs
        isInherited = draft.isInherited
        userID = draft.userID
        group = draft.group
        grant = draft.grant
        deny = draft.deny
    }

    func toMKChannelACL() -> MKChannelACL {
        let acl = MKChannelACL()
        acl.applyHere = applyHere
        acl.applySubs = applySubs
        acl.inherited = isInherited
        acl.userID = NSInteger(userID)
        acl.group = isGroupBased ? group : nil
        acl.grant = MKPermission(rawValue: grant)
        acl.deny = MKPermission(rawValue: deny)
        return acl
    }

    /// 检查某个权限是否被 grant
    func isGranted(_ perm: MKPermission) -> Bool {
        return (grant & UInt32(perm.rawValue)) != 0
    }

    /// 检查某个权限是否被 deny
    func isDenied(_ perm: MKPermission) -> Bool {
        return (deny & UInt32(perm.rawValue)) != 0
    }

    /// 设置权限状态：grant / deny / unset
    func setPermission(_ perm: MKPermission, state: PermissionState) {
        let mask = UInt32(perm.rawValue)
        switch state {
        case .granted:
            grant |= mask
            deny &= ~mask
        case .denied:
            grant &= ~mask
            deny |= mask
        case .unset:
            grant &= ~mask
            deny &= ~mask
        }
        objectWillChange.send()
    }

    func permissionState(for perm: MKPermission) -> PermissionState {
        if isGranted(perm) { return .granted }
        if isDenied(perm) { return .denied }
        return .unset
    }
}

enum PermissionState: String, CaseIterable {
    case granted = "Allow"
    case denied = "Deny"
    case unset = "Unset"

    var color: Color {
        switch self {
        case .granted: return .green
        case .denied: return .red
        case .unset: return .secondary
        }
    }

    var icon: String {
        switch self {
        case .granted: return "checkmark.circle.fill"
        case .denied: return "xmark.circle.fill"
        case .unset: return "minus.circle"
        }
    }
}

// MARK: - Group Entry Model

class GroupEntryModel: ObservableObject, Identifiable {
    let id = UUID()
    @Published var name: String
    @Published var isInherited: Bool
    @Published var inherit: Bool
    @Published var inheritable: Bool
    @Published var members: [Int]
    @Published var excludedMembers: [Int]
    @Published var inheritedMembers: [Int]

    init(from group: MKChannelGroup) {
        self.name = group.name ?? ""
        self.isInherited = group.inherited
        self.inherit = group.inherit
        self.inheritable = group.inheritable
        self.members = (group.members as? [NSNumber])?.map { $0.intValue } ?? []
        self.excludedMembers = (group.excludedMembers as? [NSNumber])?.map { $0.intValue } ?? []
        self.inheritedMembers = (group.inheritedMembers as? [NSNumber])?.map { $0.intValue } ?? []
    }

    init() {
        self.name = ""
        self.isInherited = false
        self.inherit = true
        self.inheritable = true
        self.members = []
        self.excludedMembers = []
        self.inheritedMembers = []
    }

    /// 创建一个可编辑副本（用于弹窗草稿）
    func clone() -> GroupEntryModel {
        let copy = GroupEntryModel()
        copy.name = name
        copy.isInherited = isInherited
        copy.inherit = inherit
        copy.inheritable = inheritable
        copy.members = members
        copy.excludedMembers = excludedMembers
        copy.inheritedMembers = inheritedMembers
        return copy
    }

    /// 将草稿内容回写到当前对象（保留原对象 identity）
    func apply(from draft: GroupEntryModel) {
        name = draft.name
        isInherited = draft.isInherited
        inherit = draft.inherit
        inheritable = draft.inheritable
        members = draft.members
        excludedMembers = draft.excludedMembers
        inheritedMembers = draft.inheritedMembers
    }

    func toMKChannelGroup() -> MKChannelGroup {
        let group = MKChannelGroup()
        group.name = name
        group.inherited = isInherited
        group.inherit = inherit
        group.inheritable = inheritable
        group.members = NSMutableArray(array: members.map { NSNumber(value: $0) })
        group.excludedMembers = NSMutableArray(array: excludedMembers.map { NSNumber(value: $0) })
        group.inheritedMembers = NSMutableArray(array: inheritedMembers.map { NSNumber(value: $0) })
        return group
    }
}
