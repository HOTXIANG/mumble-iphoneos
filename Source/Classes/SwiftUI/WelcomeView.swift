//
//  WelcomeView.swift
//  Mumble
//
//  Created by 王梓田 on 2025/6/27.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if os(macOS)
import AppKit
import CoreAudio
private let onboardingMacAudioInputDevicesChangedNotification = Notification.Name("MUMacAudioInputDevicesChanged")
#endif

// MARK: - Navigation Configurations

struct WelcomeNavigationConfig: NavigationConfigurable {
    let onPreferences: () -> Void
    let onAbout: () -> Void
    
    var title: String { NSLocalizedString("Mumble", comment: "") }
    var leftBarItems: [NavigationBarItem] {
        #if os(macOS)
        [] // macOS: Settings is in the app menu bar
        #else
        [NavigationBarItem(systemImage: "gearshape", action: onPreferences)]
        #endif
    }
    var rightBarItems: [NavigationBarItem] {
        []
    }
}

// MARK: - Welcome Content View

struct WelcomeContentView: View {
    @EnvironmentObject var navigationManager: NavigationManager
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var lanModel = LanDiscoveryModel()
    @ObservedObject private var recentManager = RecentServerManager.shared
    
    @State private var favouriteServers: [MUFavouriteServer] = []
    @State private var showFavouritesSheet = false

    #if os(macOS)
    private let logoSize: CGFloat = 130
    private let logoShadowWidth: CGFloat = 130
    private let logoShadowHeight: CGFloat = 110
    #else
    private let logoSize: CGFloat = 190
    private let logoShadowWidth: CGFloat = 150
    private let logoShadowHeight: CGFloat = 120
    #endif

    private var logoBlockShadowColor: Color {
        colorScheme == .light ? .black.opacity(0.46) : .black.opacity(0.22)
    }

    private var logoBlockShadowRadius: CGFloat {
        colorScheme == .light ? 40 : 14
    }

    private var logoBlockShadowYOffset: CGFloat {
        colorScheme == .light ? 8 : 6
    }

    private var recentConnectionsRowBackground: AnyView {
        #if os(macOS)
        return AnyView(Color.clear)
        #else
        return AnyView(
            Rectangle()
                .fill(.regularMaterial)
                .overlay(Color.black.opacity(colorScheme == .light ? 0.06 : 0.04))
        )
        #endif
    }
    
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Ellipse()
                    .fill(logoBlockShadowColor)
                    .frame(width: logoShadowWidth, height: logoShadowHeight)
                    .blur(radius: logoBlockShadowRadius)
                    .offset(y: logoBlockShadowYOffset)
                Image("TransparentLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: logoSize, height: logoSize)
            }
                .padding(.top, 8)
                .padding(.bottom, 10)

            VStack(spacing: 6) {
                Text(NSLocalizedString("Join a Server", comment: ""))
                    .font(.system(.title2, design: .rounded, weight: .semibold))
                    .foregroundColor(.primary)
                Text(NSLocalizedString("Choose a favourite server to connect quickly", comment: ""))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 16)
            
            VStack(spacing: 0) {
                
                Button(action: {
                    #if os(iOS)
                    if UIDevice.current.userInterfaceIdiom == .phone {
                        navigationManager.navigate(to: .swiftUI(.favouriteServerList))
                    } else {
                        showFavouritesSheet = true
                    }
                    #else
                    showFavouritesSheet = true
                    #endif
                }) {
                    ViewThatFits(in: .horizontal) {
                        // 宽度足够时：完整显示星星 + 文字 + 箭头
                        HStack(spacing: 16) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 22))
                                .foregroundColor(.yellow)
                                .frame(width: 30)
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text(NSLocalizedString("Favourite Servers", comment: ""))
                                    .font(.headline)
                                    .foregroundColor(.primary)
                                Text(NSLocalizedString("Your saved servers", comment: ""))
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .fontWeight(.bold)
                                .foregroundColor(.indigo)
                        }
                        
