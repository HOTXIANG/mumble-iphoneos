#if os(iOS)
import SwiftUI

struct PreferencesView: View {
    @StateObject private var languageManager = AppLanguageManager.shared
    @AppStorage("AppColorScheme") private var appColorSchemeRawValue: String = AppColorSchemeOption.system.rawValue
    @AppStorage("AudioOutputVolume") var outputVolume: Double = 1.0
    @AppStorage(MumbleHandoffSyncLocalAudioSettingsKey) var handoffSyncLocalAudioSettings: Bool = true
    @AppStorage("HandoffPreferredProfileKey") var handoffPreferredProfileKey: Int = -1
    @Environment(\.dismiss) var dismiss
    @State private var showingLanguageChangedAlert = false

    private var selectedAppColorScheme: AppColorSchemeOption {
        AppColorSchemeOption.normalized(from: appColorSchemeRawValue)
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

            NavigationLink(destination: AudioTransmissionSettingsView()) {
                Label("Input Setting", systemImage: "mic")
            }

            NavigationLink(destination: AdvancedAudioSettingsView()) {
                Label("Advanced & Network", systemImage: "slider.horizontal.3")
            }
        }

        Section(header: Text("Notifications")) {
            NavigationLink(destination: NotificationSettingsView()) {
                Label("Push Notifications", systemImage: "bell.badge")
            }
        }

        Section(
            header: Text("Handoff"),
            footer: Text("Choose which profile to use when continuing a session from another device. 'Automatic' will match by server address.")
        ) {
            HandoffProfilePicker(selectedKey: $handoffPreferredProfileKey)
            Toggle("Sync Local User Volume on Handoff", isOn: $handoffSyncLocalAudioSettings)
        }

        NavigationLink(destination: CertificatePreferencesView()) {
            Label("Certificates", systemImage: "checkmark.shield")
        }

        Section {
            NavigationLink(destination: AboutView()) {
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
        .modifier(SettingsColorSchemeOverrideModifier(option: selectedAppColorScheme))
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
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
            Text(NSLocalizedString("Some texts will fully update after restarting the app.", comment: ""))
        }
        .onAppear {
            languageManager.reapplyCurrentLanguage()
        }
        .onReceive(NotificationCenter.default.publisher(for: .mumbleShowVADTutorialAgain)) { _ in
            dismiss()
        }
    }
}
#endif
