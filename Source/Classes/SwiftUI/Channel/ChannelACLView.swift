//
//  ChannelACLView.swift
//  Mumble
//
//  ACL (Access Control List) management view for channels.
//

import SwiftUI

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
