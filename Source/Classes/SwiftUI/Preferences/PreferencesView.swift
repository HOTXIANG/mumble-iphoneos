//
//  PreferencesView.swift
//  Mumble
//
//  Created by 王梓田 on 12/8/25.
//

import SwiftUI
import UserNotifications
#if os(iOS)
import UIKit
#endif
#if os(macOS)
import AppKit
import CoreAudio
private let macAudioInputDevicesChangedNotification = Notification.Name("MUMacAudioInputDevicesChanged")
#endif

struct NotificationSettingsView: View {
    @AppStorage("NotificationNotifyNormalUserMessages") var notifyNormalUserMessages: Bool = true
    @AppStorage("NotificationNotifyPrivateMessages") var notifyPrivateMessages: Bool = true
    
    // 系统通知分类开关
    @AppStorage("NotifyUserJoinedSameChannel") var notifyUserJoinedSameChannel: Bool = true
    @AppStorage("NotifyUserLeftSameChannel") var notifyUserLeftSameChannel: Bool = true
    @AppStorage("NotifyUserJoinedOtherChannels") var notifyUserJoinedOtherChannels: Bool = false
    @AppStorage("NotifyUserLeftOtherChannels") var notifyUserLeftOtherChannels: Bool = false
    @AppStorage("NotifyUserMoved") var notifyUserMoved: Bool = true
    @AppStorage("NotifyMuteDeafen") var notifyMuteDeafen: Bool = false
    @AppStorage("NotifyMovedByAdmin") var notifyMovedByAdmin: Bool = true
    @AppStorage("NotifyChannelListening") var notifyChannelListening: Bool = true
    