                        // 宽度不够时
                        HStack {
                            Image(systemName: "star.fill")
                                .font(.system(size: 22))
                                .foregroundColor(.yellow)
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text(NSLocalizedString("Favourite", comment: ""))
                                    .font(.headline)
                                    .foregroundColor(.primary)
                                Text(NSLocalizedString("Servers", comment: ""))
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .fontWeight(.bold)
                                .foregroundColor(.indigo)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .contentShape(Rectangle())
                    #if os(macOS)
                    .modifier(GlassEffectModifier(cornerRadius: 20))
                    #else
                    .modifier(GlassEffectModifier(cornerRadius: 27))
                    #endif
                }
                .padding(.horizontal, 20)
                .buttonStyle(.plain)
            }
            .padding(.bottom, 20)
            
            List {
                // --- 最近访问 ---
                if !recentManager.recents.isEmpty {
                    Section(header: Text(NSLocalizedString("Recent Connections", comment: ""))) {
                        ForEach(recentManager.recents) { server in
                            ServerListRow(
                                title: server.displayName,
                                subtitle: "\(server.username) @ \(server.hostname):\(server.port)",
                                icon: "clock.fill",
                                iconColor: .blue
                            ) {
                                connectTo(hostname: server.hostname, port: server.port, username: server.username, displayName: server.displayName)
                            }
                            #if os(macOS)
                            .contextMenu {
                                Button(role: .destructive) {
                                    deleteRecentConnection(hostname: server.hostname, port: server.port, username: server.username)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            #endif
                        }
                        #if os(iOS)
                        .onDelete { indexSet in
                            recentManager.recents.remove(atOffsets: indexSet)
                        }
                        #endif
                    }
                    .listRowBackground(recentConnectionsRowBackground)
                } else if lanModel.servers.isEmpty {
                    // 如果既没有最近记录，也没有 LAN 服务器，显示一个占位提示
                    Section {
                        Text(NSLocalizedString("No recent connections.", comment: ""))
                            .font(.caption)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .foregroundColor(.secondary)
                            .listRowBackground(Color.clear)
                    }
                }
                
                // --- LAN ---
                if !lanModel.servers.isEmpty {
                    Section(header: Text(NSLocalizedString("Local Network", comment: ""))) {
                        ForEach(lanModel.servers) { server in
                            ServerListRow(
                                title: server.name,
                                subtitle: "\(server.hostname):\(server.port)",
                                icon: "network",
                                iconColor: .green
                            ) {
                                let defaultUser = UserDefaults.standard.string(forKey: "DefaultUserName") ?? "MumbleUser"
                                connectTo(hostname: server.hostname, port: server.port, username: defaultUser, displayName: server.name)
                            }
                        }
                    }
                    .listRowBackground(Rectangle().fill(.regularMaterial))
                }
            }
            .scrollContentBackground(.hidden)
            #if os(iOS)
            .listStyle(.insetGrouped)
            #else
            .listStyle(.inset)
            #endif
        }
        .background(Color.clear)
        .onAppear {
            lanModel.start()
        }
        .onDisappear {
            lanModel.stop()
        }
        .sheet(isPresented: $showFavouritesSheet) {
            NavigationStack {
                FavouriteServerListView(isModalPresentation: true)
                    .environmentObject(navigationManager)
            }
            #if os(macOS)
            .frame(minWidth: 500, idealWidth: 600, minHeight: 450, idealHeight: 550)
            #elseif os(iOS)
            .presentationDetents([.large])
            #endif
        }
    }
    
    private func connectTo(hostname: String, port: Int, username: String, displayName: String) {
        // 触发连接
        AppState.shared.serverDisplayName = hostname
        PlatformImpactFeedback(style: .medium).impactOccurred()
        
        // 尝试从收藏夹查找匹配的证书和密码（大小写不敏感匹配 hostname）
        var certRef: Data? = nil
        var password: String = ""
        let allFavs = MUDatabase.fetchAllFavourites() as? [MUFavouriteServer] ?? []
        if let match = allFavs.first(where: {
            $0.hostName?.caseInsensitiveCompare(hostname) == .orderedSame
            && $0.port == UInt(port)
            && $0.userName == username
        }) {
            certRef = match.certificateRef
            password = match.password ?? ""
        }
        
        MUConnectionController.shared()?.connect(
            toHostname: hostname,
            port: UInt(port),
            withUsername: username,
            andPassword: password,
            certificateRef: certRef,
            displayName: displayName
        )
        
        // 最近连接由 MUConnectionController 内部调用 RecentServerManager.addRecent 自动记录
        // Widget 数据也由 RecentServerManager 自动同步
    }

    private func deleteRecentConnection(hostname: String, port: Int, username: String) {
        recentManager.recents.removeAll { item in
            item.hostname == hostname && item.port == port && item.username == username
        }
    }
}

