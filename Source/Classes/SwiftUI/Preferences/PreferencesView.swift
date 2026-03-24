//
//  PreferencesView.swift
//  Mumble
//
//  Created by 王梓田 on 12/8/25.
//

import SwiftUI
import UserNotifications
import ObjectiveC.runtime
@preconcurrency import AVFoundation
#if os(iOS)
import UIKit
import CoreAudioKit
typealias PlatformViewController = UIViewController
#elseif os(macOS)
import AppKit
import CoreAudioKit
typealias PlatformViewController = NSViewController
#endif

// AVAudioUnit is not Sendable but is safe to use when accessed from the same actor
extension AVAudioUnit: @unchecked Sendable {}

struct PTTHotkeyOption: Identifiable {
    let keyCode: Int
    let label: String
    var id: Int { keyCode }
}

let pttHotkeyOptions: [PTTHotkeyOption] = [
    .init(keyCode: 49, label: "Space"),
    .init(keyCode: 36, label: "Return"),
    .init(keyCode: 48, label: "Tab"),
    .init(keyCode: 56, label: "Left Shift"),
    .init(keyCode: 60, label: "Right Shift"),
    .init(keyCode: 58, label: "Left Option"),
    .init(keyCode: 61, label: "Right Option"),
    .init(keyCode: 59, label: "Left Control"),
    .init(keyCode: 62, label: "Right Control"),
    .init(keyCode: 55, label: "Left Command"),
    .init(keyCode: 54, label: "Right Command"),
]

struct MacInputDeviceOption: Identifiable, Hashable {
    let uid: String
    let name: String
    var id: String { uid }
}

enum AppLanguageOption: String, CaseIterable, Identifiable {
    case system = "system"
    case english = "en"
    case chineseSimplified = "zh-Hans"

    var id: String { rawValue }

    var localizedLabel: String {
        switch self {
        case .system:
            return NSLocalizedString("System Default", comment: "")
        case .english:
            return NSLocalizedString("English", comment: "")
        case .chineseSimplified:
            return NSLocalizedString("Chinese (Simplified)", comment: "")
        }
    }
}

enum AppColorSchemeOption: String, CaseIterable, Identifiable {
    case system = "system"
    case light = "light"
    case dark = "dark"

    var id: String { rawValue }

    var localizedLabel: String {
        switch self {
        case .system:
            return NSLocalizedString("System Default", comment: "")
        case .light:
            return NSLocalizedString("Light", comment: "")
        case .dark:
            return NSLocalizedString("Dark", comment: "")
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }

    static func normalized(from rawValue: String) -> AppColorSchemeOption {
        AppColorSchemeOption(rawValue: rawValue) ?? .system
    }
}

private enum LanguageBundleAssociation {
    // Objective-C associated object key. This is only used as an address token.
    nonisolated(unsafe) static var key: UInt8 = 0
}

struct SettingsColorSchemeOverrideModifier: ViewModifier {
    let option: AppColorSchemeOption

    @ViewBuilder
    func body(content: Content) -> some View {
        if option == .system {
            content
        } else {
            content.preferredColorScheme(option.preferredColorScheme)
        }
    }
}

private final class OverridableMainBundle: Bundle, @unchecked Sendable {
    override func localizedString(forKey key: String, value: String?, table tableName: String?) -> String {
        if let bundle = objc_getAssociatedObject(self, &LanguageBundleAssociation.key) as? Bundle {
            return bundle.localizedString(forKey: key, value: value, table: tableName)
        }
        return super.localizedString(forKey: key, value: value, table: tableName)
    }
}

private enum BundleLanguageApplier {
    static func apply(languageCode: String?) {
        object_setClass(Bundle.main, OverridableMainBundle.self)

        let overrideBundle = languageCode.flatMap { code -> Bundle? in
            let candidates = [
                code,
                code.replacingOccurrences(of: "_", with: "-"),
                String(code.split(separator: "-").first ?? "")
            ].filter { !$0.isEmpty }

            for candidate in candidates {
                if let path = Bundle.main.path(forResource: candidate, ofType: "lproj"),
                   let bundle = Bundle(path: path) {
                    return bundle
                }
            }
            return nil
        }

        objc_setAssociatedObject(
            Bundle.main,
            &LanguageBundleAssociation.key,
            overrideBundle,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }
}

@MainActor
final class AppLanguageManager: ObservableObject {
    static let shared = AppLanguageManager()
    static let storageKey = "AppLanguageCode"

