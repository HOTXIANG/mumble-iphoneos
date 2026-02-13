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
    @State private var selectedACLEntry: ACLEntryModel? = nil
    @State private var selectedGroupEntry: GroupEntryModel? = nil
    @State private var showAddACL: Bool = false
    @State private var showAddGroup: Bool = false
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
            .sheet(item: $selectedACLEntry) { entry in
                ACLEntryEditView(entry: entry) { }
            }
            .sheet(item: $selectedGroupEntry) { entry in
                GroupEntryEditView(entry: entry, serverManager: serverManager) { }
            }
            .sheet(isPresented: $showAddACL) {
                ACLEntryEditView(entry: createNewACLEntry()) { }
            }
            .sheet(isPresented: $showAddGroup) {
                GroupEntryEditView(entry: createNewGroupEntry(), serverManager: serverManager) { }
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
                    ACLEntryRow(entry: entry)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if !entry.isInherited {
                                selectedACLEntry = entry
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
                    showAddACL = true
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
                                selectedGroupEntry = entry
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
                    showAddGroup = true
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
        
        isLoading = false
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
    
    private func createNewACLEntry() -> ACLEntryModel {
        let entry = ACLEntryModel()
        aclEntries.append(entry)
        return entry
    }
    
    private func createNewGroupEntry() -> GroupEntryModel {
        let entry = GroupEntryModel()
        groupEntries.append(entry)
        return entry
    }
}

// MARK: - ACL Entry Row

struct ACLEntryRow: View {
    @ObservedObject var entry: ACLEntryModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: entry.isGroupBased ? "person.3" : "person")
                    .foregroundColor(entry.isInherited ? .secondary : .accentColor)
                    .frame(width: 20)
                
                Text(entry.displayName)
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
    var onSave: () -> Void
    @Environment(\.dismiss) var dismiss
    
    /// 预定义的 Mumble 内置组
    static let builtInGroups = ["all", "auth", "in", "out", "admin", "sub", "~sub"]
    
    var body: some View {
        NavigationStack {
            Form {
                // 目标类型
                Section(header: Text("Target")) {
                    Picker("Type", selection: Binding(
                        get: { entry.isGroupBased },
                        set: { isGroup in
                            if isGroup {
                                entry.userID = -1
                                if entry.group.isEmpty { entry.group = "all" }
                            } else {
                                entry.userID = 0
                                entry.group = ""
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
                        HStack {
                            Text("User ID")
                            Spacer()
                            TextField("ID", value: $entry.userID, format: .number)
                                .frame(width: 100)
                                #if os(macOS)
                                .textFieldStyle(.roundedBorder)
                                #endif
                                .multilineTextAlignment(.trailing)
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
                            onSave()
                            dismiss()
                        }
                    }
                }
            }
        }
        .disabled(entry.isInherited)
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
                    }
                    .onDelete { offsets in
                        entry.members.remove(atOffsets: offsets)
                    }
                    
                    HStack {
                        TextField("User ID", text: $newMemberID)
                            #if os(macOS)
                            .textFieldStyle(.roundedBorder)
                            #endif
                        Button {
                            if let id = Int(newMemberID) {
                                entry.members.append(id)
                                newMemberID = ""
                            }
                        } label: {
                            Image(systemName: "plus.circle.fill")
                        }
                        .disabled(Int(newMemberID) == nil)
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
                        TextField("User ID", text: $newExcludedID)
                            #if os(macOS)
                            .textFieldStyle(.roundedBorder)
                            #endif
                        Button {
                            if let id = Int(newExcludedID) {
                                entry.excludedMembers.append(id)
                                newExcludedID = ""
                            }
                        } label: {
                            Image(systemName: "plus.circle.fill")
                        }
                        .disabled(Int(newExcludedID) == nil)
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
                            onSave()
                            dismiss()
                        }
                    }
                }
            }
        }
        .disabled(entry.isInherited)
    }
    
    /// 尝试从 ServerModelManager 的用户列表中查找用户名
    private func userDisplayName(for userID: Int) -> String {
        // 遍历 modelItems 查找匹配 userId 的用户
        for item in serverManager.modelItems {
            if item.type == .user, let user = item.object as? MKUser {
                if user.userId() == UInt32(userID) {
                    return user.userName() ?? "User #\(userID)"
                }
            }
        }
        return "User #\(userID)"
    }
}
