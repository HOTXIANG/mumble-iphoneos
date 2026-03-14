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
    
    private var filteredUsers: [RegisteredUserEntry] {
        if searchText.isEmpty { return users }
        return users.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }
    
    var body: some View {
        NavigationStack {
            List {
                if users.isEmpty {
                    ContentUnavailableView("Loading...", systemImage: "person.2", description: Text("Requesting registered user list from server"))
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
        guard let list = raw as? NSObject else { return }
        let sel = NSSelectorFromString("users")
        guard list.responds(to: sel),
              let usersArray = list.perform(sel)?.takeUnretainedValue() as? NSArray else { return }
        
        var parsed: [RegisteredUserEntry] = []
        for item in usersArray {
            guard let entry = item as? NSObject else { continue }
            let userIdSel = NSSelectorFromString("userId")
            let nameSel = NSSelectorFromString("name")
            
            guard entry.responds(to: userIdSel) else { continue }
            let userId = (entry.value(forKey: "userId") as? NSNumber)?.uint32Value ?? 0
            let name = (entry.value(forKey: "name") as? String) ?? "User #\(userId)"
            
            parsed.append(RegisteredUserEntry(id: userId, name: name))
        }
        users = parsed.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