    @Published private(set) var selectedOption: AppLanguageOption

    private init() {
        let savedCode = UserDefaults.standard.string(forKey: Self.storageKey) ?? AppLanguageOption.system.rawValue
        selectedOption = Self.normalizedOption(from: savedCode)
        // App launch 时就应用覆盖，避免进入界面后才切语言。
        BundleLanguageApplier.apply(languageCode: bundleLanguageCode(for: selectedOption))
    }

    var selectedRawValue: String { selectedOption.rawValue }

    var localeIdentifier: String {
        switch selectedOption {
        case .system:
            return Locale.preferredLanguages.first ?? "en"
        case .english, .chineseSimplified:
            return selectedOption.rawValue
        }
    }

    func setLanguage(rawValue: String) {
        let normalized = Self.normalizedOption(from: rawValue)
        if normalized != selectedOption {
            selectedOption = normalized
        }
        persistLanguagePreference(option: normalized)
        BundleLanguageApplier.apply(languageCode: bundleLanguageCode(for: normalized))
    }

    func reapplyCurrentLanguage() {
        persistLanguagePreference(option: selectedOption)
        BundleLanguageApplier.apply(languageCode: bundleLanguageCode(for: selectedOption))
    }

    private func bundleLanguageCode(for option: AppLanguageOption) -> String? {
        option == .system ? nil : option.rawValue
    }

    private static func normalizedOption(from rawValue: String) -> AppLanguageOption {
        AppLanguageOption(rawValue: rawValue) ?? .system
    }

    private func persistLanguagePreference(option: AppLanguageOption) {
        let defaults = UserDefaults.standard
        defaults.set(option.rawValue, forKey: Self.storageKey)
        if option == .system {
            defaults.removeObject(forKey: "AppleLanguages")
        } else {
            defaults.set([option.rawValue], forKey: "AppleLanguages")
        }
        defaults.synchronize()
    }
}

struct NotificationSettingsView: View {
    @AppStorage("NotificationNotifyNormalUserMessages") var notifyNormalUserMessages: Bool = true
    @AppStorage("NotificationNotifyPrivateMessages") var notifyPrivateMessages: Bool = true
    @AppStorage("NotificationEnableInAppMessageBanners") var enableInAppMessageBanners: Bool = true
    
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
            notificationSettingsContent
        }
        .navigationTitle("Notifications")
        .onAppear {
            AppState.shared.setAutomationCurrentScreen("notificationSettings")
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
            UNUserNotificationCenter.current().requestAuthorization(options: notificationAuthorizationOptions) { granted, error in
                if let error = error {
                    MumbleLogger.notification.error("Notification permission error: \(error)")
                }
            }
        }
    }
}

struct TTSSettingsView: View {
    @AppStorage("EnableTTS") var enableTTS: Bool = false

    @AppStorage("TTSNotifyNormalUserMessages") var ttsNormalUserMessages: Bool = true
    @AppStorage("TTSNotifyPrivateMessages") var ttsPrivateMessages: Bool = true
    @AppStorage("TTSNotifyUserJoinedSameChannel") var ttsUserJoinedSameChannel: Bool = true
    @AppStorage("TTSNotifyUserLeftSameChannel") var ttsUserLeftSameChannel: Bool = true
    @AppStorage("TTSNotifyUserJoinedOtherChannels") var ttsUserJoinedOtherChannels: Bool = false
    @AppStorage("TTSNotifyUserLeftOtherChannels") var ttsUserLeftOtherChannels: Bool = false
    @AppStorage("TTSNotifyUserMoved") var ttsUserMoved: Bool = true
    @AppStorage("TTSNotifyMuteDeafen") var ttsMuteDeafen: Bool = false
    @AppStorage("TTSNotifyMovedByAdmin") var ttsMovedByAdmin: Bool = true
    @AppStorage("TTSNotifyChannelListening") var ttsChannelListening: Bool = true
    @AppStorage("TTSNotifyGenericSystemEvents") var ttsGenericSystemEvents: Bool = true