struct ServerListRow: View {
    let title: String
    let subtitle: String
    let icon: String
    let iconColor: Color
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(iconColor)
                    .frame(width: 24)
                    .font(.system(size: 18))
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
            }
            .padding(.vertical, 4)
        }
    }
}

struct WelcomeView: MumbleContentView {
    @State private var showingPreferences = false
    @State private var showingAbout = false
    @EnvironmentObject var navigationManager: NavigationManager
    @EnvironmentObject var serverManager: ServerModelManager
    
    var navigationConfig: any NavigationConfigurable {
        WelcomeNavigationConfig(
            onPreferences: { showingPreferences = true },
            onAbout: { showingAbout = true }
        )
    }
    
    var contentBody: some View {
        WelcomeContentView()
            #if os(iOS)
            .sheet(isPresented: $showingPreferences, onDismiss: {
                serverManager.stopAudioTest()
            }) {
                NavigationStack {
                    PreferencesView()
                        .environmentObject(serverManager)
                }
                #if os(macOS)
                .frame(minWidth: 500, idealWidth: 600, minHeight: 500, idealHeight: 650)
                #endif
            }
            #endif
    }
}

struct MumbleNavigationModifier: ViewModifier {
    let config: NavigationConfigurable
    
    func body(content: Content) -> some View {
        content
            .navigationTitle(config.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            #endif
            .toolbar {
                #if os(iOS)
                ToolbarItemGroup(placement: .navigationBarLeading) {
                    ForEach(Array(config.leftBarItems.enumerated()), id: \.offset) { _, item in
                        createBarButton(item)
                    }
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    ForEach(Array(config.rightBarItems.enumerated()), id: \.offset) { _, item in
                        createBarButton(item)
                    }
                }
                #else
                ToolbarItemGroup(placement: .automatic) {
                    ForEach(Array(config.leftBarItems.enumerated()), id: \.offset) { _, item in
                        createBarButton(item)
                    }
                    ForEach(Array(config.rightBarItems.enumerated()), id: \.offset) { _, item in
                        createBarButton(item)
                    }
                }
                #endif
            }
    }
    
    @ViewBuilder
    private func createBarButton(_ item: NavigationBarItem) -> some View {
        Button(action: item.action) {
            if let title = item.title {
                Text(NSLocalizedString(title, comment: ""))
            } else if let systemImage = item.systemImage {
                Image(systemName: systemImage)
                    #if os(macOS)
                    .font(.system(size: 16))
                    #endif
            }
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.primary)
    }
}

// MARK: - App Root View (Split View & Stack Logic)

#if os(macOS)
private struct OnboardingMacInputDeviceOption: Identifiable, Hashable {
    let uid: String
    let name: String
    var id: String { uid }
}

private enum OnboardingMacInputDeviceCatalog {
    static func inputDevices() -> [OnboardingMacInputDeviceOption] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var dataSize: UInt32 = 0
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &dataSize) == noErr,
              dataSize >= UInt32(MemoryLayout<AudioDeviceID>.size) else {
            return []
        }
        
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &dataSize, &deviceIDs) == noErr else {
            return []
        }
        
        var options: [OnboardingMacInputDeviceOption] = []
        for deviceID in deviceIDs {
            guard hasInputStream(deviceID),
                  let uid = deviceUID(for: deviceID),
                  let name = deviceName(for: deviceID) else { continue }
            options.append(OnboardingMacInputDeviceOption(uid: uid, name: name))
        }
        
        return options.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    
    static func defaultInputUID() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let err = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard err == noErr else { return nil }
        return deviceUID(for: deviceID)
    }
    
    private static func hasInputStream(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let err = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
        return err == noErr && size > 0
    }
    
    private static func deviceUID(for deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let err = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        guard err == noErr, let value else { return nil }
        return value.takeUnretainedValue() as String
    }
    
    private static func deviceName(for deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let err = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        guard err == noErr, let value else { return nil }
        return value.takeUnretainedValue() as String
    }
}
#endif

