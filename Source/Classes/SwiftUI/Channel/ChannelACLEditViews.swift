//
//  ChannelACLEditViews.swift
//  Mumble
//

import SwiftUI

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
