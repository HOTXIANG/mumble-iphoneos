//
//  ChannelEditView.swift
//  Mumble
//
//  Unified channel creation and editing views with ACL management.
//

import SwiftUI

// MARK: - Create Channel View

struct CreateChannelView: View {
    let parentChannel: MKChannel
    @ObservedObject var serverManager: ServerModelManager
    
    @State private var channelName: String = ""
    @State private var channelDescription: String = ""
    @State private var isTemporary: Bool = false
    @State private var position: Int = 0
    @State private var maxUsers: Int = 0
    @State private var channelPassword: String = ""
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Channel Name")) {
                    TextField("Enter channel name", text: $channelName)
                        #if os(macOS)
                        .textFieldStyle(.roundedBorder)
                        #endif
                }
                
                Section(header: Text("Description")) {
                    RichTextEditor(htmlText: $channelDescription)
                        .frame(minHeight: 160)
                }
                
                Section(header: Text("Settings")) {
                    Toggle("Temporary Channel", isOn: $isTemporary)
                    
                    HStack {
                        Label("Position", systemImage: "number")
                        Text("(sort order)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        TextField("", value: $position, format: .number)
                            .frame(width: 150)
                            #if os(macOS)
                            .textFieldStyle(.roundedBorder)
                            #endif
                            .multilineTextAlignment(.trailing)
                    }
                    
                    HStack {
                        Label("Max Users", systemImage: "person.2")
                        Text("(0 = unlimited)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        TextField("", value: $maxUsers, format: .number)
                            .frame(width: 150)
                            #if os(macOS)
                            .textFieldStyle(.roundedBorder)
                            #endif
                            .multilineTextAlignment(.trailing)
                    }
                    
                    HStack {
                        Label("Password", systemImage: "lock")
                        Text("(optional)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        SecureField("", text: $channelPassword)
                            .frame(width: 150)
                            #if os(macOS)
                            .textFieldStyle(.roundedBorder)
                            #endif
                            .multilineTextAlignment(.trailing)
                    }
                }
                
                Section(footer: Text("Parent: \(parentChannel.channelName() ?? "Root")")) {
                    EmptyView()
                }
            }
            #if os(macOS)
            .formStyle(.grouped)
            .frame(minWidth: 450, minHeight: 400)
            #endif
            .navigationTitle("Create Channel")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { createChannel() }
                    .disabled(channelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
    
    private func createChannel() {
        let trimmedName = channelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        
        let hasExtraSettings = !channelDescription.isEmpty || position != 0 || maxUsers != 0 || !channelPassword.isEmpty
        
        if hasExtraSettings {
            // 频道创建后，服务器会返回带有 channelId 的 ChannelState
            // 监听 channelAddedNotification，在新频道出现后再设置额外属性
            let parentId = parentChannel.channelId()
            let desc = channelDescription
            let pos = position
            let maxU = maxUsers
            let pwd = channelPassword
            let mgr = serverManager
            
            var observer: NSObjectProtocol?
            observer = NotificationCenter.default.addObserver(
                forName: ServerModelNotificationManager.channelAddedNotification,
                object: nil,
                queue: .main
            ) { notification in
                guard let userInfo = notification.userInfo,
                      let newChannel = userInfo["channel"] as? MKChannel,
                      newChannel.channelName() == trimmedName,
                      newChannel.parent()?.channelId() == parentId else { return }
                
                // 移除一次性监听
                if let obs = observer {
                    NotificationCenter.default.removeObserver(obs)
                }
                
                let channelRef = UnsafeTransfer(value: newChannel)
                
                Task { @MainActor in
                    let ch = channelRef.value
                    
                    // 设置描述、位置、最大人数
                    let newDesc: String? = desc.isEmpty ? nil : desc
                    let newPos: NSNumber? = pos != 0 ? NSNumber(value: pos) : nil
                    let newMaxUsers: NSNumber? = maxU != 0 ? NSNumber(value: maxU) : nil
                    
                    if newDesc != nil || newPos != nil || newMaxUsers != nil {
                        mgr.editChannel(ch, name: nil, description: newDesc, position: newPos, maxUsers: newMaxUsers)
                    }
                    
                    // 设置密码（通过 ACL）
                    if !pwd.isEmpty {
                        Self.setupPasswordACLForChannel(ch, password: pwd, serverManager: mgr)
                    }
                }
            }
        }
        
        serverManager.createChannel(name: trimmedName, parent: parentChannel, temporary: isTemporary)
        dismiss()
    }
    
    /// 通过 ACL 为频道设置密码（静态方法，不依赖 View 生命周期）
    static func setupPasswordACLForChannel(_ channel: MKChannel, password: String, serverManager: ServerModelManager) {
        serverManager.requestACL(for: channel)
        
        let channelId = channel.channelId()
        let channelRef = UnsafeTransfer(value: channel)
        var observer: NSObjectProtocol?
        observer = NotificationCenter.default.addObserver(
            forName: ServerModelNotificationManager.aclReceivedNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let userInfo = notification.userInfo,
                  let accessControl = userInfo["accessControl"] as? MKAccessControl,
                  let chan = userInfo["channel"] as? MKChannel,
                  chan.channelId() == channelId else { return }
            
            if let obs = observer {
                NotificationCenter.default.removeObserver(obs)
            }
            
            let aclTransfer = UnsafeTransfer(value: accessControl)
            
            Task { @MainActor in
                let acl = aclTransfer.value
                let ch = channelRef.value
                
                let existingACLs = acl.acls ?? NSMutableArray()
                let filteredACLs = NSMutableArray()
                for item in existingACLs {
                    if let aclItem = item as? MKChannelACL {
                        let isPasswordGroup = (aclItem.group?.hasPrefix("#") ?? false) && !aclItem.inherited
                        let isDenyAllEnter = (aclItem.group == "all") && !aclItem.inherited &&
                            (aclItem.deny.rawValue & MKPermissionEnter.rawValue) != 0
                        if !isPasswordGroup && !isDenyAllEnter {
                            filteredACLs.add(aclItem)
                        }
                    }
                }
                
                let denyACL = MKChannelACL()
                denyACL.applyHere = true
                denyACL.applySubs = false
                denyACL.inherited = false
                denyACL.userID = -1
                denyACL.group = "all"
                denyACL.grant = MKPermission(rawValue: 0)
                denyACL.deny = MKPermissionEnter
                filteredACLs.add(denyACL)
                
                let grantACL = MKChannelACL()
                grantACL.applyHere = true
                grantACL.applySubs = false
                grantACL.inherited = false
                grantACL.userID = -1
                grantACL.group = "#\(password)"
                grantACL.grant = MKPermissionEnter
                grantACL.deny = MKPermission(rawValue: 0)
                filteredACLs.add(grantACL)
                
                acl.acls = filteredACLs
                serverManager.setACL(acl, for: ch)
                serverManager.markChannelHasPassword(ch.channelId())
            }
        }
    }
}

// MARK: - Edit Channel View (Tabbed: Properties + ACL)

struct EditChannelView: View {
    let channel: MKChannel
    @ObservedObject var serverManager: ServerModelManager
    
    @State private var selectedTab: EditTab = .properties
    @Environment(\.dismiss) var dismiss
    
    enum EditTab: String, CaseIterable {
        case properties = "Properties"
        case acl = "ACL"
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $selectedTab) {
                    ForEach(EditTab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)
                
                switch selectedTab {
                case .properties:
                    ChannelPropertiesView(
                        channel: channel,
                        serverManager: serverManager,
                        dismiss: dismiss
                    )
                case .acl:
                    ChannelACLContentView(
                        channel: channel,
                        serverManager: serverManager,
                        dismiss: dismiss
                    )
                }
            }
            #if os(macOS)
            .frame(minWidth: 520, minHeight: 500)
            #endif
            .navigationTitle("Edit: \(channel.channelName() ?? "Channel")")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Channel Properties Tab

struct ChannelPropertiesView: View {
    let channel: MKChannel
    @ObservedObject var serverManager: ServerModelManager
    let dismiss: DismissAction
    
    @State private var channelName: String = ""
    @State private var channelDescription: String = ""
    @State private var position: Int = 0
    @State private var maxUsers: Int = 0
    @State private var channelPassword: String = ""
    @State private var hasExistingPassword: Bool = false
    @State private var passwordModified: Bool = false
    @State private var showDeleteConfirmation: Bool = false
    @State private var isLoading: Bool = true
    @State private var contentHeight: CGFloat = 60
    
    var isRootChannel: Bool {
        channel.channelId() == 0
    }
    
    var body: some View {
        Form {
            // 频道名称
            if !isRootChannel {
                Section(header: Text("Channel Name")) {
                    TextField("Channel name", text: $channelName)
                        #if os(macOS)
                        .textFieldStyle(.roundedBorder)
                        #endif
                }
            }
            
            // 频道描述 (富文本编辑器)
            Section(header: Text("Description")) {
                RichTextEditor(htmlText: $channelDescription)
                    .frame(minHeight: 160)
            }
            
            // 频道属性
            Section(header: Text("Settings")) {
                HStack {
                    Label("Position", systemImage: "number")
                    Text("(sort order)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    TextField("", value: $position, format: .number)
                        .frame(width: 150)
                        #if os(macOS)
                        .textFieldStyle(.roundedBorder)
                        #endif
                        .multilineTextAlignment(.trailing)
                }
                
                HStack {
                    Label("Max Users", systemImage: "person.2")
                    Text("(0 = unlimited)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    TextField("", value: $maxUsers, format: .number)
                        .frame(width: 150)
                        #if os(macOS)
                        .textFieldStyle(.roundedBorder)
                        #endif
                        .multilineTextAlignment(.trailing)
                }
                
                HStack {
                    Label("Password", systemImage: "lock")
                    if hasExistingPassword && !passwordModified {
                        Text("(has password)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Text("(optional)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    SecureField(hasExistingPassword ? "••••••" : "", text: $channelPassword)
                        .frame(width: 150)
                        #if os(macOS)
                        .textFieldStyle(.roundedBorder)
                        #endif
                        .multilineTextAlignment(.trailing)
                        .onChange(of: channelPassword) {
                            passwordModified = true
                        }
                    if hasExistingPassword && passwordModified {
                        Button {
                            channelPassword = ""
                            passwordModified = false
                        } label: {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Reset to keep existing password")
                    }
                }
            }
            
            // 频道信息
            Section(header: Text("Info")) {
                HStack {
                    Text("Channel ID")
                    Spacer()
                    Text("\(channel.channelId())")
                        .foregroundColor(.secondary)
                }
                
                if channel.isTemporary() {
                    HStack {
                        Text("Type")
                        Spacer()
                        Text("Temporary")
                            .foregroundColor(.orange)
                    }
                }
            }
            
            // 保存按钮
            Section {
                Button {
                    saveChanges()
                } label: {
                    HStack {
                        Spacer()
                        Text("Save Changes")
                            .fontWeight(.semibold)
                        Spacer()
                    }
                }
                .disabled(!isRootChannel && channelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            
            // 删除频道
            if !isRootChannel {
                Section {
                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        HStack {
                            Image(systemName: "trash")
                            Text("Delete Channel")
                        }
                    }
                }
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
        .alert("Delete Channel", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                serverManager.removeChannel(channel)
                dismiss()
            }
        } message: {
            Text("Are you sure you want to delete \"\(channel.channelName() ?? "this channel")\"? This action cannot be undone.")
        }
        .onAppear { loadChannelInfo() }
        .onReceive(NotificationCenter.default.publisher(for: ServerModelNotificationManager.channelDescriptionChangedNotification)) { notification in
            if let chanId = notification.userInfo?["channelId"] as? UInt,
               chanId == channel.channelId(),
               let desc = channel.channelDescription(), !desc.isEmpty {
                channelDescription = desc
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: ServerModelNotificationManager.aclReceivedNotification)) { notification in
            guard let userInfo = notification.userInfo,
                  let chan = userInfo["channel"] as? MKChannel,
                  chan.channelId() == channel.channelId(),
                  let accessControl = userInfo["accessControl"] as? MKAccessControl else { return }
            // 直接从 ACL 数据检测密码状态（不依赖 ServerModelManager 的更新顺序）
            if !passwordModified {
                let detected = detectPasswordInACL(accessControl)
                hasExistingPassword = detected
            }
        }
    }
    
    private func loadChannelInfo() {
        channelName = channel.channelName() ?? ""
        position = Int(channel.position())
        maxUsers = Int(channel.maxUsers())
        
        // 检测密码状态
        hasExistingPassword = serverManager.channelsWithPassword.contains(channel.channelId())
        passwordModified = false
        channelPassword = ""
        
        // 如果还不知道密码状态，请求 ACL 来检测
        if !hasExistingPassword {
            serverManager.requestACL(for: channel)
        }
        
        if let desc = channel.channelDescription(), !desc.isEmpty {
            channelDescription = desc
            isLoading = false
        } else if channel.channelDescriptionHash() != nil {
            MUConnectionController.shared()?.serverModel?.requestDescription(for: channel)
            isLoading = false
        } else {
            channelDescription = ""
            isLoading = false
        }
    }
    
    /// 直接从 ACL 数据检测是否含有密码模式
    private func detectPasswordInACL(_ accessControl: MKAccessControl) -> Bool {
        guard let acls = accessControl.acls else { return false }
        var hasDenyEnterAll = false
        var hasGrantEnterToken = false
        for item in acls {
            guard let aclItem = item as? MKChannelACL, !aclItem.inherited else { continue }
            if aclItem.group == "all" && (aclItem.deny.rawValue & MKPermissionEnter.rawValue) != 0 {
                hasDenyEnterAll = true
            }
            if let group = aclItem.group, group.hasPrefix("#") && !group.hasPrefix("#!") &&
               (aclItem.grant.rawValue & MKPermissionEnter.rawValue) != 0 {
                hasGrantEnterToken = true
            }
        }
        return hasDenyEnterAll && hasGrantEnterToken
    }
    
    private func saveChanges() {
        let trimmedName = channelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let originalName = channel.channelName() ?? ""
        let originalDesc = channel.channelDescription() ?? ""
        let originalPosition = Int(channel.position())
        let originalMaxUsers = Int(channel.maxUsers())
        
        let newName: String? = (!isRootChannel && trimmedName != originalName) ? trimmedName : nil
        let newDesc: String? = (channelDescription != originalDesc) ? channelDescription : nil
        let newPosition: NSNumber? = (position != originalPosition) ? NSNumber(value: position) : nil
        let newMaxUsers: NSNumber? = (maxUsers != originalMaxUsers) ? NSNumber(value: maxUsers) : nil
        
        if newName != nil || newDesc != nil || newPosition != nil || newMaxUsers != nil {
            serverManager.editChannel(channel, name: newName, description: newDesc, position: newPosition, maxUsers: newMaxUsers)
        }
        
        // 处理密码设置：仅在用户明确修改了密码时才更新
        if passwordModified && !channelPassword.isEmpty {
            CreateChannelView.setupPasswordACLForChannel(channel, password: channelPassword, serverManager: serverManager)
        }
        
        dismiss()
    }
}

// MARK: - Channel ACL Content View (embedded in EditChannelView)

struct ChannelACLContentView: View {
    let channel: MKChannel
    @ObservedObject var serverManager: ServerModelManager
    let dismiss: DismissAction
    
    @State private var inheritACLs: Bool = true
    @State private var aclEntries: [ACLEntryModel] = []
    @State private var groupEntries: [GroupEntryModel] = []
    @State private var isLoading: Bool = true
    @State private var selectedSubTab: ACLSubTab = .acls
    @State private var selectedACLEntry: ACLEntryModel? = nil
    @State private var selectedGroupEntry: GroupEntryModel? = nil
    @State private var newACLEntry: ACLEntryModel? = nil
    @State private var newGroupEntry: GroupEntryModel? = nil
    
    enum ACLSubTab: String, CaseIterable {
        case acls = "ACLs"
        case groups = "Groups"
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // 继承开关
            HStack {
                Image(systemName: "arrow.down.circle")
                    .foregroundColor(.accentColor)
                Toggle("Inherit ACLs from parent", isOn: $inheritACLs)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            
            // Sub-tab
            Picker("", selection: $selectedSubTab) {
                ForEach(ACLSubTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 8)
            
            Divider()
            
            switch selectedSubTab {
            case .acls:
                aclListView
            case .groups:
                groupListView
            }
            
            // 保存按钮
            HStack {
                Spacer()
                Button("Save ACL") { saveACL() }
                    .buttonStyle(.borderedProminent)
                    .padding()
            }
        }
        .sheet(item: $selectedACLEntry) { entry in
            ACLEntryEditView(entry: entry, serverManager: serverManager) { }
        }
        .sheet(item: $selectedGroupEntry) { entry in
            GroupEntryEditView(entry: entry, serverManager: serverManager) { }
        }
        .sheet(item: $newACLEntry) { entry in
            ACLEntryEditView(entry: entry, serverManager: serverManager) { }
        }
        .sheet(item: $newGroupEntry) { entry in
            GroupEntryEditView(entry: entry, serverManager: serverManager) { }
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
                            if !entry.isInherited { selectedACLEntry = entry }
                        }
                        .opacity(entry.isInherited ? 0.6 : 1.0)
                }
                .onDelete { offsets in
                    let nonInherited = offsets.filter { !aclEntries[$0].isInherited }
                    aclEntries.remove(atOffsets: IndexSet(nonInherited))
                }
            }
            
            Section {
                Button {
                    let entry = ACLEntryModel()
                    aclEntries.append(entry)
                    newACLEntry = entry
                } label: {
                    Label("Add ACL Entry", systemImage: "plus.circle")
                }
            }
        }
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
                            if !entry.isInherited { selectedGroupEntry = entry }
                        }
                        .opacity(entry.isInherited ? 0.6 : 1.0)
                }
                .onDelete { offsets in
                    let nonInherited = offsets.filter { !groupEntries[$0].isInherited }
                    groupEntries.remove(atOffsets: IndexSet(nonInherited))
                }
            }
            
            Section {
                Button {
                    let entry = GroupEntryModel()
                    groupEntries.append(entry)
                    newGroupEntry = entry
                } label: {
                    Label("Add Group", systemImage: "plus.circle")
                }
            }
        }
    }
    
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
        for entry in aclEntries { aclArray.add(entry.toMKChannelACL()) }
        accessControl.acls = aclArray
        
        let groupArray = NSMutableArray()
        for entry in groupEntries { groupArray.add(entry.toMKChannelGroup()) }
        accessControl.groups = groupArray
        
        serverManager.setACL(accessControl, for: channel)
    }
}