private struct VADOnboardingSplashView: View {
    let onFinish: () -> Void
    let onStartAudioTest: () -> Void
    let onStopAudioTest: () -> Void
    @StateObject private var audioMeter = AudioMeterModel()
    
    @AppStorage("AudioVADKind") private var vadKind: String = "amplitude"
    @AppStorage("AudioVADBelow") private var vadBelow: Double = 0.3
    @AppStorage("AudioVADAbove") private var vadAbove: Double = 0.6
    @AppStorage("AudioVADHoldSeconds") private var vadHoldSeconds: Double = 0.1
    
    private let minThreshold: Double = 0.0
    private let maxThreshold: Double = 1.0
    private let minGap: Double = 0.05
    #if os(macOS)
    @AppStorage("AudioFollowSystemInputDevice") private var followSystemInputDevice: Bool = true
    @AppStorage("AudioPreferredInputDeviceUID") private var preferredInputDeviceUID: String = ""
    @State private var devices: [OnboardingMacInputDeviceOption] = []
    @State private var systemDefaultUID: String = ""
    private let followSystemToken = "__follow_system__"
    #endif
    
    private var belowBinding: Binding<Double> {
        Binding(
            get: { vadBelow },
            set: { newValue in
                let clamped = max(minThreshold, min(maxThreshold, newValue))
                vadBelow = min(clamped, vadAbove - minGap)
            }
        )
    }
    
    private var aboveBinding: Binding<Double> {
        Binding(
            get: { vadAbove },
            set: { newValue in
                let clamped = max(minThreshold, min(maxThreshold, newValue))
                vadAbove = max(clamped, vadBelow + minGap)
            }
        )
    }
    