    var body: some View {
        Form {
            #if os(macOS)
            Section {
                LabeledContent("Text-to-Speech:") {
                    Toggle("", isOn: $enableTTS)
                        .labelsHidden()
                }

                Text("When enabled, selected notification types will be spoken. During TTS playback, speaking may be temporarily unavailable.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 220, alignment: .leading)
                    .padding(.bottom, 2)
            }
            #else
            Section {
                Toggle("Enable Text-to-Speech", isOn: $enableTTS)
            } footer: {
                Text("When enabled, selected notification types will be spoken. During TTS playback, speaking may be temporarily unavailable.")
            }
            #endif

            #if os(macOS)
            Section {
                LabeledContent("User Messages:") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("User Messages", isOn: $ttsNormalUserMessages)
                        Toggle("Private Messages", isOn: $ttsPrivateMessages)
                    }
                    .padding(.bottom, 4)
                }

                LabeledContent("System Events:") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("User Joined (Same Channel)", isOn: $ttsUserJoinedSameChannel)
                        Toggle("User Left (Same Channel)", isOn: $ttsUserLeftSameChannel)
                        Toggle("User Joined (Other Channels)", isOn: $ttsUserJoinedOtherChannels)
                        Toggle("User Left (Other Channels)", isOn: $ttsUserLeftOtherChannels)
                        Toggle("User Moved Channel", isOn: $ttsUserMoved)
                        Toggle("Mute / Deafen", isOn: $ttsMuteDeafen)
                        Toggle("Moved by Admin", isOn: $ttsMovedByAdmin)
                        Toggle("Channel Listening", isOn: $ttsChannelListening)
                        Toggle("Other System Messages", isOn: $ttsGenericSystemEvents)
                    }
                }
            }
            .disabled(!enableTTS)
            #else
            Section(header: Text("User Messages")) {
                Toggle("User Messages", isOn: $ttsNormalUserMessages)
                Toggle("Private Messages", isOn: $ttsPrivateMessages)
            }
            .disabled(!enableTTS)

            Section(header: Text("System Events")) {
                Toggle("User Joined (Same Channel)", isOn: $ttsUserJoinedSameChannel)
                Toggle("User Left (Same Channel)", isOn: $ttsUserLeftSameChannel)
                Toggle("User Joined (Other Channels)", isOn: $ttsUserJoinedOtherChannels)
                Toggle("User Left (Other Channels)", isOn: $ttsUserLeftOtherChannels)
                Toggle("User Moved Channel", isOn: $ttsUserMoved)
                Toggle("Mute / Deafen", isOn: $ttsMuteDeafen)
                Toggle("Moved by Admin", isOn: $ttsMovedByAdmin)
                Toggle("Channel Listening", isOn: $ttsChannelListening)
                Toggle("Other System Messages", isOn: $ttsGenericSystemEvents)
            }
            .disabled(!enableTTS)
            #endif
        }
        .navigationTitle("Text-to-Speech")
        .onAppear {
            AppState.shared.setAutomationCurrentScreen("ttsSettings")
        }
    }
}

private struct TransmissionMethodPickerRow: View {
    let title: String
    @Binding var transmitMethod: String
    @State private var localSelection: String
    
    init(title: String, transmitMethod: Binding<String>) {
        self.title = title
        self._transmitMethod = transmitMethod
        self._localSelection = State(initialValue: transmitMethod.wrappedValue)
    }
    
    var body: some View {
        Picker(title, selection: $localSelection) {
            Text("Voice Activated").tag("vad" as String)
            Text("Push-to-Talk").tag("ptt" as String)
            Text("Continuous").tag("continuous" as String)
        }
        .pickerStyle(.menu)
        .onChange(of: localSelection) { _, newValue in
            guard newValue != transmitMethod else { return }
            transmitMethod = newValue
        }
        .onChange(of: transmitMethod) { _, newValue in
            if localSelection != newValue {
                localSelection = newValue
            }
        }
    }
}

// 1. 传输模式设置视图
struct AudioTransmissionSettingsView: View {
    @EnvironmentObject var serverManager: ServerModelManager
    @Environment(\.dismiss) var dismiss
    @AppStorage("AudioTransmitMethod") var transmitMethod: String = "vad"
    @AppStorage("AudioVADKind") var vadKind: String = "amplitude"
    @AppStorage("AudioVADBelow") var vadBelow: Double = 0.3
    @AppStorage("AudioVADAbove") var vadAbove: Double = 0.6
    @AppStorage("AudioVADHoldSeconds") var vadHoldSeconds: Double = 0.1
    
