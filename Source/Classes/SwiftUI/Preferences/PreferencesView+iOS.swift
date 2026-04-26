#if os(iOS)
import SwiftUI

struct PreferencesView: View {
    private enum AutomationDestination: Hashable {
        case audioTransmissionSettings
        case advancedAudioSettings
        case notificationSettings
        case ttsSettings
        case certificateSettings
        case logSettings
        case about
    }

    @StateObject private var languageManager = AppLanguageManager.shared
    @AppStorage("AppColorScheme") private var appColorSchemeRawValue: String = AppColorSchemeOption.system.rawValue
    @AppStorage("AudioOutputVolume") var outputVolume: Double = 1.0
    @AppStorage(MumbleHandoffSyncLocalAudioSettingsKey) var handoffSyncLocalAudioSettings: Bool = true
    @AppStorage("HandoffPreferredProfileKey") var handoffPreferredProfileKey: Int = -1
    @Environment(\.dismiss) var dismiss
    @State private var showingLanguageChangedAlert = false
    @State private var automationDestination: AutomationDestination? = nil

    private var selectedAppColorScheme: AppColorSchemeOption {
        AppColorSchemeOption.normalized(from: appColorSchemeRawValue)
    }

    private func automationBinding(for destination: AutomationDestination) -> Binding<Bool> {
        Binding(
            get: { automationDestination == destination },
            set: { isPresented in
                if isPresented {
                    automationDestination = destination
                } else if automationDestination == destination {
                    automationDestination = nil
                }
            }
        )
    }

    @ViewBuilder
    private var preferencesContent: some View {
        Section(header: Text("General")) {
            Picker(
                "Language",
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
            .pickerStyle(.menu)

            Picker(
                "Appearance",
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
            .pickerStyle(.menu)
            
            let showHidden = Binding(
                get: { UserDefaults.standard.bool(forKey: "ShowHiddenChannels") },
                set: {
                    UserDefaults.standard.set($0, forKey: "ShowHiddenChannels")
                    NotificationCenter.default.post(name: ServerModelNotificationManager.rebuildModelNotification, object: nil)
                }
            )
            Toggle("Show Hidden Channels", isOn: showHidden)
        }
        
        Section(header: Text("Audio")) {
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

            NavigationLink {
                AudioTransmissionSettingsView()
            } label: {
                Label("Input Setting", systemImage: "mic")
            }

            NavigationLink {
                AdvancedAudioSettingsView()
            } label: {
                Label("Advanced & Network", systemImage: "slider.horizontal.3")
            }
        }

        Section(header: Text("Notifications")) {
            NavigationLink {
                NotificationSettingsView()
            } label: {
                Label("Push Notifications", systemImage: "bell.badge")
            }
            NavigationLink {
                TTSSettingsView()
            } label: {
                Label("Text-to-Speech", systemImage: "waveform")
            }
        }

        Section(
            header: Text("Handoff"),
            footer: Text("Choose which profile to use when continuing a session from another device. 'Automatic' will match by server address.")
        ) {
            HandoffProfilePicker(selectedKey: $handoffPreferredProfileKey)
            Toggle("Sync Local User Volume on Handoff", isOn: $handoffSyncLocalAudioSettings)
        }

        NavigationLink {
            CertificatePreferencesView()
        } label: {
            Label("Certificates", systemImage: "checkmark.shield")
        }

        Section(header: Text("Developer")) {
            NavigationLink {
                LogSettingsView()
            } label: {
                Label("Logging", systemImage: "ladybug")
            }
        }

        Section {
            NavigationLink {
                AboutView()
            } label: {
                Label("About Mumble", systemImage: "info.circle")
            }
        } footer: {
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
            Text(
                String(
                    format: NSLocalizedString("Mumble iOS v%@", comment: ""),
                    version
                )
            )
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top)
        }
    }

    var body: some View {
        List {
            preferencesContent
        }
        .environment(\.locale, Locale(identifier: languageManager.localeIdentifier))
        .id(languageManager.localeIdentifier)
        .modifier(SettingsColorSchemeOverrideModifier(option: selectedAppColorScheme))
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: automationBinding(for: .audioTransmissionSettings)) {
            AudioTransmissionSettingsView()
        }
        .navigationDestination(isPresented: automationBinding(for: .advancedAudioSettings)) {
            AdvancedAudioSettingsView()
        }
        .navigationDestination(isPresented: automationBinding(for: .notificationSettings)) {
            NotificationSettingsView()
        }
        .navigationDestination(isPresented: automationBinding(for: .ttsSettings)) {
            TTSSettingsView()
        }
        .navigationDestination(isPresented: automationBinding(for: .certificateSettings)) {
            CertificatePreferencesView()
        }
        .navigationDestination(isPresented: automationBinding(for: .logSettings)) {
            LogSettingsView()
        }
        .navigationDestination(isPresented: automationBinding(for: .about)) {
            AboutView()
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button("Done") {
                    dismiss()
                }
            }
        }
        .alert(NSLocalizedString("Language Changed", comment: ""), isPresented: $showingLanguageChangedAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(NSLocalizedString("Language changes are applied immediately.", comment: ""))
        }
        .onAppear {
            AppState.shared.setAutomationCurrentScreen("preferences")
            languageManager.reapplyCurrentLanguage()
        }
        .onReceive(NotificationCenter.default.publisher(for: .muAutomationOpenUI)) { notification in
            guard let target = notification.userInfo?["target"] as? String else { return }
            switch target {
            case "notificationSettings":
                automationDestination = .notificationSettings
            case "ttsSettings":
                automationDestination = .ttsSettings
            case "audioTransmissionSettings":
                automationDestination = .audioTransmissionSettings
            case "advancedAudioSettings":
                automationDestination = .advancedAudioSettings
            case "certificateSettings":
                automationDestination = .certificateSettings
            case "logSettings":
                automationDestination = .logSettings
            case "about":
                automationDestination = .about
            default:
                break
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .muAutomationDismissUI)) { notification in
            let target = notification.userInfo?["target"] as? String
            switch target {
            case nil:
                automationDestination = nil
            case "preferencesLanguageChanged":
                showingLanguageChangedAlert = false
            case "notificationSettings" where automationDestination == .notificationSettings:
                automationDestination = nil
            case "ttsSettings" where automationDestination == .ttsSettings:
                automationDestination = nil
            case "audioTransmissionSettings" where automationDestination == .audioTransmissionSettings:
                automationDestination = nil
            case "advancedAudioSettings" where automationDestination == .advancedAudioSettings:
                automationDestination = nil
            case "certificateSettings" where automationDestination == .certificateSettings:
                automationDestination = nil
            case "logSettings" where automationDestination == .logSettings:
                automationDestination = nil
            case "about" where automationDestination == .about:
                automationDestination = nil
            default:
                break
            }
        }
        .onChange(of: showingLanguageChangedAlert) { _, isPresented in
            if isPresented {
                AppState.shared.setAutomationPresentedAlert("preferencesLanguageChanged")
            } else if AppState.shared.automationPresentedAlert == "preferencesLanguageChanged" {
                AppState.shared.setAutomationPresentedAlert(nil)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .mumbleShowVADTutorialAgain)) { _ in
            dismiss()
        }
    }
}
#endif