    private var belowPercentLabel: String { "\(Int((vadBelow * 100).rounded()))%" }
    private var abovePercentLabel: String { "\(Int((vadAbove * 100).rounded()))%" }
    private var holdMillisLabel: String { "\(Int((vadHoldSeconds * 1000).rounded())) ms" }
    private var inputPercentLabel: String {
        "\(Int((Double(audioMeter.currentLevel) * 100).rounded()))%"
    }
    private var holdBinding: Binding<Double> {
        Binding(
            get: { min(max(vadHoldSeconds, 0.0), 0.3) },
            set: { vadHoldSeconds = min(max($0, 0.0), 0.3) }
        )
    }
    private var modeDescription: String {
        if vadKind == "snr" {
            return NSLocalizedString(
                "Signal to Noise (SNR): detects speech by comparing voice against background noise. Better in noisy environments.",
                comment: ""
            )
        }
        return NSLocalizedString(
            "Amplitude: detects speech by raw input loudness. Simpler and usually more responsive in quiet environments.",
            comment: ""
        )
    }
    private var vadThresholdHelpText: String {
        let silenceBelow = NSLocalizedString(
            "Silence Below: input under this level is treated as silence.",
            comment: ""
        )
        let speechAbove = NSLocalizedString(
            "Speech Above: input over this level is treated as speech.",
            comment: ""
        )
        let silenceHold = NSLocalizedString(
            "Silence Hold: when input stays below Silence Below for this duration, it finally switches to silent.",
            comment: ""
        )
        return [silenceBelow, speechAbove, silenceHold].joined(separator: "\n")
    }
    private var systemSheetBackground: Color {
        #if os(macOS)
        return Color(nsColor: .windowBackgroundColor)
        #else
        return Color(uiColor: .systemBackground)
        #endif
    }
    
    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 8) {
                Image(systemName: "waveform.badge.mic")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundColor(.indigo)
                
                VStack(spacing: 8) {
                    Text(NSLocalizedString("Welcome to Mumble", comment: ""))
                        .font(.system(.title2, design: .rounded, weight: .bold))
                    Text(NSLocalizedString("Let's quickly tune your voice activity threshold for better automatic mic detection.", comment: ""))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                
                VStack(spacing: 8) {
                    #if os(macOS)
                    VStack(alignment: .center, spacing: 8) {
                        Text("Input Device")
                            .font(.headline)
                        Picker("", selection: selectedInputDeviceTag) {
                            Text(
                                String(
                                    format: NSLocalizedString("Follow System Default (%@)", comment: ""),
                                    systemDefaultName
                                )
                            ).tag(followSystemToken)
                            if devices.isEmpty {
                                Text("No Input Device").tag("")
                            } else {
                                ForEach(devices) { device in
                                    Text(device.name).tag(device.uid)
                                }
                            }
                        }
                        .pickerStyle(.menu)
                        
                        if !followSystemInputDevice && selectedDeviceMissing {
                            Text("Selected microphone is unavailable, automatically switched to Follow System.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    #endif
                    
                    VStack(alignment: .center, spacing: 8) {
                        Text("Detection Mode")
                            .font(.headline)
                        Picker("", selection: $vadKind) {
                            Text("Amplitude").tag("amplitude")
                            Text("Signal to Noise").tag("snr")
                        }
                        .pickerStyle(.segmented)
                        
                        Text(modeDescription)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.leading)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .layoutPriority(1)
                        
                    }
                    
                    HStack {
                        Text("Live Input Level")
                            .font(.headline)
                        Spacer()
                        Text(inputPercentLabel)
                            .font(.headline)
                            .foregroundColor(.secondary)
                    }
                    AudioBarView(
                        level: audioMeter.currentLevel,
                        lower: Float(vadBelow),
                        upper: Float(vadAbove)
                    )
                    
                    HStack {
                        Text("Silence Below")
                            .font(.headline)
                        Spacer()
                        Text(belowPercentLabel)
                            .font(.headline)
                            .foregroundColor(.secondary)
                    }
                    Slider(value: belowBinding, in: minThreshold...(maxThreshold - minGap))
                        .tint(.indigo)
                    
                    HStack {
                        Text("Speech Above")
                            .font(.headline)
                        Spacer()
                        Text(abovePercentLabel)
                            .font(.headline)
                            .foregroundColor(.secondary)
                    }
                    Slider(value: aboveBinding, in: (minThreshold + minGap)...maxThreshold)
                        .tint(.indigo)
                    
                    HStack {
                        Text("Silence Hold")
                            .font(.headline)
                        Spacer()
                        Text(holdMillisLabel)
                            .font(.headline)
                            .foregroundColor(.secondary)
                    }
                    Slider(value: holdBinding, in: 0...0.3, step: 0.01)
                        .tint(.indigo)
                }
                
                Text(vadThresholdHelpText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                
                Button("Continue") {
                    onFinish()
                }
                .font(.headline.weight(.semibold))
                .controlSize(.large)
                .frame(maxWidth: .infinity, minHeight: 32)
                .buttonStyle(.borderedProminent)
            }
            .padding(24)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(systemSheetBackground.ignoresSafeArea())
        .onAppear {
            #if os(macOS)
            refreshDevices()
            normalizeSelectionIfNeeded()
            #endif
            onStartAudioTest()
            // Defensive delayed start to survive any late stop from settings dismissal.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                onStartAudioTest()
            }
            audioMeter.startMonitoring()
        }
        .onDisappear {
            audioMeter.stopMonitoring()
            onStopAudioTest()
        }
        #if os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshDevices()
            normalizeSelectionIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: onboardingMacAudioInputDevicesChangedNotification)) { _ in
            refreshDevices()
            normalizeSelectionIfNeeded()
        }
        #endif
        .onChange(of: vadKind) { _, newValue in
            // Keep splash behavior aligned with Input Setting.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                PreferencesModel.shared.notifySettingsChanged()
            }
        }
    }
    
    #if os(macOS)
    private var selectedInputDeviceTag: Binding<String> {
        Binding<String>(
            get: {
                followSystemInputDevice ? followSystemToken : preferredInputDeviceUID
            },
            set: { newValue in
                if newValue == followSystemToken {
                    followSystemInputDevice = true
                } else {
                    followSystemInputDevice = false
                    preferredInputDeviceUID = newValue
                    normalizeSelectionIfNeeded()
                }
                PreferencesModel.shared.notifySettingsChanged()
            }
        )
    }
    
    private var selectedDeviceMissing: Bool {
        !preferredInputDeviceUID.isEmpty && !devices.contains(where: { $0.uid == preferredInputDeviceUID })
    }
    
    private var systemDefaultName: String {
        if let current = devices.first(where: { $0.uid == systemDefaultUID }) {
            return current.name
        }
        return "Unknown"
    }
    
    private func refreshDevices() {
        devices = OnboardingMacInputDeviceCatalog.inputDevices()
        systemDefaultUID = OnboardingMacInputDeviceCatalog.defaultInputUID() ?? ""
    }
    
    private func normalizeSelectionIfNeeded() {
        var changed = false
        guard !devices.isEmpty else {
            if !followSystemInputDevice {
                followSystemInputDevice = true
                changed = true
            }
            if !preferredInputDeviceUID.isEmpty {
                preferredInputDeviceUID = ""
                changed = true
            }
            if changed {
                PreferencesModel.shared.notifySettingsChanged()
            }
            return
        }
        
        if !followSystemInputDevice,
           (preferredInputDeviceUID.isEmpty || !devices.contains(where: { $0.uid == preferredInputDeviceUID })) {
            followSystemInputDevice = true
            preferredInputDeviceUID = ""
            changed = true
        }
        
        if changed {
            PreferencesModel.shared.notifySettingsChanged()
        }
    }
    #endif
}

