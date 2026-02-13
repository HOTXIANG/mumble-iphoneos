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
                        Spacer()
                        TextField("0", value: $position, format: .number)
                            .frame(width: 80)
                            #if os(macOS)
                            .textFieldStyle(.roundedBorder)
                            #endif
                            .multilineTextAlignment(.trailing)
                    }
                    
                    HStack {
                        Label("Max Users", systemImage: "person.2")
                        Spacer()
                        TextField("0 = Unlimited", value: $maxUsers, format: .number)
                            .frame(width: 120)
                            #if os(macOS)
                            .textFieldStyle(.roundedBorder)
                            #endif
                            .multilineTextAlignment(.trailing)
                    }
                    
                    HStack {
                        Label("Password", systemImage: "lock")
                        Spacer()
                        SecureField("No password", text: $channelPassword)
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
        serverManager.createChannel(name: trimmedName, parent: parentChannel, temporary: isTemporary)
        // 频道创建后，服务器会返回带有 channelId 的 ChannelState
        // 后续需要通过 editChannel 设置 description/position/maxUsers/password
        // 由于新频道的 ID 在创建后才知道，这些属性需要在频道出现后通过编辑设置
        dismiss()
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
                    Spacer()
                    TextField("0", value: $position, format: .number)
                        .frame(width: 80)
                        #if os(macOS)
                        .textFieldStyle(.roundedBorder)
                        #endif
                        .multilineTextAlignment(.trailing)
                }
                
                HStack {
                    Label("Max Users", systemImage: "person.2")
                    Spacer()
                    TextField("0 = Unlimited", value: $maxUsers, format: .number)
                        .frame(width: 120)
                        #if os(macOS)
                        .textFieldStyle(.roundedBorder)
                        #endif
                        .multilineTextAlignment(.trailing)
                }
                
                HStack {
                    Label("Password", systemImage: "lock")
                    Spacer()
                    SecureField("No password", text: $channelPassword)
                        .frame(width: 150)
                        #if os(macOS)
                        .textFieldStyle(.roundedBorder)
                        #endif
                        .multilineTextAlignment(.trailing)
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
    }
    
    private func loadChannelInfo() {
        channelName = channel.channelName() ?? ""
        position = Int(channel.position())
        maxUsers = Int(channel.maxUsers())
        
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
        
        // 处理密码设置：通过 ACL 实现
        if !channelPassword.isEmpty {
            setupPasswordACL(password: channelPassword)
        }
        
        dismiss()
    }
    
    /// 通过 ACL 设置频道密码
    /// Mumble 的频道密码是通过 access token 组实现的：
    /// 1. 先请求频道的现有 ACL
    /// 2. 在现有 ACL 基础上追加密码相关的条目
    /// 3. 发送更新后的完整 ACL
    private func setupPasswordACL(password: String) {
        // 先请求现有 ACL
        serverManager.requestACL(for: channel)
        
        // 监听 ACL 返回，追加密码条目
        let channelId = channel.channelId()
        let channelRef = UnsafeTransfer(value: channel)
        var observer: NSObjectProtocol?
        observer = NotificationCenter.default.addObserver(
            forName: ServerModelNotificationManager.aclReceivedNotification,
            object: nil,
            queue: .main
        ) { [serverManager] notification in
            guard let userInfo = notification.userInfo,
                  let accessControl = userInfo["accessControl"] as? MKAccessControl,
                  let chan = userInfo["channel"] as? MKChannel,
                  chan.channelId() == channelId else { return }
            
            // 移除一次性监听
            if let obs = observer {
                NotificationCenter.default.removeObserver(obs)
            }
            
            let aclTransfer = UnsafeTransfer(value: accessControl)
            
            Task { @MainActor in
                let acl = aclTransfer.value
                let ch = channelRef.value
                
                // 在现有 ACL 基础上追加密码条目
                let existingACLs = acl.acls ?? NSMutableArray()
                
                // 先移除之前可能存在的旧密码 ACL
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
                
                // 1. Deny Enter to @all
                let denyACL = MKChannelACL()
                denyACL.applyHere = true
                denyACL.applySubs = false
                denyACL.inherited = false
                denyACL.userID = -1
                denyACL.group = "all"
                denyACL.grant = MKPermission(rawValue: 0)
                denyACL.deny = MKPermissionEnter
                filteredACLs.add(denyACL)
                
                // 2. Grant Enter to @#<password> (access token group)
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
            }
        }
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
            ACLEntryEditView(entry: entry) { }
        }
        .sheet(item: $selectedGroupEntry) { entry in
            GroupEntryEditView(entry: entry, serverManager: serverManager) { }
        }
        .sheet(item: $newACLEntry) { entry in
            ACLEntryEditView(entry: entry) { }
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
