#if os(iOS)
import SwiftUI
import UIKit
import UserNotifications

extension NotificationSettingsView {
    @ViewBuilder
    var notificationSettingsContent: some View {
        Section(header: Text("User Messages"), footer: Text("Notifications will be sent when the app is in the background.")) {
            Toggle("User Messages", isOn: $notifyNormalUserMessages)
            Toggle("Private Messages", isOn: $notifyPrivateMessages)
        }
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
    
    var notificationAuthorizationOptions: UNAuthorizationOptions {
        [.alert, .badge, .sound]
    }
}

extension AudioTransmissionSettingsView {
    @ViewBuilder
    var platformInputDeviceSection: some View {
        EmptyView()
    }
    
    @ViewBuilder
    var platformProcessingSection: some View {
        Section(header: Text("Processing")) {
            Toggle("Stereo Input", isOn: $enableStereoInput)
            VStack(alignment: .leading) {
                Text(
                    String(
                        format: NSLocalizedString("Mic Volume: %d%%", comment: ""),
                        Int(micBoost * 100)
                    )
                )
                Slider(value: $micBoost, in: 0...3.0, step: 0.1) { editing in
                    if !editing { PreferencesModel.shared.notifySettingsChanged() }
                }
            }
        }
    }
    
    @ViewBuilder
    var platformVADSection: some View {
        Section(header: Text("Voice Activation Settings")) {
            Picker("Detection Type:", selection: $vadKind) {
                Text("Amplitude").tag("amplitude")
                Text("Signal to Noise").tag("snr")
            }
            .pickerStyle(.segmented)
            .onChange(of: vadKind) { _, newValue in
                handleVADKindSelectionChange(newValue)
            }
            
            vadDetailControls
        }
    }
    
    @ViewBuilder
    var platformPTTSettingsContent: some View {
        Text("Hold the on-screen talk button (if enabled) to speak.")
            .font(.caption)
            .foregroundColor(.secondary)
    }
    
    @ViewBuilder
    var platformVADDetailControlsContent: some View {
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
            Text(
                String(
                    format: NSLocalizedString("Silence Below: %d%%", comment: ""),
                    Int(vadBelow * 100)
                )
            )
            .font(.caption)
            .foregroundColor(.secondary)
            Slider(value: $vadBelow, in: 0...1) { editing in
                if !editing { PreferencesModel.shared.notifySettingsChanged() }
            }
        }
        
        VStack(alignment: .leading) {
            Text(
                String(
                    format: NSLocalizedString("Speech Above: %d%%", comment: ""),
                    Int(vadAbove * 100)
                )
            )
            .font(.caption)
            .foregroundColor(.secondary)
            Slider(value: $vadAbove, in: 0...1) { editing in
                if !editing { PreferencesModel.shared.notifySettingsChanged() }
            }
        }
        
        VStack(alignment: .leading) {
            Text(
                String(
                    format: NSLocalizedString("Silence Hold: %d ms", comment: ""),
                    Int((vadHoldSeconds * 1000).rounded())
                )
            )
            .font(.caption)
            .foregroundColor(.secondary)
            Slider(value: vadHoldBinding, in: 0...0.3, step: 0.01) { editing in
                if !editing { PreferencesModel.shared.notifySettingsChanged() }
            }
        }
    }
    
    func platformRefreshDevicesImpl() {}
}

extension AdvancedAudioSettingsView {
    @ViewBuilder
    var platformAdvancedSettingsContent: some View {
        if includeOutputSection {
            Section(header: Text("Output")) {
                if UIDevice.current.userInterfaceIdiom == .phone {
                    Toggle("Speakerphone Mode", isOn: $speakerPhoneMode)
                }
                Toggle("Stereo Output", isOn: $enableStereoOutput)
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
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

extension View {
    @ViewBuilder
    func platformAudioInputRefreshHandlers(_ onRefresh: @escaping () -> Void) -> some View {
        self
    }
}
#endif
