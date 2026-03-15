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
            content
                .navigationTitle("Registered Users")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .onAppear {
            users = []
            hasReceivedUserList = false
            serverManager.requestRegisteredUserList()
        }
        .onReceive(
            NotificationCenter.default
                .publisher(for: ServerModelNotificationManager.userListReceivedNotification)
                .receive(on: RunLoop.main)
        ) { notification in
            guard let userList = notification.userInfo?["userList"] else { return }
            parseUserList(userList)
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 420)
        #endif
    }

    private var content: some View {
        #if os(macOS)
        macContent
        #else
        Group {
            if users.isEmpty {
                if hasReceivedUserList {
                    ContentUnavailableView("No Registered Users", systemImage: "person.2", description: Text("The server returned an empty registered user list"))
                } else {
                    ContentUnavailableView("Loading...", systemImage: "person.2", description: Text("Requesting registered user list from server"))
                }
            } else {
                List {
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
        }
        .searchable(text: $searchText, prompt: "Search users")
        #endif
    }

    #if os(macOS)
    private var macContent: some View {
        VStack(spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Registered Users")
                        .font(.title3.weight(.semibold))
                    Text("\(users.count) users")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search users", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 240)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            Group {
                if users.isEmpty {
                    if hasReceivedUserList {
                        ContentUnavailableView("No Registered Users", systemImage: "person.2", description: Text("The server returned an empty registered user list"))
                    } else {
                        ContentUnavailableView("Loading...", systemImage: "person.2", description: Text("Requesting registered user list from server"))
                    }
                } else {
                    List {
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
                                Spacer(minLength: 8)
                            }
                        }
                        .onDelete(perform: deleteUsers)
                    }
                    .listStyle(.inset(alternatesRowBackgrounds: true))
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
    #endif
    
    private func deleteUsers(at offsets: IndexSet) {
        let toDelete = offsets.map { filteredUsers[$0] }
        users.removeAll { entry in toDelete.contains(where: { $0.id == entry.id }) }
    }
    
    private func parseUserList(_ raw: Any) {
        hasReceivedUserList = true
        var parsed: [RegisteredUserEntry] = []

        if let entries = raw as? [[String: Any]] {
            for entry in entries {
                if let user = parseUserEntry(entry) {
                    parsed.append(user)
                }
            }
        } else if let entries = raw as? [NSDictionary] {
            for entry in entries {
                if let user = parseUserEntry(entry) {
                    parsed.append(user)
                }
            }
        } else if let entries = raw as? NSArray {
            for entry in entries {
                if let user = parseUserEntry(entry) {
                    parsed.append(user)
                }
            }
        } else {
            users = []
            return
        }

        users = parsed.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func parseUserEntry(_ raw: Any) -> RegisteredUserEntry? {
        if let entry = raw as? [String: Any] {
            let userId = uint32Value(from: entry["userId"]) ?? 0
            let name = (entry["name"] as? String) ?? "User #\(userId)"
            return RegisteredUserEntry(id: userId, name: name)
        }

        if let entry = raw as? NSDictionary {
            let userId = uint32Value(from: entry["userId"]) ?? 0
            let name = (entry["name"] as? String) ?? "User #\(userId)"
            return RegisteredUserEntry(id: userId, name: name)
        }

        // macOS may bridge server payload entries as Foundation objects instead of dictionaries.
        if let obj = raw as? NSObject {
            let userId = uint32Value(from: obj.value(forKey: "userId")) ?? 0
            let name = (obj.value(forKey: "name") as? String) ?? "User #\(userId)"
            return RegisteredUserEntry(id: userId, name: name)
        }

        return nil
    }

    private func uint32Value(from any: Any?) -> UInt32? {
        if let val = any as? UInt32 { return val }
        if let val = any as? Int { return UInt32(exactly: val) }
        if let val = any as? NSNumber { return val.uint32Value }
        return nil
    }
}
