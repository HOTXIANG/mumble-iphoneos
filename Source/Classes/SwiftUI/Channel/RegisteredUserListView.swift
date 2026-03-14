import SwiftUI

// MARK: - 注册用户列表数据模型

struct RegisteredUserEntry: Identifiable, Equatable {
    let id: UInt32
    let name: String
}

// MARK: - RegisteredUserListView

struct RegisteredUserListView: View {
    @ObservedObject var serverManager: ServerModelManager
    @Environment(\.dismiss) private var dismiss
    
    @State private var users: [RegisteredUserEntry] = []
    @State private var searchText = ""
    @State private var hasReceivedUserList = false
    
    private var filteredUsers: [RegisteredUserEntry] {
        if searchText.isEmpty { return users }
        return users.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }
    
    var body: some View {
        NavigationStack {
            List {
                if users.isEmpty {
                    if hasReceivedUserList {
                        ContentUnavailableView("No Registered Users", systemImage: "person.2", description: Text("The server returned an empty registered user list"))
                    } else {
                        ContentUnavailableView("Loading...", systemImage: "person.2", description: Text("Requesting registered user list from server"))
                    }
                } else {
                    ForEach(filteredUsers) { user in
                        HStack {
                            Image(systemName: "person.fill")
                                .foregroundColor(.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(user.name)
                                    .font(.body)
                                Text("ID: \(user.id)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .onDelete(perform: deleteUsers)
                }
            }
            .searchable(text: $searchText, prompt: "Search users")
            .navigationTitle("Registered Users")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                hasReceivedUserList = false
                serverManager.requestRegisteredUserList()
            }
            .onReceive(NotificationCenter.default.publisher(for: ServerModelNotificationManager.userListReceivedNotification)) { notification in
                guard let userList = notification.userInfo?["userList"] else { return }
                parseUserList(userList)
            }
        }
    }
    
    private func deleteUsers(at offsets: IndexSet) {
        let toDelete = offsets.map { filteredUsers[$0] }
        users.removeAll { entry in toDelete.contains(where: { $0.id == entry.id }) }
    }
    
    private func parseUserList(_ raw: Any) {
        hasReceivedUserList = true
        var parsed: [RegisteredUserEntry] = []

        if let entries = raw as? [[String: Any]] {
            for entry in entries {
                let userId = uint32Value(from: entry["userId"]) ?? 0
                let name = (entry["name"] as? String) ?? "User #\(userId)"
                parsed.append(RegisteredUserEntry(id: userId, name: name))
            }
        } else if let entries = raw as? [NSDictionary] {
            for entry in entries {
                let userId = uint32Value(from: entry["userId"]) ?? 0
                let name = (entry["name"] as? String) ?? "User #\(userId)"
                parsed.append(RegisteredUserEntry(id: userId, name: name))
            }
        } else {
            users = []
            return
        }

        users = parsed.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func uint32Value(from any: Any?) -> UInt32? {
        if let val = any as? UInt32 { return val }
        if let val = any as? Int { return UInt32(exactly: val) }
        if let val = any as? NSNumber { return val.uint32Value }
        return nil
    }
}
