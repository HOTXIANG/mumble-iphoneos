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
                Toggle("In-App Message Banners", isOn: $enableInAppMessageBanners)
            }
            .padding(.bottom, 4)
        }
        
        LabeledContent("User Messages:") {
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
                Toggle("Capture All Input Channels", isOn: $captureAllInputChannels)
                Text("Enable this only for multi-channel USB microphones that otherwise show no input. It may affect macOS voice modes and expose Wide Spectrum.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 360, alignment: .leading)
                if captureAllInputChannels {
                    Toggle("Stereo Input", isOn: $enableStereoInput)
                }
                if activeInputChannelCount > 1 && !captureAllInputChannels {
                    Picker("Input Channel:", selection: $selectedInputChannel) {
                        ForEach(1...activeInputChannelCount, id: \.self) { channel in
                            Text(String(format: NSLocalizedString("Channel %d", comment: ""), channel)).tag(channel)
                        }
                    }
                    .pickerStyle(.menu)

                    Text("Choose the hardware channel to use as the mono input source for this microphone.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 360, alignment: .leading)
                }
                if captureAllInputChannels && enableStereoInput && activeInputChannelCount > 1 {
                    Picker("Left Channel:", selection: $selectedInputChannelLeft) {
                        ForEach(1...activeInputChannelCount, id: \.self) { channel in
                            Text(String(format: NSLocalizedString("Channel %d", comment: ""), channel)).tag(channel)
                        }
                    }
                    .pickerStyle(.menu)

                    Picker("Right Channel:", selection: $selectedInputChannelRight) {
                        ForEach(1...activeInputChannelCount, id: \.self) { channel in
                            Text(String(format: NSLocalizedString("Channel %d", comment: ""), channel)).tag(channel)
                        }
                    }
                    .pickerStyle(.menu)

                    Text("Choose which hardware channels feed the left and right sides of the stereo input.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 360, alignment: .leading)
                }
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
            LiveAudioBarView(
                meter: audioMeter,
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
        return NSLocalizedString("Unknown", comment: "")
    }

    var activeInputDeviceUID: String {
        followSystemInputDevice ? systemDefaultUID : preferredInputDeviceUID
    }

    var activeInputDevice: MacInputDeviceOption? {
        devices.first(where: { $0.uid == activeInputDeviceUID })
    }

    var activeInputChannelCount: Int {
        max(activeInputDevice?.inputChannels ?? 1, 1)
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
            if enableStereoInput {
                enableStereoInput = false
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

        if !captureAllInputChannels && enableStereoInput {
            enableStereoInput = false
            changed = true
        }

        let clampedMonoChannel = min(max(selectedInputChannel, 1), activeInputChannelCount)
        if selectedInputChannel != clampedMonoChannel {
            selectedInputChannel = clampedMonoChannel
            changed = true
        }

        let clampedLeftChannel = min(max(selectedInputChannelLeft, 1), activeInputChannelCount)
        if selectedInputChannelLeft != clampedLeftChannel {
            selectedInputChannelLeft = clampedLeftChannel
            changed = true
        }

        let defaultRightChannel = min(max(activeInputChannelCount, 1), 2)
        let clampedRightChannel = min(max(selectedInputChannelRight, 1), activeInputChannelCount)
        let normalizedRightChannel = captureAllInputChannels && enableStereoInput ? clampedRightChannel : defaultRightChannel
        if selectedInputChannelRight != normalizedRightChannel {
            selectedInputChannelRight = normalizedRightChannel
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
        LabeledContent("Auto Reconnect:") {
            Toggle("", isOn: $autoReconnect)
                .labelsHidden()
        }
        LabeledContent("Enable QoS:") {
            Toggle("", isOn: $enableQoS)
                .labelsHidden()
        }
        LabeledContent("Force TCP Mode:") {
            Toggle("", isOn: $forceTCP)
                .labelsHidden()
        }
        LabeledContent("Reconnect Attempts:") {
            Stepper(value: $reconnectMaxAttempts, in: 1...30) {
                Text("\(reconnectMaxAttempts)")
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 42, alignment: .trailing)
            }
        }
        LabeledContent("Reconnect Interval:") {
            HStack(spacing: 10) {
                Slider(value: $reconnectInterval, in: 0.5...10.0, step: 0.5)
                    .frame(maxWidth: 180)
                Text(
                    String(
                        format: NSLocalizedString("%.1f s", comment: "Reconnect interval unit suffix"),
                        reconnectInterval
                    )
                )
                .font(.system(.body, design: .monospaced))
                .frame(width: 50, alignment: .trailing)
            }
        }
        LabeledContent("Audio Plugin Mixer:") {
            VStack(alignment: .leading, spacing: 6) {
                Button("Open Mixer") {
                    openPluginMixer()
                }
                Text("Open a dedicated mixer page for track and plugin management.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 400, alignment: .leading)
            }
        }
        Text("Network changes require reconnection to take effect.")
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 400, alignment: .leading)
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
            options.append(MacInputDeviceOption(uid: uid, name: name, inputChannels: inputChannelCount(for: deviceID)))
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

    private static func inputChannelCount(for deviceID: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioBufferList>.size) else {
            return 1
        }

        let rawBuffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { rawBuffer.deallocate() }

        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, rawBuffer) == noErr else {
            return 1
        }

        let audioBufferListPointer = rawBuffer.bindMemory(to: AudioBufferList.self, capacity: 1)
        let audioBuffers = UnsafeMutableAudioBufferListPointer(audioBufferListPointer)
        let channelCount = audioBuffers.reduce(0) { partialResult, buffer in
            partialResult + Int(buffer.mNumberChannels)
        }
        return max(channelCount, 1)
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
            Text(NSLocalizedString("Language changes are applied immediately.", comment: ""))
        }
        .onReceive(NotificationCenter.default.publisher(for: .muAutomationOpenUI)) { notification in
            guard let target = notification.userInfo?["target"] as? String else { return }
            if target == "about" {
                showingAboutSheet = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .muAutomationDismissUI)) { notification in
            let target = notification.userInfo?["target"] as? String
            switch target {
            case nil:
                showingAboutSheet = false
                showingLanguageChangedAlert = false
            case "about":
                showingAboutSheet = false
            case "preferencesLanguageChanged":
                showingLanguageChangedAlert = false
            default:
                break
            }
        }
        .onChange(of: showingAboutSheet) { _, isPresented in
            if isPresented {
                AppState.shared.setAutomationPresentedSheet("about")
            } else {
                AppState.shared.clearAutomationPresentedSheet(ifMatches: "about")
            }
        }
        .onChange(of: showingLanguageChangedAlert) { _, isPresented in
            if isPresented {
                AppState.shared.setAutomationPresentedAlert("preferencesLanguageChanged")
            } else if AppState.shared.automationPresentedAlert == "preferencesLanguageChanged" {
                AppState.shared.setAutomationPresentedAlert(nil)
            }
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
            Text("Choose which profile to use when continuing a session from another device. \n'Automatic' will match by server address.")
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
        case logging
        
        var preferredContentSize: NSSize {
            switch self {
            case .general:
                return NSSize(width: 650, height: 240)
            case .input:
                return NSSize(width: 650, height: 600)
            case .output:
                return NSSize(width: 650, height: 220)
            case .notifications:
                return NSSize(width: 650, height: 380)
            case .tts:
                return NSSize(width: 650, height: 450)
            case .handoff:
                return NSSize(width: 650, height: 220)
            case .certificates:
                return NSSize(width: 650, height: 600)
            case .advanced:
                return NSSize(width: 650, height: 360)
            case .logging:
                return NSSize(width: 650, height: 600)
            }
        }
    }
    
    @EnvironmentObject var serverManager: ServerModelManager
    @StateObject private var languageManager = AppLanguageManager.shared
    @AppStorage("AppColorScheme") private var appColorSchemeRawValue: String = AppColorSchemeOption.system.rawValue
    @AppStorage("AudioCaptureAllInputChannels") private var captureAllInputChannels: Bool = false
    @AppStorage("AudioStereoInput") private var enableStereoInput: Bool = false
    @State private var selectedTab: MacSettingsTab = .general
    private var selectedAppColorScheme: AppColorSchemeOption {
        AppColorSchemeOption.normalized(from: appColorSchemeRawValue)
    }

    private var currentTabContentSize: NSSize {
        if selectedTab == .input && captureAllInputChannels && enableStereoInput {
            return NSSize(width: 650, height: 680)
        }
        return selectedTab.preferredContentSize
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
            
            LogSettingsView()
                .macSettingsCenteredPageStyle()
                .tabItem {
                    Label("Logging", systemImage: "ladybug")
                }
                .tag(MacSettingsTab.logging)
        }
        .frame(width: currentTabContentSize.width, height: currentTabContentSize.height)
        .background(MacSettingsWindowSizeAdaptor(targetSize: currentTabContentSize))
        .environment(\.locale, Locale(identifier: languageManager.localeIdentifier))
        .id(languageManager.localeIdentifier)
        .modifier(SettingsColorSchemeOverrideModifier(option: selectedAppColorScheme))
        .toggleStyle(.checkbox)
        .onAppear {
            languageManager.reapplyCurrentLanguage()
            syncAutomationCurrentScreen(for: selectedTab)
        }
        .onChange(of: selectedTab) { _, newValue in
            syncAutomationCurrentScreen(for: newValue)
        }
        .onReceive(NotificationCenter.default.publisher(for: .muAutomationOpenUI)) { notification in
            guard let target = notification.userInfo?["target"] as? String,
                  let tab = automationTab(for: target) else { return }
            selectedTab = tab
        }
        .onReceive(NotificationCenter.default.publisher(for: .muAutomationDismissUI)) { notification in
            let target = notification.userInfo?["target"] as? String
            guard let target,
                  let tab = automationTab(for: target),
                  selectedTab == tab else { return }
            selectedTab = .general
        }
    }
    
    private func automationTab(for target: String) -> MacSettingsTab? {
        switch target {
        case "preferences":
            return .general
        case "audioTransmissionSettings":
            return .input
        case "notificationSettings":
            return .notifications
        case "ttsSettings":
            return .tts
        case "certificateSettings":
            return .certificates
        case "advancedAudioSettings":
            return .advanced
        case "logSettings":
            return .logging
        default:
            return nil
        }
    }
    
    private func syncAutomationCurrentScreen(for tab: MacSettingsTab) {
        switch tab {
        case .general:
            AppState.shared.setAutomationCurrentScreen("preferences")
        case .input:
            AppState.shared.setAutomationCurrentScreen("audioTransmissionSettings")
        case .output:
            AppState.shared.setAutomationCurrentScreen("preferencesOutputSettings")
        case .notifications:
            AppState.shared.setAutomationCurrentScreen("notificationSettings")
        case .tts:
            AppState.shared.setAutomationCurrentScreen("ttsSettings")
        case .handoff:
            AppState.shared.setAutomationCurrentScreen("preferencesHandoffSettings")
        case .certificates:
            AppState.shared.setAutomationCurrentScreen("certificateSettings")
        case .advanced:
            AppState.shared.setAutomationCurrentScreen("advancedAudioSettings")
        case .logging:
            AppState.shared.setAutomationCurrentScreen("logSettings")
        }
    }
}

private struct MacSettingsWindowSizeAdaptor: NSViewRepresentable {
    let targetSize: NSSize
    
    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            resize(
                window: window,
                to: targetSize,
                animate: true
            )
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
