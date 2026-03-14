#if os(macOS)
import SwiftUI
import AppKit
import CoreAudio
import UserNotifications

private let macAudioInputDevicesChangedNotification = Notification.Name("MUMacAudioInputDevicesChanged")

extension View {
    func macSettingsCenteredPageStyle() -> some View {
        self
            .frame(maxWidth: 760)
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
    
    @ViewBuilder
    func platformAudioInputRefreshHandlers(_ onRefresh: @escaping () -> Void) -> some View {
        self
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                onRefresh()
            }
            .onReceive(NotificationCenter.default.publisher(for: macAudioInputDevicesChangedNotification)) { _ in
                onRefresh()
            }
    }
}

extension NotificationSettingsView {
    @ViewBuilder
    var notificationSettingsContent: some View {
        LabeledContent("Notifications:") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("User Messages", isOn: $notifyNormalUserMessages)
                Toggle("Private Messages", isOn: $notifyPrivateMessages)
            }
            .padding(.bottom, 4)
        }
        
        LabeledContent("System Events:") {
            VStack(alignment: .leading, spacing: 8) {
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
    }
    
    var notificationAuthorizationOptions: UNAuthorizationOptions {
        [.alert, .sound]
    }
}

extension AudioTransmissionSettingsView {
    @ViewBuilder
    var platformInputDeviceSection: some View {
        Section {
            LabeledContent("Microphone:") {
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
                .labelsHidden()
                .pickerStyle(.menu)
            }
            
            if !followSystemInputDevice && selectedDeviceMissing {
                Text("Selected microphone is unavailable, please choose another one.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            LabeledContent("Device List:") {
                Button("Refresh") {
                    refreshDevices()
                    normalizeSelectionIfNeeded()
                }
                .font(.caption)
            }
            .padding(.bottom, 2)
        }
    }
    
    @ViewBuilder
    var platformProcessingSection: some View {
        LabeledContent("Audio Processing:") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Stereo Input", isOn: $enableStereoInput)
                VStack(alignment: .leading, spacing: 6) {
                    Text(
                        String(
                            format: NSLocalizedString("Mic Volume: %d%%", comment: ""),
                            Int(micBoost * 100)
                        )
                    )
                    Slider(value: $micBoost, in: 0...3.0, step: 0.1) { editing in
                        if !editing { PreferencesModel.shared.notifySettingsChanged() }
                    }
                    .frame(maxWidth: 220)
                }
            }
        }
    }
    
    @ViewBuilder
    var platformVADSection: some View {
        LabeledContent("Detection Type:") {
            Picker("", selection: $vadKind) {
                Text("Amplitude").tag("amplitude")
                Text("Signal to Noise").tag("snr")
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .onChange(of: vadKind) { _, newValue in
                handleVADKindSelectionChange(newValue)
            }
            .frame(maxWidth: 120, alignment: .leading)
        }
        
        VStack(alignment: .leading, spacing: 12) {
            vadDetailControls
        }
        .padding(.vertical, 6)
    }
    
    @ViewBuilder
    var platformPTTSettingsContent: some View {
        Picker("Push-to-Talk Key:", selection: $pttHotkeyCode) {
            ForEach(pttHotkeyOptions) { option in
                Text(NSLocalizedString(option.label, comment: "")).tag(option.keyCode)
            }
        }
        .pickerStyle(.menu)
        Text("Hold the selected keyboard key to speak.")
            .font(.caption)
            .foregroundColor(.secondary)
    }
    
    @ViewBuilder
    var platformVADDetailControlsContent: some View {
        LabeledContent {
            AudioBarView(
                level: audioMeter.currentLevel,
                lower: Float(vadBelow),
                upper: Float(vadAbove)
            )
            .frame(maxWidth: 300)
        } label: {
            Text("Level:")
                .frame(width: 70, alignment: .trailing)
        }
        .padding(.vertical, 2)
        
        LabeledContent {
            HStack(spacing: 8) {
                Slider(value: $vadBelow, in: 0...1) { editing in
                    if !editing { PreferencesModel.shared.notifySettingsChanged() }
                }
                Text("\(Int(vadBelow * 100))%")
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 42, alignment: .trailing)
            }
            .frame(maxWidth: 300)
        } label: {
            Text("Silence:")
                .frame(width: 70, alignment: .trailing)
        }
        
        LabeledContent {
            HStack(spacing: 8) {
                Slider(value: $vadAbove, in: 0...1) { editing in
                    if !editing { PreferencesModel.shared.notifySettingsChanged() }
                }
                Text("\(Int(vadAbove * 100))%")
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 42, alignment: .trailing)
            }
            .frame(maxWidth: 300)
        } label: {
            Text("Speech:")
                .frame(width: 70, alignment: .trailing)
        }
        
        LabeledContent {
            HStack(spacing: 8) {
                Slider(value: vadHoldBinding, in: 0...0.3, step: 0.01) { editing in
                    if !editing { PreferencesModel.shared.notifySettingsChanged() }
                }
                Text("\(Int((vadHoldSeconds * 1000).rounded()))ms")
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 58, alignment: .trailing)
            }
            .frame(maxWidth: 300)
        } label: {
            Text("Hold:")
                .frame(width: 70, alignment: .trailing)
        }
    }
    
    func platformRefreshDevicesImpl() {
        refreshDevices()
        normalizeSelectionIfNeeded()
    }
    
    var selectedInputDeviceTag: Binding<String> {
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
    
    var selectedDeviceMissing: Bool {
        !preferredInputDeviceUID.isEmpty && !devices.contains(where: { $0.uid == preferredInputDeviceUID })
    }
    
    var systemDefaultName: String {
        if let current = devices.first(where: { $0.uid == systemDefaultUID }) {
            return current.name
        }
        return "Unknown"
    }
    
    func refreshDevices() {
        devices = MacInputDeviceCatalog.inputDevices()
        systemDefaultUID = MacInputDeviceCatalog.defaultInputUID() ?? ""
    }
    
    func normalizeSelectionIfNeeded() {
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
}

extension AdvancedAudioSettingsView {
    @ViewBuilder
    var platformAdvancedSettingsContent: some View {
        if includeOutputSection {
            LabeledContent("Output:") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Stereo Output", isOn: $enableStereoOutput)
                    Toggle("Sidetone (Hear yourself)", isOn: $enableSidetone)
                    if enableSidetone {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Sidetone Volume")
                            Slider(value: $sidetoneVolume, in: 0...1) { editing in
                                if !editing { PreferencesModel.shared.notifySettingsChanged() }
                            }
                        }
                    }
                }
            }
        }
        
        LabeledContent("Audio Quality:") {
            Picker("", selection: $qualityKind) {
                Text("Low (60kbit/s)").tag("low")
                Text("Balanced (100kbit/s)").tag("balanced")
                Text("High (192kbit/s)").tag("high")
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
        LabeledContent("Network:") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Auto Reconnect", isOn: $autoReconnect)
                Toggle("Enable QoS", isOn: $enableQoS)
                Toggle("Force TCP Mode", isOn: $forceTCP)
            }
        }
        Text("Network changes require reconnection to take effect.")
            .font(.caption)
            .foregroundColor(.secondary)
    }
}

