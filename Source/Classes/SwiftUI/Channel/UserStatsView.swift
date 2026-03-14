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
    @State private var strongCert: Bool = false
    
    private let refreshTimer = Timer.publish(every: 6, on: .main, in: .common).autoconnect()
    
    var body: some View {
        NavigationStack {
            List {
                Section("Connection") {
                    row("User", user.userName() ?? "Unknown")
                    row("Version", version)
                    row("OS", os)
                    row("Online", onlineTime)
                    row("Idle", idleTime)
                }
                
                Section("Audio") {
                    row("TCP Packets", tcpPackets)
                    row("UDP Packets", udpPackets)
                    row("TCP Ping", tcpPing)
                    row("UDP Ping", udpPing)
                    row("Opus", isOpus ? "Yes" : "No")
                }
                
                Section("Bandwidth") {
                    row("Bandwidth", bandwidth)
                    row("Strong Certificate", strongCert ? "Yes" : "No")
                }
            }
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
                serverManager.requestUserStats(for: user)
            }
            .onReceive(refreshTimer) { _ in
                serverManager.requestUserStats(for: user)
            }
            .onReceive(NotificationCenter.default.publisher(for: ServerModelNotificationManager.userStatsReceivedNotification)) { notification in
                guard let stats = notification.userInfo?["stats"] else { return }
                parseStats(stats)
            }
        }
    }
    
    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.body.monospacedDigit())
        }
    }
    
    private func parseStats(_ raw: Any) {
        guard let stats = raw as? NSObject else { return }
        
        if let sess = stats.value(forKey: "session") as? UInt32, sess != UInt32(user.session()) {
            return
        }
        
        if let v = stats.value(forKey: "version") as? NSObject {
            let release = (v.value(forKey: "release") as? String) ?? ""
            let osStr = (v.value(forKey: "os") as? String) ?? ""
            let osVer = (v.value(forKey: "osVersion") as? String) ?? ""
            version = release.isEmpty ? "—" : release
            os = osStr.isEmpty ? "—" : "\(osStr) \(osVer)"
        }
        
        if let secs = stats.value(forKey: "onlinesecs") as? UInt32 {
            onlineTime = formatDuration(secs)
        }
        if let secs = stats.value(forKey: "idlesecs") as? UInt32 {
            idleTime = formatDuration(secs)
        }
        if let bw = stats.value(forKey: "bandwidth") as? UInt32 {
            bandwidth = "\(bw / 1000) kbit/s"
        }
        if let p = stats.value(forKey: "tcpPackets") as? UInt32 {
            tcpPackets = "\(p)"
        }
        if let p = stats.value(forKey: "udpPackets") as? UInt32 {
            udpPackets = "\(p)"
        }
        if let avg = stats.value(forKey: "tcpPingAvg") as? Float,
           let v = stats.value(forKey: "tcpPingVar") as? Float {
            tcpPing = String(format: "%.1f ms (±%.1f)", avg, sqrt(v))
        }
        if let avg = stats.value(forKey: "udpPingAvg") as? Float,
           let v = stats.value(forKey: "udpPingVar") as? Float {
            udpPing = String(format: "%.1f ms (±%.1f)", avg, sqrt(v))
        }
        isOpus = (stats.value(forKey: "opus") as? Bool) ?? false
        strongCert = (stats.value(forKey: "strongCertificate") as? Bool) ?? false
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
}
