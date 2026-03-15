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
                    print("Notification permission error: \(error)")
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
#if os(iOS)
    @State private var showPluginMixer: Bool = false
#endif
    
    init(includeOutputSection: Bool = true) {
        self.includeOutputSection = includeOutputSection
    }
    
    var body: some View {
        Form {
            platformAdvancedSettingsContent
        }
        .navigationTitle("Advanced")
#if os(iOS)
        .sheet(isPresented: $showPluginMixer) {
            NavigationStack {
                AudioPluginMixerView()
                    .navigationTitle("Audio Plugin Mixer")
                    .toolbar {
                        ToolbarItem(placement: .automatic) {
                            Button("Done") {
                                showPluginMixer = false
                            }
                        }
                    }
#if os(macOS)
                    .frame(minWidth: 1080, minHeight: 760)
#endif
            }
#if os(iOS)
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
#endif
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
        .onChange(of: pluginRemoteBusGain) { PreferencesModel.shared.notifySettingsChanged() }
    }

    func openPluginMixer() {
#if os(macOS)
        AudioPluginMixerWindowController.shared.showWindow()
#else
        showPluginMixer = true
#endif
    }
}

#if os(macOS)
@MainActor
final class AudioPluginMixerWindowController {
    static let shared = AudioPluginMixerWindowController()

    private var window: NSWindow?

    private init() {}

    func showWindow() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let rootView = NavigationStack {
            AudioPluginMixerView()
                .navigationTitle("Audio Plugin Mixer")
        }
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = NSLocalizedString("Audio Plugin Mixer", comment: "")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 1220, height: 860))
        window.minSize = NSSize(width: 980, height: 680)
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.window = nil
        }

        self.window = window
    }
}
#endif

struct AudioPluginMixerView: View {
    private let maxInsertSlots: Int = 8

    private enum MixerTrack: Hashable {
        case input
        case remoteBus
        case remoteSession(Int)

        var title: String {
            switch self {
            case .input:
                return NSLocalizedString("Input Track", comment: "")
            case .remoteBus:
                return NSLocalizedString("Remote Bus", comment: "")
            case .remoteSession(let session):
                return String(format: NSLocalizedString("Session %d", comment: ""), session)
            }
        }

        var subtitle: String {
            switch self {
            case .input:
                return NSLocalizedString("Local microphone before encode", comment: "")
            case .remoteBus:
                return NSLocalizedString("Post-mix remote output bus", comment: "")
            case .remoteSession:
                return NSLocalizedString("Per-user remote audio lane", comment: "")
            }
        }

        var shortLabel: String {
            switch self {
            case .input:
                return NSLocalizedString("IN", comment: "")
            case .remoteBus:
                return NSLocalizedString("BUS", comment: "")
            case .remoteSession:
                return NSLocalizedString("USR", comment: "")
            }
        }
    }

    private enum PluginSource: String, Codable {
        case audioUnit
        case filesystem
    }

    private enum PluginCategory: String, CaseIterable, Hashable {
        case dynamics
        case eq
        case reverb
        case utility

        var title: String {
            switch self {
            case .dynamics:
                return NSLocalizedString("Dynamics", comment: "")
            case .eq:
                return NSLocalizedString("EQ", comment: "")
            case .reverb:
                return NSLocalizedString("Reverb", comment: "")
            case .utility:
                return NSLocalizedString("Utility", comment: "")
            }
        }
    }

    private struct DiscoveredPlugin: Identifiable, Hashable {
        let id: String
        let name: String
        let subtitle: String
        let source: PluginSource
        let categoryHint: PluginCategory?
    }

    private struct TrackPlugin: Identifiable, Codable, Hashable {
        let id: String
        var name: String
        var subtitle: String
        var source: PluginSource
        var identifier: String
        var bypassed: Bool
        var stageGain: Float
        var autoLoad: Bool
        var savedParameterValues: [String: Float]

        enum CodingKeys: String, CodingKey {
            case id
            case name
            case subtitle
            case source
            case identifier
            case bypassed
            case stageGain
            case autoLoad
            case savedParameterValues
        }

        init(
            id: String,
            name: String,
            subtitle: String,
            source: PluginSource,
            identifier: String,
            bypassed: Bool,
            stageGain: Float,
            autoLoad: Bool,
            savedParameterValues: [String: Float]
        ) {
            self.id = id
            self.name = name
            self.subtitle = subtitle
            self.source = source
            self.identifier = identifier
            self.bypassed = bypassed
            self.stageGain = stageGain
            self.autoLoad = autoLoad
            self.savedParameterValues = savedParameterValues
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            name = try container.decode(String.self, forKey: .name)
            subtitle = try container.decode(String.self, forKey: .subtitle)
            source = try container.decode(PluginSource.self, forKey: .source)
            identifier = try container.decode(String.self, forKey: .identifier)
            bypassed = try container.decodeIfPresent(Bool.self, forKey: .bypassed) ?? false
            stageGain = try container.decodeIfPresent(Float.self, forKey: .stageGain) ?? 1.0
            autoLoad = try container.decodeIfPresent(Bool.self, forKey: .autoLoad) ?? (source == .audioUnit)
            savedParameterValues = try container.decodeIfPresent([String: Float].self, forKey: .savedParameterValues) ?? [:]
        }
    }

    private struct RuntimeParameter: Identifiable {
        let id: UInt64
        let name: String
        let minValue: Float
        let maxValue: Float
        var value: Float
    }

    private enum ProcessorNodeState: String {
        case unloaded
        case loading
        case loaded
        case failed
        case bypassed
    }

    private struct ProcessorNodeSnapshot: Identifiable {
        let id: String
        let pluginName: String
        let source: PluginSource
        let state: ProcessorNodeState
        let stageGain: Float
        let parameterCount: Int
        let errorDescription: String?
    }

    private struct TrackProcessorState {
        let trackKey: String
        let nodes: [ProcessorNodeSnapshot]
        let effectiveGain: Float
        let activeNodeCount: Int
    }

    @AppStorage("AudioPluginInputTrackEnabled") private var pluginInputTrackEnabled: Bool = false
    @AppStorage("AudioPluginInputTrackGain") private var pluginInputTrackGain: Double = 1.0
    @AppStorage("AudioPluginRemoteBusEnabled") private var pluginRemoteBusEnabled: Bool = false
    @AppStorage("AudioPluginRemoteBusGain") private var pluginRemoteBusGain: Double = 1.0
    @AppStorage("AudioPluginCustomScanPaths") private var pluginCustomScanPaths: String = ""
    @AppStorage("AudioPluginTrackChainsV1") private var pluginTrackChainsData: String = ""
    @AppStorage("AudioPluginChainLivePreviewEnabled") private var pluginChainLivePreviewEnabled: Bool = true