private struct MacAudioOutputSettingsTabView: View {
    @AppStorage("AudioOutputVolume") var outputVolume: Double = 1.0
    @AppStorage("AudioStereoOutput") var enableStereoOutput: Bool = true
    @AppStorage("AudioSidetone") var enableSidetone: Bool = false
    @AppStorage("AudioSidetoneVolume") var sidetoneVolume: Double = 0.2
    
    var body: some View {
        Form {
            LabeledContent("Output Volume:") {
                HStack(spacing: 2) {
                    Slider(value: $outputVolume, in: 0...3, step: 0.1) { editing in
                        if !editing { PreferencesModel.shared.notifySettingsChanged() }
                    }
                    Text("\(Int(outputVolume * 100))%")
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 52, alignment: .trailing)
                }
                .frame(maxWidth: 300)
                .padding(.bottom, 4)
            }
            
            LabeledContent("Audio Output:") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Stereo Output", isOn: $enableStereoOutput)
                    Toggle("Sidetone (Hear yourself)", isOn: $enableSidetone)
                    if enableSidetone {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Sidetone Volume")
                            Slider(value: $sidetoneVolume, in: 0...1) { editing in
                                if !editing { PreferencesModel.shared.notifySettingsChanged() }
                            }
                        }
                        .frame(maxWidth: 300)
                    }
                }
            }
        }
        .onChange(of: enableStereoOutput) { PreferencesModel.shared.notifySettingsChanged() }
        .onChange(of: enableSidetone) { PreferencesModel.shared.notifySettingsChanged() }
    }
}

