//
//  ChannelACLView.swift
//  Mumble
//
//  ACL (Access Control List) management view for channels.
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

// MARK: - Channel ACL View

struct ChannelACLView: View {
    let channel: MKChannel
    @ObservedObject var serverManager: ServerModelManager
    
    @State private var inheritACLs: Bool = true
    @State private var aclEntries: [ACLEntryModel] = []
    @State private var groupEntries: [GroupEntryModel] = []
    @State private var isLoading: Bool = true
    @State private var selectedTab: ACLTab = .acls
    @State private var aclDraftEntry: ACLEntryModel? = nil
    @State private var groupDraftEntry: GroupEntryModel? = nil
    @State private var editingACLIndex: Int? = nil
    @State private var editingGroupIndex: Int? = nil
    @Environment(\.dismiss) var dismiss
    
    enum ACLTab: String, CaseIterable {
        case acls = "ACLs"
        case groups = "Groups"
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 继承 ACL 开关
                inheritToggle
                
                // Tab 选择
                Picker("View", selection: $selectedTab) {
                    ForEach(ACLTab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)
                
                Divider()
                
                // 内容区域
                switch selectedTab {
                case .acls:
                    aclListView
                case .groups:
                    groupListView
                }
            }
            #if os(macOS)
            .frame(minWidth: 500, minHeight: 450)
            #endif
            .navigationTitle("ACL - \(channel.channelName() ?? "Channel")")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveACL() }
                }
            }
            .sheet(item: $aclDraftEntry) { draft in
                ACLEntryEditView(entry: draft, serverManager: serverManager) {
                    commitACLEntryDraft()
                }
            }
            .sheet(item: $groupDraftEntry) { draft in
                GroupEntryEditView(entry: draft, serverManager: serverManager) {
                    commitGroupEntryDraft()
                }
            }
        }
        .onAppear { loadACL() }
        .onReceive(NotificationCenter.default.publisher(for: ServerModelNotificationManager.aclReceivedNotification)) { notification in
            guard let userInfo = notification.userInfo,
                  let accessControl = userInfo["accessControl"] as? MKAccessControl,
                  let chan = userInfo["channel"] as? MKChannel,
                  chan.channelId() == channel.channelId() else { return }
            
            parseAccessControl(accessControl)
        }
    }
    
    // MARK: - Subviews
    
    private var inheritToggle: some View {
        HStack {
            Image(systemName: "arrow.down.circle")
                .foregroundColor(.accentColor)
            Toggle("Inherit ACLs from parent", isOn: $inheritACLs)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }
    
    private var aclListView: some View {
        List {
            if isLoading {
                ProgressView("Loading ACLs...")
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            } else if aclEntries.isEmpty {
                Text("No ACL entries")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            } else {
                ForEach(aclEntries) { entry in
                    ACLEntryRow(
                        entry: entry,
                        resolvedUserName: entry.isGroupBased ? nil : serverManager.aclUserDisplayName(for: entry.userID)
                    )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if !entry.isInherited {
                                beginEditACLEntry(entry)
                            }
                        }
                        .opacity(entry.isInherited ? 0.6 : 1.0)
                }
                .onDelete { offsets in
                    // 只允许删除非继承的条目
                    let nonInheritedOffsets = offsets.filter { !aclEntries[$0].isInherited }
                    aclEntries.remove(atOffsets: IndexSet(nonInheritedOffsets))
                }
            }
            
            Section {
                Button {
                    beginAddACLEntry()
                } label: {
                    Label("Add ACL Entry", systemImage: "plus.circle")
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
    }
    
    private var groupListView: some View {
        List {
            if isLoading {
                ProgressView("Loading Groups...")
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            } else if groupEntries.isEmpty {
                Text("No group entries")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            } else {
                ForEach(groupEntries) { entry in
                    GroupEntryRow(entry: entry)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if !entry.isInherited {
                                beginEditGroupEntry(entry)
                            }
                        }
                        .opacity(entry.isInherited ? 0.6 : 1.0)
                }
                .onDelete { offsets in
                    let nonInheritedOffsets = offsets.filter { !groupEntries[$0].isInherited }
                    groupEntries.remove(atOffsets: IndexSet(nonInheritedOffsets))
                }
            }
            
            Section {
                Button {
                    beginAddGroupEntry()
                } label: {
                    Label("Add Group", systemImage: "plus.circle")
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
    }
    
    // MARK: - Actions
    
    private func loadACL() {
        isLoading = true
        serverManager.requestACL(for: channel)
    }
    
    private func parseAccessControl(_ accessControl: MKAccessControl) {
        inheritACLs = accessControl.inheritACLs
        
        aclEntries = (accessControl.acls as? [MKChannelACL])?.map { ACLEntryModel(from: $0) } ?? []
        groupEntries = (accessControl.groups as? [MKChannelGroup])?.map { GroupEntryModel(from: $0) } ?? []
        requestUserNamesForCurrentACL()
        
        isLoading = false
    }

    private func requestUserNamesForCurrentACL() {
        var ids: Set<Int> = []
        for acl in aclEntries where !acl.isGroupBased && acl.userID >= 0 {
            ids.insert(acl.userID)
        }
        for group in groupEntries {
            ids.formUnion(group.members.filter { $0 >= 0 })
            ids.formUnion(group.excludedMembers.filter { $0 >= 0 })
            ids.formUnion(group.inheritedMembers.filter { $0 >= 0 })
        }
        serverManager.requestACLUserNames(for: Array(ids))
    }
    
    private func saveACL() {
        let accessControl = MKAccessControl()
        accessControl.inheritACLs = inheritACLs
        
        let aclArray = NSMutableArray()
        for entry in aclEntries {
            aclArray.add(entry.toMKChannelACL())
        }
        accessControl.acls = aclArray
        
        let groupArray = NSMutableArray()
        for entry in groupEntries {
            groupArray.add(entry.toMKChannelGroup())
        }
        accessControl.groups = groupArray
        
        serverManager.setACL(accessControl, for: channel)
        dismiss()
    }
    
    private func beginAddACLEntry() {
        editingACLIndex = nil
        aclDraftEntry = ACLEntryModel()
    }

    private func beginEditACLEntry(_ entry: ACLEntryModel) {
        editingACLIndex = aclEntries.firstIndex(where: { $0.id == entry.id })
        aclDraftEntry = entry.clone()
    }

    private func commitACLEntryDraft() {
        guard let draft = aclDraftEntry else { return }
        if let index = editingACLIndex, aclEntries.indices.contains(index) {
            aclEntries[index].apply(from: draft)
        } else {
            aclEntries.append(draft)
        }
        editingACLIndex = nil
    }

    private func beginAddGroupEntry() {
        editingGroupIndex = nil
        groupDraftEntry = GroupEntryModel()
    }

    private func beginEditGroupEntry(_ entry: GroupEntryModel) {
        editingGroupIndex = groupEntries.firstIndex(where: { $0.id == entry.id })
        groupDraftEntry = entry.clone()
    }

    private func commitGroupEntryDraft() {
        guard let draft = groupDraftEntry else { return }
        if let index = editingGroupIndex, groupEntries.indices.contains(index) {
            groupEntries[index].apply(from: draft)
        } else {
            groupEntries.append(draft)
        }
        editingGroupIndex = nil
    }
}

// MARK: - ACL Entry Row

struct ACLEntryRow: View {
    @ObservedObject var entry: ACLEntryModel
    var resolvedUserName: String? = nil

    private var titleText: String {
        if entry.isGroupBased {
            return "@\(entry.group)"
        }
        if let name = resolvedUserName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        return "User #\(entry.userID)"
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: entry.isGroupBased ? "person.3" : "person")
                    .foregroundColor(entry.isInherited ? .secondary : .accentColor)
                    .frame(width: 20)
                
                Text(titleText)
                    .font(.headline)
                
                Spacer()
                
                if entry.isInherited {
                    Text("Inherited")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15))
                        .cornerRadius(4)
                }
            }
            
            HStack(spacing: 12) {
                if entry.applyHere {
                    Label("Here", systemImage: "checkmark")
                        .font(.caption)
                        .foregroundColor(.blue)
                }
                if entry.applySubs {
                    Label("Subs", systemImage: "checkmark")
                        .font(.caption)
                        .foregroundColor(.purple)
                }
                
                Spacer()
                
                // 简要显示 grant/deny 数量
                let grantCount = countBits(entry.grant)
                let denyCount = countBits(entry.deny)
                
                if grantCount > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.caption)
                        Text("\(grantCount)")
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                }
                
                if denyCount > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.red)
                            .font(.caption)
                        Text("\(denyCount)")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
    
    private func countBits(_ value: UInt32) -> Int {
        var count = 0
        var v = value
        while v != 0 {
            count += Int(v & 1)
            v >>= 1
        }
        return count
    }
}

