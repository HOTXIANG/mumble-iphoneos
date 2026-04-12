import SwiftUI
import Combine

// MARK: - UserStatsView

struct UserStatsView: View {
    let user: MKUser
    @ObservedObject var serverManager: ServerModelManager
    @Environment(\.dismiss) private var dismiss
    
    @State private var version: String = "—"
    @State private var os: String = "—"
    @State private var onlineTime: String = "—"
    @State private var idleTime: String = "—"
    @State private var bandwidth: String = "—"
    @State private var tcpPackets: String = "—"
    @State private var udpPackets: String = "—"
    @State private var tcpPing: String = "—"
    @State private var udpPing: String = "—"
    @State private var isOpus: Bool = false
    @State private var strongCertText: String = "—"
    @State private var fromClientText: String = "—"
    @State private var fromServerText: String = "—"
    @State private var addressText: String? = nil
    
    private let refreshTimer = Timer.publish(every: 6, on: .main, in: .common).autoconnect()
    
    var body: some View {
        NavigationStack {
            List {
                Section("Connection") {
                    row("User", user.userName() ?? "Unknown")
                    if let addressText {
                        row("Address", addressText)
                    }
                    row("Version", version)
                    row("OS", os)
                    row("Online", onlineTime)
                    row("Idle", idleTime)
                }

                Section("Audio") {
                    row("From Client", fromClientText)
                    row("From Server", fromServerText)
                    row("UDP Packets", udpPackets)
                    row("TCP Packets", tcpPackets)
                    row("UDP Ping", udpPing)
                    row("TCP Ping", tcpPing)
                    row("Opus", isOpus ? "Yes" : "No")
                }

                Section("Bandwidth") {
                    row("Bandwidth", bandwidth)
                    row("Strong Certificate", strongCertText)
                }
            }
            #if os(macOS)
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .scrollContentBackground(.hidden)
            .background(Color(nsColor: .windowBackgroundColor))
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity, alignment: .center)
            #endif
            .navigationTitle("User Statistics")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        .onAppear {
            AppState.shared.setAutomationCurrentScreen("userStats")
            serverManager.requestUserStats(for: user)
        }
            .onReceive(refreshTimer) { _ in
                serverManager.requestUserStats(for: user)
            }
            .onReceive(NotificationCenter.default.publisher(for: ServerModelNotificationManager.userStatsReceivedNotification)) { notification in
                if let receivedUser = notification.userInfo?["user"] as? MKUser,
                   receivedUser.session() != user.session() {
                    return
                }
                guard let stats = notification.userInfo?["stats"] else { return }
                parseStats(stats)
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, idealWidth: 500, minHeight: 420)
        #endif
    }
    
