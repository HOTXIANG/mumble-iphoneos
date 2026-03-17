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

private struct PluginEditorParameterSnapshot: Identifiable, Hashable {
    let id: UInt64
    let name: String
    let minValue: Float
    let maxValue: Float
    var value: Float
}

private struct PluginEditorSnapshot {
    let name: String
    let subtitle: String
    let isLoading: Bool
    let isLoaded: Bool
    let errorDescription: String?
    let parameters: [PluginEditorParameterSnapshot]
}

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
        window.setContentSize(NSSize(width: 960, height: 640))
        window.minSize = NSSize(width: 780, height: 520)
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

// MARK: - Shared Types

enum PluginSource: String, Codable {
    case audioUnit
    case filesystem
}

struct TrackPlugin: Identifiable, Codable, Hashable {
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
        bypassed: Bool = false,
        stageGain: Float = 1.0,
        autoLoad: Bool = true,
        savedParameterValues: [String: Float] = [:]
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

    private struct DiscoveredPlugin: Identifiable, Hashable {
        let id: String
        let name: String
        let subtitle: String
        let source: PluginSource
        let categorySeedText: String
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

    @AppStorage("AudioPluginInputTrackGain") private var pluginInputTrackGain: Double = 1.0
    @AppStorage("AudioPluginRemoteBusGain") private var pluginRemoteBusGain: Double = 1.0
    @AppStorage("AudioPluginCustomScanPaths") private var pluginCustomScanPaths: String = ""
    @AppStorage("AudioPluginTrackChainsV1") private var pluginTrackChainsData: String = ""
    @AppStorage("AudioPluginPresetsV1") private var pluginPresetsData: String = ""
    @AppStorage("AudioPluginHostBufferFrames") private var pluginHostBufferFrames: Int = 256
    @AppStorage("AudioPluginCategoryOverridesV1") private var pluginCategoryOverridesData: String = ""
    @AppStorage("AudioPluginCustomCategoriesV1") private var pluginCustomCategoriesData: String = ""

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
    @State private var loadedVST3Hosts: [String: MKVST3PluginHost] = [:]  // Key: "\(trackKey):\(pluginID)"
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
    @State private var pluginCategoryOverrides: [String: String] = [:]
    @State private var customPluginCategories: [String] = []
    @State private var customCategoryInput: String = ""

    var body: some View {
        VStack(spacing: 0) {
            mixerTransportBar
            Divider()
            GeometryReader { geometry in
                let isWideLayout = geometry.size.width >= 900
                let isCompact = geometry.size.width < 500
                Group {
                    if isWideLayout {
                        HStack(spacing: 0) {
                            mixerTrackSidebar
                                .frame(width: min(340, max(260, geometry.size.width * 0.33)))
                            Divider()
                            mixerWorkspace(compact: false)
                        }
                    } else if isCompact {
                        // iPhone 竖屏：紧凑水平轨道选择器 + 全屏工作区
                        VStack(spacing: 0) {
                            compactTrackPicker
                            Divider()
                            mixerWorkspace(compact: true)
                        }
                    } else {
                        VStack(spacing: 0) {
                            mixerTrackSidebar
                                .frame(height: 300)
                            Divider()
                            mixerWorkspace(compact: false)
                        }
                    }
                }
            }
        }
        .onAppear {
            loadPluginChainState()
            loadPluginCategoryConfiguration()
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
        .onDisappear {
            // Mixer 关闭时，抓取所有插件的当前参数值并持久化
            snapshotAllPluginParameters()
        }
        .onChange(of: selectedTrack) {
            loadSelectedTrackState()
            normalizeSelectedPluginSelection()
            rebuildProcessorStateMachine()
        }
        .onChange(of: pluginInputTrackGain) {
            applyLivePreviewForTrackKey("input")
            PreferencesModel.shared.notifySettingsChanged()
        }
        .onChange(of: pluginRemoteBusGain) {
            applyLivePreviewForTrackKey("remoteBus")
            PreferencesModel.shared.notifySettingsChanged()
        }
        .onChange(of: pluginRemoteTrackGain) {
            applyRemoteTrackPreview()
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
                // 插件编辑器关闭时，抓取参数快照（捕获原生 UI 的修改）
                snapshotAllPluginParameters()
                pluginEditorController = nil
                pluginEditorTitle = ""
                selectedPluginID = nil
            }
        }
#endif
    }