struct AppRootView: View {
    @ObservedObject private var appState = AppState.shared
    @Environment(\.colorScheme) private var colorScheme
    
    @StateObject private var serverManager: ServerModelManager
    @StateObject private var languageManager = AppLanguageManager.shared
    @AppStorage("AppColorScheme") private var appColorSchemeRawValue: String = AppColorSchemeOption.system.rawValue
    @AppStorage("HasCompletedVADOnboarding") private var hasCompletedVADOnboarding: Bool = false
    @State private var showVADOnboarding = false
    
    // iPhone 使用的单一导航管理器
    @StateObject private var navigationManager = NavigationManager()
    
    // iPad 使用的侧边栏导航管理器 (让 Detail 独立变化)
    @StateObject private var sidebarNavigationManager = NavigationManager()
 
    @State private var preferredCompactColumn: NavigationSplitViewColumn = .sidebar
    @State private var splitVisibility: NavigationSplitViewVisibility = .automatic

    #if os(iOS)
    private let narrowWindowThreshold: CGFloat = 700
    #else
    private let narrowWindowThreshold: CGFloat = 1100
    #endif

    private var selectedAppColorScheme: AppColorSchemeOption {
        AppColorSchemeOption.normalized(from: appColorSchemeRawValue)
    }

    init(serverManager: ServerModelManager = ServerModelManager()) {
        _serverManager = StateObject(wrappedValue: serverManager)
    }
    