// MARK: - Group Entry Row

struct GroupEntryRow: View {
    @ObservedObject var entry: GroupEntryModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "person.3.fill")
                    .foregroundColor(entry.isInherited ? .secondary : .accentColor)
                    .frame(width: 20)
                
                Text(entry.name)
                    .font(.headline)
                
                Spacer()
                
                if entry.isInherited {
                    Text("Inherited")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15))
                        .cornerRadius(4)
                }
            }
            
            HStack(spacing: 12) {
                if entry.inherit {
                    Label("Inherit", systemImage: "arrow.down")
                        .font(.caption)
                        .foregroundColor(.blue)
                }
                if entry.inheritable {
                    Label("Inheritable", systemImage: "arrow.up")
                        .font(.caption)
                        .foregroundColor(.purple)
                }
                
                Spacer()
                
                Text("\(entry.members.count) members")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                if !entry.inheritedMembers.isEmpty {
                    Text("+\(entry.inheritedMembers.count) inherited")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - ACL Entry Edit View

struct ACLEntryEditView: View {
    @ObservedObject var entry: ACLEntryModel
    @ObservedObject var serverManager: ServerModelManager
    var onSave: () -> Void
    @Environment(\.dismiss) var dismiss
    
    /// 预定义的 Mumble 内置组
    static let builtInGroups = ["all", "auth", "in", "out", "admin", "sub", "~sub"]
    
    @State private var userSearchText: String = ""
    @State private var userSearchError: String? = nil
    @State private var lastSelectedUserID: Int = 0
    @State private var lastSelectedGroup: String = "all"
    
    /// 在线已注册用户列表
    private var registeredOnlineUsers: [(name: String, userId: Int)] {
        var users: [(name: String, userId: Int)] = []
        for item in serverManager.modelItems {
            if item.type == .user, let user = item.object as? MKUser {
                let regId = Int(user.userId())
                if regId >= 0, let name = user.userName() {
                    users.append((name: name, userId: regId))
                }
            }
        }
        return users.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    
    /// 根据用户名或 User ID 字符串解析出注册 User ID
    private func resolveUserId(from input: String) -> Int? {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        if let numericId = Int(trimmed) { return numericId }
        for item in serverManager.modelItems {
            if item.type == .user, let user = item.object as? MKUser {
                if let name = user.userName(),
                   name.caseInsensitiveCompare(trimmed) == .orderedSame {
                    let regId = Int(user.userId())
                    return regId >= 0 ? regId : nil
                }
            }
        }
        return nil
    }
    
    /// 判断用户名是否匹配到了未注册用户
    private func isUnregisteredUser(_ input: String) -> Bool {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        for item in serverManager.modelItems {
            if item.type == .user, let user = item.object as? MKUser {
                if let name = user.userName(),
                   name.caseInsensitiveCompare(trimmed) == .orderedSame {
                    return Int(user.userId()) < 0
                }
            }
        }
        return false
    }
    
    private func applyUserSearch() {
        userSearchError = nil
        let trimmed = userSearchText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        
        if let userId = resolveUserId(from: trimmed) {
            entry.userID = userId
            lastSelectedUserID = userId
            userSearchText = ""
        } else if isUnregisteredUser(trimmed) {
            userSearchError = "'\(trimmed)' is not a registered user."
        } else {
            userSearchError = "User '\(trimmed)' not found online. Enter a numeric User ID for offline users."
        }
    }

    private func switchTargetMode(toGroup: Bool) {
        if toGroup {
            if entry.userID >= 0 {
                lastSelectedUserID = entry.userID
            }
            let trimmedGroup = entry.group.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedGroup.isEmpty {
                lastSelectedGroup = trimmedGroup
            }
            entry.userID = -1
            entry.group = lastSelectedGroup.isEmpty ? "all" : lastSelectedGroup
        } else {
            let trimmedGroup = entry.group.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedGroup.isEmpty {
                lastSelectedGroup = trimmedGroup
            }
            entry.userID = max(lastSelectedUserID, 0)
            // 切到 User ID 时不清空 group，保证切回时内容仍在
        }
    }
    
    /// 根据 User ID 查找显示名称
    private func userDisplayName(for userId: Int) -> String {
        return serverManager.aclUserDisplayName(for: userId)
    }
    
    var body: some View {
        NavigationStack {
            Form {
                // 目标类型
                Section(header: Text("Target")) {
                    Picker("Type", selection: Binding(
                        get: { entry.isGroupBased },
                        set: { isGroup in
                            // 避免在 View 更新周期内直接发布 ObservableObject 变更
                            DispatchQueue.main.async {
                                self.switchTargetMode(toGroup: isGroup)
                            }
                        }
                    )) {
                        Text("Group").tag(true)
                        Text("User ID").tag(false)
                    }
                    .pickerStyle(.segmented)
                    
                    if entry.isGroupBased {
                        #if os(macOS)
                        HStack {
                            Text("Group")
                            Spacer()
                            Picker("", selection: $entry.group) {
                                ForEach(Self.builtInGroups, id: \.self) { group in
                                    Text(group).tag(group)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(maxWidth: 200)
                        }
                        #else
                        Picker("Group", selection: $entry.group) {
                            ForEach(Self.builtInGroups, id: \.self) { group in
                                Text(group).tag(group)
                            }
                        }
                        #endif
                        
                        TextField("Or enter custom group", text: $entry.group)
                            #if os(macOS)
                            .textFieldStyle(.roundedBorder)
                            #endif
                    } else {
                        // 当前选中的用户
                        if entry.userID >= 0 {
                            HStack {
                                Image(systemName: "person.fill")
                                    .foregroundColor(.accentColor)
                                Text(userDisplayName(for: entry.userID))
                                Spacer()
                                Text("ID: \(entry.userID)")
                                    .foregroundColor(.secondary)
                                    .font(.caption)
                            }
                        }
                        
                        // 搜索框
                        HStack {
                            TextField("Username or User ID", text: $userSearchText)
                                .onSubmit { applyUserSearch() }
                                #if os(macOS)
                                .textFieldStyle(.roundedBorder)
                                #endif
                            Button {
                                applyUserSearch()
                            } label: {
                                Image(systemName: "magnifyingglass.circle.fill")
                            }
                            .disabled(userSearchText.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        
                        if let error = userSearchError {
                            Text(error)
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                        
                        // 在线已注册用户快捷选择
                        if !registeredOnlineUsers.isEmpty {
                            DisclosureGroup("Online Registered Users") {
                                ForEach(registeredOnlineUsers, id: \.userId) { info in
                                    Button {
                                        entry.userID = info.userId
                                        lastSelectedUserID = info.userId
                                    } label: {
                                        HStack {
                                            Image(systemName: "person.fill")
                                                .foregroundColor(.accentColor)
                                            Text(info.name)
                                            Spacer()
                                            Text("ID: \(info.userId)")
                                                .foregroundColor(.secondary)
                                                .font(.caption)
                                            if entry.userID == info.userId {
                                                Image(systemName: "checkmark")
                                                    .foregroundColor(.green)
                                            }
                                        }
                                    }
                                    .foregroundColor(.primary)
                                }
                            }
                        }
                    }
                }
                
                // 应用范围
                Section(header: Text("Scope")) {
                    Toggle("Apply to this channel", isOn: $entry.applyHere)
                    Toggle("Apply to sub-channels", isOn: $entry.applySubs)
                }
                
                // 权限矩阵
                Section(header: Text("Permissions")) {
                    ForEach(PermissionItem.allPermissions) { perm in
                        PermissionToggleRow(
                            permission: perm,
                            state: entry.permissionState(for: perm.id)
                        ) { newState in
                            entry.setPermission(perm.id, state: newState)
                        }
                    }
                }
            }
            #if os(macOS)
            .formStyle(.grouped)
            .frame(minWidth: 420, minHeight: 400)
            #endif
            .navigationTitle(entry.isInherited ? "ACL Entry (Read-only)" : "Edit ACL Entry")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if !entry.isInherited {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            // 提交未完成的搜索
                            if !userSearchText.trimmingCharacters(in: .whitespaces).isEmpty {
                                applyUserSearch()
                            }
                            onSave()
                            dismiss()
                        }
                    }
                }
            }
        }
        .disabled(entry.isInherited)
        .onAppear {
            if entry.userID >= 0 {
                serverManager.requestACLUserNames(for: [entry.userID])
            }
            let trimmedGroup = entry.group.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedGroup.isEmpty {
                lastSelectedGroup = trimmedGroup
            }
            if entry.userID >= 0 {
                lastSelectedUserID = entry.userID
            }
        }
        .onChange(of: entry.group) { newValue in
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                lastSelectedGroup = trimmed
            }
        }
    }
}

// MARK: - Permission Toggle Row

struct PermissionToggleRow: View {
    let permission: PermissionItem
    let state: PermissionState
    var onChange: (PermissionState) -> Void
    
    var body: some View {
        HStack {
            Image(systemName: permission.icon)
                .foregroundColor(.secondary)
                .frame(width: 24)
            
            Text(permission.name)
            
            Spacer()
            
            // 三态切换按钮
            HStack(spacing: 4) {
                ForEach(PermissionState.allCases, id: \.self) { permState in
                    Button {
                        onChange(permState)
                    } label: {
                        Image(systemName: permState.icon)
                            .font(.system(size: 16))
                            .foregroundColor(state == permState ? permState.color : Color.secondary.opacity(0.3))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Group Entry Edit View

struct GroupEntryEditView: View {
    @ObservedObject var entry: GroupEntryModel
    @ObservedObject var serverManager: ServerModelManager
    var onSave: () -> Void
    @Environment(\.dismiss) var dismiss
    
    @State private var newMemberID: String = ""
    @State private var newExcludedID: String = ""
    @State private var memberAddError: String? = nil
    @State private var excludedAddError: String? = nil
    
    /// 在线已注册用户列表（用于快捷选择）
    private var registeredOnlineUsers: [(name: String, userId: Int)] {
        var users: [(name: String, userId: Int)] = []
        for item in serverManager.modelItems {
            if item.type == .user, let user = item.object as? MKUser {
                let regId = Int(user.userId())
                if regId >= 0, let name = user.userName() {
                    users.append((name: name, userId: regId))
                }
            }
        }
        return users.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    
    /// 根据用户名或 User ID 字符串解析出注册 User ID
    private func resolveUserId(from input: String) -> Int? {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        // 首先尝试作为数字解析
        if let numericId = Int(trimmed) {
            return numericId
        }
        // 按用户名查找在线用户
        for item in serverManager.modelItems {
            if item.type == .user, let user = item.object as? MKUser {
                if let name = user.userName(),
                   name.caseInsensitiveCompare(trimmed) == .orderedSame {
                    let regId = Int(user.userId())
                    if regId >= 0 {
                        return regId
                    } else {
                        return nil  // 找到了但未注册
                    }
                }
            }
        }
        return nil
    }
    
    /// 判断用户名是否匹配到了未注册用户
    private func isUnregisteredUser(_ input: String) -> Bool {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        for item in serverManager.modelItems {
            if item.type == .user, let user = item.object as? MKUser {
                if let name = user.userName(),
                   name.caseInsensitiveCompare(trimmed) == .orderedSame {
                    return Int(user.userId()) < 0
                }
            }
        }
        return false
    }
    
    private func addMember() {
        memberAddError = nil
        let trimmed = newMemberID.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        
        if let userId = resolveUserId(from: trimmed) {
            if !entry.members.contains(userId) {
                entry.members.append(userId)
                serverManager.requestACLUserNames(for: [userId])
            }
            newMemberID = ""
        } else if isUnregisteredUser(trimmed) {
            memberAddError = "'\(trimmed)' is not a registered user."
        } else {
            memberAddError = "User '\(trimmed)' not found online. Enter a numeric User ID for offline users."
        }
    }
    
    private func addExcludedMember() {
        excludedAddError = nil
        let trimmed = newExcludedID.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        
        if let userId = resolveUserId(from: trimmed) {
            if !entry.excludedMembers.contains(userId) {
                entry.excludedMembers.append(userId)
                serverManager.requestACLUserNames(for: [userId])
            }
            newExcludedID = ""
        } else if isUnregisteredUser(trimmed) {
            excludedAddError = "'\(trimmed)' is not a registered user."
        } else {
            excludedAddError = "User '\(trimmed)' not found online. Enter a numeric User ID for offline users."
        }
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Group Name")) {
                    TextField("Group name", text: $entry.name)
                        #if os(macOS)
                        .textFieldStyle(.roundedBorder)
                        #endif
                }
                
                Section(header: Text("Inheritance")) {
                    Toggle("Inherit members from parent", isOn: $entry.inherit)
                    Toggle("Allow child channels to inherit", isOn: $entry.inheritable)
                }
                
                // 成员列表
                Section(header: Text("Members (\(entry.members.count))")) {
                    ForEach(entry.members, id: \.self) { memberID in
                        HStack {
                            Image(systemName: "person.fill")
                                .foregroundColor(.green)
                            Text(userDisplayName(for: memberID))
                            Spacer()
                            Text("ID: \(memberID)")
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                        #if os(macOS)
                        .contentShape(Rectangle())
                        .contextMenu {
                            Button(role: .destructive) {
                                entry.members.removeAll { $0 == memberID }
                            } label: {
                                Label("Remove Member", systemImage: "trash")
                            }
                        }
                        #endif
                    }
                    .onDelete { offsets in
                        entry.members.remove(atOffsets: offsets)
                    }
                    
                    HStack {
                        TextField("Username or User ID", text: $newMemberID)
                            .onSubmit { addMember() }
                            #if os(macOS)
                            .textFieldStyle(.roundedBorder)
                            #endif
                        Button {
                            addMember()
                        } label: {
                            Image(systemName: "plus.circle.fill")
                        }
                        .disabled(newMemberID.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    
                    if let error = memberAddError {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                    
                    // 在线已注册用户快捷选择
                    if !registeredOnlineUsers.isEmpty {
                        DisclosureGroup("Online Registered Users") {
                            ForEach(registeredOnlineUsers, id: \.userId) { info in
                                Button {
                                    if !entry.members.contains(info.userId) {
                                        entry.members.append(info.userId)
                                        serverManager.requestACLUserNames(for: [info.userId])
                                    }
                                } label: {
                                    HStack {
                                        Image(systemName: "person.fill")
                                            .foregroundColor(.accentColor)
                                        Text(info.name)
                                        Spacer()
                                        Text("ID: \(info.userId)")
                                            .foregroundColor(.secondary)
                                            .font(.caption)
                                        if entry.members.contains(info.userId) {
                                            Image(systemName: "checkmark")
                                                .foregroundColor(.green)
                                        }
                                    }
                                }
                                .foregroundColor(.primary)
                            }
                        }
                    }
                }
                
                // 排除列表
                Section(header: Text("Excluded Members (\(entry.excludedMembers.count))")) {
                    ForEach(entry.excludedMembers, id: \.self) { memberID in
                        HStack {
                            Image(systemName: "person.fill.xmark")
                                .foregroundColor(.red)
                            Text(userDisplayName(for: memberID))
                            Spacer()
                            Text("ID: \(memberID)")
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                    }
                    .onDelete { offsets in
                        entry.excludedMembers.remove(atOffsets: offsets)
                    }
                    
                    HStack {
                        TextField("Username or User ID", text: $newExcludedID)
                            .onSubmit { addExcludedMember() }
                            #if os(macOS)
                            .textFieldStyle(.roundedBorder)
                            #endif
                        Button {
                            addExcludedMember()
                        } label: {
                            Image(systemName: "plus.circle.fill")
                        }
                        .disabled(newExcludedID.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    
                    if let error = excludedAddError {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
                
                // 继承成员（只读）
                if !entry.inheritedMembers.isEmpty {
                    Section(header: Text("Inherited Members (\(entry.inheritedMembers.count))")) {
                        ForEach(entry.inheritedMembers, id: \.self) { memberID in
                            HStack {
                                Image(systemName: "person.fill")
                                    .foregroundColor(.secondary)
                                Text(userDisplayName(for: memberID))
                                Spacer()
                                Text("ID: \(memberID)")
                                    .foregroundColor(.secondary)
                                    .font(.caption)
                            }
                        }
                    }
                }
            }
            #if os(macOS)
            .formStyle(.grouped)
            .frame(minWidth: 400, minHeight: 350)
            #endif
            .navigationTitle(entry.isInherited ? "Group (Read-only)" : "Edit Group")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if !entry.isInherited {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            // 提交未完成的输入
                            if !newMemberID.trimmingCharacters(in: .whitespaces).isEmpty {
                                addMember()
                            }
                            if !newExcludedID.trimmingCharacters(in: .whitespaces).isEmpty {
                                addExcludedMember()
                            }
                            onSave()
                            dismiss()
                        }
                    }
                }
            }
        }
        .disabled(entry.isInherited)
        .onAppear {
            let ids = Set(entry.members + entry.excludedMembers + entry.inheritedMembers).filter { $0 >= 0 }
            serverManager.requestACLUserNames(for: Array(ids))
        }
    }
    
    /// 尝试从 ServerModelManager 的用户列表中查找用户名
    private func userDisplayName(for userID: Int) -> String {
        return serverManager.aclUserDisplayName(for: userID)
    }
}