enum MacInputDeviceCatalog {
    static func inputDevices() -> [MacInputDeviceOption] {
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

private struct MacGeneralSettingsTabView: View {
    @StateObject private var languageManager = AppLanguageManager.shared
    @AppStorage("AppColorScheme") private var appColorSchemeRawValue: String = AppColorSchemeOption.system.rawValue
    @State private var showingLanguageChangedAlert = false
    @State private var showingAboutSheet = false
    
    var body: some View {
        Form {
            LabeledContent("Language:") {
                Picker(
                    "",
                    selection: Binding(
                        get: { languageManager.selectedRawValue },
                        set: { newValue in
                            languageManager.setLanguage(rawValue: newValue)
                            showingLanguageChangedAlert = true
                        }
                    )
                ) {
                    ForEach(AppLanguageOption.allCases) { option in
                        Text(option.localizedLabel)
                            .tag(option.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            
            LabeledContent("Appearance:") {
                Picker(
                    "",
                    selection: Binding(
                        get: { AppColorSchemeOption.normalized(from: appColorSchemeRawValue).rawValue },
                        set: { newValue in
                            appColorSchemeRawValue = AppColorSchemeOption.normalized(from: newValue).rawValue
                        }
                    )
                ) {
                    ForEach(AppColorSchemeOption.allCases) { option in
                        Text(option.localizedLabel)
                            .tag(option.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            
            LabeledContent("Channels:") {
                let showHidden = Binding(
                    get: { UserDefaults.standard.bool(forKey: "ShowHiddenChannels") },
                    set: {
                        UserDefaults.standard.set($0, forKey: "ShowHiddenChannels")
                        NotificationCenter.default.post(name: ServerModelNotificationManager.rebuildModelNotification, object: nil)
                    }
                )
                Toggle("Show Hidden Channels", isOn: showHidden)
            }
            
            LabeledContent("About:") {
                Button("Open About Mumble") {
                    showingAboutSheet = true
                }
            }
        }
        .sheet(isPresented: $showingAboutSheet) {
            NavigationStack {
                AboutView()
                    .toolbar {
                        ToolbarItem(placement: .automatic) {
                            Button("Close") {
                                showingAboutSheet = false
                            }
                        }
                    }
            }
            .frame(minWidth: 440, idealWidth: 520, minHeight: 420, idealHeight: 520)
        }
        .alert(NSLocalizedString("Language Changed", comment: ""), isPresented: $showingLanguageChangedAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(NSLocalizedString("Some texts will fully update after restarting the app.", comment: ""))
        }
    }
}

private struct MacHandoffSettingsTabView: View {
    @AppStorage(MumbleHandoffSyncLocalAudioSettingsKey) var handoffSyncLocalAudioSettings: Bool = true
    @AppStorage("HandoffPreferredProfileKey") var handoffPreferredProfileKey: Int = -1
    
    var body: some View {
        Form {
            HandoffProfilePicker(selectedKey: $handoffPreferredProfileKey)
            LabeledContent("Handoff:") {
                Toggle("", isOn: $handoffSyncLocalAudioSettings)
                    .labelsHidden()
            }
            Text("Choose which profile to use when continuing a session from another device. 'Automatic' will match by server address.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

struct MacSettingsRootView: View {
    private enum MacSettingsTab: Hashable {
        case general
        case input
        case output
        case notifications
        case tts
        case handoff
        case certificates
        case advanced
        
        var preferredContentSize: NSSize {
            switch self {
            case .general:
                return NSSize(width: 550, height: 220)
            case .input:
                return NSSize(width: 550, height: 520)
            case .output:
                return NSSize(width: 550, height: 220)
            case .notifications:
                return NSSize(width: 550, height: 360)
            case .tts:
                return NSSize(width: 550, height: 450)
            case .handoff:
                return NSSize(width: 550, height: 220)
            case .certificates:
                return NSSize(width: 550, height: 600)
            case .advanced:
                return NSSize(width: 550, height: 220)
            }
        }
    }
    
    @EnvironmentObject var serverManager: ServerModelManager
    @StateObject private var languageManager = AppLanguageManager.shared
    @AppStorage("AppColorScheme") private var appColorSchemeRawValue: String = AppColorSchemeOption.system.rawValue
    @State private var selectedTab: MacSettingsTab = .general
    
    private var selectedAppColorScheme: AppColorSchemeOption {
        AppColorSchemeOption.normalized(from: appColorSchemeRawValue)
    }
    
    var body: some View {
        TabView(selection: $selectedTab) {
            MacGeneralSettingsTabView()
                .macSettingsCenteredPageStyle()
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }
                .tag(MacSettingsTab.general)
            
            AudioTransmissionSettingsView()
                .macSettingsCenteredPageStyle()
                .tabItem {
                    Label("Input", systemImage: "mic")
                }
                .tag(MacSettingsTab.input)
            
            MacAudioOutputSettingsTabView()
                .macSettingsCenteredPageStyle()
                .tabItem {
                    Label("Output", systemImage: "speaker.wave.2")
                }
                .tag(MacSettingsTab.output)
            
            NotificationSettingsView()
                .macSettingsCenteredPageStyle()
                .tabItem {
                    Label("Notifications", systemImage: "bell.badge")
                }
                .tag(MacSettingsTab.notifications)

            TTSSettingsView()
                .macSettingsCenteredPageStyle()
                .tabItem {
                    Label("Text-to-Speech", systemImage: "waveform")
                }
                .tag(MacSettingsTab.tts)
            MacHandoffSettingsTabView()
                .macSettingsCenteredPageStyle()
                .tabItem {
                    Label("Handoff", systemImage: "rectangle.3.group.bubble.left")
                }
                .tag(MacSettingsTab.handoff)
            
            CertificatePreferencesView()
                .macSettingsCenteredPageStyle()
                .tabItem {
                    Label("Certificates", systemImage: "checkmark.shield")
                }
                .tag(MacSettingsTab.certificates)
            
            AdvancedAudioSettingsView(includeOutputSection: false)
                .macSettingsCenteredPageStyle()
                .tabItem {
                    Label("Advanced", systemImage: "slider.horizontal.3")
                }
                .tag(MacSettingsTab.advanced)
        }
        .background(MacSettingsWindowSizeAdaptor(targetSize: selectedTab.preferredContentSize))
        .environment(\.locale, Locale(identifier: languageManager.localeIdentifier))
        .modifier(SettingsColorSchemeOverrideModifier(option: selectedAppColorScheme))
        .toggleStyle(.checkbox)
        .onAppear {
            languageManager.reapplyCurrentLanguage()
        }
    }
}

private struct MacSettingsWindowSizeAdaptor: NSViewRepresentable {
    let targetSize: NSSize
    
    final class Coordinator {
        var hasAppliedInitialSize = false
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            resize(
                window: window,
                to: targetSize,
                animate: context.coordinator.hasAppliedInitialSize
            )
            context.coordinator.hasAppliedInitialSize = true
        }
    }
    
    private func resize(window: NSWindow, to targetSize: NSSize, animate: Bool) {
        let minSize = NSSize(width: 400, height: 100)
        let clampedContentSize = NSSize(
            width: max(minSize.width, targetSize.width),
            height: max(minSize.height, targetSize.height)
        )
        
        let targetFrameSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: clampedContentSize)).size
        let currentSize = window.frame.size
        guard abs(currentSize.width - targetFrameSize.width) > 0.5 || abs(currentSize.height - targetFrameSize.height) > 0.5 else {
            return
        }
        
        var frame = window.frame
        frame.origin.y += frame.size.height - targetFrameSize.height
        frame.size = targetFrameSize
        window.minSize = minSize
        window.setFrame(frame, display: true, animate: animate)
    }
}
#endif