    var body: some View {
        // 内容区域
        Group {
            #if os(iOS)
            if UIDevice.current.userInterfaceIdiom == .pad {
                iPadLayout
            } else {
                iPhoneLayout
            }
            #else
            iPadLayout
            #endif
        }
        .environment(\.locale, Locale(identifier: languageManager.localeIdentifier))
        .preferredColorScheme(selectedAppColorScheme.preferredColorScheme)
        .environmentObject(serverManager)
        .focusedValue(\.serverManager, serverManager)
        // --- 全局覆盖层 (Toast, PTT, Connect Loading) ---
        .overlay(alignment: .top) {
            if let toast = appState.activeToast {
                ToastView(toast: toast)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(2000)
                    .onTapGesture { withAnimation { appState.activeToast = nil } }
            }
        }
        .overlay(alignment: .bottom) {
            // 连接成功后显示 PTT 按钮
            if appState.isConnected {
                ZStack {
                    #if os(macOS)
                    PTTKeyboardMonitor()
                    #endif
                    PTTButton()
                        .padding(.bottom, 20)
                }
            }
        }
        .overlay {
            if appState.isConnecting {
                ZStack {
                    Color.black
                        .opacity(colorScheme == .dark ? 0.58 : 0.28)
                        .ignoresSafeArea()
                        .onTapGesture { }
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.large)
                            .tint(.accentColor)
                        Text(
                            appState.isReconnecting
                                ? NSLocalizedString("Reconnecting...", comment: "")
                                : NSLocalizedString("Connecting...", comment: "")
                        )
                            .font(.headline)
                            .foregroundColor(.primary)
                        Button(action: { appState.cancelConnection() }) {
                            Text("Cancel")
                                .font(.subheadline).fontWeight(.semibold).foregroundColor(.white)
                                .padding(.horizontal, 32).padding(.vertical, 4)
                        }
                        .modifier(RedGlassCapsuleModifier())
                        .clipShape(Capsule())
                        .contentShape(Capsule())
                    }
                    .padding(.horizontal, 64).padding(.vertical, 24)
                    .modifier(GlassEffectModifier(cornerRadius: 32))
                    .shadow(radius: 10)
                }
                .ignoresSafeArea().zIndex(9999)
                .transition(.opacity.animation(.easeInOut(duration: 0.3)))
            }
        }
        .sheet(isPresented: $showVADOnboarding) {
            VADOnboardingSplashView {
                hasCompletedVADOnboarding = true
                showVADOnboarding = false
            } onStartAudioTest: {
                serverManager.startAudioTest()
            } onStopAudioTest: {
                serverManager.stopAudioTest()
            }
            #if os(iOS)
            .presentationDetents([.large])
            #else
            .frame(minWidth: 400, idealWidth: 600, minHeight: 300, idealHeight: 660)
            #endif
            .onAppear {
                // Defensive start for iOS: avoid race with settings-sheet onDismiss stop.
                serverManager.startAudioTest()
            }
        }
        // macOS 全窗口图片预览 overlay（覆盖整个 App 界面，包括分栏）
        #if os(macOS)
        .overlay {
            if let image = appState.previewImage {
                MacImagePreviewOverlay(image: image) {
                    appState.previewImage = nil
                }
                .transition(.opacity)
                .zIndex(10000)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: appState.previewImage != nil)
        #endif
        .alert(item: $appState.activeError) { error in
            Alert(title: Text(error.title), message: Text(error.message), dismissButton: .default(Text("OK")))
        }
        .onReceive(NotificationCenter.default.publisher(for: .mumbleShowVADTutorialAgain)) { _ in
            // Delay to avoid racing with settings-sheet onDismiss stopAudioTest().
            // We re-open tutorial after settings has fully dismissed.
            showVADOnboarding = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                showVADOnboarding = true
            }
        }
        .onAppear {
            languageManager.reapplyCurrentLanguage()
            serverManager.activate()
            if !hasCompletedVADOnboarding {
                showVADOnboarding = true
            }
        }
        .animation(.default, value: appState.isConnecting)
        .animation(.spring(), value: appState.isConnected)
        .animation(.easeInOut(duration: 0.2), value: showVADOnboarding)
    }
    
    // MARK: - iPad Split View Layout
    
    var iPadLayout: some View {
        GeometryReader { geo in
            NavigationSplitView(columnVisibility: $splitVisibility, preferredCompactColumn: $preferredCompactColumn) {
                // 左侧 Sidebar：使用独立的 sidebarNavigationManager
                NavigationStack(path: $sidebarNavigationManager.navigationPath) {
                    WelcomeView()
                        .navigationDestination(for: NavigationDestination.self) { destination in
                            destinationView(for: destination, navigationManager: sidebarNavigationManager)
                                .environmentObject(sidebarNavigationManager)
                        }
                        .background(Color.clear)
                }
                .environmentObject(sidebarNavigationManager)
                .navigationSplitViewColumnWidth(min: 220, ideal: 290, max: 360)
                .background(Color.clear)
            } detail: {
                ZStack {
                    if appState.isConnected {
                        NavigationStack {
                            ChannelListView()
                                .environmentObject(NavigationManager())
                        }
                    } else {
                        ContentUnavailableView {
                            Label(NSLocalizedString("No Server Connected", comment: ""), systemImage: "server.rack")
                        } description: {
                            Text(NSLocalizedString("Select a server from the sidebar to start chatting.", comment: ""))
                        }
                    }
                }
                .background(Color.clear) // Detail 区域透明
            }
            .onChange(of: appState.isConnected) { _, isConnected in
                preferredCompactColumn = isConnected ? .detail : .sidebar
                updateSplitVisibility(width: geo.size.width, connectionChanged: true)
            }
            .onChange(of: geo.size.width) { _, width in
                updateSplitVisibility(width: width, connectionChanged: false)
            }
            .onAppear {
                if appState.isConnected {
                    preferredCompactColumn = .detail
                }
                updateSplitVisibility(width: geo.size.width, connectionChanged: false)
            }
            #if os(iOS)
            .navigationSplitViewStyle(.balanced)
            #else
            .navigationSplitViewStyle(.prominentDetail)
            #endif
            .background(Color.clear)
        }
    }

    private func updateSplitVisibility(width: CGFloat, connectionChanged: Bool) {
        #if os(iOS)
        // iPad：连接服务器后主动关闭侧边栏，调整窗口大小时不自动弹出
        if connectionChanged {
            if appState.isConnected {
                splitVisibility = .detailOnly
            } else {
                splitVisibility = .all
            }
        }
        // 宽度变化时不主动改变侧边栏状态，用户可通过按钮手动打开
        #else
        // macOS：根据窗口宽度自动切换
        if appState.isConnected && width < narrowWindowThreshold {
            splitVisibility = .detailOnly
        } else {
            splitVisibility = .all
        }
        #endif
    }
    
    // MARK: - iPhone Stack Layout
    
    var iPhoneLayout: some View {
        NavigationStack(path: $navigationManager.navigationPath) {
            WelcomeView()
                .navigationDestination(for: NavigationDestination.self) { destination in
                    destinationView(for: destination, navigationManager: navigationManager)
                        .environmentObject(navigationManager)
                }
        }
        .environmentObject(navigationManager)
        .background(Color.clear)
        // iPhone 需要手动监听连接状态来 Push 界面
        .onChange(of: appState.isConnected) { _, isConnected in
            if isConnected {
                navigationManager.navigate(to: .swiftUI(.channelList))
            } else {
                navigationManager.goToRoot()
            }
        }
    }
    
    // MARK: - Helper
    
    @ViewBuilder
    private func destinationView(for destination: NavigationDestination, navigationManager: NavigationManager) -> some View {
        switch destination {
        case .swiftUI(let type):
            switch type {
            case .favouriteServerList:
                FavouriteServerListView()
            case .favouriteServerEdit(let primaryKey):
                let server: MUFavouriteServer? = {
                    guard let key = primaryKey else { return nil }
                    if let allFavourites = MUDatabase.fetchAllFavourites() as? [MUFavouriteServer] {
                        return allFavourites.first { $0.primaryKey == key }
                    }
                    return nil
                }()
                FavouriteServerEditView(server: server) { serverToSave in
                    MUDatabase.storeFavourite(serverToSave)
                    navigationManager.goBack()
                }
            case .channelList:
                ChannelListView()
            }
        }
    }
}