    @State private var pluginRemoteTrackEnabled: Bool = false
    @State private var pluginRemoteTrackGain: Double = 1.0
    @State private var remoteTrackSettings: [Int: (enabled: Bool, gain: Double)] = [:]
    @State private var remoteSessionOrder: [Int] = []
    @State private var selectedTrack: MixerTrack = .input
    @State private var installedAudioUnits: [DiscoveredPlugin] = []
    @State private var scannedFilesystemPlugins: [DiscoveredPlugin] = []
    @State private var pluginChainByTrack: [String: [TrackPlugin]] = [:]
    @State private var customScanPathInput: String = ""
    @State private var pluginOperationMessage: String = ""
    @State private var selectedPluginID: String? = nil
    @State private var loadingPluginIDs: Set<String> = []
    @State private var loadedAudioUnits: [String: AVAudioUnit] = [:]
    @State private var parameterStateByPlugin: [String: [RuntimeParameter]] = [:]
    @State private var lastLoadErrorByPlugin: [String: String] = [:]
    @State private var processorStateByTrack: [String: TrackProcessorState] = [:]
    @State private var audioUnitDescriptionByIdentifier: [String: AudioComponentDescription] = [:]
#if os(iOS)
    @State private var pluginEditorController: PlatformViewController? = nil
    @State private var pluginEditorTitle: String = ""
    @State private var showingPluginEditor: Bool = false
#endif
    @State private var pluginEditorLockedSlotID: String? = nil
    @State private var isAutoLoadingPlugins: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            mixerTransportBar
            Divider()
            GeometryReader { geometry in
                let isWideLayout = geometry.size.width >= 900
                Group {
                    if isWideLayout {
                        HStack(spacing: 0) {
                            mixerTrackSidebar
                                .frame(width: min(340, max(260, geometry.size.width * 0.33)))
                            Divider()
                            mixerWorkspace
                        }
                    } else {
                        VStack(spacing: 0) {
                            mixerTrackSidebar
                                .frame(height: 300)
                            Divider()
                            mixerWorkspace
                        }
                    }
                }
            }
        }
        .onAppear {
            loadPluginChainState()
            refreshRemoteSessionOrder()
            refreshInstalledAudioUnits()
#if os(macOS)
            refreshFilesystemPluginScan()
#endif
            loadSelectedTrackState()
            normalizeSelectedPluginSelection()
            applyLivePreviewForAllTracks()
            rebuildProcessorStateMachine()
        }
        .onChange(of: selectedTrack) {
            loadSelectedTrackState()
            normalizeSelectedPluginSelection()
            rebuildProcessorStateMachine()
            if pluginEditorLockedSlotID != nil {
                syncPluginEditorForSelection()
            }
        }
        .onChange(of: selectedPluginID) {
            if pluginEditorLockedSlotID != nil {
                syncPluginEditorForSelection()
            }
        }
        .onChange(of: pluginInputTrackEnabled) { PreferencesModel.shared.notifySettingsChanged() }
        .onChange(of: pluginInputTrackGain) { PreferencesModel.shared.notifySettingsChanged() }
        .onChange(of: pluginRemoteBusEnabled) { PreferencesModel.shared.notifySettingsChanged() }
        .onChange(of: pluginRemoteBusGain) { PreferencesModel.shared.notifySettingsChanged() }
        .onChange(of: pluginRemoteTrackEnabled) {
            applyRemoteTrackPreview()
            PreferencesModel.shared.notifySettingsChanged()
        }
        .onChange(of: pluginRemoteTrackGain) {
            applyRemoteTrackPreview()
            PreferencesModel.shared.notifySettingsChanged()
        }
        .onChange(of: pluginChainLivePreviewEnabled) {
            applyLivePreviewForAllTracks()
            PreferencesModel.shared.notifySettingsChanged()
        }