    private var mixerTransportBar: some View {
        ViewThatFits(in: .horizontal) {
            // 宽屏：完整显示所有按钮
            mixerTransportBarContent(compact: false)
            // 窄屏：收纳到菜单
            mixerTransportBarContent(compact: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func mixerTransportBarContent(compact: Bool) -> some View {
        HStack(spacing: compact ? 8 : 10) {
            Text(NSLocalizedString("Audio Plugin Mixer", comment: ""))
                .font(.headline)
                .lineLimit(1)
            if !pluginOperationMessage.isEmpty {
                Text(pluginOperationMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if compact {
                // 紧凑模式：Buffer + 更多操作收入菜单
                Menu {
                    Menu(NSLocalizedString("Buffer Size", comment: "")) {
                        ForEach([64, 128, 256, 512, 1024, 2048], id: \.self) { frames in
                            Button(frames == pluginHostBufferFrames ? "✓ \(frames)" : "\(frames)") {
                                pluginHostBufferFrames = frames
                            }
                        }
                    }
                    Button {
                        refreshRemoteSessionOrder()
                    } label: {
                        Label(NSLocalizedString("Refresh Remote Tracks", comment: ""), systemImage: "arrow.clockwise")
                    }
                    Button {
                        showingPluginBrowser = true
                    } label: {
                        Label(NSLocalizedString("Plugin Browser", comment: ""), systemImage: "square.grid.2x2")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                }
            } else {
                Text(NSLocalizedString("Buffer", comment: ""))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Menu {
                    ForEach([64, 128, 256, 512, 1024, 2048], id: \.self) { frames in
                        Button("\(frames)") {
                            pluginHostBufferFrames = frames
                        }
                    }
                } label: {
                    Text("\(pluginHostBufferFrames)")
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.primary)
                        .frame(minWidth: 52)
                }
                .menuStyle(.borderlessButton)
                Button(NSLocalizedString("Refresh Remote Tracks", comment: "")) {
                    refreshRemoteSessionOrder()
                }
                .buttonStyle(.bordered)
                Button(NSLocalizedString("Plugin Browser", comment: "")) {
                    showingPluginBrowser = true
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Compact Track Picker (iPhone 竖屏)

    private var compactTrackPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(allTracks, id: \.self) { track in
                    let isSelected = selectedTrack == track
                    Button {
                        selectedTrack = track
                    } label: {
                        HStack(spacing: 6) {
                            Text(track.shortLabel)
                                .font(.caption2.monospaced().weight(.bold))
                                .foregroundColor(isSelected ? .white : .secondary)
                                .frame(width: 28, height: 18)
                                .background(
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .fill(isSelected ? Color.accentColor : Color.secondary.opacity(0.15))
                                )
                            Text(track.title)
                                .font(.caption.weight(isSelected ? .semibold : .regular))
                                .foregroundColor(isSelected ? .primary : .secondary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.regularMaterial)
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

    private func mixerWorkspace(compact: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                pluginChainPanel(compact: compact)
            }
            .padding(compact ? 10 : 16)
        }
        .background(.thinMaterial)
    }

    private func pluginChainPanel(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 10) {
            Text(NSLocalizedString("Plugin Chain", comment: ""))
                .font(.headline)
            if !compact {
                Text(NSLocalizedString("Choose a plugin for each insert, enable it when needed, open its editor, and set its mix.", comment: ""))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            ForEach(0..<maxInsertSlots, id: \.self) { slotIndex in
                let plugin = pluginAtSlot(slotIndex)
                let isSelected = selectedPluginID == plugin?.id

                if compact {
                    compactPluginSlotRow(slotIndex: slotIndex, plugin: plugin, isSelected: isSelected)
                } else {
                    widePluginSlotRow(slotIndex: slotIndex, plugin: plugin, isSelected: isSelected)
                }
            }
        }
        .padding(compact ? 10 : 14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
        )
    }

    // MARK: - Wide Plugin Slot (macOS / iPad 横屏)

    @ViewBuilder
    private func widePluginSlotRow(slotIndex: Int, plugin: TrackPlugin?, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Text("\(slotIndex + 1)")
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 24)

            pluginSelectMenu(slotIndex: slotIndex, plugin: plugin, minWidth: 240)

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
        .frame(minHeight: 58)
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

    // MARK: - Compact Plugin Slot (iPhone 竖屏)

    @ViewBuilder
    private func compactPluginSlotRow(slotIndex: Int, plugin: TrackPlugin?, isSelected: Bool) -> some View {
        VStack(spacing: 6) {
            // 第一行：槽位编号 + 插件选择（限宽）+ 打开编辑器按钮
            HStack(spacing: 8) {
                Text("\(slotIndex + 1)")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
                    .frame(width: 20)

                pluginSelectMenu(slotIndex: slotIndex, plugin: plugin, minWidth: 0, compact: true)
                    .frame(maxWidth: 200)

                if plugin != nil {
                    // 打开插件编辑器的按钮
                    Button {
                        if let plugin = pluginAtSlot(slotIndex) {
                            selectedPluginID = plugin.id
                            openPluginEditor(for: plugin)
                        }
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.body)
                            .foregroundColor(.accentColor)
                            .frame(maxWidth: .infinity, minHeight: 34)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    Spacer(minLength: 0)
                }
            }

            // 第二行：控制按钮和 Mix 滑块（仅在有插件时显示）
            if let plugin {
                HStack(spacing: 8) {
                    Button(plugin.bypassed ? NSLocalizedString("Off", comment: "") : NSLocalizedString("On", comment: "")) {
                        toggleBypass(at: slotIndex)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        movePluginUp(at: slotIndex)
                    } label: {
                        Image(systemName: "chevron.up")
                            .font(.caption2)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(slotIndex == 0)

                    Button {
                        movePluginDown(at: slotIndex)
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(slotIndex >= selectedTrackChain.count - 1)

                    Slider(
                        value: Binding(
                            get: { Double(plugin.stageGain * 100.0) },
                            set: { updateMixLevel(at: slotIndex, newValue: Float($0 / 100.0)) }
                        ),
                        in: 0...100
                    )

                    Text("\(Int((plugin.stageGain * 100.0).rounded()))%")
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(.secondary)
                        .frame(width: 34, alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08))
        )
    }

    // MARK: - Plugin Select Menu (共用)

    @ViewBuilder
    private func pluginSelectMenu(slotIndex: Int, plugin: TrackPlugin?, minWidth: CGFloat, compact: Bool = false) -> some View {
        Menu {
            if installedAudioUnits.isEmpty && scannedFilesystemPlugins.isEmpty {
                Text(NSLocalizedString("No plugins available", comment: ""))
            }
            if !installedAudioUnits.isEmpty {
                Menu(NSLocalizedString("Audio Units", comment: "")) {
                    ForEach(groupedPluginsByCategory(installedAudioUnits), id: \.category) { group in
                        Menu(group.category) {
                            ForEach(group.plugins, id: \.id) { discovered in
                                Button(discovered.name) {
                                    Task {
                                        await assignPluginToSlot(discovered, slotIndex: slotIndex)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            if !scannedFilesystemPlugins.isEmpty {
                Menu(NSLocalizedString("VST3", comment: "")) {
                    ForEach(groupedPluginsByCategory(scannedFilesystemPlugins), id: \.category) { group in
                        Menu(group.category) {
                            ForEach(group.plugins, id: \.id) { discovered in
                                Button(discovered.name) {
                                    Task {
                                        await assignPluginToSlot(discovered, slotIndex: slotIndex)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            if plugin != nil {
                Divider()
                Button(NSLocalizedString("Remove Plugin", comment: ""), role: .destructive) {
                    clearPluginSlot(slotIndex: slotIndex)
                }
            }
        } label: {
            HStack(spacing: compact ? 4 : 8) {
                Text(plugin?.name ?? NSLocalizedString("Select Plugin", comment: ""))
                    .font(compact ? .caption : .body)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, compact ? 8 : 10)
            .padding(.vertical, compact ? 6 : 8)
            .frame(minWidth: minWidth > 0 ? minWidth : nil, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.secondary.opacity(0.12))
            )
        }
        .menuStyle(.borderlessButton)
    }

    private var pluginBrowserPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(NSLocalizedString("Plugin Browser", comment: ""))
                .font(.headline)

            Text(String(format: NSLocalizedString("Selected Track: %@", comment: ""), selectedTrack.title))
                .font(.caption)
                .foregroundColor(.secondary)

            pluginCategoryManagementPanel

            if installedAudioUnits.isEmpty {
                Text(NSLocalizedString("No installed Audio Units found", comment: ""))
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(NSLocalizedString("Audio Units", comment: ""))
                        .font(.subheadline.weight(.semibold))
                    ForEach(groupedPluginsByCategory(installedAudioUnits), id: \.category) { group in
                        pluginBrowserCategorySection(group)
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
                Text(NSLocalizedString("No VST3 bundles found in scan paths", comment: ""))
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(NSLocalizedString("VST3", comment: ""))
                        .font(.subheadline.weight(.semibold))
                    ForEach(groupedPluginsByCategory(scannedFilesystemPlugins), id: \.category) { group in
                        pluginBrowserCategorySection(group)
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
        .frame(minWidth: 780, minHeight: 620)
#endif
    }

    private var pluginCategoryManagementPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(NSLocalizedString("Categories", comment: ""))
                .font(.subheadline.weight(.semibold))

            HStack(spacing: 8) {
                TextField(NSLocalizedString("Add category", comment: ""), text: $customCategoryInput)
                Button(NSLocalizedString("Add", comment: "")) {
                    addCustomPluginCategory()
                }
                .disabled(customCategoryInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if availablePluginCategories.isEmpty {
                Text(NSLocalizedString("No categories configured", comment: ""))
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(availablePluginCategories, id: \.self) { category in
                        HStack(spacing: 6) {
                            Text(category)
                                .font(.caption)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            if isCustomPluginCategory(category) {
                                Button {
                                    removeCustomPluginCategory(category)
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.caption2)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.secondary.opacity(0.1))
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func pluginBrowserCategorySection(_ group: PluginCategoryGroup) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(group.category)
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)

            ForEach(group.plugins, id: \.id) { plugin in
                pluginBrowserRow(plugin)
            }
        }
        .padding(.top, 4)
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
            Menu {
                ForEach(availablePluginCategories, id: \.self) { category in
                    Button(category) {
                        setCategory(category, for: plugin)
                    }
                }
                Divider()
                Button(NSLocalizedString("Use Suggested Category", comment: "")) {
                    resetCategory(for: plugin)
                }
            } label: {
                Text(categoryForPlugin(plugin))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .frame(minWidth: 88, alignment: .trailing)
            }
            .menuStyle(.borderlessButton)
            Text(plugin.source == .audioUnit ? NSLocalizedString("AU", comment: "") : NSLocalizedString("VST", comment: ""))
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

    private struct PluginCategoryGroup: Identifiable {
        let category: String
        let plugins: [DiscoveredPlugin]

        var id: String { category }
    }

    private var defaultPluginCategories: [String] {
        [
            NSLocalizedString("Dynamics", comment: ""),
            NSLocalizedString("EQ", comment: ""),
            NSLocalizedString("Space", comment: ""),
            NSLocalizedString("Distortion", comment: "")
        ]
    }

    private var otherPluginCategory: String {
        NSLocalizedString("Other", comment: "")
    }

    private var availablePluginCategories: [String] {
        let merged = defaultPluginCategories + customPluginCategories + Array(pluginCategoryOverrides.values)
        var ordered: [String] = []
        for category in merged {
            let trimmed = category.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !ordered.contains(trimmed) else { continue }
            ordered.append(trimmed)
        }
        if !ordered.contains(otherPluginCategory) {
            ordered.append(otherPluginCategory)
        }
        return ordered
    }

    private func isCustomPluginCategory(_ category: String) -> Bool {
        customPluginCategories.contains(category)
    }

    private func groupedPluginsByCategory(_ plugins: [DiscoveredPlugin]) -> [PluginCategoryGroup] {
        let grouped = Dictionary(grouping: plugins, by: categoryForPlugin)
        let orderedCategories = availablePluginCategories.filter { grouped[$0] != nil }
        let extraCategories = grouped.keys
            .filter { !orderedCategories.contains($0) }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

        return (orderedCategories + extraCategories).map { category in
            PluginCategoryGroup(
                category: category,
                plugins: (grouped[category] ?? [])
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            )
        }
    }

    private func loadPluginCategoryConfiguration() {
        if let data = pluginCategoryOverridesData.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            pluginCategoryOverrides = decoded
        } else {
            pluginCategoryOverrides = [:]
        }

        if let data = pluginCustomCategoriesData.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            customPluginCategories = decoded
        } else {
            customPluginCategories = []
        }
    }

    private func savePluginCategoryConfiguration() {
        if let data = try? JSONEncoder().encode(pluginCategoryOverrides),
           let encoded = String(data: data, encoding: .utf8) {
            pluginCategoryOverridesData = encoded
        }

        if let data = try? JSONEncoder().encode(customPluginCategories),
           let encoded = String(data: data, encoding: .utf8) {
            pluginCustomCategoriesData = encoded
        }
    }

    private func addCustomPluginCategory() {
        let candidate = customCategoryInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return }
        if !customPluginCategories.contains(candidate) && !defaultPluginCategories.contains(candidate) {
            customPluginCategories.append(candidate)
            customPluginCategories.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            savePluginCategoryConfiguration()
        }
        customCategoryInput = ""
    }

    private func removeCustomPluginCategory(_ category: String) {
        customPluginCategories.removeAll { $0 == category }
        pluginCategoryOverrides = pluginCategoryOverrides.filter { $0.value != category }
        savePluginCategoryConfiguration()
    }

    private func setCategory(_ category: String, for plugin: DiscoveredPlugin) {
        pluginCategoryOverrides[plugin.id] = category
        savePluginCategoryConfiguration()
    }

    private func resetCategory(for plugin: DiscoveredPlugin) {
        pluginCategoryOverrides.removeValue(forKey: plugin.id)
        savePluginCategoryConfiguration()
    }

    private func categoryForPlugin(_ plugin: DiscoveredPlugin) -> String {
        if let override = pluginCategoryOverrides[plugin.id], !override.isEmpty {
            return override
        }
        return inferredCategory(for: plugin)
    }

    private func inferredCategory(for plugin: DiscoveredPlugin) -> String {
        let lowered = plugin.categorySeedText.lowercased()

        let dynamicsKeywords = ["compress", "comp", "limiter", "gate", "expander", "de-esser", "deesser", "transient", "dynamics"]
        if dynamicsKeywords.contains(where: { lowered.contains($0) }) {
            return defaultPluginCategories[0]
        }

        let eqKeywords = ["eq", "equalizer", "filter", "shelf", "notch", "bandpass", "highpass", "lowpass", "tone"]
        if eqKeywords.contains(where: { lowered.contains($0) }) {
            return defaultPluginCategories[1]
        }

        let spaceKeywords = ["reverb", "delay", "echo", "room", "hall", "plate", "chamber", "ambience", "space", "stereo", "widener"]
        if spaceKeywords.contains(where: { lowered.contains($0) }) {
            return defaultPluginCategories[2]
        }

        let distortionKeywords = ["distortion", "drive", "satur", "fuzz", "clip", "crusher", "amp", "cab", "overdrive"]
        if distortionKeywords.contains(where: { lowered.contains($0) }) {
            return defaultPluginCategories[3]
        }

        return otherPluginCategory
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

    private func pluginLoaded(for pluginID: String) -> Bool {
        let loadedKey = loadedAudioUnitKey(trackKey: selectedTrackKey, pluginID: pluginID)
        return loadedAudioUnits[loadedKey] != nil || loadedVST3Hosts[loadedKey] != nil
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
        if let existing, pluginLoaded(for: existing.id) {
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
        if pluginLoaded(for: existing.id) {
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
                    return loadedAudioUnits[loadedKey] == nil && loadedVST3Hosts[loadedKey] == nil
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
        let chain = pluginChainByTrack[key] ?? []
        let hasActivePlugins = chain.contains { !$0.bypassed }

        if key == "input" {
            let gain = Float(pluginInputTrackGain)
            let enabled = hasActivePlugins || abs(gain - 1.0) > 0.0001
            MKAudio.shared().setInputTrackPreviewGain(gain, enabled: enabled)
            return
        }
        if key == "remoteBus" {
            let gain = Float(pluginRemoteBusGain)
            let enabled = hasActivePlugins || abs(gain - 1.0) > 0.0001
            MKAudio.shared().setRemoteBusPreviewGain(gain, enabled: enabled)
            return
        }
        if let session = parseRemoteSessionID(from: key) {
            let gain = Float(pluginRemoteTrackGain)
            let enabled = hasActivePlugins || abs(gain - 1.0) > 0.0001
            remoteTrackSettings[session] = (enabled: enabled, gain: Double(gain))
            MKAudio.shared().setRemoteTrackPreviewGain(gain, enabled: enabled, forSession: UInt(session))
        }
    }

    private enum LoadedPluginProcessor {
        case audioUnit(AVAudioUnit)
        case vst3(MKVST3PluginHost)
    }

    private func loadedProcessor(for trackKey: String, pluginID: String) -> LoadedPluginProcessor? {
        let loadedKey = loadedAudioUnitKey(trackKey: trackKey, pluginID: pluginID)
        if let audioUnit = loadedAudioUnits[loadedKey] {
            return .audioUnit(audioUnit)
        }
        if let vst3Host = loadedVST3Hosts[loadedKey] {
            return .vst3(vst3Host)
        }
        return nil
    }

    private func activeProcessorChain(for key: String) -> [NSDictionary] {
        let chain = pluginChainByTrack[key] ?? []
        return chain
            .filter { !$0.bypassed }
            .compactMap { plugin in
                guard let processor = loadedProcessor(for: key, pluginID: plugin.id) else {
                    return nil
                }
                let mix = NSNumber(value: min(max(plugin.stageGain, 0.0), 1.0))
                switch processor {
                case .audioUnit(let audioUnit):
                    return [
                        "audioUnit": audioUnit,
                        "mix": mix
                    ] as NSDictionary
                case .vst3(let vst3Host):
                    return [
                        "vst3Host": vst3Host,
                        "mix": mix
                    ] as NSDictionary
                }
            }
    }

    private func syncPluginHostBufferFrames() {
        MKAudio.shared().setPluginHostBufferFrames(UInt(max(pluginHostBufferFrames, 64)))
    }

    private func syncAudioUnitDSPChainForTrackKey(_ key: String) {
        if key == "input" {
            MKAudio.shared().setInputTrackAudioUnitChain(activeProcessorChain(for: key))
            return
        }
        if key == "remoteBus" {
            MKAudio.shared().setRemoteBusAudioUnitChain(activeProcessorChain(for: key))
            return
        }
        if let session = parseRemoteSessionID(from: key) {
            MKAudio.shared().setRemoteTrackAudioUnitChain(activeProcessorChain(for: key), forSession: UInt(session))
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
            } else if loadedAudioUnits[loadedKey] != nil || loadedVST3Hosts[loadedKey] != nil {
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
        if loadedAudioUnits[loadedKey] != nil || loadedVST3Hosts[loadedKey] != nil {
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
            if let unit = loadedAudioUnits[loadedKey] {
                rebuildParameterState(pluginID: plugin.id, unit: unit)
            } else {
                parameterStateByPlugin[plugin.id] = []
            }
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
        guard plugin.identifier.hasPrefix("fs:") else {
            let message = NSLocalizedString("Invalid filesystem plugin identifier", comment: "")
            lastLoadErrorByPlugin[plugin.id] = message
            pluginOperationMessage = String(format: NSLocalizedString("Failed to load %@: %@", comment: ""), plugin.name, message)
            rebuildProcessorStateMachine()
            return false
        }

        loadingPluginIDs.insert(plugin.id)
        lastLoadErrorByPlugin[plugin.id] = nil
        rebuildProcessorStateMachine()

        let bundlePath = String(plugin.identifier.dropFirst(3))

        let host: MKVST3PluginHost
        do {
            host = try MKVST3PluginHost(bundlePath: bundlePath, displayName: plugin.name)
        } catch {
            loadingPluginIDs.remove(plugin.id)
            parameterStateByPlugin[plugin.id] = nil
            let message = error.localizedDescription.isEmpty
                ? NSLocalizedString("Failed to create VST3 host", comment: "")
                : error.localizedDescription
            lastLoadErrorByPlugin[plugin.id] = message
            pluginOperationMessage = String(format: NSLocalizedString("Failed to load %@: %@", comment: ""), plugin.name, message)
            NSLog("MKVST3-Swift: init FAILED for '\(plugin.name)': \(message)")
            rebuildProcessorStateMachine()
            return false
        }

        let effectiveSampleRate = sampleRate > 0 ? sampleRate : 48_000
        let effectiveFrames = max(pluginHostBufferFrames, 64)
        do {
            try host.configure(
                withInputChannels: UInt(requiredChannels),
                outputChannels: UInt(requiredChannels),
                sampleRate: effectiveSampleRate,
                maximumFramesToRender: UInt(effectiveFrames)
            )
        } catch {
            loadingPluginIDs.remove(plugin.id)
            parameterStateByPlugin[plugin.id] = nil
            let message = error.localizedDescription.isEmpty
                ? NSLocalizedString("Failed to configure VST3 plug-in", comment: "")
                : error.localizedDescription
            lastLoadErrorByPlugin[plugin.id] = message
            pluginOperationMessage = String(format: NSLocalizedString("Failed to load %@: %@", comment: ""), plugin.name, message)
            NSLog("MKVST3-Swift: configure FAILED for '\(plugin.name)': \(message)")
            rebuildProcessorStateMachine()
            return false
        }

        loadingPluginIDs.remove(plugin.id)
        loadedVST3Hosts[loadedKey] = host
        NSLog("MKVST3-Swift: fully loaded '\(plugin.name)' key=\(loadedKey)")
        rebuildParameterState(pluginID: plugin.id, vst3Host: host)
        lastLoadErrorByPlugin[plugin.id] = nil
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

    private func pluginEditorSnapshot(trackKey: String, pluginID: String) -> PluginEditorSnapshot {
        let plugin = findPlugin(withID: pluginID, trackKey: trackKey)
        let parameters = (parameterStateByPlugin[pluginID] ?? []).map {
            PluginEditorParameterSnapshot(
                id: $0.id,
                name: $0.name,
                minValue: $0.minValue,
                maxValue: $0.maxValue,
                value: parameterStateValue(pluginID: pluginID, parameterID: $0.id, fallback: $0.value)
            )
        }

        return PluginEditorSnapshot(
            name: plugin?.name ?? NSLocalizedString("Plugin", comment: ""),
            subtitle: plugin?.subtitle ?? "",
            isLoading: loadingPluginIDs.contains(pluginID),
            isLoaded: loadedProcessor(for: trackKey, pluginID: pluginID) != nil,
            errorDescription: lastLoadErrorByPlugin[pluginID],
            parameters: parameters
        )
    }

    private func openPluginEditor(for plugin: TrackPlugin) {
        selectedPluginID = plugin.id

        guard let trackKey = self.trackKey(containingPluginID: plugin.id) else {
            pluginOperationMessage = NSLocalizedString("Plugin not found in any track", comment: "")
            return
        }

        switch loadedProcessor(for: trackKey, pluginID: plugin.id) {
        case .audioUnit(let unit):
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
                    let pluginKey = "\(targetTrackKey):\(targetPluginID)"
                    PluginEditorWindowController.shared.show(
                        pluginKey: pluginKey,
                        rootView: AnyView(
                            PluginEditorWindowContentView(
                                controller: viewController,
                                snapshotProvider: { pluginEditorSnapshot(trackKey: targetTrackKey, pluginID: targetPluginID) },
                                refreshAction: { refreshParameters(for: targetPluginID, trackKey: targetTrackKey) },
                                parameterChangeAction: { parameterID, value in
                                    setParameterValue(pluginID: targetPluginID, trackKey: targetTrackKey, parameterID: parameterID, newValue: value)
                                }
                            )
                        ),
                        observedController: viewController,
                        preferredContentSize: viewController.preferredContentSize,
                        title: plugin.name
                    ) {
                        snapshotAllPluginParameters()
                        if selectedPluginID == targetPluginID {
                            selectedPluginID = nil
                        }
                    }
#endif
                }
            }
        case .vst3(let vst3Host):
#if os(iOS)
            pluginOperationMessage = NSLocalizedString("Plugin UI is unavailable on iOS", comment: "")
#else
            let pluginKey = "\(trackKey):\(plugin.id)"
            // Try native VST3 editor view first
            let nativeVC: NSViewController? = try? vst3Host.requestViewController()
            // Use plugin's preferred size, or fallback to default
            // Add toolbar height (~49pt) to the plugin's content size
            let toolbarHeight: CGFloat = 49.0
            let pluginSize = nativeVC?.preferredContentSize ?? NSSize(width: 600, height: 400)
            let editorSize = NSSize(width: max(500, pluginSize.width), height: pluginSize.height + toolbarHeight)
            PluginEditorWindowController.shared.show(
                pluginKey: pluginKey,
                rootView: AnyView(
                    PluginEditorWindowContentView(
                        controller: nativeVC,
                        snapshotProvider: { pluginEditorSnapshot(trackKey: trackKey, pluginID: plugin.id) },
                        refreshAction: { refreshParameters(for: plugin.id, trackKey: trackKey) },
                        parameterChangeAction: { parameterID, value in
                            setParameterValue(pluginID: plugin.id, trackKey: trackKey, parameterID: parameterID, newValue: value)
                        }
                    )
                ),
                observedController: nativeVC,  // Enable size observer for dynamic resize
                preferredContentSize: editorSize,
                title: plugin.name
            ) {
                snapshotAllPluginParameters()
                if selectedPluginID == plugin.id {
                    selectedPluginID = nil
                }
            }
#endif
        case .none:
            pluginOperationMessage = NSLocalizedString("Plugin is not ready", comment: "")
            return
        }
    }

    private func unloadAudioUnit(for plugin: TrackPlugin) {
        if let trackKey = self.trackKey(containingPluginID: plugin.id) {
#if os(macOS)
            PluginEditorWindowController.shared.close(pluginKey: "\(trackKey):\(plugin.id)")
#endif
            let loadedKey = loadedAudioUnitKey(trackKey: trackKey, pluginID: plugin.id)
            loadedAudioUnits[loadedKey] = nil
            loadedVST3Hosts[loadedKey] = nil
        }

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

    private func rebuildParameterState(pluginID: String, vst3Host: MKVST3PluginHost) {
        var state = vst3Host.copyParameterSnapshots()
            .prefix(64)
            .compactMap { snapshot -> RuntimeParameter? in
                guard let parameterID = snapshot["id"] as? NSNumber,
                      let name = snapshot["name"] as? String,
                      let minValue = snapshot["minValue"] as? NSNumber,
                      let maxValue = snapshot["maxValue"] as? NSNumber,
                      let value = snapshot["value"] as? NSNumber else {
                    return nil
                }

                return RuntimeParameter(
                    id: parameterID.uint64Value,
                    name: name,
                    minValue: minValue.floatValue,
                    maxValue: maxValue.floatValue,
                    value: value.floatValue
                )
            }
        applySavedParameters(pluginID: pluginID, state: &state, vst3Host: vst3Host)
        parameterStateByPlugin[pluginID] = state
    }

    private func refreshParameters(for pluginID: String, trackKey: String? = nil) {
        let tk = trackKey ?? selectedTrackKey
        let loadedKey = loadedAudioUnitKey(trackKey: tk, pluginID: pluginID)
        DispatchQueue.main.async {
            if let unit = loadedAudioUnits[loadedKey] {
                rebuildParameterState(pluginID: pluginID, unit: unit)
            } else if let vst3Host = loadedVST3Hosts[loadedKey] {
                rebuildParameterState(pluginID: pluginID, vst3Host: vst3Host)
            }
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

    private func applySavedParameters(pluginID: String, state: inout [RuntimeParameter], vst3Host: MKVST3PluginHost) {
        guard let plugin = findPlugin(withID: pluginID), !plugin.savedParameterValues.isEmpty else {
            // No saved values - this is normal for newly added plugins, don't log
            return
        }
        var restoredCount = 0
        for index in state.indices {
            let key = String(state[index].id)
            guard let saved = plugin.savedParameterValues[key] else { continue }
            let normalized = min(max(saved, state[index].minValue), state[index].maxValue)
            state[index].value = normalized
            _ = vst3Host.setParameter(withID: state[index].id, normalizedValue: normalized)
            restoredCount += 1
        }
        if restoredCount > 0 {
            NSLog("MKVST3-Swift: restored \(restoredCount) saved params for \(plugin.name)")
        }
    }

    private func parameterStateValue(pluginID: String, parameterID: UInt64, fallback: Float) -> Float {
        parameterStateByPlugin[pluginID]?.first(where: { $0.id == parameterID })?.value ?? fallback
    }

    private func setParameterValue(pluginID: String, parameterID: UInt64, newValue: Float) {
        setParameterValue(pluginID: pluginID, trackKey: selectedTrackKey, parameterID: parameterID, newValue: newValue)
    }

    private func setParameterValue(pluginID: String, trackKey: String, parameterID: UInt64, newValue: Float) {
        let loadedKey = loadedAudioUnitKey(trackKey: trackKey, pluginID: pluginID)
        if let unit = loadedAudioUnits[loadedKey],
           let parameter = unit.auAudioUnit.parameterTree?.allParameters.first(where: { $0.address == parameterID }) {
            parameter.value = newValue
        } else if let vst3Host = loadedVST3Hosts[loadedKey] {
            _ = vst3Host.setParameter(withID: parameterID, normalizedValue: newValue)
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

    /// 从所有已加载的 AU/VST3 实例中抓取当前参数值，写入 savedParameterValues 并持久化。
    /// 用于捕获通过原生插件 UI 修改的参数（这些参数不经过 setParameterValue 回调）。
    private func snapshotAllPluginParameters() {
        var didChange = false
        for (trackKey, chain) in pluginChainByTrack {
            for plugin in chain {
                let loadedKey = loadedAudioUnitKey(trackKey: trackKey, pluginID: plugin.id)
                var captured: [String: Float] = [:]

                if let unit = loadedAudioUnits[loadedKey] {
                    for param in unit.auAudioUnit.parameterTree?.allParameters ?? [] {
                        captured[String(param.address)] = param.value
                    }
                } else if let vst3Host = loadedVST3Hosts[loadedKey] {
                    for snapshot in vst3Host.copyParameterSnapshots() {
                        guard let parameterID = snapshot["id"] as? NSNumber,
                              let value = snapshot["value"] as? NSNumber else { continue }
                        captured[String(parameterID.uint64Value)] = value.floatValue
                    }
                }

                if !captured.isEmpty && captured != plugin.savedParameterValues {
                    if var mutableChain = pluginChainByTrack[trackKey],
                       let idx = mutableChain.firstIndex(where: { $0.id == plugin.id }) {
                        mutableChain[idx].savedParameterValues = captured
                        pluginChainByTrack[trackKey] = mutableChain
                        didChange = true
                    }
                }
            }
        }
        if didChange {
            savePluginChainState()
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

    private func findPlugin(withID pluginID: String, trackKey: String) -> TrackPlugin? {
        pluginChainByTrack[trackKey]?.first(where: { $0.id == pluginID })
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
        let loadedKey = loadedAudioUnitKey(trackKey: selectedTrackKey, pluginID: pluginID)
        if let unit = loadedAudioUnits[loadedKey] {
            let au = unit.auAudioUnit
            for (paramIDString, value) in preset.parameterValues {
                if let paramID = UInt64(paramIDString),
                   let param = au.parameterTree?.parameter(withAddress: AUParameterAddress(paramID)) {
                    param.value = value
                }
            }
        } else if let vst3Host = loadedVST3Hosts[loadedKey] {
            for (paramIDString, value) in preset.parameterValues {
                if let paramID = UInt64(paramIDString) {
                    _ = vst3Host.setParameter(withID: paramID, normalizedValue: value)
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
        let trackKey = "remoteSession:\(session)"
        let hasActivePlugins = (pluginChainByTrack[trackKey] ?? []).contains { !$0.bypassed }
        let gain = Float(pluginRemoteTrackGain)
        let enabled = hasActivePlugins || abs(gain - 1.0) > 0.0001
        remoteTrackSettings[session] = (enabled: enabled, gain: pluginRemoteTrackGain)
        MKAudio.shared().setRemoteTrackPreviewGain(gain, enabled: enabled, forSession: UInt(session))
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
                        categorySeedText: ([component.typeName, component.name, component.manufacturerName] + component.allTagNames)
                            .joined(separator: " ")
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
            "/Library/Audio/Plug-Ins/VST3",
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
                if item.hasSuffix(".vst3") {
                    found.append("\(root)/\(item)")
                }
            }
        }
        scannedFilesystemPlugins = Array(Set(found))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { fullPath in
                DiscoveredPlugin(
                    id: "fs:\(fullPath)",
                    name: URL(fileURLWithPath: fullPath).deletingPathExtension().lastPathComponent,
                    subtitle: fullPath,
                    source: .filesystem,
                    categorySeedText: "\(URL(fileURLWithPath: fullPath).deletingPathExtension().lastPathComponent) \(fullPath)"
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
private struct PluginEditorMacHostView: NSViewControllerRepresentable {
    let controller: NSViewController

    func makeNSViewController(context: Context) -> NSViewController {
        let container = PluginEditorMacContainerViewController()
        container.setEmbeddedController(controller)
        return container
    }

    func updateNSViewController(_ nsViewController: NSViewController, context: Context) {
        (nsViewController as? PluginEditorMacContainerViewController)?.setEmbeddedController(controller)
    }
}

private final class PluginEditorMacContainerViewController: NSViewController {
    private weak var embeddedController: NSViewController?

    override func loadView() {
        view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
    }

    func setEmbeddedController(_ controller: NSViewController) {
        guard embeddedController !== controller else { return }

        if let existing = embeddedController {
            existing.view.removeFromSuperview()
            existing.removeFromParent()
        }

        embeddedController = controller
        addChild(controller)
        let childView = controller.view
        childView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(childView)
        NSLayoutConstraint.activate([
            childView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            childView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            childView.topAnchor.constraint(equalTo: view.topAnchor),
            childView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }
}

private struct PluginEditorWindowContentView: View {
    private enum Tab: String, CaseIterable, Identifiable {
        case pluginUI
        case parameters

        var id: String { rawValue }

        var title: String {
            switch self {
            case .pluginUI:
                return NSLocalizedString("Plugin UI", comment: "")
            case .parameters:
                return NSLocalizedString("Parameters", comment: "")
            }
        }
    }

    let controller: NSViewController?
    let snapshotProvider: () -> PluginEditorSnapshot
    let refreshAction: () -> Void
    let parameterChangeAction: (UInt64, Float) -> Void

    @State private var selectedTab: Tab = .pluginUI
    @State private var snapshot: PluginEditorSnapshot

    init(
        controller: NSViewController?,
        snapshotProvider: @escaping () -> PluginEditorSnapshot,
        refreshAction: @escaping () -> Void,
        parameterChangeAction: @escaping (UInt64, Float) -> Void
    ) {
        self.controller = controller
        self.snapshotProvider = snapshotProvider
        self.refreshAction = refreshAction
        self.parameterChangeAction = parameterChangeAction
        _snapshot = State(initialValue: snapshotProvider())
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if controller != nil {
                    Picker("", selection: $selectedTab) {
                        ForEach(Tab.allCases) { tab in
                            Text(tab.title).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                }

                Spacer()

                if selectedTab == .parameters {
                    Button(NSLocalizedString("Refresh", comment: "")) {
                        refreshSnapshot()
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(12)

            Divider()

            if selectedTab == .pluginUI, let controller {
                PluginEditorMacHostView(controller: controller)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(snapshot.name)
                            .font(.headline)
                        if !snapshot.subtitle.isEmpty {
                            Text(snapshot.subtitle)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        if snapshot.isLoading {
                            Text(NSLocalizedString("Loading Audio Unit...", comment: ""))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else if let errorDescription = snapshot.errorDescription {
                            Text(errorDescription)
                                .font(.caption)
                                .foregroundColor(.red)
                        } else if !snapshot.isLoaded {
                            Text(NSLocalizedString("Plugin is not ready", comment: ""))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else if snapshot.parameters.isEmpty {
                            Text(NSLocalizedString("No automatable parameters exposed", comment: ""))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            ForEach(snapshot.parameters) { parameter in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(parameter.name)
                                            .font(.caption)
                                        Spacer()
                                        Text(String(format: "%.3f", snapshotValue(for: parameter.id, fallback: parameter.value)))
                                            .font(.caption.monospacedDigit())
                                            .foregroundColor(.secondary)
                                    }
                                    Slider(
                                        value: Binding(
                                            get: { Double(snapshotValue(for: parameter.id, fallback: parameter.value)) },
                                            set: { newValue in
                                                parameterChangeAction(parameter.id, Float(newValue))
                                                refreshSnapshot()
                                            }
                                        ),
                                        in: Double(parameter.minValue)...Double(parameter.maxValue)
                                    )
                                }
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(minWidth: 640, maxWidth: .infinity, minHeight: 420, maxHeight: .infinity)
        .onAppear {
            if controller == nil {
                selectedTab = .parameters
            }
            refreshSnapshot()
        }
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in
            guard selectedTab == .parameters else { return }
            refreshSnapshot()
        }
    }

    private func refreshSnapshot() {
        refreshAction()
        snapshot = snapshotProvider()
    }

    private func snapshotValue(for parameterID: UInt64, fallback: Float) -> Float {
        snapshot.parameters.first(where: { $0.id == parameterID })?.value ?? fallback
    }
}

@MainActor
final class PluginEditorWindowController: NSObject {
    static let shared = PluginEditorWindowController()

    private var windows: [String: NSWindow] = [:]
    private var closeHandlers: [String: () -> Void] = [:]
    private var sizeObservers: [String: NSKeyValueObservation] = [:]

    private override init() {
        super.init()
    }

    func show(
        pluginKey: String,
        rootView: AnyView,
        observedController: NSViewController?,
        preferredContentSize: NSSize,
        title: String,
        onClose: @escaping () -> Void
    ) {
        let targetSize = normalizedSize(from: preferredContentSize)
        let hostingController = NSHostingController(rootView: rootView)

        if let window = windows[pluginKey] {
            window.title = title
            window.contentViewController = hostingController
            resize(window: window, to: targetSize)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            closeHandlers[pluginKey] = onClose
            if let observedController {
                installSizeObserver(for: pluginKey, controller: observedController)
            } else {
                sizeObservers.removeValue(forKey: pluginKey)
            }
            return
        }

        let window = NSWindow(contentViewController: hostingController)
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable]  // Not resizable
        window.setContentSize(targetSize)
        window.minSize = targetSize
        window.maxSize = targetSize
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
        if let observedController {
            installSizeObserver(for: pluginKey, controller: observedController)
        }
    }

    func close(pluginKey: String) {
        if let window = windows.removeValue(forKey: pluginKey) {
            closeHandlers.removeValue(forKey: pluginKey)
            sizeObservers.removeValue(forKey: pluginKey)
            window.close()
        }
    }

    private func normalizedSize(from preferred: NSSize) -> NSSize {
        let width = preferred.width > 10 ? preferred.width : 960
        let height = preferred.height > 10 ? preferred.height + 52 : 620
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
        sizeObservers.removeValue(forKey: pluginKey)
        handler?()
    }

    private func installSizeObserver(for pluginKey: String, controller: NSViewController) {
        sizeObservers[pluginKey] = controller.observe(\.preferredContentSize, options: [.new]) { [weak self] controller, _ in
            DispatchQueue.main.async {
                self?.applyPreferredSize(of: controller, for: pluginKey)
            }
        }
    }

    private func applyPreferredSize(of controller: NSViewController, for pluginKey: String) {
        guard let window = windows[pluginKey] else { return }
        let normalized = normalizedSize(from: controller.preferredContentSize)
        // Lock window to plugin size
        window.minSize = normalized
        window.maxSize = normalized
        resize(window: window, to: normalized)
    }
}
#endif