    @AppStorage("AudioStereoInput") var enableStereoInput: Bool = false
    @AppStorage("AudioMicBoost") var micBoost: Double = 1.0
    @AppStorage("ShowPTTButton") var showPTTButton: Bool = false
    @AppStorage("PTTHotkeyCode") var pttHotkeyCode: Int = 49
    @AppStorage("AudioFollowSystemInputDevice") var followSystemInputDevice: Bool = true
    @AppStorage("AudioPreferredInputDeviceUID") var preferredInputDeviceUID: String = ""
    @State var devices: [MacInputDeviceOption] = []
    @State var systemDefaultUID: String = ""
    let followSystemToken = "__follow_system__"
    
    @StateObject var audioMeter = AudioMeterModel()
    
    var vadHoldBinding: Binding<Double> {
        Binding(
            get: { min(max(vadHoldSeconds, 0.0), 0.3) },
            set: { vadHoldSeconds = min(max($0, 0.0), 0.3) }
        )
    }

    var body: some View {
        Form {
            platformInputDeviceSection
            platformProcessingSection

            #if os(iOS)
            TransmissionMethodPickerRow(title: NSLocalizedString("Transmission Method", comment: ""), transmitMethod: $transmitMethod)
            #else
            TransmissionMethodPickerRow(title: NSLocalizedString("Transmission Method:", comment: ""), transmitMethod: $transmitMethod)
            #endif
            
            if transmitMethod == "vad" {
                platformVADSection
            }
            
            if transmitMethod == "ptt" {
                Section(header: Text("Push-to-Talk Settings")) {
                    Toggle("Show On-Screen Talk Button", isOn: $showPTTButton)
                    platformPTTSettingsContent
                }
            }
        }
        .navigationTitle("Input Setting")
        .onChange(of: transmitMethod) { _, newValue in
            syncAudioMeter(for: newValue)
            PreferencesModel.shared.notifySettingsChanged()
        }
        .onChange(of: vadHoldSeconds) { PreferencesModel.shared.notifySettingsChanged() }
        .onChange(of: enableStereoInput) { PreferencesModel.shared.notifySettingsChanged() }
        .onAppear {
            AppState.shared.setAutomationCurrentScreen("audioTransmissionSettings")
            serverManager.startAudioTest()
            platformRefreshDevices()
            syncAudioMeter(for: transmitMethod)
        }
        .onDisappear {
            serverManager.stopAudioTest()
            audioMeter.stopMonitoring()
        }
        .platformAudioInputRefreshHandlers {
            platformRefreshDevices()
        }
    }

    private func platformRefreshDevices() {
        platformRefreshDevicesImpl()
    }
    
    private func syncAudioMeter(for method: String) {
        if method == "vad" {
            audioMeter.startMonitoring()
        } else {
            audioMeter.stopMonitoring()
        }
    }

    func handleVADKindSelectionChange(_ newValue: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            PreferencesModel.shared.notifySettingsChanged()
        }
    }

    @ViewBuilder
    var vadDetailControls: some View {
        platformVADDetailControlsContent

        Text("Adjust sliders so that the bar stays in green when speaking and red when silent.")
            .font(.caption)
            .foregroundColor(.secondary)

        Button {
            NotificationCenter.default.post(name: .mumbleShowVADTutorialAgain, object: nil)
            dismiss()
        } label: {
            Label("Show VAD Tutorial Again", systemImage: "waveform.badge.mic")
        }
    }
    
}

// 3. 高级音频设置视图
struct AdvancedAudioSettingsView: View {
    let includeOutputSection: Bool
    @AppStorage("AudioQualityKind") var qualityKind: String = "balanced"
    @AppStorage("AudioStereoOutput") var enableStereoOutput: Bool = true
    @AppStorage("AudioSidetone") var enableSidetone: Bool = false
    @AppStorage("AudioSidetoneVolume") var sidetoneVolume: Double = 0.2
    @AppStorage("AudioSpeakerPhoneMode") var speakerPhoneMode: Bool = true
    @AppStorage("NetworkForceTCP") var forceTCP: Bool = false
    @AppStorage("NetworkAutoReconnect") var autoReconnect: Bool = true
    @AppStorage("NetworkQoS") var enableQoS: Bool = true
    @AppStorage("NetworkReconnectMaxAttempts") var reconnectMaxAttempts: Int = 10
    @AppStorage("NetworkReconnectInterval") var reconnectInterval: Double = 1.0
    @AppStorage("AudioPluginInputTrackEnabled") var pluginInputTrackEnabled: Bool = false
    @AppStorage("AudioPluginInputTrackGain") var pluginInputTrackGain: Double = 1.0
    @AppStorage("AudioPluginRemoteBusEnabled") var pluginRemoteBusEnabled: Bool = false
    @AppStorage("AudioPluginRemoteBusGain") var pluginRemoteBusGain: Double = 1.0