    private func row(_ label: String, _ value: String) -> some View {
        #if os(macOS)
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .foregroundColor(.secondary)
                .frame(width: 140, alignment: .leading)
            Text(value)
                .font(.body.monospacedDigit())
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        #else
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.body.monospacedDigit())
        }
        #endif
    }
    
    private func parseStats(_ raw: Any) {
        guard let stats = raw as? NSObject else { return }
        
        if let sess = uint32Value(from: stats.value(forKey: "session")),
           sess != UInt32(user.session()) {
            return
        }

        if let v = stats.value(forKey: "version") as? NSObject {
            let release = (v.value(forKey: "release") as? String) ?? ""
            let osStr = (v.value(forKey: "os") as? String) ?? ""
            let osVer = (v.value(forKey: "osVersion") as? String) ?? ""
            version = release.isEmpty ? "—" : release
            os = osStr.isEmpty ? "—" : "\(osStr) \(osVer)"
        }

        if let secs = uint32Value(from: stats.value(forKey: "onlinesecs")) {
            onlineTime = formatDuration(secs)
        }
        if let secs = uint32Value(from: stats.value(forKey: "idlesecs")) {
            idleTime = formatDuration(secs)
        }
        let bandwidthValue = uint32Value(from: stats.value(forKey: "bandwidth"))
        let hasBandwidth = boolValue(from: stats.value(forKey: "hasBandwidth")) ?? (bandwidthValue != nil)
        if let bw = bandwidthValue, hasBandwidth || bw > 0 {
            bandwidth = String(format: "%.1f kbit/s", Double(bw) / 125.0)
        } else {
            bandwidth = "—"
        }
        if let p = uint32Value(from: stats.value(forKey: "tcpPackets")) {
            tcpPackets = "\(p)"
        }
        if let p = uint32Value(from: stats.value(forKey: "udpPackets")) {
            udpPackets = "\(p)"
        }
        // fromClient / fromServer 详细包统计（good/late/lost/resync）
        if let fc = stats.value(forKey: "fromClient") as? NSObject {
            fromClientText = formatPacketStats(fc)
        }
        if let fs = stats.value(forKey: "fromServer") as? NSObject {
            fromServerText = formatPacketStats(fs)
        }
        // IP 地址（仅管理员可见）
        if let addrData = stats.value(forKey: "address") as? Data, !addrData.isEmpty {
            addressText = parseAddress(addrData)
        }
        if let avg = floatValue(from: stats.value(forKey: "tcpPingAvg")),
           let v = floatValue(from: stats.value(forKey: "tcpPingVar")) {
            tcpPing = String(format: "%.1f ms (±%.1f)", avg, sqrt(v))
        }
        if let avg = floatValue(from: stats.value(forKey: "udpPingAvg")),
           let v = floatValue(from: stats.value(forKey: "udpPingVar")) {
            udpPing = String(format: "%.1f ms (±%.1f)", avg, sqrt(v))
        }
        if let opus = boolValue(from: stats.value(forKey: "opus")) {
            isOpus = opus
        }
        let strongCertValue = boolValue(from: stats.value(forKey: "strongCertificate"))
        let hasStrongCert = boolValue(from: stats.value(forKey: "hasStrongCertificate")) ?? (strongCertValue != nil)
        if hasStrongCert, let strong = strongCertValue {
            strongCertText = strong ? "Yes" : "No"
        } else {
            strongCertText = "—"
        }
    }
    
    private func formatDuration(_ seconds: UInt32) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 {
            return String(format: "%dh %02dm %02ds", h, m, s)
        } else if m > 0 {
            return String(format: "%dm %02ds", m, s)
        } else {
            return "\(s)s"
        }
    }

    private func uint32Value(from raw: Any?) -> UInt32? {
        if let value = raw as? UInt32 { return value }
        if let value = raw as? Int { return UInt32(exactly: value) }
        if let value = raw as? NSNumber { return value.uint32Value }
        return nil
    }

    private func floatValue(from raw: Any?) -> Float? {
        if let value = raw as? Float { return value }
        if let value = raw as? Double { return Float(value) }
        if let value = raw as? NSNumber { return value.floatValue }
        return nil
    }

    private func boolValue(from raw: Any?) -> Bool? {
        if let value = raw as? Bool { return value }
        if let value = raw as? NSNumber { return value.boolValue }
        return nil
    }

    /// 格式化 MPUserStats_Stats（good/late/lost/resync）
    private func formatPacketStats(_ obj: NSObject) -> String {
        let good = uint32Value(from: obj.value(forKey: "good")) ?? 0
        let late = uint32Value(from: obj.value(forKey: "late")) ?? 0
        let lost = uint32Value(from: obj.value(forKey: "lost")) ?? 0
        let resync = uint32Value(from: obj.value(forKey: "resync")) ?? 0
        return "\(good) good, \(late) late, \(lost) lost, \(resync) resync"
    }

    /// 解析 IP 地址（IPv4 / IPv6-mapped IPv4 / IPv6）
    private func parseAddress(_ data: Data) -> String? {
        if data.count == 4 {
            // IPv4
            return data.map { String($0) }.joined(separator: ".")
        } else if data.count == 16 {
            // 检查是否为 IPv6-mapped IPv4（前 12 字节为 00...00:ffff，后 4 字节为 IPv4）
            let prefix = data.prefix(12)
            let mappedPrefix = Data([0,0,0,0, 0,0,0,0, 0,0, 0xff,0xff])
            if prefix == mappedPrefix {
                let ipv4 = data.suffix(4)
                return ipv4.map { String($0) }.joined(separator: ".")
            }
            // 完整 IPv6
            var parts: [String] = []
            for i in stride(from: 0, to: 16, by: 2) {
                let val = UInt16(data[i]) << 8 | UInt16(data[i + 1])
                parts.append(String(val, radix: 16))
            }
            return parts.joined(separator: ":")
        }
        return nil
    }
}
