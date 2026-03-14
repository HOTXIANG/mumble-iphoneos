import SwiftUI

// MARK: - Local Model

struct BanEntryModel: Identifiable {
    let id = UUID()
    var addressData: Data
    var mask: UInt32
    var username: String
    var certHash: String
    var reason: String
    var start: String
    var duration: UInt32

    var addressString: String {
        if addressData.count == 4 {
            return addressData.map { String($0) }.joined(separator: ".")
        } else if addressData.count == 16 {
            let isIPv4Mapped = addressData.prefix(12) == Data([0,0,0,0, 0,0,0,0, 0,0,0xFF,0xFF])
            if isIPv4Mapped {
                return addressData.suffix(4).map { String($0) }.joined(separator: ".")
            }
            var parts: [String] = []
            for i in stride(from: 0, to: 16, by: 2) {
                let val = UInt16(addressData[i]) << 8 | UInt16(addressData[i + 1])
                parts.append(String(format: "%x", val))
            }
            return parts.joined(separator: ":")
        }
        return addressData.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    var durationText: String {
        if duration == 0 { return "Permanent" }
        let hours = duration / 3600
        let minutes = (duration % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}

// MARK: - BanListView

struct BanListView: View {
    @ObservedObject var serverManager: ServerModelManager
    @Environment(\.dismiss) private var dismiss

    @State private var entries: [BanEntryModel] = []
    @State private var searchText = ""
    @State private var showingAddSheet = false
    @State private var isLoading = true

    private var filteredEntries: [BanEntryModel] {
        if searchText.isEmpty { return entries }
        let query = searchText.lowercased()
        return entries.filter {
            $0.addressString.lowercased().contains(query) ||
            $0.username.lowercased().contains(query) ||
            $0.certHash.lowercased().contains(query) ||
            $0.reason.lowercased().contains(query)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading ban list…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if entries.isEmpty {
                    ContentUnavailableView("No Bans", systemImage: "shield.slash", description: Text("The server ban list is empty."))
                } else {
                    List {
                        ForEach(filteredEntries) { entry in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Label(entry.addressString, systemImage: "network").font(.headline)
                                    Text("/\(entry.mask)").font(.subheadline).foregroundStyle(.secondary)
                                    Spacer()
                                    Text(entry.durationText).font(.caption)
                                        .padding(.horizontal, 8).padding(.vertical, 2)
                                        .background(entry.duration == 0 ? Color.red.opacity(0.15) : Color.orange.opacity(0.15))
                                        .clipShape(Capsule())
                                }
                                if !entry.username.isEmpty {
                                    Label(entry.username, systemImage: "person").font(.subheadline).foregroundStyle(.secondary)
                                }
                                if !entry.reason.isEmpty {
                                    Label(entry.reason, systemImage: "text.quote").font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .onDelete { offsets in
                            let filtered = filteredEntries
                            let idsToRemove = Set(offsets.map { filtered[$0].id })
                            entries.removeAll { idsToRemove.contains($0.id) }
                        }
                    }
                }
            }
            .navigationTitle("Ban List")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .searchable(text: $searchText, prompt: "Search bans")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: 12) {
                        Button { showingAddSheet = true } label: { Image(systemName: "plus") }
                        Button { saveBanList() } label: {
                            Image(systemName: "square.and.arrow.down")
                        }
                    }
                }
            }
            .sheet(isPresented: $showingAddSheet) {
                AddBanView { newEntry in entries.append(newEntry) }
            }
            .onAppear { serverManager.requestBanList() }
            .onReceive(NotificationCenter.default.publisher(for: ServerModelNotificationManager.banListReceivedNotification)) { notification in
                parseBanList(notification.userInfo?["banList"])
            }
        }
    }

    private func parseBanList(_ raw: Any?) {
        guard let list = raw as? NSObject else { isLoading = false; return }
        let sel = NSSelectorFromString("bans")
        guard list.responds(to: sel),
              let bansArray = list.perform(sel)?.takeUnretainedValue() else {
            isLoading = false; return
        }

        var parsed: [BanEntryModel] = []
        let countSel = NSSelectorFromString("count")
        guard let countObj = (bansArray as AnyObject).perform(countSel) else { isLoading = false; return }
        let count = Int(bitPattern: countObj.toOpaque())

        for i in 0..<count {
            let atSel = NSSelectorFromString("objectAtIndex:")
            guard let entryObj = (bansArray as AnyObject).perform(atSel, with: i as AnyObject)?.takeUnretainedValue() as? NSObject else { continue }

            let address = (entryObj.value(forKey: "address") as? Data) ?? Data(repeating: 0, count: 16)
            let mask = (entryObj.value(forKey: "mask") as? NSNumber)?.uint32Value ?? 0
            let name = (entryObj.value(forKey: "name") as? String) ?? ""
            let cert = (entryObj.value(forKey: "certHash") as? String) ?? ""
            let reason = (entryObj.value(forKey: "reason") as? String) ?? ""
            let start = (entryObj.value(forKey: "start") as? String) ?? ""
            let dur = (entryObj.value(forKey: "duration") as? NSNumber)?.uint32Value ?? 0

            parsed.append(BanEntryModel(addressData: address, mask: mask, username: name, certHash: cert, reason: reason, start: start, duration: dur))
        }
        entries = parsed
        isLoading = false
    }

    private func saveBanList() {
        // 由于无法直接在 Swift 中创建 protobuf Builder 对象，
        // 通过 ServerModelManager 发送原始条目列表
        serverManager.sendBanList(entries.map { $0 as Any })
        dismiss()
    }
}

// MARK: - Add Ban View

private struct AddBanView: View {
    var onAdd: (BanEntryModel) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var ipAddress = ""
    @State private var mask: UInt32 = 32
    @State private var username = ""
    @State private var certHash = ""
    @State private var reason = ""
    @State private var duration: UInt32 = 0

    var body: some View {
        NavigationStack {
            Form {
                Section("Address") {
                    TextField("IP Address (e.g. 192.168.1.1)", text: $ipAddress)
                    HStack {
                        Text("Mask")
                        Spacer()
                        TextField("", value: $mask, format: .number).frame(width: 80).multilineTextAlignment(.trailing)
                    }
                }
                Section("Details") {
                    TextField("Username", text: $username)
                    TextField("Certificate Hash", text: $certHash)
                    TextField("Reason", text: $reason)
                }
                Section("Duration") {
                    HStack {
                        Text("Seconds (0 = permanent)")
                        Spacer()
                        TextField("", value: $duration, format: .number).frame(width: 100).multilineTextAlignment(.trailing)
                    }
                }
            }
            .navigationTitle("Add Ban")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let addressData = parseIP(ipAddress.trimmingCharacters(in: .whitespacesAndNewlines))
                        onAdd(BanEntryModel(addressData: addressData, mask: mask, username: username, certHash: certHash, reason: reason, start: "", duration: duration))
                        dismiss()
                    }
                    .disabled(ipAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func parseIP(_ string: String) -> Data {
        let parts = string.split(separator: ".")
        if parts.count == 4, let a = UInt8(parts[0]), let b = UInt8(parts[1]),
           let c = UInt8(parts[2]), let d = UInt8(parts[3]) {
            var data = Data(repeating: 0, count: 10)
            data.append(contentsOf: [0xFF, 0xFF, a, b, c, d])
            return data
        }
        return Data(repeating: 0, count: 16)
    }
}
