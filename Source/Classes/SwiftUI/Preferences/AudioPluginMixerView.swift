//
//  AudioPluginMixerView.swift
//  Mumble
//
//  DAW-style audio plugin mixer for input/output effect processing.
//

import SwiftUI
@preconcurrency import AVFoundation
#if os(iOS)
import UIKit
import CoreAudioKit
#elseif os(macOS)
import AppKit
import CoreAudioKit
#endif

#if os(macOS)
@MainActor
final class AudioPluginMixerWindowController: NSObject {
    static let shared = AudioPluginMixerWindowController()

    private var window: NSWindow?

    private override init() {
        super.init()
    }

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
            self,
            selector: #selector(handleMixerWindowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: window
        )

        self.window = window
    }

    @objc private func handleMixerWindowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing == window else { return }
        window = nil
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
            autoLoad = try container.decodeIfPresent(Bool.self, forKey: .autoLoad) ?? true
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

    private struct PluginPreset: Identifiable, Codable, Hashable {
        let id: String
        var name: String
        var parameterValues: [String: Float]
        var createdAt: Date

        enum CodingKeys: String, CodingKey {
            case id, name, parameterValues, createdAt
        }
    }

    private struct AudioUnitInstantiationResult: @unchecked Sendable {
        let unit: AVAudioUnit?
        let error: NSError?
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
        let parameterCount: Int
        let errorDescription: String?
    }

    private struct TrackProcessorState {
        let trackKey: String
        let nodes: [ProcessorNodeSnapshot]
    }

    @AppStorage("AudioPluginInputTrackEnabled") private var pluginInputTrackEnabled: Bool = false
    @AppStorage("AudioPluginInputTrackGain") private var pluginInputTrackGain: Double = 1.0
    @AppStorage("AudioPluginRemoteBusEnabled") private var pluginRemoteBusEnabled: Bool = false
    @AppStorage("AudioPluginRemoteBusGain") private var pluginRemoteBusGain: Double = 1.0
    @AppStorage("AudioPluginCustomScanPaths") private var pluginCustomScanPaths: String = ""
    @AppStorage("AudioPluginTrackChainsV1") private var pluginTrackChainsData: String = ""
    @AppStorage("AudioPluginChainLivePreviewEnabled") private var pluginChainLivePreviewEnabled: Bool = true
    @AppStorage("AudioPluginPresetsV1") private var pluginPresetsData: String = ""
    @AppStorage("AudioPluginHostBufferFrames") private var pluginHostBufferFrames: Int = 256

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
    @State private var loadedAudioUnits: [String: AVAudioUnit] = [:]  // Key: "\(trackKey):\(pluginID)"
    @State private var parameterStateByPlugin: [String: [RuntimeParameter]] = [:]
    @State private var lastLoadErrorByPlugin: [String: String] = [:]
    @State private var processorStateByTrack: [String: TrackProcessorState] = [:]
    @State private var audioUnitDescriptionByIdentifier: [String: AudioComponentDescription] = [:]
    @State private var showingPluginBrowser: Bool = false
#if os(iOS)
    @State private var pluginEditorController: PlatformViewController? = nil
    @State private var pluginEditorTitle: String = ""
    @State private var showingPluginEditor: Bool = false
#endif
    @State private var isLoadingPersistedPlugins: Bool = false
    @State private var pluginPresetsByIdentifier: [String: [PluginPreset]] = [:]
    @State private var showingPresetSaveDialog: Bool = false
    @State private var presetNameInput: String = ""
    @State private var selectedPresetID: String? = nil

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
            let remoteBusChainCount = pluginChainByTrack["remoteBus"]?.count ?? 0
            NSLog("MKAudioProbe: Mixer onAppear remoteBusChain=\(remoteBusChainCount) selectedTrack=\(String(describing: selectedTrack))")
            loadPluginPresets()
            refreshRemoteSessionOrder()
            refreshInstalledAudioUnits()
#if os(macOS)
            refreshFilesystemPluginScan()