#if os(iOS)
        .sheet(isPresented: $showingPluginEditor) {
            NavigationStack {
                Group {
                    if let pluginEditorController {
                        PluginEditorHostView(controller: pluginEditorController)
                    } else {
                        Text(NSLocalizedString("Plugin UI is unavailable", comment: ""))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .navigationTitle(pluginEditorTitle)
                .toolbar {
                    ToolbarItem(placement: .automatic) {
                        Button(NSLocalizedString("Done", comment: "")) {
                            showingPluginEditor = false
                        }
                    }
                }
            }
#if os(macOS)
            .frame(minWidth: 860, minHeight: 540)
#endif
        }
#endif
#if os(iOS)
        .onChange(of: showingPluginEditor) {
            if showingPluginEditor {
                pluginEditorLockedSlotID = selectedPluginID
                syncPluginEditorForSelection()
            } else {
                pluginEditorLockedSlotID = nil
                pluginEditorController = nil
                pluginEditorTitle = ""
            }
        }
#endif
    }

    private var mixerTransportBar: some View {
        HStack(spacing: 10) {
            Text(NSLocalizedString("Audio Plugin Mixer", comment: ""))
                .font(.headline)
            if !pluginOperationMessage.isEmpty {
                Text(pluginOperationMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Toggle(NSLocalizedString("Chain Live", comment: ""), isOn: $pluginChainLivePreviewEnabled)
                .toggleStyle(.switch)
                .labelsHidden()
            Spacer()
            Button(NSLocalizedString("Refresh Remote Tracks", comment: "")) {
                refreshRemoteSessionOrder()
            }
            .buttonStyle(.bordered)
            Button(NSLocalizedString("Refresh Audio Units", comment: "")) {
                refreshInstalledAudioUnits()
            }
            .buttonStyle(.bordered)
            Button(NSLocalizedString("Auto Load", comment: "")) {
                autoLoadPersistedAudioUnits()
            }
            .buttonStyle(.bordered)
#if os(macOS)
            Button(NSLocalizedString("Scan Plugin Bundles", comment: "")) {
                refreshFilesystemPluginScan()
            }
            .buttonStyle(.borderedProminent)
#endif
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var mixerTrackSidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(NSLocalizedString("Tracks", comment: ""))
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.top, 12)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(allTracks, id: \.self) { track in
                        mixerTrackRow(track)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }

            if remoteSessionOrder.isEmpty {
                Text(NSLocalizedString("No active remote tracks", comment: ""))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }
        }
        .background(.regularMaterial)
    }

    @ViewBuilder
    private func mixerTrackRow(_ track: MixerTrack) -> some View {
        let isSelected = selectedTrack == track
        Button {
            selectedTrack = track
        } label: {
            HStack(spacing: 10) {
                Text(track.shortLabel)
                    .font(.caption.monospaced())
                    .foregroundColor(isSelected ? .accentColor : .secondary)
                    .frame(width: 34, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.1))
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)
                    Text(track.subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    private var mixerWorkspace: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                selectedTrackPanel
                pluginChainPanel
                pluginInspectorPanel
                pluginBrowserPanel
            }
            .padding(16)
        }
        .background(.thinMaterial)
    }

    @ViewBuilder
    private var selectedTrackPanel: some View {
        switch selectedTrack {
        case .input:
            mixerControlCard(
                title: NSLocalizedString("Input Track Plugin", comment: ""),
                subtitle: NSLocalizedString("Plugin preview runs after system processing (input) and after remote mix (output bus).", comment: ""),
                isEnabled: $pluginInputTrackEnabled,
                gain: $pluginInputTrackGain,
                gainTitle: NSLocalizedString("Input Track Gain", comment: "")
            )
        case .remoteBus:
            mixerControlCard(
                title: NSLocalizedString("Remote Bus Plugin", comment: ""),
                subtitle: NSLocalizedString("Plugin preview runs after system processing (input) and after remote mix (output bus).", comment: ""),
                isEnabled: $pluginRemoteBusEnabled,
                gain: $pluginRemoteBusGain,
                gainTitle: NSLocalizedString("Remote Bus Gain", comment: "")
            )
        case .remoteSession:
            VStack(alignment: .leading, spacing: 12) {
                mixerControlCard(
                    title: NSLocalizedString("Remote Track Plugin", comment: ""),
                    subtitle: NSLocalizedString("Per-user remote audio lane", comment: ""),
                    isEnabled: $pluginRemoteTrackEnabled,
                    gain: $pluginRemoteTrackGain,
                    gainTitle: NSLocalizedString("Remote Track Gain", comment: "")
                )
                Button(NSLocalizedString("Apply to Selected Track", comment: "")) {
                    applyRemoteTrackPreview()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func mixerControlCard(
        title: String,
        subtitle: String,
        isEnabled: Binding<Bool>,
        gain: Binding<Double>,
        gainTitle: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.headline)
                Spacer()
                Toggle("", isOn: isEnabled)
                    .labelsHidden()
            }

            Text(subtitle)
                .font(.caption)
                .foregroundColor(.secondary)

            HStack(spacing: 10) {
                Text(gainTitle)
                    .font(.subheadline)
                Spacer()
                Text(String(format: NSLocalizedString("%.1fx", comment: ""), gain.wrappedValue))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
            }

            Slider(value: gain, in: 0.1...3.0, step: 0.1)
                .disabled(!isEnabled.wrappedValue)

            ProgressView(value: min(max(gain.wrappedValue / 3.0, 0.0), 1.0))
                .tint(isEnabled.wrappedValue ? .accentColor : .secondary)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
        )
    }

    private var pluginChainPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(NSLocalizedString("Plugin Chain", comment: ""))
                .font(.headline)
            Text(NSLocalizedString("Each track provides fixed insert slots. Click a slot to choose or replace a plugin.", comment: ""))
                .font(.caption)
                .foregroundColor(.secondary)

            if let processorState = processorStateByTrack[selectedTrackKey] {
                HStack(spacing: 10) {
                    Text(String(format: NSLocalizedString("Active Nodes: %d", comment: ""), processorState.activeNodeCount))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(String(format: NSLocalizedString("Chain Gain: %.2fx", comment: ""), processorState.effectiveGain))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }

            ForEach(0..<maxInsertSlots, id: \.self) { slotIndex in
                let plugin = pluginAtSlot(slotIndex)
                let isSelected = selectedPluginID == plugin?.id

                VStack(spacing: 8) {
                    HStack(spacing: 10) {
                        Text(String(format: NSLocalizedString("Insert %d", comment: ""), slotIndex + 1))
                            .font(.subheadline.monospacedDigit())
                            .frame(width: 92, alignment: .leading)

                        Menu {
                            if installedAudioUnits.isEmpty && scannedFilesystemPlugins.isEmpty {
                                Text(NSLocalizedString("No plugins available", comment: ""))
                            }
                            ForEach(PluginCategory.allCases, id: \.self) { category in
                                let categorized = discoveredPlugins(in: category)
                                if !categorized.isEmpty {
                                    Menu(category.title) {
                                        ForEach(categorized, id: \.id) { discovered in
                                            Button(discovered.name) {
                                                assignPluginToSlot(discovered, slotIndex: slotIndex)
                                            }
                                        }
                                    }
                                }
                            }
                            if plugin != nil {
                                Divider()
                                Button(NSLocalizedString("Clear Slot", comment: ""), role: .destructive) {
                                    clearPluginSlot(slotIndex: slotIndex)
                                }
                            }
                        } label: {
                            HStack {
                                Text(plugin?.name ?? NSLocalizedString("Select Plugin", comment: ""))
                                    .lineLimit(1)
                                Spacer()
                                Image(systemName: "chevron.down")
                                    .font(.caption)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.secondary.opacity(0.12))
                            )
                        }
                        .menuStyle(.borderlessButton)

                        Spacer()
                    }

                    if let plugin {
                        HStack(spacing: 8) {
                            Button(plugin.bypassed ? NSLocalizedString("Bypassed", comment: "") : NSLocalizedString("Active", comment: "")) {
                                toggleBypass(at: slotIndex)
                            }
                            .buttonStyle(.bordered)

                            Button(plugin.autoLoad ? NSLocalizedString("Auto", comment: "") : NSLocalizedString("Manual", comment: "")) {
                                toggleAutoLoad(at: slotIndex)
                            }
                            .buttonStyle(.bordered)

                            Button(audioUnitLoaded(for: plugin.id) ? NSLocalizedString("Unload", comment: "") : NSLocalizedString("Load", comment: "")) {
                                if audioUnitLoaded(for: plugin.id) {
                                    unloadAudioUnit(for: plugin)
                                } else {
                                    loadAudioUnit(for: plugin)
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(plugin.source != .audioUnit || loadingPluginIDs.contains(plugin.id))

                            Button(NSLocalizedString("Open UI", comment: "")) {
                                openPluginEditor(for: plugin)
                            }
                            .buttonStyle(.bordered)
                            .disabled(!audioUnitLoaded(for: plugin.id))

                            Spacer()

                            if let nodeState = nodeStateLabel(for: plugin.id) {
                                Text(nodeState)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }

                        HStack {
                            Text(NSLocalizedString("Stage Gain", comment: ""))
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(String(format: NSLocalizedString("%.1fx", comment: ""), plugin.stageGain))
                                .font(.caption.monospacedDigit())
                                .foregroundColor(.secondary)
                        }
                        Slider(
                            value: Binding(
                                get: { Double(plugin.stageGain) },
                                set: { updateStageGain(at: slotIndex, newValue: Float($0)) }
                            ),
                            in: 0.1...2.0,
                            step: 0.1
                        )
                    } else {
                        Text(NSLocalizedString("Empty slot", comment: ""))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08))
                )
                .onTapGesture {
                    selectedPluginID = plugin?.id
                    if pluginEditorLockedSlotID != nil {
                        pluginEditorLockedSlotID = plugin?.id
                        syncPluginEditorForSelection()
                    }
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
        )
    }

    private var pluginBrowserPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(NSLocalizedString("Plugin Browser", comment: ""))
                .font(.headline)

            Text(String(format: NSLocalizedString("Selected Track: %@", comment: ""), selectedTrack.title))
                .font(.caption)
                .foregroundColor(.secondary)

            if installedAudioUnits.isEmpty {
                Text(NSLocalizedString("No installed AUv3 effects found", comment: ""))
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(NSLocalizedString("Installed Audio Units", comment: ""))
                        .font(.subheadline.weight(.semibold))
                    ForEach(installedAudioUnits.prefix(24), id: \.id) { plugin in
                        pluginBrowserRow(plugin)
                    }
                }
            }

#if os(macOS)
            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text(NSLocalizedString("Custom Scan Paths", comment: ""))
                    .font(.subheadline.weight(.semibold))
                HStack(spacing: 8) {
                    TextField("/Library/Audio/Plug-Ins/VST3", text: $customScanPathInput)
                    Button(NSLocalizedString("Add", comment: "")) {
                        addCustomScanPath()
                    }
                    .disabled(customScanPathInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if customScanPathEntries.isEmpty {
                    Text(NSLocalizedString("No custom scan paths", comment: ""))
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(customScanPathEntries, id: \.self) { path in
                        HStack {
                            Text(path)
                                .font(.caption)
                                .lineLimit(1)
                            Spacer()
                            Button(NSLocalizedString("Remove", comment: "")) {
                                removeCustomScanPath(path)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }

            if scannedFilesystemPlugins.isEmpty {
                Text(NSLocalizedString("No plugin bundles found in scan paths", comment: ""))
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(NSLocalizedString("Scanned Plugin Bundles", comment: ""))
                        .font(.subheadline.weight(.semibold))
                    ForEach(scannedFilesystemPlugins.prefix(60), id: \.id) { plugin in
                        pluginBrowserRow(plugin)
                    }
                }
            }
#endif
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
        )
    }

    @ViewBuilder
    private var pluginInspectorPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(NSLocalizedString("Plugin Inspector", comment: ""))
                .font(.headline)

            if let selectedPlugin {
                Group {
                    Text(selectedPlugin.name)
                        .font(.subheadline.weight(.semibold))
                    Text(selectedPlugin.subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if selectedPlugin.source != .audioUnit {
                        Text(NSLocalizedString("Filesystem plugins are discoverable now; runtime hosting for VST3/Component will be connected in next phase.", comment: ""))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else if loadingPluginIDs.contains(selectedPlugin.id) {
                        Text(NSLocalizedString("Loading Audio Unit...", comment: ""))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else if audioUnitLoaded(for: selectedPlugin.id) {
                        Text(NSLocalizedString("Audio Unit is loaded", comment: ""))
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Button(NSLocalizedString("Refresh Parameters", comment: "")) {
                            refreshParameters(for: selectedPlugin.id)
                        }
                        .buttonStyle(.bordered)

                        let parameters = parameterStateByPlugin[selectedPlugin.id] ?? []
                        if parameters.isEmpty {
                            Text(NSLocalizedString("No automatable parameters exposed", comment: ""))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            ForEach(parameters.prefix(18)) { parameter in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(parameter.name)
                                            .font(.caption)
                                        Spacer()
                                        Text(String(format: "%.3f", parameter.value))
                                            .font(.caption.monospacedDigit())
                                            .foregroundColor(.secondary)
                                    }
                                    Slider(
                                        value: Binding(
                                            get: { Double(parameterStateValue(pluginID: selectedPlugin.id, parameterID: parameter.id, fallback: parameter.value)) },
                                            set: { setParameterValue(pluginID: selectedPlugin.id, parameterID: parameter.id, newValue: Float($0)) }
                                        ),
                                        in: Double(parameter.minValue)...Double(parameter.maxValue)
                                    )
                                }
                            }
                        }
                    } else {
                        Text(NSLocalizedString("Click Load to instantiate this Audio Unit", comment: ""))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            } else {
                Text(NSLocalizedString("Select a plugin insert to inspect details", comment: ""))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
        )
    }

    @ViewBuilder
    private func pluginBrowserRow(_ plugin: DiscoveredPlugin) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(plugin.name)
                    .font(.caption.weight(.semibold))
                Text(plugin.subtitle)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(plugin.source == .audioUnit ? NSLocalizedString("AU", comment: "") : NSLocalizedString("FS", comment: ""))
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var allTracks: [MixerTrack] {
        var tracks: [MixerTrack] = [.input, .remoteBus]
        tracks.append(contentsOf: remoteSessionOrder.map { .remoteSession($0) })
        return tracks
    }

    private var selectedTrackKey: String {
        switch selectedTrack {
        case .input:
            return "input"
        case .remoteBus:
            return "remoteBus"
        case .remoteSession(let session):
            return "remoteSession:\(session)"
        }
    }

    private var selectedTrackChain: [TrackPlugin] {
        pluginChainByTrack[selectedTrackKey] ?? []
    }

    private func pluginAtSlot(_ slotIndex: Int) -> TrackPlugin? {
        guard slotIndex >= 0, slotIndex < selectedTrackChain.count else { return nil }
        return selectedTrackChain[slotIndex]
    }

    private var selectedPlugin: TrackPlugin? {
        guard let selectedPluginID else { return nil }
        return selectedTrackChain.first(where: { $0.id == selectedPluginID })
    }

    private func normalizeSelectedPluginSelection() {
        let validIDs = Set(selectedTrackChain.map { $0.id })
        if let selectedPluginID, validIDs.contains(selectedPluginID) {
            return
        }
        selectedPluginID = selectedTrackChain.first?.id
    }

    private func audioUnitLoaded(for pluginID: String) -> Bool {
        loadedAudioUnits[pluginID] != nil
    }

    private func mutateSelectedTrackChain(_ update: (inout [TrackPlugin]) -> Void) {
        var chain = pluginChainByTrack[selectedTrackKey] ?? []
        update(&chain)
        pluginChainByTrack[selectedTrackKey] = chain
        savePluginChainState()
        normalizeSelectedPluginSelection()
        applyLivePreviewForTrackKey(selectedTrackKey)
        rebuildProcessorState(for: selectedTrackKey)
    }

    private func loadPluginChainState() {
        guard !pluginTrackChainsData.isEmpty,
              let data = pluginTrackChainsData.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: [TrackPlugin]].self, from: data) else {
            pluginChainByTrack = [:]
            return
        }
        pluginChainByTrack = decoded
    }

    private func savePluginChainState() {
        guard let data = try? JSONEncoder().encode(pluginChainByTrack),
              let string = String(data: data, encoding: .utf8) else {
            return
        }
        pluginTrackChainsData = string
    }

    private func addPlugin(_ plugin: DiscoveredPlugin) {
        mutateSelectedTrackChain { chain in
            if chain.contains(where: { $0.identifier == plugin.id }) {
                pluginOperationMessage = NSLocalizedString("Plugin already exists on this track", comment: "")
                return
            }
            chain.append(
                TrackPlugin(
                    id: UUID().uuidString,
                    name: plugin.name,
                    subtitle: plugin.subtitle,
                    source: plugin.source,
                    identifier: plugin.id,
                    bypassed: false,
                    stageGain: 1.0,
                    autoLoad: plugin.source == .audioUnit,
                    savedParameterValues: [:]
                )
            )
            pluginOperationMessage = String(format: NSLocalizedString("Added %@", comment: ""), plugin.name)
        }
        if plugin.source == .audioUnit, let latest = selectedTrackChain.last {
            selectedPluginID = latest.id
            loadAudioUnit(for: latest)
        }
    }

    private func assignPluginToSlot(_ discovered: DiscoveredPlugin, slotIndex: Int) {
        guard slotIndex >= 0 else { return }

        let existing = pluginAtSlot(slotIndex)
        if let existing, audioUnitLoaded(for: existing.id) {
            unloadAudioUnit(for: existing)
        }

        var insertedPluginID: String?
        mutateSelectedTrackChain { chain in
            let newPlugin = TrackPlugin(
                id: UUID().uuidString,
                name: discovered.name,
                subtitle: discovered.subtitle,
                source: discovered.source,
                identifier: discovered.id,
                bypassed: false,
                stageGain: 1.0,
                autoLoad: discovered.source == .audioUnit,
                savedParameterValues: [:]
            )

            if slotIndex < chain.count {
                chain[slotIndex] = newPlugin
            } else if slotIndex == chain.count {
                chain.append(newPlugin)
            } else {
                // Keep slot indices contiguous by appending to the tail if user picks a deeper empty slot.
                chain.append(newPlugin)
            }
            insertedPluginID = newPlugin.id
            pluginOperationMessage = String(format: NSLocalizedString("Inserted %@", comment: ""), discovered.name)
        }

        guard let insertedPluginID else { return }
        selectedPluginID = insertedPluginID
        if let inserted = selectedTrackChain.first(where: { $0.id == insertedPluginID }), inserted.source == .audioUnit {
            loadAudioUnit(for: inserted)
        }
    }

    private func clearPluginSlot(slotIndex: Int) {
        guard let existing = pluginAtSlot(slotIndex) else { return }
        if audioUnitLoaded(for: existing.id) {
            unloadAudioUnit(for: existing)
        }
        mutateSelectedTrackChain { chain in
            guard chain.indices.contains(slotIndex) else { return }
            let removed = chain.remove(at: slotIndex)
            pluginOperationMessage = String(format: NSLocalizedString("Removed %@", comment: ""), removed.name)
        }
    }

    private func removePlugin(at index: Int) {
        mutateSelectedTrackChain { chain in
            guard chain.indices.contains(index) else { return }
            let removed = chain.remove(at: index)
            pluginOperationMessage = String(format: NSLocalizedString("Removed %@", comment: ""), removed.name)
        }
    }

    private func toggleBypass(at index: Int) {
        mutateSelectedTrackChain { chain in
            guard chain.indices.contains(index) else { return }
            chain[index].bypassed.toggle()
            let key = chain[index].bypassed ? "Plugin bypassed" : "Plugin activated"
            pluginOperationMessage = String(format: NSLocalizedString(key, comment: ""), chain[index].name)
        }
    }

    private func movePluginUp(at index: Int) {
        mutateSelectedTrackChain { chain in
            guard index > 0, chain.indices.contains(index) else { return }
            chain.swapAt(index, index - 1)
            pluginOperationMessage = NSLocalizedString("Plugin order updated", comment: "")
        }
    }

    private func movePluginDown(at index: Int) {
        mutateSelectedTrackChain { chain in
            guard chain.indices.contains(index), index < chain.count - 1 else { return }
            chain.swapAt(index, index + 1)
            pluginOperationMessage = NSLocalizedString("Plugin order updated", comment: "")
        }
    }

    private func toggleAutoLoad(at index: Int) {
        mutateSelectedTrackChain { chain in
            guard chain.indices.contains(index) else { return }
            chain[index].autoLoad.toggle()
            pluginOperationMessage = chain[index].autoLoad
                ? NSLocalizedString("Plugin set to auto-load", comment: "")
                : NSLocalizedString("Plugin set to manual-load", comment: "")
        }
    }

    private func updateStageGain(at index: Int, newValue: Float) {
        mutateSelectedTrackChain { chain in
            guard chain.indices.contains(index) else { return }
            chain[index].stageGain = newValue
        }
    }

    private func autoLoadPersistedAudioUnits() {
        guard !isAutoLoadingPlugins else { return }

        let targets = pluginChainByTrack.values
            .flatMap { $0 }
            .filter { $0.source == .audioUnit && $0.autoLoad && !$0.bypassed && loadedAudioUnits[$0.id] == nil }

        guard !targets.isEmpty else {
            pluginOperationMessage = NSLocalizedString("No auto-load plugins pending", comment: "")
            return
        }

        isAutoLoadingPlugins = true
        pluginOperationMessage = String(format: NSLocalizedString("Auto-loading %d plugins...", comment: ""), targets.count)
        autoLoadNextPlugin(targets, index: 0)
    }

    private func autoLoadNextPlugin(_ targets: [TrackPlugin], index: Int) {
        guard index < targets.count else {
            isAutoLoadingPlugins = false
            rebuildProcessorStateMachine()
            pluginOperationMessage = NSLocalizedString("Auto-load finished", comment: "")
            return
        }

        let plugin = targets[index]
        loadAudioUnit(for: plugin) { _ in
            autoLoadNextPlugin(targets, index: index + 1)
        }
    }

    private func applyLivePreviewForAllTracks() {
        for key in pluginChainByTrack.keys {
            applyLivePreviewForTrackKey(key)
        }
        if pluginChainByTrack["input"] == nil {
            applyLivePreviewForTrackKey("input")
        }
        if pluginChainByTrack["remoteBus"] == nil {
            applyLivePreviewForTrackKey("remoteBus")
        }
    }

    private func applyLivePreviewForTrackKey(_ key: String) {
        syncAudioUnitDSPChainForTrackKey(key)

        guard pluginChainLivePreviewEnabled else {
            if key == "input" {
                MKAudio.shared().setInputTrackPreviewGain(Float(pluginInputTrackGain), enabled: pluginInputTrackEnabled)
            } else if key == "remoteBus" {
                MKAudio.shared().setRemoteBusPreviewGain(Float(pluginRemoteBusGain), enabled: pluginRemoteBusEnabled)
            } else if let session = parseRemoteSessionID(from: key) {
                MKAudio.shared().setRemoteTrackPreviewGain(Float(pluginRemoteTrackGain), enabled: pluginRemoteTrackEnabled, forSession: UInt(session))
            }
            return
        }

        let chain = pluginChainByTrack[key] ?? []
        let active = chain.filter { !$0.bypassed }
        let gain = active.reduce(Float(1.0)) { partial, plugin in
            partial * max(0.1, plugin.stageGain)
        }
        let enabled = !active.isEmpty

        if key == "input" {
            pluginInputTrackEnabled = enabled
            pluginInputTrackGain = Double(gain)
            MKAudio.shared().setInputTrackPreviewGain(gain, enabled: enabled)
            return
        }
        if key == "remoteBus" {
            pluginRemoteBusEnabled = enabled
            pluginRemoteBusGain = Double(gain)
            MKAudio.shared().setRemoteBusPreviewGain(gain, enabled: enabled)
            return
        }
        if let session = parseRemoteSessionID(from: key) {
            if case .remoteSession(let currentSession) = selectedTrack, currentSession == session {
                pluginRemoteTrackEnabled = enabled
                pluginRemoteTrackGain = Double(gain)
            }
            remoteTrackSettings[session] = (enabled: enabled, gain: Double(gain))
            MKAudio.shared().setRemoteTrackPreviewGain(gain, enabled: enabled, forSession: UInt(session))
        }
    }

    private func activeAudioUnitChain(for key: String) -> [AVAudioUnit] {
        let chain = pluginChainByTrack[key] ?? []
        return chain
            .filter { !$0.bypassed }
            .compactMap { loadedAudioUnits[$0.id] }
    }

    private func syncAudioUnitDSPChainForTrackKey(_ key: String) {
        if key == "input" {
            MKAudio.shared().setInputTrackAudioUnitChain(activeAudioUnitChain(for: key))
            return
        }
        if key == "remoteBus" {
            MKAudio.shared().setRemoteBusAudioUnitChain(activeAudioUnitChain(for: key))
        }
    }

    private func parseRemoteSessionID(from key: String) -> Int? {
        guard key.hasPrefix("remoteSession:") else { return nil }
        let value = key.replacingOccurrences(of: "remoteSession:", with: "")
        return Int(value)
    }

    private func allTrackKeys() -> [String] {
        var keys: [String] = ["input", "remoteBus"]
        keys.append(contentsOf: remoteSessionOrder.map { "remoteSession:\($0)" })
        for key in pluginChainByTrack.keys where !keys.contains(key) {
            keys.append(key)
        }
        return keys
    }

    private func rebuildProcessorStateMachine() {
        for key in allTrackKeys() {
            rebuildProcessorState(for: key)
        }
    }

    private func rebuildProcessorState(for key: String) {
        let chain = pluginChainByTrack[key] ?? []
        let nodes: [ProcessorNodeSnapshot] = chain.map { plugin in
            let state: ProcessorNodeState
            if plugin.bypassed {
                state = .bypassed
            } else if loadingPluginIDs.contains(plugin.id) {
                state = .loading
            } else if loadedAudioUnits[plugin.id] != nil {
                state = .loaded
            } else if lastLoadErrorByPlugin[plugin.id] != nil {
                state = .failed
            } else {
                state = .unloaded
            }
            return ProcessorNodeSnapshot(
                id: plugin.id,
                pluginName: plugin.name,
                source: plugin.source,
                state: state,
                stageGain: plugin.stageGain,
                parameterCount: parameterStateByPlugin[plugin.id]?.count ?? -1,
                errorDescription: lastLoadErrorByPlugin[plugin.id]
            )
        }

        let active = chain.filter { !$0.bypassed }
        let effectiveGain = active.reduce(Float(1.0)) { partial, plugin in
            partial * max(0.1, plugin.stageGain)
        }
        let snapshot = TrackProcessorState(
            trackKey: key,
            nodes: nodes,
            effectiveGain: active.isEmpty ? 1.0 : effectiveGain,
            activeNodeCount: active.count
        )
        processorStateByTrack[key] = snapshot
    }

    private func nodeStateLabel(for pluginID: String) -> String? {
        guard let state = processorStateByTrack[selectedTrackKey]?.nodes.first(where: { $0.id == pluginID }) else {
            return nil
        }
        let base: String
        switch state.state {
        case .unloaded:
            base = NSLocalizedString("State: Unloaded", comment: "")
        case .loading:
            base = NSLocalizedString("State: Loading", comment: "")
        case .loaded:
            if state.parameterCount >= 0 {
                base = String(format: NSLocalizedString("State: Loaded (%d params)", comment: ""), state.parameterCount)
            } else {
                base = NSLocalizedString("State: Loaded (params pending)", comment: "")
            }
        case .failed:
            base = NSLocalizedString("State: Failed", comment: "")
        case .bypassed:
            base = NSLocalizedString("State: Bypassed", comment: "")
        }
        if let error = state.errorDescription, !error.isEmpty {
            return "\(base) - \(error)"
        }
        return base
    }

    private func discoveredPlugins(in category: PluginCategory) -> [DiscoveredPlugin] {
        let all = installedAudioUnits + scannedFilesystemPlugins
        var unique: [String: DiscoveredPlugin] = [:]
        for plugin in all where unique[plugin.id] == nil {
            unique[plugin.id] = plugin
        }
        return Array(unique.values)
            .filter { pluginCategory(for: $0) == category }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func pluginCategory(for plugin: DiscoveredPlugin) -> PluginCategory {
        if let hint = plugin.categoryHint {
            return hint
        }
        let lowered = (plugin.name + " " + plugin.subtitle).lowercased()

        let dynamicsKeywords = ["compress", "comp", "limiter", "gate", "expander", "de-esser", "deesser", "transient"]
        if dynamicsKeywords.contains(where: { lowered.contains($0) }) {
            return .dynamics
        }

        let eqKeywords = ["eq", "equalizer", "filter", "shelf", "notch", "bandpass", "highpass", "lowpass"]
        if eqKeywords.contains(where: { lowered.contains($0) }) {
            return .eq
        }

        let reverbKeywords = ["reverb", "room", "hall", "plate", "chamber", "ambience"]
        if reverbKeywords.contains(where: { lowered.contains($0) }) {
            return .reverb
        }

        return .utility
    }

    private func auCategoryHint(from component: AVAudioUnitComponent) -> PluginCategory? {
        let info = ([component.typeName, component.name, component.manufacturerName] + component.allTagNames)
            .joined(separator: " ")
            .lowercased()

        let dynamicsKeywords = ["compress", "comp", "limiter", "gate", "expander", "de-esser", "deesser", "transient", "dynamics"]
        if dynamicsKeywords.contains(where: { info.contains($0) }) {
            return .dynamics
        }

        let eqKeywords = ["eq", "equalizer", "filter", "shelf", "notch", "bandpass", "highpass", "lowpass", "tone"]
        if eqKeywords.contains(where: { info.contains($0) }) {
            return .eq
        }

        let reverbKeywords = ["reverb", "room", "hall", "plate", "chamber", "ambience"]
        if reverbKeywords.contains(where: { info.contains($0) }) {
            return .reverb
        }

        let utilityKeywords = ["analyzer", "meter", "gain", "utility", "stereo", "phase", "delay", "pan"]
        if utilityKeywords.contains(where: { info.contains($0) }) {
            return .utility
        }

        return nil
    }

    private func loadAudioUnit(for plugin: TrackPlugin, completion: ((Bool) -> Void)? = nil) {
        guard plugin.source == .audioUnit else {
            pluginOperationMessage = NSLocalizedString("Only Audio Unit plugins can be loaded right now", comment: "")
            completion?(false)
            return
        }
        if loadingPluginIDs.contains(plugin.id) {
            completion?(false)
            return
        }
        if loadedAudioUnits[plugin.id] != nil {
            completion?(true)
            return
        }
        let description = audioUnitDescriptionByIdentifier[plugin.identifier] ?? parseAudioUnitDescription(from: plugin.identifier)
        guard let description else {
            pluginOperationMessage = NSLocalizedString("Failed to parse Audio Unit identifier", comment: "")
            completion?(false)
            return
        }
        loadingPluginIDs.insert(plugin.id)
        lastLoadErrorByPlugin[plugin.id] = nil
        rebuildProcessorStateMachine()

        instantiateAudioUnitWithFallback(description: description) { unit, errorText in
            DispatchQueue.main.async {
                loadingPluginIDs.remove(plugin.id)
                if let unit {
                    loadedAudioUnits[plugin.id] = unit
                    lastLoadErrorByPlugin[plugin.id] = nil
                    // Delay heavy parameter-tree traversal until user inspects this plugin,
                    // which avoids crashing some AU implementations right after instantiation.
                    parameterStateByPlugin[plugin.id] = []
                    pluginOperationMessage = String(format: NSLocalizedString("Loaded %@", comment: ""), plugin.name)
                    if let chainKey = trackKey(containingPluginID: plugin.id) {
                        applyLivePreviewForTrackKey(chainKey)
                    } else {
                        applyLivePreviewForTrackKey(selectedTrackKey)
                    }
                    rebuildProcessorStateMachine()
                    completion?(true)
                    return
                }

                parameterStateByPlugin[plugin.id] = nil
                let finalError = errorText ?? NSLocalizedString("Unknown error", comment: "")
                lastLoadErrorByPlugin[plugin.id] = finalError
                pluginOperationMessage = String(format: NSLocalizedString("Failed to load %@: %@", comment: ""), plugin.name, finalError)
                rebuildProcessorStateMachine()
                completion?(false)
            }
        }
    }

    private func instantiateAudioUnitWithFallback(
        description: AudioComponentDescription,
        completion: @escaping (AVAudioUnit?, String?) -> Void
    ) {
#if os(macOS)
        AVAudioUnit.instantiate(with: description, options: [.loadInProcess]) { unitIn, errorIn in
            if let unitIn {
                completion(unitIn, nil)
                return
            }

            AVAudioUnit.instantiate(with: description, options: []) { unitDefault, errorDefault in
                if let unitDefault {
                    completion(unitDefault, nil)
                    return
                }

                // Last fallback: out-of-process may trigger system security prompts on macOS.
                AVAudioUnit.instantiate(with: description, options: [.loadOutOfProcess]) { unitOut, errorOut in
                    if let unitOut {
                        completion(unitOut, nil)
                        return
                    }

                    let finalError = (errorOut ?? errorDefault ?? errorIn) as NSError?
                    if let finalError,
                       finalError.domain == NSOSStatusErrorDomain,
                       finalError.code == -3000 {
                        completion(nil, NSLocalizedString("Audio Unit host compatibility error (-3000). Try another AU or restart audio engine.", comment: ""))
                        return
                    }
                    completion(nil, finalError?.localizedDescription ?? NSLocalizedString("Unknown error", comment: ""))
                }
            }
        }
#else
        AVAudioUnit.instantiate(with: description, options: []) { unitDefault, errorDefault in
            if let unitDefault {
                completion(unitDefault, nil)
                return
            }

            let finalError = errorDefault as NSError?
            if let finalError,
               finalError.domain == NSOSStatusErrorDomain,
               finalError.code == -3000 {
                completion(nil, NSLocalizedString("Audio Unit host compatibility error (-3000). Try another AU or restart audio engine.", comment: ""))
                return
            }
            completion(nil, finalError?.localizedDescription ?? NSLocalizedString("Unknown error", comment: ""))
        }
#endif
    }

    private func openPluginEditor(for plugin: TrackPlugin) {
        selectedPluginID = plugin.id
        pluginEditorLockedSlotID = plugin.id
        syncPluginEditorForSelection()
#if os(iOS)
        showingPluginEditor = true
#endif
    }

    private func syncPluginEditorForSelection() {
        guard let plugin = selectedPlugin else {
#if os(iOS)
            pluginEditorController = nil
            pluginEditorTitle = NSLocalizedString("Plugin Editor", comment: "")
#else
            PluginEditorWindowController.shared.hide()
#endif
            return
        }

        pluginEditorLockedSlotID = plugin.id
#if os(iOS)
        pluginEditorTitle = plugin.name
#endif

        guard plugin.source == .audioUnit else {
#if os(iOS)
            pluginEditorController = nil
#else
            PluginEditorWindowController.shared.hide()
#endif
            pluginOperationMessage = NSLocalizedString("Plugin UI is unavailable", comment: "")
            return
        }

        guard let unit = loadedAudioUnits[plugin.id] else {
#if os(iOS)
            pluginEditorController = nil
#else
            PluginEditorWindowController.shared.hide()
#endif
            pluginOperationMessage = NSLocalizedString("Load plugin first", comment: "")
            return
        }

        let targetPluginID = plugin.id
        unit.auAudioUnit.requestViewController { viewController in
            DispatchQueue.main.async {
                guard selectedPluginID == targetPluginID else { return }
                guard let viewController else {
#if os(iOS)
                    pluginEditorController = nil
#else
                    PluginEditorWindowController.shared.hide()
#endif
                    pluginOperationMessage = NSLocalizedString("Plugin UI is unavailable", comment: "")
                    return
                }

#if os(iOS)
                guard showingPluginEditor else { return }
                pluginEditorController = viewController
                pluginEditorTitle = plugin.name
#else
                PluginEditorWindowController.shared.show(controller: viewController, title: plugin.name)
#endif
            }
        }
    }

    private func unloadAudioUnit(for plugin: TrackPlugin) {
        loadedAudioUnits[plugin.id] = nil
        parameterStateByPlugin[plugin.id] = nil
        lastLoadErrorByPlugin[plugin.id] = nil
        if let chainKey = trackKey(containingPluginID: plugin.id) {
            applyLivePreviewForTrackKey(chainKey)
        }
        pluginOperationMessage = String(format: NSLocalizedString("Unloaded %@", comment: ""), plugin.name)
        rebuildProcessorStateMachine()
    }

    private func trackKey(containingPluginID pluginID: String) -> String? {
        for (key, chain) in pluginChainByTrack {
            if chain.contains(where: { $0.id == pluginID }) {
                return key
            }
        }
        return nil
    }

    private func parseAudioUnitDescription(from identifier: String) -> AudioComponentDescription? {
        guard identifier.hasPrefix("au:") else { return nil }
        let remainder = String(identifier.dropFirst(3))
        let parts = remainder.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count >= 3,
              let type = UInt32(parts[0]),
              let subtype = UInt32(parts[1]),
              let manufacturer = UInt32(parts[2]) else {
            return nil
        }
        return AudioComponentDescription(
            componentType: type,
            componentSubType: subtype,
            componentManufacturer: manufacturer,
            componentFlags: 0,
            componentFlagsMask: 0
        )
    }

    private func rebuildParameterState(pluginID: String, unit: AVAudioUnit) {
        let parameters = unit.auAudioUnit.parameterTree?.allParameters ?? []
        var state = parameters
            .prefix(32)
            .map {
                RuntimeParameter(
                    id: $0.address,
                    name: $0.displayName,
                    minValue: $0.minValue,
                    maxValue: $0.maxValue,
                    value: $0.value
                )
            }
        applySavedParameters(pluginID: pluginID, state: &state, unit: unit)
        parameterStateByPlugin[pluginID] = state
    }

    private func refreshParameters(for pluginID: String) {
        guard let unit = loadedAudioUnits[pluginID] else { return }
        DispatchQueue.main.async {
            rebuildParameterState(pluginID: pluginID, unit: unit)
        }
    }

    private func applySavedParameters(pluginID: String, state: inout [RuntimeParameter], unit: AVAudioUnit) {
        guard let plugin = findPlugin(withID: pluginID), !plugin.savedParameterValues.isEmpty else {
            return
        }
        var lookup: [UInt64: AUParameter] = [:]
        for parameter in unit.auAudioUnit.parameterTree?.allParameters ?? [] {
            lookup[parameter.address] = parameter
        }
        for index in state.indices {
            let key = String(state[index].id)
            guard let saved = plugin.savedParameterValues[key] else { continue }
            state[index].value = saved
            lookup[state[index].id]?.value = saved
        }
    }

    private func parameterStateValue(pluginID: String, parameterID: UInt64, fallback: Float) -> Float {
        parameterStateByPlugin[pluginID]?.first(where: { $0.id == parameterID })?.value ?? fallback
    }

    private func setParameterValue(pluginID: String, parameterID: UInt64, newValue: Float) {
        if let unit = loadedAudioUnits[pluginID],
           let parameter = unit.auAudioUnit.parameterTree?.allParameters.first(where: { $0.address == parameterID }) {
            parameter.value = newValue
        }

        guard var list = parameterStateByPlugin[pluginID],
              let index = list.firstIndex(where: { $0.id == parameterID }) else {
            return
        }
        list[index].value = newValue
        parameterStateByPlugin[pluginID] = list
        updateSavedParameter(pluginID: pluginID, parameterID: parameterID, value: newValue)
        rebuildProcessorStateMachine()
    }

    private func updateSavedParameter(pluginID: String, parameterID: UInt64, value: Float) {
        mutatePlugin(withID: pluginID) { plugin in
            plugin.savedParameterValues[String(parameterID)] = value
        }
    }

    private func findPlugin(withID pluginID: String) -> TrackPlugin? {
        for chain in pluginChainByTrack.values {
            if let plugin = chain.first(where: { $0.id == pluginID }) {
                return plugin
            }
        }
        return nil
    }

    private func mutatePlugin(withID pluginID: String, mutate: (inout TrackPlugin) -> Void) {
        for key in pluginChainByTrack.keys {
            guard var chain = pluginChainByTrack[key], let index = chain.firstIndex(where: { $0.id == pluginID }) else {
                continue
            }
            mutate(&chain[index])
            pluginChainByTrack[key] = chain
            savePluginChainState()
            applyLivePreviewForTrackKey(key)
            rebuildProcessorState(for: key)
            return
        }
    }

    private func loadSelectedTrackState() {
        guard case .remoteSession(let session) = selectedTrack else {
            return
        }
        let trackState = remoteTrackSettings[session] ?? (enabled: false, gain: 1.0)
        pluginRemoteTrackEnabled = trackState.enabled
        pluginRemoteTrackGain = trackState.gain
    }

    private func refreshRemoteSessionOrder() {
        let sessions = (MKAudio.shared().copyRemoteSessionOrder() as? [NSNumber])?.map { $0.intValue } ?? []
        remoteSessionOrder = sessions
        switch selectedTrack {
        case .remoteSession(let session) where sessions.contains(session):
            return
        case .remoteSession:
            selectedTrack = sessions.first.map { .remoteSession($0) } ?? .input
        default:
            if selectedTrack == .input || selectedTrack == .remoteBus {
                return
            }
        }
    }

    private func applyRemoteTrackPreview() {
        guard case .remoteSession(let session) = selectedTrack else { return }
        remoteTrackSettings[session] = (enabled: pluginRemoteTrackEnabled, gain: pluginRemoteTrackGain)
        MKAudio.shared().setRemoteTrackPreviewGain(Float(pluginRemoteTrackGain), enabled: pluginRemoteTrackEnabled, forSession: UInt(session))
    }

    private func refreshInstalledAudioUnits() {
        let manager = AVAudioUnitComponentManager.shared()
        let desc = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: 0,
            componentManufacturer: 0,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        let components = manager.components(matching: desc)
        var descriptionLookup: [String: AudioComponentDescription] = [:]
        var deduped: [String: DiscoveredPlugin] = [:]
        for component in components {
                let acd = component.audioComponentDescription
                let identifier = "au:\(acd.componentType):\(acd.componentSubType):\(acd.componentManufacturer):\(component.name)"
                if deduped[identifier] == nil {
                    descriptionLookup[identifier] = acd
                    deduped[identifier] = DiscoveredPlugin(
                        id: identifier,
                        name: component.name,
                        subtitle: component.manufacturerName,
                        source: .audioUnit,
                        categoryHint: auCategoryHint(from: component)
                    )
                }
            }
        installedAudioUnits = Array(deduped.values)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        audioUnitDescriptionByIdentifier = descriptionLookup
    }

    private var customScanPathEntries: [String] {
        pluginCustomScanPaths
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func addCustomScanPath() {
        let candidate = customScanPathInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return }
        var entries = customScanPathEntries
        if !entries.contains(candidate) {
            entries.append(candidate)
            pluginCustomScanPaths = entries.joined(separator: "\n")
        }
        customScanPathInput = ""
        refreshFilesystemPluginScan()
    }

    private func removeCustomScanPath(_ path: String) {
        let entries = customScanPathEntries.filter { $0 != path }
        pluginCustomScanPaths = entries.joined(separator: "\n")
        refreshFilesystemPluginScan()
    }

    private func refreshFilesystemPluginScan() {
#if os(macOS)
        var scanRoots: [String] = [
            "/Library/Audio/Plug-Ins/Components",
            "/Library/Audio/Plug-Ins/VST3",
            NSString(string: "~/Library/Audio/Plug-Ins/Components").expandingTildeInPath,
            NSString(string: "~/Library/Audio/Plug-Ins/VST3").expandingTildeInPath
        ]
        scanRoots.append(contentsOf: customScanPathEntries)

        let fm = FileManager.default
        var found: [String] = []
        for root in scanRoots {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            let children = (try? fm.contentsOfDirectory(atPath: root)) ?? []
            for item in children {
                if item.hasSuffix(".vst3") || item.hasSuffix(".component") {
                    found.append("\(root)/\(item)")
                }
            }
        }
        scannedFilesystemPlugins = Array(Set(found))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { fullPath in
                DiscoveredPlugin(
                    id: "fs:\(fullPath)",
                    name: URL(fileURLWithPath: fullPath).lastPathComponent,
                    subtitle: fullPath,
                    source: .filesystem,
                    categoryHint: nil
                )
            }
#endif
    }
}

#if os(iOS)
private struct PluginEditorHostView: UIViewControllerRepresentable {
    let controller: UIViewController

    func makeUIViewController(context: Context) -> UIViewController {
        controller
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}
#elseif os(macOS)
@MainActor
final class PluginEditorWindowController {
    static let shared = PluginEditorWindowController()

    private var window: NSWindow?

    private init() {}

    func show(controller: NSViewController, title: String) {
        let targetSize = normalizedSize(from: controller.preferredContentSize)

        if let window {
            window.title = title
            window.contentViewController = controller
            resize(window: window, to: targetSize)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(contentViewController: controller)
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(targetSize)
        window.minSize = NSSize(width: max(480, targetSize.width * 0.8), height: max(320, targetSize.height * 0.8))
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.window = nil
        }

        self.window = window
    }

    func hide() {
        window?.orderOut(nil)
    }

    private func normalizedSize(from preferred: NSSize) -> NSSize {
        let width = preferred.width > 10 ? preferred.width : 960
        let height = preferred.height > 10 ? preferred.height : 620
        return NSSize(width: max(600, width), height: max(420, height))
    }

    private func resize(window: NSWindow, to contentSize: NSSize) {
        let frameSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize)).size
        var frame = window.frame
        frame.origin.y += frame.size.height - frameSize.height
        frame.size = frameSize
        window.setFrame(frame, display: true, animate: true)
    }
}
#endif