    // Weak Network Mode Settings (弱网模式设置)
    @AppStorage("WeakNetworkModeEnabled") var weakNetworkModeEnabled: Bool = false
    @AppStorage("WeakNetworkJitterBufferMs") var weakNetworkJitterBufferMs: Int = 100
    @AppStorage("WeakNetworkExpectedLoss") var weakNetworkExpectedLoss: Int = 20
    @AppStorage("WeakNetworkAdaptiveBitrate") var weakNetworkAdaptiveBitrate: Bool = true
    @AppStorage("WeakNetworkEnhancedPLC") var weakNetworkEnhancedPLC: Bool = true
    @AppStorage("WeakNetworkMinBitrate") var weakNetworkMinBitrate: Int = 16000
    @AppStorage("WeakNetworkMaxBitrate") var weakNetworkMaxBitrate: Int = 64000

#if os(iOS)
    @State private var showPluginMixer: Bool = false
#endif

    init(includeOutputSection: Bool = true) {
        self.includeOutputSection = includeOutputSection
    }

    var body: some View {
        Form {
            platformAdvancedSettingsContent

#if os(iOS)
            // MARK: Weak Network Mode Section (iOS only)
            Section(header: Text("Weak Network Mode"),
                    footer: Text("Optimize audio quality for high latency or lossy network conditions. Enables FEC, adaptive bitrate, and enhanced packet loss concealment.")) {
                Toggle("Enable Weak Network Mode", isOn: $weakNetworkModeEnabled)
                    .onChange(of: weakNetworkModeEnabled) { _, newValue in
                        applyWeakNetworkSettings()
                    }

                if weakNetworkModeEnabled {
                    HStack {
                        Text("Jitter Buffer")
                        Spacer()
                        Text("\(weakNetworkJitterBufferMs)ms")
                            .foregroundColor(.secondary)
                    }
                    Slider(value: Binding(
                        get: { Double(weakNetworkJitterBufferMs) },
                        set: {
                            weakNetworkJitterBufferMs = Int($0)
                            applyWeakNetworkSettings()
                        }
                    ), in: 30...500, step: 10)

                    HStack {
                        Text("Expected Packet Loss")
                        Spacer()
                        Text("\(weakNetworkExpectedLoss)%")
                            .foregroundColor(.secondary)
                    }
                    Slider(value: Binding(
                        get: { Double(weakNetworkExpectedLoss) },
                        set: {
                            weakNetworkExpectedLoss = Int($0)
                            applyWeakNetworkSettings()
                        }
                    ), in: 0...60, step: 5)

                    Toggle("Adaptive Bitrate", isOn: $weakNetworkAdaptiveBitrate)
                        .onChange(of: weakNetworkAdaptiveBitrate) { _, _ in
                            applyWeakNetworkSettings()
                        }

                    Toggle("Enhanced PLC", isOn: $weakNetworkEnhancedPLC)
                        .onChange(of: weakNetworkEnhancedPLC) { _, _ in
                            applyWeakNetworkSettings()
                        }

                    HStack {
                        Text("Bitrate Range")
                        Spacer()
                        Text("\(weakNetworkMinBitrate/1000)-\(weakNetworkMaxBitrate/1000)kbps")
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Slider(value: Binding(
                            get: { Double(weakNetworkMinBitrate) },
                            set: {
                                weakNetworkMinBitrate = min(Int($0), weakNetworkMaxBitrate - 16000)
                                applyWeakNetworkSettings()
                            }
                        ), in: 32000...80000, step: 8000)
                        Slider(value: Binding(
                            get: { Double(weakNetworkMaxBitrate) },
                            set: {
                                weakNetworkMaxBitrate = max(Int($0), weakNetworkMinBitrate + 16000)
                                applyWeakNetworkSettings()
                            }
                        ), in: 96000...192000, step: 8000)
                    }
                }
            }
#endif
        }
        .navigationTitle("Advanced")
        .onAppear {
            AppState.shared.setAutomationCurrentScreen("advancedAudioSettings")
        }
#if os(iOS)
        .fullScreenCover(isPresented: $showPluginMixer) {
            NavigationStack {
                AudioPluginMixerView()
                    .navigationTitle("Audio Plugin Mixer")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") {
                                showPluginMixer = false
                            }
                        }
                    }
            }
        }
        #endif
        .onChange(of: enableStereoOutput) { PreferencesModel.shared.notifySettingsChanged() }
        .onChange(of: enableSidetone) { PreferencesModel.shared.notifySettingsChanged() }
        .onChange(of: speakerPhoneMode) { PreferencesModel.shared.notifySettingsChanged() }
        .onChange(of: qualityKind) { PreferencesModel.shared.notifySettingsChanged() }
        .onChange(of: reconnectMaxAttempts) { PreferencesModel.shared.notifySettingsChanged() }
        .onChange(of: reconnectInterval) { PreferencesModel.shared.notifySettingsChanged() }
        .onChange(of: pluginInputTrackEnabled) { PreferencesModel.shared.notifySettingsChanged() }
        .onChange(of: pluginInputTrackGain) { PreferencesModel.shared.notifySettingsChanged() }
        .onChange(of: pluginRemoteBusEnabled) { PreferencesModel.shared.notifySettingsChanged() }
        .onChange(of: pluginRemoteBusGain) { _, _ in
            applyWeakNetworkSettings()
        }
        .onReceive(NotificationCenter.default.publisher(for: .muAutomationOpenUI)) { notification in
            guard let target = notification.userInfo?["target"] as? String else { return }
            if target == "audioPluginMixer" {
                openPluginMixer()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .muAutomationDismissUI)) { notification in
            let target = notification.userInfo?["target"] as? String
            guard target == nil || target == "audioPluginMixer" else { return }
            #if os(macOS)
            AudioPluginMixerWindowController.shared.closeWindow()
            #else
            showPluginMixer = false
            #endif
        }
        #if os(iOS)
        .onChange(of: showPluginMixer) { _, isPresented in
            if isPresented {
                AppState.shared.setAutomationPresentedSheet("audioPluginMixer")
            } else {
                AppState.shared.clearAutomationPresentedSheet(ifMatches: "audioPluginMixer")
            }
        }
        #endif
    }

    func applyWeakNetworkSettings() {
        // 通过 UserDefaults 同步设置到 MKAudioSettings
        UserDefaults.standard.set(weakNetworkModeEnabled, forKey: "WeakNetworkModeEnabled")
        UserDefaults.standard.set(weakNetworkJitterBufferMs, forKey: "WeakNetworkJitterBufferMs")
        UserDefaults.standard.set(weakNetworkExpectedLoss, forKey: "WeakNetworkExpectedLoss")
        UserDefaults.standard.set(weakNetworkAdaptiveBitrate, forKey: "WeakNetworkAdaptiveBitrate")
        UserDefaults.standard.set(weakNetworkEnhancedPLC, forKey: "WeakNetworkEnhancedPLC")
        UserDefaults.standard.set(weakNetworkMinBitrate, forKey: "WeakNetworkMinBitrate")
        UserDefaults.standard.set(weakNetworkMaxBitrate, forKey: "WeakNetworkMaxBitrate")

        // 更新 MKAudio 设置
        var settings = MKAudioSettings()
        MKAudio.shared()?.read(&settings)
        settings.enableWeakNetworkMode = ObjCBool(weakNetworkModeEnabled)
        settings.weakNetworkJitterBufferMs = Int32(weakNetworkJitterBufferMs)
        settings.weakNetworkExpectedLoss = Int32(weakNetworkExpectedLoss)
        settings.weakNetworkAdaptiveBitrate = ObjCBool(weakNetworkAdaptiveBitrate)
        settings.weakNetworkEnhancedPLC = ObjCBool(weakNetworkEnhancedPLC)
        settings.weakNetworkMinBitrate = Int32(weakNetworkMinBitrate)
        settings.weakNetworkMaxBitrate = Int32(weakNetworkMaxBitrate)
        MKAudio.shared()?.update(&settings)

        MumbleLogger.audio.info("Weak network settings applied: enabled=\(weakNetworkModeEnabled ? "1" : "0"), jitter=\(weakNetworkJitterBufferMs)ms, loss=\(weakNetworkExpectedLoss)%, bitrate=\(weakNetworkMinBitrate)-\(weakNetworkMaxBitrate)")
    }

    func openPluginMixer() {
#if os(macOS)
        AudioPluginMixerWindowController.shared.showWindow()
#else
        showPluginMixer = true
#endif
    }
}