#endif
            loadSelectedTrackState()
            normalizeSelectedPluginSelection()
            applyLivePreviewForAllTracks()
            rebuildProcessorStateMachine()
            syncPluginHostBufferFrames()
            Task {
                await loadPersistedAudioUnits()
            }
        }
        .onChange(of: selectedTrack) {
            loadSelectedTrackState()
            normalizeSelectedPluginSelection()
            rebuildProcessorStateMachine()
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
        .onChange(of: pluginHostBufferFrames) {
            syncPluginHostBufferFrames()
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
        .sheet(isPresented: $showingPluginBrowser) {
            pluginBrowserSheet
        }
#if os(iOS)
        .onChange(of: showingPluginEditor) {
            if !showingPluginEditor {
                pluginEditorController = nil
                pluginEditorTitle = ""
                selectedPluginID = nil
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
            Text(NSLocalizedString("Buffer", comment: ""))
                .font(.caption)
                .foregroundColor(.secondary)
            Picker(NSLocalizedString("Buffer", comment: ""), selection: $pluginHostBufferFrames) {
                Text("64").tag(64)
                Text("128").tag(128)
                Text("256").tag(256)
                Text("512").tag(512)
                Text("1024").tag(1024)
                Text("2048").tag(2048)
            }
            .pickerStyle(.menu)
            Button(NSLocalizedString("Refresh Remote Tracks", comment: "")) {
                refreshRemoteSessionOrder()
            }
            .buttonStyle(.bordered)
            Button(NSLocalizedString("Plugin Browser", comment: "")) {
                showingPluginBrowser = true
            }
            .buttonStyle(.bordered)
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
            .contentShape(Rectangle())
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
            Text(NSLocalizedString("Choose a plugin for each insert, enable it when needed, open its editor, and set its mix.", comment: ""))
                .font(.caption)
                .foregroundColor(.secondary)

            ForEach(0..<maxInsertSlots, id: \.self) { slotIndex in
                let plugin = pluginAtSlot(slotIndex)
                let isSelected = selectedPluginID == plugin?.id

                HStack(spacing: 10) {
                    Text("\(slotIndex + 1)")
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                        .frame(width: 24)

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
                                            Task {
                                                await assignPluginToSlot(discovered, slotIndex: slotIndex)
                                            }
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
                        HStack(spacing: 8) {
                            Text(plugin?.name ?? NSLocalizedString("Select Plugin", comment: ""))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .frame(minWidth: 240, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.secondary.opacity(0.12))
                        )
                    }
                    .menuStyle(.borderlessButton)

                    if let plugin {
                        Spacer(minLength: 0)

                        HStack(spacing: 10) {
                            Button(plugin.bypassed ? NSLocalizedString("Off", comment: "") : NSLocalizedString("On", comment: "")) {
                                toggleBypass(at: slotIndex)
                            }
                            .buttonStyle(.bordered)

                            Button {
                                movePluginUp(at: slotIndex)
                            } label: {
                                Image(systemName: "chevron.up")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .disabled(slotIndex == 0)

                            Button {
                                movePluginDown(at: slotIndex)
                            } label: {
                                Image(systemName: "chevron.down")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .disabled(slotIndex >= selectedTrackChain.count - 1)

                            HStack(spacing: 8) {
                                Text(NSLocalizedString("Mix", comment: ""))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Slider(
                                    value: Binding(
                                        get: { Double(plugin.stageGain * 100.0) },
                                        set: { updateMixLevel(at: slotIndex, newValue: Float($0 / 100.0)) }
                                    ),
                                    in: 0...100
                                )
                                .frame(width: 140)
                                Text("\(Int((plugin.stageGain * 100.0).rounded()))%")
                                    .font(.caption.monospacedDigit())
                                    .foregroundColor(.secondary)
                                    .frame(width: 40, alignment: .trailing)
                            }
                            .frame(width: 220, alignment: .trailing)
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    } else {
                        Spacer(minLength: 0)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08))
                )
                .onTapGesture {
                    guard let plugin else {
                        selectedPluginID = nil
                        return
                    }
                    selectedPluginID = plugin.id
                    openPluginEditor(for: plugin)
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

    private var pluginBrowserSheet: some View {
        NavigationStack {
            ScrollView {
                pluginBrowserPanel
                    .padding(16)
            }
            .navigationTitle(NSLocalizedString("Plugin Browser", comment: ""))
            .toolbar {
                ToolbarItemGroup(placement: .automatic) {
                    Button(NSLocalizedString("Refresh Audio Units", comment: "")) {
                        refreshInstalledAudioUnits()
                    }
#if os(macOS)
                    Button(NSLocalizedString("Scan Plugin Bundles", comment: "")) {
                        refreshFilesystemPluginScan()
                    }
#endif
                    Button(NSLocalizedString("Done", comment: "")) {
                        showingPluginBrowser = false
                    }
                }
            }
        }
#if os(macOS)
        .frame(minWidth: 920, minHeight: 720)
#endif
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
                        Text(NSLocalizedString("Filesystem plugin hosting is enabled. If loading fails, check the status line for detailed error.", comment: ""))
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
                            // Preset Management Section
                            Divider()
                            VStack(alignment: .leading, spacing: 8) {
                                Text(NSLocalizedString("Presets", comment: ""))
                                    .font(.caption.weight(.semibold))

                                let presets = pluginPresetsByIdentifier[selectedPlugin.identifier] ?? []
                                if presets.isEmpty {
                                    Text(NSLocalizedString("No saved presets", comment: ""))
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                } else {
                                    ForEach(presets) { preset in
                                        HStack(spacing: 8) {
                                            Button(preset.name) {
                                                loadPreset(preset, for: selectedPlugin.id)
                                            }
                                            .buttonStyle(.borderless)
                                            .font(.caption)

                                            Spacer()

                                            Button(action: {
                                                deletePreset(preset, for: selectedPlugin.identifier)
                                            }) {
                                                Image(systemName: "trash")
                                                    .font(.caption)
                                            }
                                            .buttonStyle(.borderless)
                                            .foregroundColor(.red)
                                        }
                                    }
                                }

                                HStack(spacing: 8) {
                                    TextField(NSLocalizedString("Preset name", comment: ""), text: $presetNameInput)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.caption)

                                    Button(NSLocalizedString("Save", comment: "")) {
                                        saveCurrentAsPreset(for: selectedPlugin)
                                    }
                                    .buttonStyle(.bordered)
                                    .font(.caption)
                                    .disabled(presetNameInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                }
                            }

                            Divider()

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
                        Text(NSLocalizedString("Plugin is still initializing or failed to load. Check the status message for details.", comment: ""))
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
        selectedPluginID = nil
    }

    private func audioUnitLoaded(for pluginID: String) -> Bool {
        let loadedKey = loadedAudioUnitKey(trackKey: selectedTrackKey, pluginID: pluginID)
        return loadedAudioUnits[loadedKey] != nil
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

    private func addPlugin(_ plugin: DiscoveredPlugin) async {
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
                    autoLoad: true,
                    savedParameterValues: [:]
                )
            )
            pluginOperationMessage = String(format: NSLocalizedString("Added %@", comment: ""), plugin.name)
        }
        if (plugin.source == .audioUnit || plugin.source == .filesystem), let latest = selectedTrackChain.last {
            _ = await loadAudioUnit(for: latest)
        }
    }

    private func assignPluginToSlot(_ discovered: DiscoveredPlugin, slotIndex: Int) async {
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
                autoLoad: true,
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
        if let inserted = selectedTrackChain.first(where: { $0.id == insertedPluginID }),
           inserted.source == .audioUnit || inserted.source == .filesystem {
            _ = await loadAudioUnit(for: inserted)
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

    private func updateMixLevel(at index: Int, newValue: Float) {
        mutateSelectedTrackChain { chain in
            guard chain.indices.contains(index) else { return }
            chain[index].stageGain = min(max(newValue, 0.0), 1.0)
        }
    }

    private func loadPersistedAudioUnits() async {
        guard !isLoadingPersistedPlugins else { return }

        let targets = pluginChainByTrack
            .flatMap { trackKey, chain in
                chain.filter { plugin in
                    guard plugin.source == .audioUnit || plugin.source == .filesystem else {
                        return false
                    }
                    let loadedKey = loadedAudioUnitKey(trackKey: trackKey, pluginID: plugin.id)
                    return loadedAudioUnits[loadedKey] == nil
                }
            }

        guard !targets.isEmpty else { return }

        let remoteBusTargets = targets.filter { plugin in
            pluginChainByTrack["remoteBus"]?.contains(where: { $0.id == plugin.id }) == true
        }.count
        NSLog("MKAudioProbe: loadPersistedAudioUnits targets=\(targets.count) remoteBusTargets=\(remoteBusTargets)")

        isLoadingPersistedPlugins = true
        defer { isLoadingPersistedPlugins = false }

        for plugin in targets {
            _ = await loadAudioUnit(for: plugin)
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
        let enabled = chain.contains { !$0.bypassed }
        let gain: Float = 1.0

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

    private func activeAudioUnitChain(for key: String) -> [NSDictionary] {
        let chain = pluginChainByTrack[key] ?? []
        return chain
            .filter { !$0.bypassed }
            .compactMap { plugin in
                guard let audioUnit = loadedAudioUnits[loadedAudioUnitKey(trackKey: key, pluginID: plugin.id)] else {
                    return nil
                }
                return [
                    "audioUnit": audioUnit,
                    "mix": NSNumber(value: min(max(plugin.stageGain, 0.0), 1.0))
                ] as NSDictionary
            }
    }

    private func syncPluginHostBufferFrames() {
        MKAudio.shared().setPluginHostBufferFrames(UInt(max(pluginHostBufferFrames, 64)))
    }

    private func syncAudioUnitDSPChainForTrackKey(_ key: String) {
        if key == "input" {
            MKAudio.shared().setInputTrackAudioUnitChain(activeAudioUnitChain(for: key))
            return
        }
        if key == "remoteBus" {
            MKAudio.shared().setRemoteBusAudioUnitChain(activeAudioUnitChain(for: key))
            return
        }
        if let session = parseRemoteSessionID(from: key) {
            MKAudio.shared().setRemoteTrackAudioUnitChain(activeAudioUnitChain(for: key), forSession: UInt(session))
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
            let loadedKey = loadedAudioUnitKey(trackKey: key, pluginID: plugin.id)
            let state: ProcessorNodeState
            if plugin.bypassed {
                state = .bypassed
            } else if loadingPluginIDs.contains(plugin.id) {
                state = .loading
            } else if loadedAudioUnits[loadedKey] != nil {
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
                parameterCount: parameterStateByPlugin[plugin.id]?.count ?? -1,
                errorDescription: lastLoadErrorByPlugin[plugin.id]
            )
        }
        let snapshot = TrackProcessorState(
            trackKey: key,
            nodes: nodes
        )
        processorStateByTrack[key] = snapshot
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

    private func loadAudioUnit(for plugin: TrackPlugin) async -> Bool {
        guard plugin.source == .audioUnit || plugin.source == .filesystem else {
            pluginOperationMessage = NSLocalizedString("Only Audio Unit and filesystem plugins can be loaded", comment: "")
            return false
        }

        // Determine the track key for this plugin
        let trackKey: String
        if let containingTrack = self.trackKey(containingPluginID: plugin.id) {
            trackKey = containingTrack
        } else {
            trackKey = selectedTrackKey
        }

        let loadedKey = loadedAudioUnitKey(trackKey: trackKey, pluginID: plugin.id)

        if loadingPluginIDs.contains(plugin.id) {
            return false
        }
        if loadedAudioUnits[loadedKey] != nil {
            return true
        }

        let requiredChannels = channelCount(for: trackKey)
        let requiredSampleRate = pluginSampleRate(for: trackKey)

        // For filesystem plugins (VST3), use dedicated VST3 loading
        if plugin.source == .filesystem {
            return await loadVST3Plugin(
                plugin,
                loadedKey: loadedKey,
                requiredChannels: requiredChannels,
                sampleRate: requiredSampleRate,
                trackKey: trackKey
            )
        }

        // For Audio Unit plugins, use the component description lookup
        let description = audioUnitDescriptionByIdentifier[plugin.identifier] ?? parseAudioUnitDescription(from: plugin.identifier)
        guard let description else {
            pluginOperationMessage = NSLocalizedString("Failed to parse Audio Unit identifier", comment: "")
            return false
        }

        loadingPluginIDs.insert(plugin.id)
        lastLoadErrorByPlugin[plugin.id] = nil
        rebuildProcessorStateMachine()

        let errorText = await instantiateAudioUnitWithFallback(
            description: description,
            requiredChannels: requiredChannels,
            sampleRate: requiredSampleRate,
            loadedKey: loadedKey
        )

        loadingPluginIDs.remove(plugin.id)

        if errorText == nil {
            lastLoadErrorByPlugin[plugin.id] = nil
            parameterStateByPlugin[plugin.id] = []
            pluginOperationMessage = String(format: NSLocalizedString("Loaded %@", comment: ""), plugin.name)
            applyLivePreviewForTrackKey(trackKey)
            rebuildProcessorStateMachine()
            return true
        }

        parameterStateByPlugin[plugin.id] = nil
        lastLoadErrorByPlugin[plugin.id] = errorText
        pluginOperationMessage = String(format: NSLocalizedString("Failed to load %@: %@", comment: ""), plugin.name, errorText!)
        rebuildProcessorStateMachine()
        return false
    }

    private func loadVST3Plugin(
        _ plugin: TrackPlugin,
        loadedKey: String,
        requiredChannels: UInt,
        sampleRate: Double,
        trackKey: String
    ) async -> Bool {
        // Extract the VST3 bundle path from the identifier (format: "fs:/path/to/plugin.vst3")
        guard plugin.identifier.hasPrefix("fs:") else {
            let message = NSLocalizedString("Invalid filesystem plugin identifier", comment: "")
            lastLoadErrorByPlugin[plugin.id] = message
            pluginOperationMessage = String(format: NSLocalizedString("Failed to load %@: %@", comment: ""), plugin.name, message)
            rebuildProcessorStateMachine()
            return false
        }

        let bundlePath = String(plugin.identifier.dropFirst(3))
        let bundleURL = URL(fileURLWithPath: bundlePath)
        let canonicalBundlePath = bundleURL.standardizedFileURL.path
        let bundleName = bundleURL.deletingPathExtension().lastPathComponent.lowercased()
        let pluginDisplayName = plugin.name.replacingOccurrences(of: ".vst3", with: "", options: [.caseInsensitive]).lowercased()

        // Load the VST3 bundle as an Audio Unit component
        // macOS exposes VST3 plugins as AU components when they're properly installed
        // For manually scanned VST3 bundles, we search for matching component by name
        let manager = AVAudioUnitComponentManager.shared()

        // Search by bundle path first, then fallback to name matching.
        let componentTypes: [UInt32] = [
            kAudioUnitType_Effect,
            kAudioUnitType_MusicEffect,
            kAudioUnitType_FormatConverter,
            kAudioUnitType_Generator
        ]
        var foundComponent: AVAudioUnitComponent?

        for type in componentTypes {
            let desc = AudioComponentDescription(
                componentType: type,
                componentSubType: 0,
                componentManufacturer: 0,
                componentFlags: 0,
                componentFlagsMask: 0
            )
            let components = manager.components(matching: desc)
            for component in components {
                let componentName = component.name.lowercased()
                let manufacturerName = component.manufacturerName.lowercased()
                if componentName.contains(bundleName)
                    || componentName.contains(pluginDisplayName)
                    || manufacturerName.contains(bundleName)
                    || manufacturerName.contains(pluginDisplayName)
                    || componentName.localizedStandardContains(canonicalBundlePath) {
                    foundComponent = component
                    break
                }
            }
            if foundComponent != nil { break }
        }

        guard let component = foundComponent else {
            let message = NSLocalizedString("No matching AU component found for this filesystem plugin", comment: "")
            lastLoadErrorByPlugin[plugin.id] = message
            pluginOperationMessage = String(format: NSLocalizedString("Failed to load %@: %@", comment: ""), plugin.name, message)
            rebuildProcessorStateMachine()
            return false
        }

        loadingPluginIDs.insert(plugin.id)
        lastLoadErrorByPlugin[plugin.id] = nil
        rebuildProcessorStateMachine()

        let errorText = await instantiateAudioUnitWithFallback(
            description: component.audioComponentDescription,
            requiredChannels: requiredChannels,
            sampleRate: sampleRate,
            loadedKey: loadedKey
        )
        if let errorText {
            loadingPluginIDs.remove(plugin.id)
            parameterStateByPlugin[plugin.id] = nil
            lastLoadErrorByPlugin[plugin.id] = errorText
            pluginOperationMessage = String(format: NSLocalizedString("Failed to load %@: %@", comment: ""), plugin.name, errorText)
            rebuildProcessorStateMachine()
            return false
        }

        loadingPluginIDs.remove(plugin.id)
        lastLoadErrorByPlugin[plugin.id] = nil
        parameterStateByPlugin[plugin.id] = []
        pluginOperationMessage = String(format: NSLocalizedString("Loaded %@", comment: ""), plugin.name)
        applyLivePreviewForTrackKey(trackKey)
        rebuildProcessorStateMachine()
        return true
    }

    private func instantiateAudioUnitWithFallback(
        description: AudioComponentDescription,
        requiredChannels: UInt,
        sampleRate: Double,
        loadedKey: String
    ) async -> String? {
        // Try with required channels first
        if let error = await tryInstantiateWithChannels(
            description: description,
            channels: requiredChannels,
            sampleRate: sampleRate,
            loadedKey: loadedKey
        ) {
            // If required channels is 2 and failed, try with 1 channel (mono plugins)
            if requiredChannels == 2 {
                NSLog("MKAudio: Failed to load AU with 2 channels, trying 1 channel (mono)")
                if let monoError = await tryInstantiateWithChannels(
                    description: description,
                    channels: 1,
                    sampleRate: sampleRate,
                    loadedKey: loadedKey
                ) {
                    return monoError
                }
                return nil  // Success with 1 channel
            }
            return error
        }
        return nil  // Success with required channels
    }

    private func tryInstantiateWithChannels(
        description: AudioComponentDescription,
        channels: UInt,
        sampleRate: Double,
        loadedKey: String
    ) async -> String? {
        // Create format with specified channels
        let effectiveSampleRate = sampleRate > 0 ? sampleRate : 48_000
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: effectiveSampleRate,
            channels: AVAudioChannelCount(channels)
        ) else {
            return NSLocalizedString("Failed to create audio format", comment: "")
        }

#if os(macOS)
        // Prefer out-of-process hosting on macOS. Third-party AUs frequently fail
        // hardened runtime validation in-process, which creates load churn and XRuns.
        let (unitOut, errorOut) = await withUnsafeContinuation { (c: UnsafeContinuation<(AVAudioUnit?, NSError?), Never>) in
            AVAudioUnit.instantiate(with: description, options: [.loadOutOfProcess]) { unit, error in
                c.resume(returning: (unit, error as NSError?))
            }
        }

        if let unitOut, self.configureAudioUnit(unitOut, format: format) {
            self.loadedAudioUnits[loadedKey] = unitOut
            NSLog("MKAudio: AU loaded successfully with %lu channels (loadOutOfProcess)", UInt(channels))
            return nil
        }

        // Try default load
        let (unitDefault, errorDefault) = await withUnsafeContinuation { (c: UnsafeContinuation<(AVAudioUnit?, NSError?), Never>) in
            AVAudioUnit.instantiate(with: description, options: []) { unit, error in
                c.resume(returning: (unit, error as NSError?))
            }
        }

        if let unitDefault, self.configureAudioUnit(unitDefault, format: format) {
            self.loadedAudioUnits[loadedKey] = unitDefault
            NSLog("MKAudio: AU loaded successfully with %lu channels (default)", UInt(channels))
            return nil
        }

        // Built-in/system AUs can still succeed in-process.
        let (unitIn, errorIn) = await withUnsafeContinuation { (c: UnsafeContinuation<(AVAudioUnit?, NSError?), Never>) in
            AVAudioUnit.instantiate(with: description, options: [.loadInProcess]) { unit, error in
                c.resume(returning: (unit, error as NSError?))
            }
        }

        if let unitIn, self.configureAudioUnit(unitIn, format: format) {
            self.loadedAudioUnits[loadedKey] = unitIn
            NSLog("MKAudio: AU loaded successfully with %lu channels (loadInProcess)", UInt(channels))
            return nil
        }

        let finalError = (errorOut ?? errorDefault ?? errorIn)
        if finalError?.domain == NSOSStatusErrorDomain, finalError?.code == -3000 {
            return NSLocalizedString("Audio Unit host compatibility error (-3000). Try another AU or restart audio engine.", comment: "")
        }
        return finalError?.localizedDescription ?? NSLocalizedString("Unknown error", comment: "")
#else
        let (unitDefault, errorDefault) = await withUnsafeContinuation { (c: UnsafeContinuation<(AVAudioUnit?, NSError?), Never>) in
            AVAudioUnit.instantiate(with: description, options: []) { unit, error in
                c.resume(returning: (unit, error as NSError?))
            }
        }

        if let unitDefault, self.configureAudioUnit(unitDefault, format: format) {
            self.loadedAudioUnits[loadedKey] = unitDefault
            NSLog("MKAudio: AU loaded successfully with %lu channels", UInt(channels))
            return nil
        }

        return errorDefault?.localizedDescription ?? NSLocalizedString("Unknown error", comment: "")
#endif
    }

    private func configuredAudioUnitFormat(for bus: AUAudioUnitBus?, fallback: AVAudioFormat) -> AVAudioFormat {
        let reference = bus?.format
        let interleaved = reference?.isInterleaved ?? fallback.isInterleaved
        let commonFormat = reference?.commonFormat == .pcmFormatFloat32 ? reference!.commonFormat : AVAudioCommonFormat.pcmFormatFloat32
        return AVAudioFormat(
            commonFormat: commonFormat,
            sampleRate: fallback.sampleRate,
            channels: fallback.channelCount,
            interleaved: interleaved
        ) ?? fallback
    }

    private func configureAudioUnit(_ unit: AVAudioUnit, format: AVAudioFormat) -> Bool {
        let au = unit.auAudioUnit

        if let effect = unit as? AVAudioUnitEffect {
            effect.bypass = false
        } else if let timeEffect = unit as? AVAudioUnitTimeEffect {
            timeEffect.bypass = false
        }
        au.shouldBypassEffect = false

        // Probe whether the AU accepts the requested channel layout, but leave
        // render resource allocation to MKAudio's realtime host so the unit is
        // only configured once for the live graph.
        if au.inputBusses.count > 0 {
            do {
                let inputFormat = configuredAudioUnitFormat(for: au.inputBusses[0], fallback: format)
                try au.inputBusses[0].setFormat(inputFormat)
            } catch {
                return false
            }
        }

        // Configure output bus format
        if au.outputBusses.count > 0 {
            do {
                let outputFormat = configuredAudioUnitFormat(for: au.outputBusses[0], fallback: format)
                try au.outputBusses[0].setFormat(outputFormat)
            } catch {
                return false
            }
        }

        au.maximumFramesToRender = max(au.maximumFramesToRender, 4096)

        return true
    }

    private func openPluginEditor(for plugin: TrackPlugin) {
        selectedPluginID = plugin.id

        guard plugin.source == .audioUnit else {
            pluginOperationMessage = NSLocalizedString("Plugin UI is unavailable", comment: "")
            return
        }

        guard let trackKey = self.trackKey(containingPluginID: plugin.id) else {
            pluginOperationMessage = NSLocalizedString("Plugin not found in any track", comment: "")
            return
        }

        let loadedKey = loadedAudioUnitKey(trackKey: trackKey, pluginID: plugin.id)
        guard let unit = loadedAudioUnits[loadedKey] else {
            pluginOperationMessage = NSLocalizedString("Plugin is not ready", comment: "")
            return
        }

        let targetPluginID = plugin.id
        let targetTrackKey = trackKey
        unit.auAudioUnit.requestViewController { viewController in
            DispatchQueue.main.async {
                guard let viewController else {
                    pluginOperationMessage = NSLocalizedString("Plugin UI is unavailable", comment: "")
                    return
                }

#if os(iOS)
                pluginEditorTitle = plugin.name
                pluginEditorController = viewController
                showingPluginEditor = true
#else
                PluginEditorWindowController.shared.show(
                    pluginKey: "\(targetTrackKey):\(targetPluginID)",
                    controller: viewController,
                    title: plugin.name
                ) {
                    if selectedPluginID == targetPluginID {
                        selectedPluginID = nil
                    }
                }
#endif
            }
        }
    }

    private func unloadAudioUnit(for plugin: TrackPlugin) {
        // Unload from all tracks
        if let trackKey = self.trackKey(containingPluginID: plugin.id) {
#if os(macOS)
            PluginEditorWindowController.shared.close(pluginKey: "\(trackKey):\(plugin.id)")
#endif
            let loadedKey = loadedAudioUnitKey(trackKey: trackKey, pluginID: plugin.id)
            loadedAudioUnits[loadedKey] = nil
        }
        // Also try legacy key
        loadedAudioUnits[plugin.id] = nil

        parameterStateByPlugin[plugin.id] = nil
        lastLoadErrorByPlugin[plugin.id] = nil
        if let chainKey = trackKey(containingPluginID: plugin.id) {
            applyLivePreviewForTrackKey(chainKey)
        }
        if selectedPluginID == plugin.id {
            selectedPluginID = nil
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

    private func channelCount(for trackKey: String, pluginDescription: AudioComponentDescription? = nil) -> UInt {
        _ = pluginDescription

        if trackKey == "input" {
            return 1  // Mono for input track
        }
        if trackKey == "remoteBus" || trackKey.hasPrefix("remoteSession:") {
            return 2  // Stereo for remote bus and sessions
        }
        return 2  // Default to stereo
    }

    private func pluginSampleRate(for trackKey: String) -> Double {
        let sampleRate = MKAudio.shared().pluginSampleRate(forTrackKey: trackKey)
        return sampleRate > 0 ? Double(sampleRate) : 48_000
    }

    private func loadedAudioUnitKey(trackKey: String, pluginID: String) -> String {
        return "\(trackKey):\(pluginID)"
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

    private func refreshParameters(for pluginID: String, trackKey: String? = nil) {
        let tk = trackKey ?? selectedTrackKey
        let loadedKey = loadedAudioUnitKey(trackKey: tk, pluginID: pluginID)
        guard let unit = loadedAudioUnits[loadedKey] else { return }
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
        let loadedKey = loadedAudioUnitKey(trackKey: selectedTrackKey, pluginID: pluginID)
        if let unit = loadedAudioUnits[loadedKey],
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

    // MARK: - Preset Management

    private func loadPluginPresets() {
        guard !pluginPresetsData.isEmpty,
              let data = pluginPresetsData.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: [PluginPreset]].self, from: data) else {
            pluginPresetsByIdentifier = [:]
            return
        }
        pluginPresetsByIdentifier = decoded
    }

    private func savePluginPresets() {
        guard let data = try? JSONEncoder().encode(pluginPresetsByIdentifier),
              let string = String(data: data, encoding: .utf8) else {
            return
        }
        pluginPresetsData = string
    }

    private func saveCurrentAsPreset(for plugin: TrackPlugin) {
        let name = presetNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        let preset = PluginPreset(
            id: UUID().uuidString,
            name: name,
            parameterValues: plugin.savedParameterValues,
            createdAt: Date()
        )

        var presets = pluginPresetsByIdentifier[plugin.identifier] ?? []
        presets.append(preset)
        pluginPresetsByIdentifier[plugin.identifier] = presets
        savePluginPresets()

        presetNameInput = ""
        pluginOperationMessage = String(format: NSLocalizedString("Preset '%@' saved", comment: ""), name)
    }

    private func loadPreset(_ preset: PluginPreset, for pluginID: String) {
        mutatePlugin(withID: pluginID) { plugin in
            plugin.savedParameterValues = preset.parameterValues
        }

        // Apply preset values to runtime parameters
        if let unit = loadedAudioUnits[loadedAudioUnitKey(trackKey: selectedTrackKey, pluginID: pluginID)] {
            let au = unit.auAudioUnit
            for (paramIDString, value) in preset.parameterValues {
                if let paramID = UInt64(paramIDString),
                   let param = au.parameterTree?.parameter(withAddress: AUParameterAddress(paramID)) {
                    param.value = value
                }
            }
        }

        // Update UI state
        if var parameters = parameterStateByPlugin[pluginID] {
            for i in parameters.indices {
                if let savedValue = preset.parameterValues[String(parameters[i].id)] {
                    parameters[i].value = savedValue
                }
            }
            parameterStateByPlugin[pluginID] = parameters
        }

        pluginOperationMessage = String(format: NSLocalizedString("Preset '%@' loaded", comment: ""), preset.name)
        rebuildProcessorStateMachine()
    }

    private func deletePreset(_ preset: PluginPreset, for identifier: String) {
        var presets = pluginPresetsByIdentifier[identifier] ?? []
        presets.removeAll { $0.id == preset.id }
        pluginPresetsByIdentifier[identifier] = presets
        savePluginPresets()

        pluginOperationMessage = String(format: NSLocalizedString("Preset '%@' deleted", comment: ""), preset.name)
    }

    private func refreshRemoteSessionOrder() {
        let sessions = MKAudio.shared().copyRemoteSessionOrder().map { $0.intValue }
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
        let componentTypes: [UInt32] = [
            kAudioUnitType_Effect,
            kAudioUnitType_MusicEffect
        ]
        var components: [AVAudioUnitComponent] = []
        for type in componentTypes {
            let desc = AudioComponentDescription(
                componentType: type,
                componentSubType: 0,
                componentManufacturer: 0,
                componentFlags: 0,
                componentFlagsMask: 0
            )
            components.append(contentsOf: manager.components(matching: desc))
        }
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
final class PluginEditorWindowController: NSObject {
    static let shared = PluginEditorWindowController()

    private var windows: [String: NSWindow] = [:]
    private var closeHandlers: [String: () -> Void] = [:]

    private override init() {
        super.init()
    }

    func show(pluginKey: String, controller: NSViewController, title: String, onClose: @escaping () -> Void) {
        let targetSize = normalizedSize(from: controller.preferredContentSize)

        if let window = windows[pluginKey] {
            window.title = title
            window.contentViewController = controller
            resize(window: window, to: targetSize)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            closeHandlers[pluginKey] = onClose
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
            self,
            selector: #selector(handlePluginEditorWindowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: window
        )

        windows[pluginKey] = window
        closeHandlers[pluginKey] = onClose
    }

    func close(pluginKey: String) {
        if let window = windows.removeValue(forKey: pluginKey) {
            closeHandlers.removeValue(forKey: pluginKey)
            window.close()
        }
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

    @objc private func handlePluginEditorWindowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow,
              let pluginKey = windows.first(where: { $0.value == closing })?.key else { return }
        windows.removeValue(forKey: pluginKey)
        let handler = closeHandlers.removeValue(forKey: pluginKey)
        handler?()
    }
}
#endif