    var body: some View {
        Form {
            #if os(macOS)
            Section(header: Text("User Messages")) {
                Toggle("User Messages", isOn: $notifyNormalUserMessages)
                Toggle("Private Messages", isOn: $notifyPrivateMessages)
            }
            #else
            Section(header: Text("User Messages"), footer: Text("Notifications will be sent when the app is in the background.")) {
                Toggle("User Messages", isOn: $notifyNormalUserMessages)
                Toggle("Private Messages", isOn: $notifyPrivateMessages)
            }
            #endif
            
            Section(header: Text("System Events")) {
                Toggle("User Joined (Same Channel)", isOn: $notifyUserJoinedSameChannel)
                Toggle("User Left (Same Channel)", isOn: $notifyUserLeftSameChannel)
                Toggle("User Joined (Other Channels)", isOn: $notifyUserJoinedOtherChannels)
                Toggle("User Left (Other Channels)", isOn: $notifyUserLeftOtherChannels)
                Toggle("User Moved Channel", isOn: $notifyUserMoved)
                Toggle("Mute / Deafen", isOn: $notifyMuteDeafen)
                Toggle("Moved by Admin", isOn: $notifyMovedByAdmin)
                Toggle("Channel Listening", isOn: $notifyChannelListening)
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
        .navigationTitle("Notifications")
        .onAppear {
            // 兼容旧版本的单一开关：如果新开关尚未写入，则沿用旧值
            let defaults = UserDefaults.standard
            let legacy = defaults.object(forKey: "NotificationNotifyUserMessages") as? Bool ?? true
            if defaults.object(forKey: "NotificationNotifyNormalUserMessages") == nil {
                notifyNormalUserMessages = legacy
            }
            if defaults.object(forKey: "NotificationNotifyPrivateMessages") == nil {
                notifyPrivateMessages = legacy
            }
            
            // 兼容旧版本的加入/离开总开关，迁移到同频道/异频道四个开关
            if defaults.object(forKey: "NotifyUserJoinedSameChannel") == nil {
                let legacyJoined = defaults.object(forKey: "NotifyUserJoined") as? Bool ?? true
                notifyUserJoinedSameChannel = legacyJoined
            }
            if defaults.object(forKey: "NotifyUserJoinedOtherChannels") == nil {
                notifyUserJoinedOtherChannels = false
            }
            if defaults.object(forKey: "NotifyUserLeftSameChannel") == nil {
                let legacyLeft = defaults.object(forKey: "NotifyUserLeft") as? Bool ?? true
                notifyUserLeftSameChannel = legacyLeft
            }
            if defaults.object(forKey: "NotifyUserLeftOtherChannels") == nil {
                notifyUserLeftOtherChannels = false
            }
            
            // 进入页面时检查/请求权限
            #if os(iOS)
            let options: UNAuthorizationOptions = [.alert, .badge, .sound]
            #else
            let options: UNAuthorizationOptions = [.alert, .sound]
            #endif
            UNUserNotificationCenter.current().requestAuthorization(options: options) { granted, error in
                if let error = error {
                    print("Notification permission error: \(error)")
                }
            }
        }
    }
}

// 1. 传输模式设置视图
struct AudioTransmissionSettingsView: View {
    @AppStorage("AudioTransmitMethod") var transmitMethod: String = "vad"
    @AppStorage("AudioVADKind") var vadKind: String = "amplitude"
    @AppStorage("AudioVADBelow") var vadBelow: Double = 0.3
    @AppStorage("AudioVADAbove") var vadAbove: Double = 0.6
    
    @AppStorage("AudioPreprocessor") var enablePreprocessor: Bool = true
    @AppStorage("AudioEchoCancel") var enableEchoCancel: Bool = true
    @AppStorage("AudioMicBoost") var micBoost: Double = 1.0
    #if os(macOS)
    @AppStorage("AudioFollowSystemInputDevice") private var followSystemInputDevice: Bool = true
    @AppStorage("AudioPreferredInputDeviceUID") private var preferredInputDeviceUID: String = ""
    @State private var devices: [MacInputDeviceOption] = []
    @State private var systemDefaultUID: String = ""
    private let followSystemToken = "__follow_system__"
    #endif
    
    @StateObject private var audioMeter = AudioMeterModel()
    
    var body: some View {
        Form {
            #if os(macOS)
            Section(header: Text("Input Device")) {
                Picker("Microphone", selection: selectedInputDeviceTag) {
                    Text("Follow System Default (\(systemDefaultName))").tag(followSystemToken)
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
                    Text("Selected microphone is unavailable, please choose another one.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Button("Refresh Device List") {
                    refreshDevices()
                    normalizeSelectionIfNeeded()
                }
                .font(.caption)
            }
            #endif
            
            Section(header: Text("Processing")) {
                Toggle("Preprocessing", isOn: $enablePreprocessor)
                if enablePreprocessor {
                    Toggle("Echo Cancellation", isOn: $enableEchoCancel)
                } else {
                    VStack(alignment: .leading) {
                        Text("Mic Volume: \(Int(micBoost * 100))%")
                        Slider(value: $micBoost, in: 0...3.0, step: 0.1) { editing in
                            if !editing { PreferencesModel.shared.notifySettingsChanged() }
                        }
                    }
                }
            }

            Picker("Transmission Method", selection: $transmitMethod) {
                Text("Voice Activated").tag("vad")
                Text("Push-to-Talk").tag("ptt")
                Text("Continuous").tag("continuous")
            }
            .pickerStyle(.menu)
            
            if transmitMethod == "vad" {
                Section(header: Text("Voice Activation Settings")) {
                    // ✅ 修改 1: 使用分段控制器，不再是列表选择
                    Picker("Detection Type", selection: $vadKind) {
                        Text("Amplitude").tag("amplitude")
                        Text("Signal to Noise").tag("snr")
                    }
                    .pickerStyle(.segmented) // 变成左右切换的滑块样式
                    .onChange(of: vadKind) { newValue in
                        // 如果选择了 SNR 且预处理没开，自动开启
                        if newValue == "snr" && !enablePreprocessor {
                            enablePreprocessor = true
                        }
                        
                        // ✅ 修改 2: 延迟通知
                        // 让 UI 先完成切换动画，0.5秒后再去重启音频引擎
                        // 这样用户就不会觉得“卡住”了
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            PreferencesModel.shared.notifySettingsChanged()
                        }
                    }
                    
                    if vadKind == "snr" && !enablePreprocessor {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.yellow)
                            Text("SNR requires Preprocessing")
                                .font(.caption)
                            Spacer()
                            Button("Enable") {
                                enablePreprocessor = true
                                PreferencesModel.shared.notifySettingsChanged()
                            }
                            .font(.caption)
                            .buttonStyle(.bordered)
                        }
                    }
                    
                    VStack(spacing: 8) {
                        HStack {
                            Text("Input Level")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                                            
                        AudioBarView(
                            level: audioMeter.currentLevel,
                            lower: Float(vadBelow),
                            upper: Float(vadAbove)
                        )
                    }
                    .padding(.vertical, 4)
                    
                    VStack(alignment: .leading) {
                        Text("Silence Below: \(Int(vadBelow * 100))%")
                            .font(.caption).foregroundColor(.secondary)
                        Slider(value: $vadBelow, in: 0...1) { editing in
                            if !editing { PreferencesModel.shared.notifySettingsChanged() }
                        }
                    }
                    
                    VStack(alignment: .leading) {
                        Text("Speech Above: \(Int(vadAbove * 100))%")
                            .font(.caption).foregroundColor(.secondary)
                        Slider(value: $vadAbove, in: 0...1) { editing in
                            if !editing { PreferencesModel.shared.notifySettingsChanged() }
                        }
                    }
                    
                    Text("Adjust sliders so that the bar stays in green when speaking and red when silent.")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            }
            
            if transmitMethod == "ptt" {
                Section {
                    Text("In Push-to-Talk mode, a button will appear on the screen. Hold it to speak.")
                        .font(.caption).foregroundColor(.gray)
                }
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
        .navigationTitle("Input Setting")
        .onChange(of: transmitMethod) { PreferencesModel.shared.notifySettingsChanged() }
        .onChange(of: vadKind) { PreferencesModel.shared.notifySettingsChanged() }
        .onChange(of: enablePreprocessor) { PreferencesModel.shared.notifySettingsChanged() }
        .onChange(of: enableEchoCancel) { PreferencesModel.shared.notifySettingsChanged() }
        .onAppear {
            #if os(macOS)
            refreshDevices()
            normalizeSelectionIfNeeded()
            #endif
            audioMeter.startMonitoring()
        }
        .onDisappear {
            audioMeter.stopMonitoring()
        }
        #if os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshDevices()
            normalizeSelectionIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: macAudioInputDevicesChangedNotification)) { _ in
            refreshDevices()
            normalizeSelectionIfNeeded()
        }
        #endif
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
        devices = MacInputDeviceCatalog.inputDevices()
        systemDefaultUID = MacInputDeviceCatalog.defaultInputUID() ?? ""
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

// 2. 音频质量设置视图
struct AudioQualitySettingsView: View {
    @AppStorage("AudioQualityKind") var qualityKind: String = "Balanced"
    
    var body: some View {
        Form {
            Picker("Quality Preset", selection: $qualityKind) {
                Text("Low (60kbit/s)").tag("low")
                Text("Balanced (100kbit/s)").tag("balanced")
                Text("High (192kbit/s)").tag("high")
            }
            .pickerStyle(.menu)
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
        .navigationTitle("Audio Quality")
        .onChange(of: qualityKind) { PreferencesModel.shared.notifySettingsChanged() }
    }
}

// 3. 高级音频设置视图
struct AdvancedAudioSettingsView: View {
    @AppStorage("AudioQualityKind") var qualityKind: String = "balanced"
    @AppStorage("AudioSidetone") var enableSidetone: Bool = false
    @AppStorage("AudioSidetoneVolume") var sidetoneVolume: Double = 0.2
    @AppStorage("AudioSpeakerPhoneMode") var speakerPhoneMode: Bool = true
    @AppStorage("NetworkForceTCP") var forceTCP: Bool = false
    
    var body: some View {
        Form {
            Section(header: Text("Output")) {
                #if os(iOS)
                if UIDevice.current.userInterfaceIdiom == .phone {
                Toggle("Speakerphone Mode", isOn: $speakerPhoneMode)
                }
                #endif
                Toggle("Sidetone (Hear yourself)", isOn: $enableSidetone)
                if enableSidetone {
                    VStack(alignment: .leading) {
                        Text("Sidetone Volume")
                        Slider(value: $sidetoneVolume, in: 0...1) { editing in
                            if !editing { PreferencesModel.shared.notifySettingsChanged() }
                        }
                    }
                }
            }
            
            Section(header: Text("Quality")) {
                Picker("Audio Quality", selection: $qualityKind) {
                    Text("Low (60kbit/s)").tag("low")
                    Text("Balanced (100kbit/s)").tag("balanced")
                    Text("High (192kbit/s)").tag("high")
                }
                .pickerStyle(.menu)
            }
            
            Section(header: Text("Network")) {
                Toggle("Force TCP Mode", isOn: $forceTCP)
                Text("Requires reconnection to take effect.")
                    .font(.caption).foregroundColor(.gray)
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
        .navigationTitle("Advanced")
        .onChange(of: enableSidetone) { PreferencesModel.shared.notifySettingsChanged() }
        .onChange(of: speakerPhoneMode) { PreferencesModel.shared.notifySettingsChanged() }
        .onChange(of: qualityKind) { PreferencesModel.shared.notifySettingsChanged() }
    }
}

#if os(macOS)
private struct MacInputDeviceOption: Identifiable, Hashable {
    let uid: String
    let name: String
    var id: String { uid }
}

private enum MacInputDeviceCatalog {
    static func inputDevices() -> [MacInputDeviceOption] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMaster
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
        
        var options: [MacInputDeviceOption] = []
        for deviceID in deviceIDs {
            guard hasInputStream(deviceID),
                  let uid = deviceUID(for: deviceID),
                  let name = deviceName(for: deviceID) else { continue }
            options.append(MacInputDeviceOption(uid: uid, name: name))
        }
        
        return options.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    
    static func defaultInputUID() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMaster
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
            mElement: kAudioObjectPropertyElementMaster
        )
        var size: UInt32 = 0
        let err = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
        return err == noErr && size > 0
    }
    
    private static func deviceUID(for deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMaster
        )
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let err = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        guard err == noErr, let uid = value else { return nil }
        return uid as String
    }
    
    private static func deviceName(for deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMaster
        )
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let err = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        guard err == noErr, let name = value else { return nil }
        return name as String
    }
}

#endif

// 4. 主设置入口视图
struct PreferencesView: View {
    @EnvironmentObject var serverManager: ServerModelManager
    @AppStorage("AudioOutputVolume") var outputVolume: Double = 1.0
    @AppStorage(MumbleHandoffSyncLocalAudioSettingsKey) var handoffSyncLocalAudioSettings: Bool = true
    @AppStorage("HandoffPreferredProfileKey") var handoffPreferredProfileKey: Int = -1
    @Environment(\.dismiss) var dismiss
    
    // 这里我们还需要暂时保留对旧 Objective-C 证书管理器的引用
    // 因为重写证书逻辑比较复杂，我们先用 Wrapper 兼容

    @ViewBuilder
    private var preferencesContent: some View {
        // --- 音频部分 ---
        Section(header: Text("Audio")) {
            #if os(macOS)
            HStack(spacing: 8) {
                Label("Output Volume", systemImage: "speaker.wave.1")
                    .frame(width: 140, alignment: .leading)
                Slider(value: $outputVolume, in: 0...3, step: 0.1) { editing in
                    if !editing { PreferencesModel.shared.notifySettingsChanged() }
                }
                Text("\(Int(outputVolume * 100))%")
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 56, alignment: .trailing)
            }
            #else
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Output Volume", systemImage: "speaker.wave.2")
                    Spacer()
                    Text("\(Int(outputVolume * 100))%")
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
                HStack(spacing: 8) {
                    Image(systemName: "speaker")
                        .foregroundColor(.secondary)
                        .frame(width: 16)
                    Slider(value: $outputVolume, in: 0...3, step: 0.1) { editing in
                        if !editing { PreferencesModel.shared.notifySettingsChanged() }
                    }
                    Image(systemName: "speaker.wave.3")
                        .foregroundColor(.secondary)
                        .frame(width: 16)
                }
                .padding(.vertical, 4)
            }
            #endif
            
            NavigationLink(destination: AudioTransmissionSettingsView()) {
                Label("Input Setting", systemImage: "mic")
            }
            
            NavigationLink(destination: AdvancedAudioSettingsView()) {
                Label("Advanced & Network", systemImage: "slider.horizontal.3")
            }
        }
        
        // --- 通知部分 ---
        Section(header: Text("Notifications")) {
            NavigationLink(destination: NotificationSettingsView()) {
                Label("Push Notifications", systemImage: "bell.badge")
            }
        }

        // --- 接力部分 ---
        Section(header: Text("Handoff"), footer: Text("Choose which profile to use when continuing a session from another device. 'Automatic' will match by server address.")) {
            HandoffProfilePicker(selectedKey: $handoffPreferredProfileKey)
            
            Toggle("Sync Local User Volume on Handoff", isOn: $handoffSyncLocalAudioSettings)
        }
        
        // --- 身份与证书 ---
        NavigationLink(destination: CertificatePreferencesView()) {
            Label("Certificates", systemImage: "checkmark.shield")
        }
        
        // --- 关于 ---
        Section {
            NavigationLink(destination: AboutView()) {
                Label("About Mumble", systemImage: "info.circle")
            }
        } footer: {
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
            #if os(macOS)
            Text("Mumble macOS v\(version)")
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top)
            #else
            Text("Mumble iOS v\(version)")
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top)
            #endif
        }
    }
    
    var body: some View {
        Group {
            #if os(macOS)
            Form {
                preferencesContent
            }
            .formStyle(.grouped)
            #else
            List {
                preferencesContent
            }
            #endif
        }
        .navigationTitle("Settings")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button("Done") {
                    dismiss()
                }
            }
        }
        .onAppear {
            serverManager.startAudioTest()
        }
    }
}

