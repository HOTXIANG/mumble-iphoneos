//
//  AudioPluginMixerView.swift
//  Mumble
//
//  DAW-style audio plugin mixer for input/output effect processing.
//

import SwiftUI
import Combine
@preconcurrency import AVFoundation
import UniformTypeIdentifiers
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

private struct TrackChainPresetPlugin: Codable, Hashable {
    let name: String
    let subtitle: String
    let source: PluginSource
    let identifier: String
    let bypassed: Bool
    let stageGain: Float
    let autoLoad: Bool
    let savedParameterValues: [String: Float]
    let sidechainSourceKey: String?

    init(plugin: TrackPlugin) {
        name = plugin.name
        subtitle = plugin.subtitle
        source = plugin.source
        identifier = plugin.identifier
        bypassed = plugin.bypassed
        stageGain = plugin.stageGain
        autoLoad = plugin.autoLoad
        savedParameterValues = plugin.savedParameterValues
        sidechainSourceKey = plugin.sidechainSourceKey
    }

    func makeTrackPlugin() -> TrackPlugin {
        TrackPlugin(
            id: UUID().uuidString,
            name: name,
            subtitle: subtitle,
            source: source,
            identifier: identifier,
            bypassed: bypassed,
            stageGain: stageGain,
            autoLoad: autoLoad,
            savedParameterValues: savedParameterValues,
            sidechainSourceKey: sidechainSourceKey
        )
    }
}

private struct TrackChainPresetFile: Codable, Hashable {
    let version: Int
    let exportedAt: Date
    let name: String
    let sourceTrackKey: String
    let sourceTrackTitle: String
    let slotCount: Int
    let plugins: [TrackChainPresetPlugin]
}

private struct TrackChainPresetDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var preset: TrackChainPresetFile

    init(preset: TrackChainPresetFile) {
        self.preset = preset
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        preset = try decoder.decode(TrackChainPresetFile.self, from: data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(preset)
        return .init(regularFileWithContents: data)
    }
}

private struct PluginEditorSnapshot {
    let name: String
    let subtitle: String
    let isLoading: Bool
    let isLoaded: Bool
    let errorDescription: String?
    var parameters: [PluginEditorParameterSnapshot]
}

private struct MixerLiveTrackRefreshModifier<TimerEvents: Publisher>: ViewModifier where TimerEvents.Output == Date, TimerEvents.Failure == Never {
    let timer: TimerEvents
    let refreshLiveTrackState: (Bool) -> Void
    let handleListeningChannelAdd: (Notification) -> Void
    let handleListeningChannelRemove: (Notification) -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(timer) { _ in refreshLiveTrackState(false) }
            .onReceive(NotificationCenter.default.publisher(for: ServerModelNotificationManager.userJoinedNotification).receive(on: RunLoop.main)) { _ in refreshLiveTrackState(true) }
            .onReceive(NotificationCenter.default.publisher(for: ServerModelNotificationManager.userLeftNotification).receive(on: RunLoop.main)) { _ in refreshLiveTrackState(true) }
            .onReceive(NotificationCenter.default.publisher(for: ServerModelNotificationManager.userMovedNotification).receive(on: RunLoop.main)) { _ in refreshLiveTrackState(true) }
            .onReceive(NotificationCenter.default.publisher(for: ServerModelNotificationManager.userStateUpdatedNotification).receive(on: RunLoop.main)) { _ in refreshLiveTrackState(true) }
            .onReceive(NotificationCenter.default.publisher(for: ServerModelNotificationManager.rebuildModelNotification).receive(on: RunLoop.main)) { _ in refreshLiveTrackState(true) }
            .onReceive(NotificationCenter.default.publisher(for: .muConnectionReady).receive(on: RunLoop.main)) { _ in refreshLiveTrackState(true) }
            .onReceive(NotificationCenter.default.publisher(for: .muConnectionClosed).receive(on: RunLoop.main)) { _ in refreshLiveTrackState(true) }
            .onReceive(NotificationCenter.default.publisher(for: .mkAudioDidRestart).receive(on: RunLoop.main)) { _ in refreshLiveTrackState(true) }
            .onReceive(NotificationCenter.default.publisher(for: .mkListeningChannelAdd).receive(on: RunLoop.main), perform: handleListeningChannelAdd)
            .onReceive(NotificationCenter.default.publisher(for: .mkListeningChannelRemove).receive(on: RunLoop.main), perform: handleListeningChannelRemove)
    }
}

private struct MixerTranslucentPanelModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(colorScheme == .light ? 0.10 : 0.12), lineWidth: 1)
            )
            .shadow(
                color: colorScheme == .light ? .black.opacity(0.07) : .clear,
                radius: colorScheme == .light ? 5 : 0,
                x: 0,
                y: colorScheme == .light ? 1 : 0
            )
    }
}

private struct MixerInstructionTextModifier: ViewModifier {
    let foregroundColor: Color

    func body(content: Content) -> some View {
        content
            .font(.caption)
            .foregroundColor(foregroundColor)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
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

        let rootView = AudioPluginMixerView()
            .modifier(MixerColorSchemeModifier())
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = NSLocalizedString("Audio Plugin Mixer", comment: "")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .windowBackgroundColor  // 跟随系统亮暗模式
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

        // 监听系统亮暗模式变化，强制窗口刷新外观
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleAppearanceChanged(_:)),
            name: .init("AppleInterfaceThemeChangedNotification"),
            object: nil
        )

        self.window = window
    }

    func closeWindow() {
        window?.close()
        window = nil
    }

    @objc private func handleMixerWindowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing == window else { return }
        DistributedNotificationCenter.default().removeObserver(self, name: .init("AppleInterfaceThemeChangedNotification"), object: nil)
        window = nil
    }

    @objc private func handleAppearanceChanged(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let window = self?.window else { return }
            // 重新继承系统外观
            window.appearance = nil
            window.invalidateShadow()
            window.displayIfNeeded()
        }
    }

}

/// 读取 AppColorScheme 设置并应用到 Mixer 窗口，确保跟随用户选择的亮暗模式
private struct MixerColorSchemeModifier: ViewModifier {
    @AppStorage("AppColorScheme") private var appColorSchemeRawValue: String = "system"

    func body(content: Content) -> some View {
        let option = AppColorSchemeOption.normalized(from: appColorSchemeRawValue)
        if let scheme = option.preferredColorScheme {
            content.preferredColorScheme(scheme)
        } else {
            content
        }
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
    var sidechainSourceKey: String?  // NEW — nil means no sidechain

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
        case sidechainSourceKey
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
        savedParameterValues: [String: Float] = [:],
        sidechainSourceKey: String? = nil
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
        self.sidechainSourceKey = sidechainSourceKey
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
        sidechainSourceKey = try container.decodeIfPresent(String.self, forKey: .sidechainSourceKey)
    }
}

struct AudioPluginMixerView: View {
    private let defaultInsertSlots: Int = 8
    private let maxInsertSlots: Int = 100
    private let liveTrackRefreshTimer = Timer.publish(every: 0.75, on: .main, in: .common).autoconnect()
    @ObservedObject private var sharedRackManager = AudioPluginRackManager.shared

    private struct HearableUser: Identifiable, Hashable {
        let id: String       // userHash（持久化键）
        let session: UInt
        let userName: String
    }

    private enum MixerTrack: Hashable {
        case input
        case sidetone
        case masterBus1
        case masterBus2
        case remoteUser(String)  // keyed by userHash

        var shortLabel: String {
            switch self {
            case .input:     return "IN"
            case .sidetone:  return "MON"
            case .masterBus1: return "M1"
            case .masterBus2: return "M2"
            case .remoteUser: return "USR"
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
    @AppStorage("AudioSidetone") private var audioSidetoneEnabled: Bool = false
    @AppStorage("AudioPluginRemoteBusGain") private var pluginRemoteBusGain: Double = 1.0
    @AppStorage("AudioPluginRemoteBus2Gain") private var pluginRemoteBus2Gain: Double = 1.0
    @AppStorage("AudioPluginTrackChainsV1") private var pluginTrackChainsData: String = ""
    @AppStorage("AudioPluginSlotCountsV1") private var pluginSlotCountsData: String = ""
    @AppStorage("AudioPluginPresetsV1") private var pluginPresetsData: String = ""
    @AppStorage("AudioPluginHostBufferFrames") private var pluginHostBufferFrames: Int = 256
    @AppStorage("AudioPluginCategoryOverridesV1") private var pluginCategoryOverridesData: String = ""
    @AppStorage("AudioPluginCustomCategoriesV1") private var pluginCustomCategoriesData: String = ""

    @State private var pluginRemoteTrackGain: Double = 1.0
    @State private var remoteTrackSettings: [Int: (enabled: Bool, gain: Double)] = [:]
    @State private var remoteSessionOrder: [Int] = []
    @State private var hearableUsers: [HearableUser] = []
    @State private var sessionToHash: [UInt: String] = [:]
    @State private var hashToSession: [String: UInt] = [:]
    @State private var listeningChannelIds: Set<UInt> = []  // 本地维护的监听频道集合
    @State private var selectedTrack: MixerTrack = .input
    @State private var installedAudioUnits: [DiscoveredPlugin] = []
    @State private var pluginChainByTrack: [String: [TrackPlugin]] = [:]
    @State private var slotCountByTrack: [String: Int] = [:]
    @State private var trackSendRoutesBySource: [String: [TrackSendRoute]] = [:]
    @State private var pluginOperationMessage: String = ""
    @State private var selectedPluginID: String? = nil
    @State private var loadingPluginIDs: Set<String> = []
    @State private var loadedAudioUnits: [String: AVAudioUnit] = [:]  // Key: "\(trackKey):\(pluginID)"
    @State private var cachedPluginEditorControllers: [String: PlatformViewController] = [:]
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
    @State private var showingTrackPresetImporter: Bool = false
    @State private var showingTrackPresetExporter: Bool = false
    @State private var trackPresetExportDocument: TrackChainPresetDocument? = nil
    @State private var trackPresetExportFilename: String = "mumble-track-preset"
    @State private var pluginCategoryOverrides: [String: String] = [:]
    @State private var customPluginCategories: [String] = []
    @State private var customCategoryInput: String = ""
    @State private var pendingPluginChainSaveWorkItem: DispatchWorkItem? = nil

    #if os(macOS)
    /// 将非 Optional 的 selectedTrack 桥接为 Optional Binding（List selection 需要）
    private var selectedTrackBinding: Binding<MixerTrack?> {
        Binding<MixerTrack?>(
            get: { selectedTrack },
            set: { newValue in
                if let newValue { selectedTrack = newValue }
            }
        )
    }
    #endif

    var body: some View {
        mixerBodyCore
            .modifier(MixerSheetsModifier(
                showingPluginBrowser: $showingPluginBrowser,
                showingPluginEditor: showingPluginEditorBinding,
                pluginEditorController: pluginEditorControllerValue,
                pluginEditorTitle: pluginEditorTitleValue,
                pluginBrowserSheet: { pluginBrowserSheet },
                onPluginEditorDismiss: {
                    snapshotAllPluginParameters()
                    #if os(iOS)
                    pluginEditorController = nil
                    pluginEditorTitle = ""
                    selectedPluginID = nil
                    #endif
                }
            ))
            .fileImporter(
                isPresented: $showingTrackPresetImporter,
                allowedContentTypes: [.json, .data],
                allowsMultipleSelection: false,
                onCompletion: handleTrackPresetImportSelection
            )
            .fileExporter(
                isPresented: $showingTrackPresetExporter,
                document: trackPresetExportDocument,
                contentType: .json,
                defaultFilename: trackPresetExportFilename,
                onCompletion: handleTrackPresetExportResult
            )
    }

    /// body 拆分：核心 onAppear / onReceive / onChange（减轻 type-checker 压力）
    private var mixerBodyCore: some View {
        mixerContentView
        .onAppear { performOnAppear() }
        .onDisappear { performOnDisappear() }
        .modifier(MixerLiveTrackRefreshModifier(
            timer: liveTrackRefreshTimer,
            refreshLiveTrackState: { force in refreshLiveTrackState(force: force) },
            handleListeningChannelAdd: handleListeningChannelAdd,
            handleListeningChannelRemove: handleListeningChannelRemove
        ))
        .onReceive(NotificationCenter.default.publisher(for: .muAutomationOpenUI)) { n in handleAutomationOpenUI(n) }
        .onReceive(NotificationCenter.default.publisher(for: .muAutomationDismissUI)) { n in handleAutomationDismissUI(n) }
        .onChange(of: selectedTrack) { loadSelectedTrackState(); normalizeSelectedPluginSelection(); rebuildProcessorStateMachine() }
        .onChange(of: pluginInputTrackGain) { applyLivePreviewForTrackKey("input"); PreferencesModel.shared.notifySettingsChanged() }
        .onChange(of: audioSidetoneEnabled) {
            syncInputToSidetoneSend()
            syncAllTrackSendRouting()
            PreferencesModel.shared.notifySettingsChanged()
        }
        .onChange(of: pluginRemoteBusGain) { applyLivePreviewForTrackKey("masterBus1"); PreferencesModel.shared.notifySettingsChanged() }
        .onChange(of: pluginRemoteBus2Gain) { applyLivePreviewForTrackKey("masterBus2"); PreferencesModel.shared.notifySettingsChanged() }
        .onChange(of: pluginRemoteTrackGain) { applyRemoteTrackPreview(); PreferencesModel.shared.notifySettingsChanged() }
        .onChange(of: pluginHostBufferFrames) { syncPluginHostBufferFrames(); PreferencesModel.shared.notifySettingsChanged() }
    }

    private func performOnAppear() {
        AppState.shared.setAutomationCurrentScreen("audioPluginMixer")
        ServerModelManager.shared?.startAudioTest()
        loadPluginChainState()
        let adoptedLiveProcessorState = syncLoadedStateFromSharedRackManager()
        migrateRemoteBusToMasterBus1()
        loadPluginSlotCountState()
        UserDefaults.standard.removeObject(forKey: "AudioPluginBusAssignmentsV1")
        loadPluginCategoryConfiguration()
        loadPluginPresets()
        initializeListeningChannels()
        refreshLiveTrackState(force: true)
        refreshInstalledAudioUnits()
        loadSelectedTrackState()
        normalizeSelectedPluginSelection()
        if !adoptedLiveProcessorState {
            applyLivePreviewForAllTracks()
        }
        rebuildProcessorStateMachine()
        syncPluginHostBufferFrames()
        syncAllTrackSendRouting()
        Task { await loadPersistedAudioUnits() }
    }

    private func performOnDisappear() {
        snapshotAllPluginParameters()
        ServerModelManager.shared?.stopAudioTest()
    }

    @discardableResult
    private func syncLoadedStateFromSharedRackManager() -> Bool {
        let manager = AudioPluginRackManager.shared
        let adoptedLiveProcessorState = !manager.loadedAudioUnits.isEmpty

        if !manager.pluginChainByTrack.isEmpty {
            pluginChainByTrack = manager.pluginChainByTrack
        }
        trackSendRoutesBySource = manager.trackSendRoutesBySource
        if !manager.loadedAudioUnits.isEmpty {
            loadedAudioUnits = manager.loadedAudioUnits
        }
        if !manager.lastLoadErrorByPlugin.isEmpty {
            lastLoadErrorByPlugin = manager.lastLoadErrorByPlugin
        }
        if !manager.parameterStateByPlugin.isEmpty {
            parameterStateByPlugin = manager.parameterStateByPlugin.mapValues { infos in
                infos.map {
                    RuntimeParameter(
                        id: $0.id,
                        name: $0.name,
                        minValue: $0.minValue,
                        maxValue: $0.maxValue,
                        value: $0.value
                    )
                }
            }
        }
        normalizePluginSlotCountsPersistingIfNeeded()
        return adoptedLiveProcessorState
    }

    private func handleAutomationOpenUI(_ notification: Notification) {
        guard let target = notification.userInfo?["target"] as? String else { return }
        applyAutomationTrackSelection(from: notification.userInfo)
        switch target {
        case "pluginBrowser":
            showingPluginBrowser = true
        case "pluginEditor":
            if let plugin = automationPlugin(from: notification.userInfo) {
                openPluginEditor(for: plugin)
            }
        default:
            break
        }
    }

    private func handleAutomationDismissUI(_ notification: Notification) {
        let target = notification.userInfo?["target"] as? String
        switch target {
        case nil:
            showingPluginBrowser = false
            #if os(iOS)
            showingPluginEditor = false
            #endif
        case "pluginBrowser":
            showingPluginBrowser = false
        case "pluginEditor":
            #if os(iOS)
            showingPluginEditor = false
            #endif
        default:
            break
        }
    }

    /// iOS 有 pluginEditorController，macOS 没有此 state — 统一 Binding 接口
    private var showingPluginEditorBinding: Binding<Bool> {
        #if os(iOS)
        return $showingPluginEditor
        #else
        return .constant(false)
        #endif
    }

    private var pluginEditorControllerValue: PlatformViewController? {
        #if os(iOS)
        return pluginEditorController
        #else
        return nil
        #endif
    }

    private var pluginEditorTitleValue: String {
        #if os(iOS)
        return pluginEditorTitle
        #else
        return ""
        #endif
    }

    private func applyAutomationTrackSelection(from userInfo: [AnyHashable: Any]?) {
        guard let userInfo else { return }
        if let trackKey = userInfo["trackKey"] as? String {
            switch trackKey {
            case "input":
                selectedTrack = .input
            case "sidetone":
                selectedTrack = .sidetone
            case "masterBus1":
                selectedTrack = .masterBus1
            case "masterBus2":
                selectedTrack = .masterBus2
            default:
                if trackKey.hasPrefix("remoteUser:") {
                    let hash = String(trackKey.dropFirst("remoteUser:".count))
                    selectedTrack = .remoteUser(hash)
                }
            }
        } else if let hash = userInfo["userHash"] as? String {
            selectedTrack = .remoteUser(hash)
        }
    }

    private func automationPlugin(from userInfo: [AnyHashable: Any]?) -> TrackPlugin? {
        if let pluginID = userInfo?["pluginID"] as? String,
           let plugin = findPlugin(withID: pluginID) {
            return plugin
        }
        if let slotIndex = userInfo?["slotIndex"] as? Int {
            return pluginAtSlot(slotIndex)
        }
        return selectedPlugin
    }

    // MARK: - Platform Content Layout

    @ViewBuilder
    private var mixerContentView: some View {
        #if os(macOS)
        NavigationSplitView {
            mixerTrackSidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 380)
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                if !pluginOperationMessage.isEmpty {
                    Text(pluginOperationMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 16)
                        .padding(.top, 2)
                }
                mixerWorkspace(compact: false)
            }
            .navigationTitle("Audio Plugin Mixer")
            .toolbarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .windowToolbar)
        }
        .navigationSplitViewStyle(.balanced)
        #else
        VStack(spacing: 0) {
            mixerTransportBar
            Divider()
            GeometryReader { geometry in
                let isCompact = geometry.size.width < 500
                Group {
                    if isCompact {
                        VStack(spacing: 0) {
                            compactTrackPicker
                            Divider()
                            mixerWorkspace(compact: true)
                        }
                    } else {
                        HStack(spacing: 0) {
                            mixerTrackSidebar
                                .frame(width: min(340, max(260, geometry.size.width * 0.33)))
                            Divider()
                            mixerWorkspace(compact: false)
                        }
                    }
                }
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
                            Text(trackTitle(track))
                                .font(.caption.weight(isSelected ? .semibold : .regular))
                                .foregroundColor(isSelected ? .primary : .secondary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .modifier(TintedGlassRowModifier(isHighlighted: isSelected, highlightColor: .accentColor, cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private var mixerTrackSidebar: some View {
        #if os(macOS)
        // macOS: 使用系统原生 List sidebar 风格
        VStack(spacing: 0) {
            List(allTracks, id: \.self, selection: selectedTrackBinding) { track in
                mixerTrackLabel(track)
                    .tag(track)
            }
            .listStyle(.sidebar)

            Divider()
            mixerSidebarControls
        }
        .toolbar(removing: .sidebarToggle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    NSApp.keyWindow?.firstResponder?.tryToPerform(
                        #selector(NSSplitViewController.toggleSidebar(_:)), with: nil
                    )
                } label: {
                    Image(systemName: "sidebar.leading")
                }
            }
        }
        #else
        // iOS: 自定义侧边栏布局
        VStack(alignment: .leading, spacing: 12) {
            Text(NSLocalizedString("Tracks", comment: ""))
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.top, 12)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 7) {
                    ForEach(allTracks, id: \.self) { track in
                        mixerTrackButton(track)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
            .scrollContentBackground(.hidden)

            if hearableUsers.isEmpty {
                Text(NSLocalizedString("No users in channel", comment: ""))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
        }
        .background(Color.clear)
        #endif
    }

    // MARK: - macOS Sidebar Controls & Detail Header

    #if os(macOS)
    /// 侧边栏底部：Buffer Size / Refresh / Plugin Browser
    private var mixerSidebarControls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
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
                        .frame(minWidth: 44)
                }
                .menuStyle(.borderlessButton)
                Spacer()
            }

            HStack(spacing: 8) {
                Button {
                    showingPluginBrowser = true
                } label: {
                    Label(NSLocalizedString("Plugins", comment: ""), systemImage: "square.grid.2x2")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    #endif

    /// 轨道行内容（Label 部分，macOS List 和 iOS Button 共用）
    private func trackTitle(_ track: MixerTrack) -> String {
        switch track {
        case .input: return NSLocalizedString("Input Track", comment: "")
        case .sidetone: return NSLocalizedString("Sidetone Track", comment: "")
        case .masterBus1: return NSLocalizedString("Master Bus 1", comment: "")
        case .masterBus2: return NSLocalizedString("Master Bus 2", comment: "")
        case .remoteUser(let hash): return hearableUserName(for: hash)
        }
    }

    private func trackSubtitle(_ track: MixerTrack) -> String {
        switch track {
        case .input: return NSLocalizedString("Local microphone before encode", comment: "")
        case .sidetone: return NSLocalizedString("Dedicated local monitor bus after input track", comment: "")
        case .masterBus1: return NSLocalizedString("Post-mix output bus 1", comment: "")
        case .masterBus2: return NSLocalizedString("Post-mix output bus 2", comment: "")
        case .remoteUser:
            return NSLocalizedString("Remote user post-decode track", comment: "")
        }
    }

    private func mixerTrackLabel(_ track: MixerTrack) -> some View {
        HStack(spacing: 8) {
            Text(track.shortLabel)
                .font(.caption.monospaced())
                .foregroundColor(.accentColor)
                .frame(width: 34, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.accentColor.opacity(0.15))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(trackTitle(track))
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.primary)
                Text(trackSubtitle(track))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)

        }
        .contentShape(Rectangle())
    }

    /// iOS 专用：带手动选中高亮的按钮行
    @ViewBuilder
    private func mixerTrackButton(_ track: MixerTrack) -> some View {
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
                    Text(trackTitle(track))
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)
                    Text(trackSubtitle(track))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)

            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .modifier(TintedGlassRowModifier(isHighlighted: isSelected, highlightColor: .accentColor))
        }
        .buttonStyle(.plain)
    }

    private func mixerWorkspace(compact: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                trackSendPanel(compact: compact)
                pluginChainPanel(compact: compact)
            }
            .padding(compact ? 10 : 16)
        }
    }

    private func trackSendPanel(compact: Bool) -> some View {
        let sourceTrackKey = selectedTrackKey
        let destinations = availableSendDestinations(for: sourceTrackKey)

        return VStack(alignment: .leading, spacing: compact ? 8 : 10) {
            Text(NSLocalizedString("Track Sends", comment: ""))
                .font(.headline)

            if !trackCanSend(sourceTrackKey) {
                Text(NSLocalizedString("Master tracks are receive-only and cannot send to other tracks.", comment: ""))
                    .modifier(MixerInstructionTextModifier(foregroundColor: .secondary))
            } else if destinations.isEmpty {
                Text(NSLocalizedString("No available destination tracks right now.", comment: ""))
                    .modifier(MixerInstructionTextModifier(foregroundColor: .secondary))
            } else {
                Text(NSLocalizedString("Choose which tracks should receive this track, and whether each send is audible audio or sidechain-only.", comment: ""))
                    .modifier(MixerInstructionTextModifier(foregroundColor: .secondary))

                LazyVGrid(columns: [GridItem(.adaptive(minimum: compact ? 132 : 170), spacing: 8)], spacing: 8) {
                    ForEach(destinations, id: \.self) { destinationKey in
                        sendTargetChip(for: destinationKey, sourceTrackKey: sourceTrackKey)
                    }
                }
            }
        }
        .padding(compact ? 10 : 14)
        .modifier(MixerTranslucentPanelModifier(cornerRadius: 12))
    }

    private func sendTargetChip(for destinationKey: String, sourceTrackKey: String) -> some View {
        let currentMode = trackSendMode(from: sourceTrackKey, to: destinationKey)
        let enabled = currentMode != nil
        let cycleBlocked = currentMode == nil && wouldCreateSendCycle(source: sourceTrackKey, destination: destinationKey)
        let disableBlocked = wouldRemoveLastRequiredMasterSend(proposedMode: nil,
                                                               from: sourceTrackKey,
                                                               to: destinationKey)
        let audioModeBlocked = wouldCreateSendCycle(source: sourceTrackKey, destination: destinationKey)
        let sidechainModeBlocked = wouldRemoveLastRequiredMasterSend(proposedMode: .sidechain,
                                                                     from: sourceTrackKey,
                                                                     to: destinationKey)

        return HStack(spacing: 8) {
            Button {
                setTrackSendEnabled(!enabled, from: sourceTrackKey, to: destinationKey)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: enabled ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(
                            enabled
                                ? Color.accentColor
                                : ((cycleBlocked || disableBlocked) ? Color.secondary : Color.primary)
                        )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(trackLabel(forTrackKey: destinationKey))
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(.primary)
                            .multilineTextAlignment(.leading)
                        if enabled, let currentMode {
                            Text(currentMode == .audio
                                 ? NSLocalizedString("Audio Send", comment: "")
                                 : NSLocalizedString("Sidechain Only", comment: ""))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        } else if cycleBlocked {
                            Text(NSLocalizedString("Would create a send loop", comment: ""))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        } else if disableBlocked {
                            Text(NSLocalizedString("At least one master bus must stay enabled", comment: ""))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)
            .disabled((!enabled && cycleBlocked) || (enabled && disableBlocked))

            if enabled {
                Menu {
                    Button(NSLocalizedString("Audio Send", comment: "")) {
                        setTrackSendMode(.audio, from: sourceTrackKey, to: destinationKey)
                    }
                    .disabled(audioModeBlocked)

                    Button(NSLocalizedString("Sidechain Only", comment: "")) {
                        setTrackSendMode(.sidechain, from: sourceTrackKey, to: destinationKey)
                    }
                    .disabled(sidechainModeBlocked)
                } label: {
                    Text(currentMode == .sidechain ? NSLocalizedString("SC", comment: "") : NSLocalizedString("AUD", comment: ""))
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.secondary.opacity(0.12))
                        )
                }
                .menuStyle(.borderlessButton)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(enabled ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.08))
        )
    }

    private func pluginChainPanel(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 10) {
            HStack(spacing: 8) {
                Text(NSLocalizedString("Plugin Chain", comment: ""))
                    .font(.headline)
                Spacer(minLength: 0)
                if compact {
                    Button {
                        showingTrackPresetImporter = true
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        prepareTrackPresetExport()
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button {
                        showingTrackPresetImporter = true
                    } label: {
                        Label(NSLocalizedString("Import Track Preset", comment: ""), systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        prepareTrackPresetExport()
                    } label: {
                        Label(NSLocalizedString("Export Track Preset", comment: ""), systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                }
            }
            if sharedRackManager.isSafeModeActive {
                Text(
                    NSLocalizedString(
                        "Safe Mode is active. Mixer plugins will not be loaded this session, but you can still remove problematic plugins.",
                        comment: ""
                    )
                )
                .modifier(MixerInstructionTextModifier(foregroundColor: .orange))
            }
            if !compact {
                Text(NSLocalizedString("Choose a plugin for each insert, enable it when needed, open its editor, and set its mix.", comment: ""))
                    .modifier(MixerInstructionTextModifier(foregroundColor: .secondary))
            }

            ForEach(0..<selectedTrackSlotCount, id: \.self) { slotIndex in
                let plugin = pluginAtSlot(slotIndex)
                let isSelected = selectedPluginID == plugin?.id

                if compact {
                    compactPluginSlotRow(slotIndex: slotIndex, plugin: plugin, isSelected: isSelected)
                } else {
                    widePluginSlotRow(slotIndex: slotIndex, plugin: plugin, isSelected: isSelected)
                }
            }

            Button {
                addPluginSlot()
            } label: {
                Label(NSLocalizedString("Add Slot", comment: ""), systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(selectedTrackSlotCount >= maxInsertSlots)
        }
        .padding(compact ? 10 : 14)
        .modifier(MixerTranslucentPanelModifier(cornerRadius: 12))
    }

    // MARK: - Wide Plugin Slot (macOS / iPad 横屏)

    @ViewBuilder
    private func widePluginSlotRow(slotIndex: Int, plugin: TrackPlugin?, isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            Text("\(slotIndex + 1)")
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 24)

            pluginSelectMenu(slotIndex: slotIndex, plugin: plugin, minWidth: 240)

            if let plugin {
                if auHasSidechainInput(plugin: plugin, trackKey: selectedTrackKey) {
                    sidechainSourcePicker(for: plugin, trackKey: selectedTrackKey, width: 88)
                }

                Spacer(minLength: 0)

                HStack(spacing: 8) {
                    Button {
                        toggleBypass(at: slotIndex)
                    } label: {
                        Text(plugin.bypassed ? NSLocalizedString("Off", comment: "") : NSLocalizedString("On", comment: ""))
                            .frame(minWidth: 32, minHeight: 22)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        movePluginUp(at: slotIndex)
                    } label: {
                        Image(systemName: "chevron.up")
                            .font(.caption)
                            .frame(width: 26, height: 22)
                    }
                    .buttonStyle(.bordered)
                    .disabled(slotIndex == 0)

                    Button {
                        movePluginDown(at: slotIndex)
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.caption)
                            .frame(width: 26, height: 22)
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
                                set: { updateMixLevel(at: slotIndex, newValue: Float($0 / 100.0), commit: false) }
                            ),
                            in: 0...100,
                            onEditingChanged: { editing in
                                if !editing {
                                    commitMixLevel(at: slotIndex)
                                }
                            }
                        )
                        .frame(width: 100)
                        Text("\(Int((plugin.stageGain * 100.0).rounded()))%")
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                    .frame(width: 180, alignment: .trailing)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                Spacer(minLength: 0)

                Button(role: .destructive) {
                    removeEmptyPluginSlot(slotIndex: slotIndex)
                } label: {
                    Image(systemName: "minus.circle")
                        .font(.body)
                }
                .buttonStyle(.bordered)
                .disabled(!canRemoveEmptyPluginSlot(at: slotIndex))
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

                if let plugin {
                    if auHasSidechainInput(plugin: plugin, trackKey: selectedTrackKey) {
                        sidechainSourcePicker(for: plugin, trackKey: selectedTrackKey, width: 72)
                    }

                    // 打开插件编辑器的按钮
                    Button {
                        selectedPluginID = plugin.id
                        openPluginEditor(for: plugin)
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

                    Button(role: .destructive) {
                        removeEmptyPluginSlot(slotIndex: slotIndex)
                    } label: {
                        Image(systemName: "minus.circle")
                            .font(.body)
                            .foregroundColor(canRemoveEmptyPluginSlot(at: slotIndex) ? .red : .secondary)
                            .frame(maxWidth: .infinity, minHeight: 34)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canRemoveEmptyPluginSlot(at: slotIndex))
                }
            }

            // 第二行：控制按钮和 Mix 滑块（仅在有插件时显示）
            if let plugin {
                HStack(spacing: 8) {
                    Button {
                        toggleBypass(at: slotIndex)
                    } label: {
                        Text(plugin.bypassed ? NSLocalizedString("Off", comment: "") : NSLocalizedString("On", comment: ""))
                            .frame(minWidth: 28, minHeight: 18)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        movePluginUp(at: slotIndex)
                    } label: {
                        Image(systemName: "chevron.up")
                            .font(.caption2)
                            .frame(width: 22, height: 18)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(slotIndex == 0)

                    Button {
                        movePluginDown(at: slotIndex)
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                            .frame(width: 22, height: 18)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(slotIndex >= selectedTrackChain.count - 1)

                    Slider(
                        value: Binding(
                            get: { Double(plugin.stageGain * 100.0) },
                            set: { updateMixLevel(at: slotIndex, newValue: Float($0 / 100.0), commit: false) }
                        ),
                        in: 0...100,
                        onEditingChanged: { editing in
                            if !editing {
                                commitMixLevel(at: slotIndex)
                            }
                        }
                    )
                    .frame(maxWidth: 110)

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

    private func sidechainSourcePicker(for plugin: TrackPlugin, trackKey: String, width: CGFloat) -> some View {
        let sources = availableSidechainSources(for: trackKey, selectedSourceKey: plugin.sidechainSourceKey)
        let selectedKey = plugin.sidechainSourceKey ?? ""
        let selectedLabel = sources.first(where: { $0.key == selectedKey })?.label ?? NSLocalizedString("None", comment: "")

        return Menu {
            ForEach(sources, id: \.key) { source in
                Button {
                    setSidechainSource(source.key.isEmpty ? nil : source.key, forPlugin: plugin, trackKey: trackKey)
                } label: {
                    HStack {
                        Text(source.label)
                        if source.key == selectedKey {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text("SC")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(selectedKey.isEmpty ? Color.secondary : Color.orange)
                Text(selectedLabel)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: width, alignment: .leading)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.secondary.opacity(0.12))
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private func pluginSelectMenu(slotIndex: Int, plugin: TrackPlugin?, minWidth: CGFloat, compact: Bool = false) -> some View {
        Menu {
            if installedAudioUnits.isEmpty {
                Text(NSLocalizedString("No plugins available", comment: ""))
            }
            if !installedAudioUnits.isEmpty {
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
        .menuIndicator(.hidden)
    }

    private var pluginBrowserPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(NSLocalizedString("Plugin Browser", comment: ""))
                .font(.headline)

            Text(String(format: NSLocalizedString("Selected Track: %@", comment: ""), trackTitle(selectedTrack)))
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
        }
        .padding(14)
        .modifier(ClearGlassModifier(cornerRadius: 12))
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
                    Button(NSLocalizedString("Done", comment: "")) {
                        showingPluginBrowser = false
                    }
                }
            }
        }
#if os(macOS)
        .frame(minWidth: 780, minHeight: 620)
#endif
        .onAppear {
            AppState.shared.setAutomationCurrentScreen("pluginBrowser")
        }
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
            Text(NSLocalizedString("AU", comment: ""))
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var allTracks: [MixerTrack] {
        var tracks: [MixerTrack] = [.input, .sidetone]
        tracks.append(contentsOf: hearableUsers.map { .remoteUser($0.id) })
        tracks.append(.masterBus1)
        tracks.append(.masterBus2)
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
        case .sidetone:
            return "sidetone"
        case .masterBus1:
            return "masterBus1"
        case .masterBus2:
            return "masterBus2"
        case .remoteUser(let hash):
            return "remoteUser:\(hash)"
        }
    }

    private var selectedTrackChain: [TrackPlugin] {
        pluginChainByTrack[selectedTrackKey] ?? []
    }

    private var selectedTrackSlotCount: Int {
        normalizedSlotCount(for: selectedTrackKey, requested: slotCountByTrack[selectedTrackKey])
    }

    private func pluginAtSlot(_ slotIndex: Int) -> TrackPlugin? {
        guard slotIndex >= 0, slotIndex < selectedTrackChain.count else { return nil }
        return selectedTrackChain[slotIndex]
    }

    private func normalizedSlotCount(for trackKey: String, requested: Int?) -> Int {
        let minimum = max(defaultInsertSlots, pluginChainByTrack[trackKey]?.count ?? 0)
        let requestedCount = requested ?? minimum
        let clampedRequested = min(maxInsertSlots, requestedCount)
        return max(minimum, clampedRequested)
    }

    private func canRemoveEmptyPluginSlot(at slotIndex: Int) -> Bool {
        guard slotIndex >= selectedTrackChain.count else { return false }
        return selectedTrackSlotCount > max(defaultInsertSlots, selectedTrackChain.count)
    }

    private func addPluginSlot() {
        let nextCount = min(maxInsertSlots, selectedTrackSlotCount + 1)
        guard nextCount != selectedTrackSlotCount else { return }
        updateSlotCount(nextCount, for: selectedTrackKey)
        pluginOperationMessage = NSLocalizedString("Added empty plugin slot", comment: "")
    }

    private func removeEmptyPluginSlot(slotIndex: Int) {
        guard canRemoveEmptyPluginSlot(at: slotIndex) else { return }
        let nextCount = max(max(defaultInsertSlots, selectedTrackChain.count), selectedTrackSlotCount - 1)
        guard nextCount != selectedTrackSlotCount else { return }
        updateSlotCount(nextCount, for: selectedTrackKey)
        pluginOperationMessage = NSLocalizedString("Removed empty plugin slot", comment: "")
    }

    private func updateSlotCount(_ requestedCount: Int, for trackKey: String) {
        let normalized = normalizedSlotCount(for: trackKey, requested: requestedCount)
        if normalized == defaultInsertSlots {
            slotCountByTrack.removeValue(forKey: trackKey)
        } else {
            slotCountByTrack[trackKey] = normalized
        }
        savePluginSlotCountState()
    }

    private func normalizePluginSlotCountsPersistingIfNeeded() {
        var normalizedCounts: [String: Int] = [:]
        let knownTrackKeys = Set(slotCountByTrack.keys).union(pluginChainByTrack.keys)
        for trackKey in knownTrackKeys {
            let normalized = normalizedSlotCount(for: trackKey, requested: slotCountByTrack[trackKey])
            if normalized != defaultInsertSlots {
                normalizedCounts[trackKey] = normalized
            }
        }

        guard normalizedCounts != slotCountByTrack else { return }
        slotCountByTrack = normalizedCounts
        savePluginSlotCountState()
    }

    private func sanitizedPresetFilename(from rawTitle: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(.init(charactersIn: "-_ "))
        let filteredScalars = rawTitle.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let filtered = String(filteredScalars)
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return filtered.isEmpty ? "mumble-track-preset" : filtered
    }

    private func makeCurrentTrackPresetFile() -> TrackChainPresetFile {
        snapshotAllPluginParameters()
        return TrackChainPresetFile(
            version: 1,
            exportedAt: Date(),
            name: trackTitle(selectedTrack),
            sourceTrackKey: selectedTrackKey,
            sourceTrackTitle: trackTitle(selectedTrack),
            slotCount: selectedTrackSlotCount,
            plugins: selectedTrackChain.map(TrackChainPresetPlugin.init(plugin:))
        )
    }

    private func prepareTrackPresetExport() {
        let preset = makeCurrentTrackPresetFile()
        trackPresetExportDocument = TrackChainPresetDocument(preset: preset)
        trackPresetExportFilename = sanitizedPresetFilename(from: "\(preset.sourceTrackTitle)-track-preset.mumbletrackpreset")
        showingTrackPresetExporter = true
    }

    private func handleTrackPresetExportResult(_ result: Result<URL, Error>) {
        switch result {
        case .success:
            pluginOperationMessage = String(
                format: NSLocalizedString("Exported track preset for %@", comment: ""),
                trackTitle(selectedTrack)
            )
        case .failure(let error):
            pluginOperationMessage = String(
                format: NSLocalizedString("Failed to export track preset: %@", comment: ""),
                error.localizedDescription
            )
        }
    }

    private func handleTrackPresetImportSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            pluginOperationMessage = String(
                format: NSLocalizedString("Failed to import track preset: %@", comment: ""),
                error.localizedDescription
            )
        case .success(let urls):
            guard let fileURL = urls.first else { return }
            let didAccess = fileURL.startAccessingSecurityScopedResource()
            defer {
                if didAccess {
                    fileURL.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let data = try Data(contentsOf: fileURL)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let preset = try decoder.decode(TrackChainPresetFile.self, from: data)
                Task {
                    await importTrackPreset(preset)
                }
            } catch {
                pluginOperationMessage = String(
                    format: NSLocalizedString("Failed to read track preset: %@", comment: ""),
                    error.localizedDescription
                )
            }
        }
    }

    private func replaceLocalTrackChain(trackKey: String, with plugins: [TrackPlugin]) async {
        let existingChain = pluginChainByTrack[trackKey] ?? []
        for plugin in existingChain {
            closePluginEditorIfNeeded(for: plugin, trackKey: trackKey)
            clearPluginEditorCache(for: plugin, trackKey: trackKey)
            if pluginLoaded(for: plugin.id) {
                unloadAudioUnit(for: plugin)
            }
        }

        pluginChainByTrack[trackKey] = plugins
        savePluginChainState()
        normalizePluginSlotCountsPersistingIfNeeded()
        normalizeSelectedPluginSelection()
        applyLivePreviewForTrackKey(trackKey)
        rebuildProcessorState(for: trackKey)

        for plugin in plugins where plugin.source == .audioUnit && plugin.autoLoad {
            _ = await loadAudioUnit(for: plugin)
        }
        rebuildProcessorState(for: trackKey)
    }

    private func importTrackPreset(_ preset: TrackChainPresetFile) async {
        let importedPlugins = preset.plugins.map { $0.makeTrackPlugin() }
        let trackKey = selectedTrackKey

        if isSharedManagedTrack(trackKey) {
            for plugin in selectedTrackChain {
                closePluginEditorIfNeeded(for: plugin, trackKey: trackKey)
                clearPluginEditorCache(for: plugin, trackKey: trackKey)
            }
            await AudioPluginRackManager.shared.replaceTrackChain(trackKey: trackKey, with: importedPlugins)
            await MainActor.run {
                updateSlotCount(preset.slotCount, for: trackKey)
                refreshSharedManagedTrackState()
                pluginOperationMessage = String(
                    format: NSLocalizedString("Imported track preset '%@'", comment: ""),
                    preset.name
                )
            }
            return
        }

        await MainActor.run {
            updateSlotCount(preset.slotCount, for: trackKey)
        }
        await replaceLocalTrackChain(trackKey: trackKey, with: importedPlugins)
        await MainActor.run {
            pluginOperationMessage = String(
                format: NSLocalizedString("Imported track preset '%@'", comment: ""),
                preset.name
            )
        }
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
        return loadedAudioUnits[loadedKey] != nil
    }

    // MARK: - Sidechain Support

    /// Checks if the Audio Unit has sidechain input capability (more than 1 input bus)
    private func auHasSidechainInput(plugin: TrackPlugin, trackKey: String) -> Bool {
        let loadedKey = loadedAudioUnitKey(trackKey: trackKey, pluginID: plugin.id)
        guard let au = loadedAudioUnits[loadedKey] else { return false }
        return au.auAudioUnit.inputBusses.count > 1
    }

    /// Builds the list of available sidechain sources from incoming sends.
    private func availableSidechainSources(for trackKey: String, selectedSourceKey: String?) -> [(key: String, label: String)] {
        var sources: [(key: String, label: String)] = [("", "None")]

        for route in incomingSendRoutes(forDestinationTrackKey: trackKey) {
            guard let routingKey = routingSourceKey(forTrackKey: route.source) else { continue }
            sources.append((routingKey, trackLabel(forTrackKey: route.source)))
        }

        if let selectedSourceKey,
           !selectedSourceKey.isEmpty,
           !sources.contains(where: { $0.key == selectedSourceKey }) {
            sources.append((selectedSourceKey, NSLocalizedString("Unavailable Sidechain Source", comment: "")))
        }

        return sources
    }

    private func validSidechainRoutingKeys(forDestinationTrackKey trackKey: String) -> Set<String> {
        Set(incomingSendRoutes(forDestinationTrackKey: trackKey).compactMap { route in
            routingSourceKey(forTrackKey: route.source)
        })
    }

    /// Creates a Binding for the sidechain source picker
    private func sidechainBinding(for plugin: TrackPlugin, trackKey: String) -> Binding<String> {
        Binding<String>(
            get: { plugin.sidechainSourceKey ?? "" },
            set: { newValue in
                let key = newValue.isEmpty ? nil : newValue
                self.setSidechainSource(key, forPlugin: plugin, trackKey: trackKey)
            }
        )
    }

    private func setSidechainSource(_ sourceKey: String?, forPlugin plugin: TrackPlugin, trackKey: String) {
        if isSharedManagedTrack(trackKey) {
            AudioPluginRackManager.shared.setSidechainSource(sourceKey, forPluginID: plugin.id, inTrack: trackKey)
            refreshSharedManagedTrackState()
            return
        }

        mutateSelectedTrackChain { chain in
            guard let index = chain.firstIndex(where: { $0.id == plugin.id }) else { return }
            chain[index].sidechainSourceKey = sourceKey
        }
    }

    private func mutateSelectedTrackChain(_ update: (inout [TrackPlugin]) -> Void) {
        var chain = pluginChainByTrack[selectedTrackKey] ?? []
        update(&chain)
        pluginChainByTrack[selectedTrackKey] = chain
        savePluginChainState()
        normalizePluginSlotCountsPersistingIfNeeded()
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
        removeLegacyFilesystemPlugins()
        normalizePluginSlotCountsPersistingIfNeeded()
    }

    private func loadPluginSlotCountState() {
        guard !pluginSlotCountsData.isEmpty,
              let data = pluginSlotCountsData.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: Int].self, from: data) else {
            slotCountByTrack = [:]
            normalizePluginSlotCountsPersistingIfNeeded()
            return
        }
        slotCountByTrack = decoded
        normalizePluginSlotCountsPersistingIfNeeded()
    }

    /// 旧版使用 "remoteBus" 键，新版迁移到 "masterBus1"
    private func migrateRemoteBusToMasterBus1() {
        if let oldChain = pluginChainByTrack["remoteBus"], pluginChainByTrack["masterBus1"] == nil {
            pluginChainByTrack["masterBus1"] = oldChain
            pluginChainByTrack.removeValue(forKey: "remoteBus")
            savePluginChainState()
        }
        // 同理迁移 remoteSession:xxx → 无需迁移，因为 hash-based key 是新格式
    }

    private func savePluginChainState() {
        guard let data = try? JSONEncoder().encode(pluginChainByTrack),
              let string = String(data: data, encoding: .utf8) else {
            return
        }
        pluginTrackChainsData = string
    }

    private func savePluginSlotCountState() {
        guard let data = try? JSONEncoder().encode(slotCountByTrack),
              let string = String(data: data, encoding: .utf8) else {
            return
        }
        pluginSlotCountsData = string
    }

    private func removeLegacyFilesystemPlugins() {
        var modified = false
        for (trackKey, chain) in pluginChainByTrack {
            let filteredChain = chain.filter { $0.source != .filesystem }
            if filteredChain.count != chain.count {
                pluginChainByTrack[trackKey] = filteredChain
                modified = true
            }
        }
        if modified {
            savePluginChainState()
            normalizePluginSlotCountsPersistingIfNeeded()
        }
    }

    private func addPlugin(_ plugin: DiscoveredPlugin) async {
        if isSharedManagedTrack(selectedTrackKey) {
            let discovery = AudioPluginDiscovery(
                id: plugin.id,
                name: plugin.name,
                subtitle: plugin.subtitle,
                source: plugin.source,
                categorySeedText: plugin.categorySeedText
            )
            _ = await AudioPluginRackManager.shared.addPlugin(discovery, to: selectedTrackKey)
            syncLoadedStateFromSharedRackManager()
            loadSelectedTrackState()
            normalizeSelectedPluginSelection()
            rebuildProcessorStateMachine()
            pluginOperationMessage = String(format: NSLocalizedString("Added %@", comment: ""), plugin.name)
            if let latest = selectedTrackChain.last, loadedProcessor(for: selectedTrackKey, pluginID: latest.id) != nil {
                openPluginEditor(for: latest)
            }
            return
        }

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
                    savedParameterValues: [:],
                    sidechainSourceKey: nil
                )
            )
            pluginOperationMessage = String(format: NSLocalizedString("Added %@", comment: ""), plugin.name)
        }

        // Sync DSP chain first to register the plugin in the chain
        syncAudioUnitDSPChainForTrackKey(selectedTrackKey)

        if plugin.source == .audioUnit, let latest = selectedTrackChain.last {
            if await loadAudioUnit(for: latest) {
                await MainActor.run {
                    openPluginEditor(for: latest)
                }
            }
        }
    }

    private func assignPluginToSlot(_ discovered: DiscoveredPlugin, slotIndex: Int) async {
        guard slotIndex >= 0 else { return }

        if isSharedManagedTrack(selectedTrackKey) {
            let existing = pluginAtSlot(slotIndex)
            let reopenEditorAfterReplace = existing.map { pluginEditorWasOpen(for: $0, trackKey: selectedTrackKey) } ?? false
            if let existing {
                closePluginEditorIfNeeded(for: existing, trackKey: selectedTrackKey)
                clearPluginEditorCache(for: existing, trackKey: selectedTrackKey)
            }
            let discovery = AudioPluginDiscovery(
                id: discovered.id,
                name: discovered.name,
                subtitle: discovered.subtitle,
                source: discovered.source,
                categorySeedText: discovered.categorySeedText
            )
            if let existing {
                _ = AudioPluginRackManager.shared.removePlugin(trackKey: selectedTrackKey, pluginID: existing.id)
            }
            let insertedPlugin = await AudioPluginRackManager.shared.addPlugin(discovery, to: selectedTrackKey, at: slotIndex)
            syncLoadedStateFromSharedRackManager()
            loadSelectedTrackState()
            normalizeSelectedPluginSelection()
            rebuildProcessorStateMachine()
            pluginOperationMessage = String(format: NSLocalizedString("Inserted %@", comment: ""), discovered.name)
            if loadedProcessor(for: selectedTrackKey, pluginID: insertedPlugin.id) != nil || reopenEditorAfterReplace {
                await MainActor.run {
                    openPluginEditor(for: insertedPlugin)
                }
            }
            return
        }

        let existing = pluginAtSlot(slotIndex)
        if let existing {
            closePluginEditorIfNeeded(for: existing, trackKey: selectedTrackKey)
        }
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
                savedParameterValues: [:],
                sidechainSourceKey: nil
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

        // Sync DSP chain first to register the plugin in the chain
        syncAudioUnitDSPChainForTrackKey(selectedTrackKey)

        guard let insertedPluginID else { return }
        if let inserted = selectedTrackChain.first(where: { $0.id == insertedPluginID }),
           inserted.source == .audioUnit {
            if await loadAudioUnit(for: inserted) {
                await MainActor.run {
                    openPluginEditor(for: inserted)
                }
            }
        }
    }

    private func clearPluginSlot(slotIndex: Int) {
        guard let existing = pluginAtSlot(slotIndex) else { return }
        closePluginEditorIfNeeded(for: existing, trackKey: selectedTrackKey)
        if isSharedManagedTrack(selectedTrackKey) {
            clearPluginEditorCache(for: existing, trackKey: selectedTrackKey)
            if let removed = AudioPluginRackManager.shared.removePlugin(trackKey: selectedTrackKey, pluginID: existing.id) {
                refreshSharedManagedTrackState()
                pluginOperationMessage = String(format: NSLocalizedString("Removed %@", comment: ""), removed.name)
            }
            return
        }
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
        guard selectedTrackChain.indices.contains(index) else { return }
        let plugin = selectedTrackChain[index]
        closePluginEditorIfNeeded(for: plugin, trackKey: selectedTrackKey)
        if isSharedManagedTrack(selectedTrackKey) {
            clearPluginEditorCache(for: plugin, trackKey: selectedTrackKey)
            if let removed = AudioPluginRackManager.shared.removePlugin(trackKey: selectedTrackKey, pluginID: plugin.id) {
                refreshSharedManagedTrackState()
                pluginOperationMessage = String(format: NSLocalizedString("Removed %@", comment: ""), removed.name)
            }
            return
        }
        if pluginLoaded(for: plugin.id) {
            unloadAudioUnit(for: plugin)
        }
        mutateSelectedTrackChain { chain in
            guard chain.indices.contains(index) else { return }
            let removed = chain.remove(at: index)
            pluginOperationMessage = String(format: NSLocalizedString("Removed %@", comment: ""), removed.name)
        }
    }

    private func toggleBypass(at index: Int) {
        if isSharedManagedTrack(selectedTrackKey) {
            guard selectedTrackChain.indices.contains(index) else { return }
            let plugin = selectedTrackChain[index]
            let bypassed = !plugin.bypassed
            AudioPluginRackManager.shared.setPluginBypassed(trackKey: selectedTrackKey, pluginID: plugin.id, bypassed: bypassed)
            refreshSharedManagedTrackState()
            let key = bypassed ? "Plugin bypassed" : "Plugin activated"
            pluginOperationMessage = String(format: NSLocalizedString(key, comment: ""), plugin.name)
            return
        }
        mutateSelectedTrackChain { chain in
            guard chain.indices.contains(index) else { return }
            chain[index].bypassed.toggle()
            let key = chain[index].bypassed ? "Plugin bypassed" : "Plugin activated"
            pluginOperationMessage = String(format: NSLocalizedString(key, comment: ""), chain[index].name)
        }
    }

    private func movePluginUp(at index: Int) {
        if isSharedManagedTrack(selectedTrackKey) {
            guard index > 0, selectedTrackChain.indices.contains(index) else { return }
            let plugin = selectedTrackChain[index]
            AudioPluginRackManager.shared.movePlugin(trackKey: selectedTrackKey, pluginID: plugin.id, to: index - 1)
            refreshSharedManagedTrackState()
            pluginOperationMessage = NSLocalizedString("Plugin order updated", comment: "")
            return
        }
        mutateSelectedTrackChain { chain in
            guard index > 0, chain.indices.contains(index) else { return }
            chain.swapAt(index, index - 1)
            pluginOperationMessage = NSLocalizedString("Plugin order updated", comment: "")
        }
    }

    private func movePluginDown(at index: Int) {
        if isSharedManagedTrack(selectedTrackKey) {
            guard selectedTrackChain.indices.contains(index), index < selectedTrackChain.count - 1 else { return }
            let plugin = selectedTrackChain[index]
            AudioPluginRackManager.shared.movePlugin(trackKey: selectedTrackKey, pluginID: plugin.id, to: index + 1)
            refreshSharedManagedTrackState()
            pluginOperationMessage = NSLocalizedString("Plugin order updated", comment: "")
            return
        }
        mutateSelectedTrackChain { chain in
            guard chain.indices.contains(index), index < chain.count - 1 else { return }
            chain.swapAt(index, index + 1)
            pluginOperationMessage = NSLocalizedString("Plugin order updated", comment: "")
        }
    }

    private func updateMixLevel(at index: Int, newValue: Float, commit: Bool) {
        let clampedValue = min(max(newValue, 0.0), 1.0)

        if isSharedManagedTrack(selectedTrackKey) {
            guard selectedTrackChain.indices.contains(index) else { return }
            let plugin = selectedTrackChain[index]
            AudioPluginRackManager.shared.setPluginStageGain(
                trackKey: selectedTrackKey,
                pluginID: plugin.id,
                stageGain: clampedValue,
                persist: commit
            )
            updateLocalMixMirror(at: index, newValue: clampedValue)
            return
        }

        guard var chain = pluginChainByTrack[selectedTrackKey],
              chain.indices.contains(index),
              abs(chain[index].stageGain - clampedValue) > 0.0001 || commit else {
            return
        }

        chain[index].stageGain = clampedValue
        pluginChainByTrack[selectedTrackKey] = chain
        applyLivePreviewForTrackKey(selectedTrackKey)

        if commit {
            savePluginChainState()
        }
    }

    private func commitMixLevel(at index: Int) {
        guard selectedTrackChain.indices.contains(index) else { return }
        updateMixLevel(at: index, newValue: selectedTrackChain[index].stageGain, commit: true)
    }

    private func updateLocalMixMirror(at index: Int, newValue: Float) {
        guard var chain = pluginChainByTrack[selectedTrackKey],
              chain.indices.contains(index),
              abs(chain[index].stageGain - newValue) > 0.0001 else {
            return
        }
        chain[index].stageGain = newValue
        pluginChainByTrack[selectedTrackKey] = chain
    }

    private func loadPersistedAudioUnits() async {
        guard !sharedRackManager.isSafeModeActive else {
            applyLivePreviewForAllTracks()
            return
        }
        guard !isLoadingPersistedPlugins else { return }

        let targets = pluginChainByTrack
            .flatMap { trackKey, chain in
                chain.filter { plugin in
                    guard plugin.source == .audioUnit else {
                        return false
                    }
                    let loadedKey = loadedAudioUnitKey(trackKey: trackKey, pluginID: plugin.id)
                    return loadedAudioUnits[loadedKey] == nil
                }
            }

        guard !targets.isEmpty else { return }

        let masterBus1Targets = targets.filter { plugin in
            pluginChainByTrack["masterBus1"]?.contains(where: { $0.id == plugin.id }) == true
        }.count
        NSLog("MKAudioProbe: loadPersistedAudioUnits targets=\(targets.count) masterBus1Targets=\(masterBus1Targets)")

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
        if pluginChainByTrack["sidetone"] == nil {
            applyLivePreviewForTrackKey("sidetone")
        }
        if pluginChainByTrack["masterBus1"] == nil {
            applyLivePreviewForTrackKey("masterBus1")
        }
        if pluginChainByTrack["masterBus2"] == nil {
            applyLivePreviewForTrackKey("masterBus2")
        }
    }

    private func applyLivePreviewForTrackKey(_ key: String) {
        syncAudioUnitDSPChainForTrackKey(key)
        let chain = pluginChainByTrack[key] ?? []
        let hasActivePlugins = !sharedRackManager.isSafeModeActive && chain.contains { !$0.bypassed }

        if key == "input" {
            let gain = Float(pluginInputTrackGain)
            let enabled = hasActivePlugins || abs(gain - 1.0) > 0.0001
            MKAudio.shared().setInputTrackPreviewGain(gain, enabled: enabled)
            return
        }
        if key == "masterBus1" {
            let gain = Float(pluginRemoteBusGain)
            let enabled = hasActivePlugins || abs(gain - 1.0) > 0.0001
            MKAudio.shared().setRemoteBusPreviewGain(gain, enabled: enabled)
            return
        }
        if key == "masterBus2" {
            let gain = Float(pluginRemoteBus2Gain)
            let enabled = hasActivePlugins || abs(gain - 1.0) > 0.0001
            MKAudio.shared().setRemoteBus2PreviewGain(gain, enabled: enabled)
            return
        }
        if let hash = parseRemoteUserHash(from: key), let session = hashToSession[hash] {
            let gain = Float(pluginRemoteTrackGain)
            let enabled = hasActivePlugins || abs(gain - 1.0) > 0.0001
            remoteTrackSettings[Int(session)] = (enabled: enabled, gain: Double(gain))
            MumbleLogger.plugin.debug("applyPreview remoteUser hash=\(hash) session=\(session) enabled=\(enabled) gain=\(gain) hasActivePlugins=\(hasActivePlugins)")
            MKAudio.shared().setRemoteTrackPreviewGain(gain, enabled: enabled, forSession: session)
        } else if key.hasPrefix("remoteUser:") {
            MumbleLogger.plugin.warning("applyPreview remoteUser SKIP key=\(key) — no session mapping")
        }
    }

    private func loadedProcessor(for trackKey: String, pluginID: String) -> AVAudioUnit? {
        let loadedKey = loadedAudioUnitKey(trackKey: trackKey, pluginID: pluginID)
        return loadedAudioUnits[loadedKey]
    }

    private func activeProcessorChain(for key: String) -> [NSDictionary] {
        guard !sharedRackManager.isSafeModeActive else { return [] }
        let chain = pluginChainByTrack[key] ?? []
        let validSidechainKeys = validSidechainRoutingKeys(forDestinationTrackKey: key)
        return chain
            .filter { !$0.bypassed }
            .compactMap { plugin in
                guard let processor = loadedProcessor(for: key, pluginID: plugin.id) else {
                    return nil
                }
                let mix = NSNumber(value: min(max(plugin.stageGain, 0.0), 1.0))
                var dict: [String: Any] = [
                    "audioUnit": processor,
                    "mix": mix
                ]
                if let sidechainSource = plugin.sidechainSourceKey,
                   !sidechainSource.isEmpty,
                   validSidechainKeys.contains(sidechainSource) {
                    dict["sidechainSource"] = sidechainSource
                }
                return dict as NSDictionary
            }
    }

    private func syncPluginHostBufferFrames() {
        MKAudio.shared().setPluginHostBufferFrames(UInt(max(pluginHostBufferFrames, 64)))
    }

    private func syncAudioUnitDSPChainForTrackKey(_ key: String) {
        if sharedRackManager.isSafeModeActive {
            if key == "input" {
                MKAudio.shared().setInputTrackAudioUnitChain([])
                return
            }
            if key == "sidetone" {
                MKAudio.shared().setSidetoneAudioUnitChain([])
                return
            }
            if key == "masterBus1" {
                MKAudio.shared().setRemoteBusAudioUnitChain([])
                return
            }
            if key == "masterBus2" {
                MKAudio.shared().setRemoteBus2AudioUnitChain([])
                return
            }
            if let hash = parseRemoteUserHash(from: key), let session = hashToSession[hash] {
                MKAudio.shared().setRemoteTrackAudioUnitChain([], forSession: session)
            }
            return
        }
        if key == "input" {
            MKAudio.shared().setInputTrackAudioUnitChain(activeProcessorChain(for: key))
            return
        }
        if key == "sidetone" {
            MKAudio.shared().setSidetoneAudioUnitChain(activeProcessorChain(for: key))
            return
        }
        if key == "masterBus1" {
            MKAudio.shared().setRemoteBusAudioUnitChain(activeProcessorChain(for: key))
            return
        }
        if key == "masterBus2" {
            MKAudio.shared().setRemoteBus2AudioUnitChain(activeProcessorChain(for: key))
            return
        }
        if let hash = parseRemoteUserHash(from: key), let session = hashToSession[hash] {
            let chain = activeProcessorChain(for: key)
            MumbleLogger.plugin.debug("syncDSP remoteUser hash=\(hash) session=\(session) chainCount=\(chain.count)")
            MKAudio.shared().setRemoteTrackAudioUnitChain(chain, forSession: session)
        } else {
            let hash = parseRemoteUserHash(from: key)
            MumbleLogger.plugin.warning("syncDSP remoteUser SKIP key=\(key) hash=\(hash ?? "nil") hashToSession has \(hashToSession.count) entries")
        }
    }

    private func parseRemoteUserHash(from key: String) -> String? {
        guard key.hasPrefix("remoteUser:") else { return nil }
        return String(key.dropFirst("remoteUser:".count))
    }

    private func routingSourceKey(forTrackKey key: String) -> String? {
        switch key {
        case "input", "sidetone", "masterBus1", "masterBus2":
            return key
        default:
            guard let hash = parseRemoteUserHash(from: key),
                  let session = hashToSession[hash] else {
                return nil
            }
            return "session:\(session)"
        }
    }

    private func trackCanSend(_ trackKey: String) -> Bool {
        trackKey != "masterBus1" && trackKey != "masterBus2" && trackKey != "sidetone"
    }

    private func isTrackSendEnabled(from sourceTrackKey: String, to destinationTrackKey: String) -> Bool {
        trackSendMode(from: sourceTrackKey, to: destinationTrackKey) != nil
    }

    private func trackSendMode(from sourceTrackKey: String, to destinationTrackKey: String) -> TrackSendMode? {
        trackSendRoutesBySource[sourceTrackKey]?.first(where: { $0.destination == destinationTrackKey })?.mode
    }

    private func incomingSendRoutes(forDestinationTrackKey trackKey: String,
                                    mode: TrackSendMode? = nil) -> [(source: String, mode: TrackSendMode)] {
        trackSendRoutesBySource
            .compactMap { sourceKey, routes in
                guard let route = routes.first(where: { $0.destination == trackKey }) else {
                    return nil
                }
                if let mode, route.mode != mode {
                    return nil
                }
                return (source: sourceKey, mode: route.mode)
            }
            .sorted { lhs, rhs in
                trackLabel(forTrackKey: lhs.source).localizedCaseInsensitiveCompare(trackLabel(forTrackKey: rhs.source)) == .orderedAscending
            }
    }

    private func availableSendDestinations(for sourceTrackKey: String) -> [String] {
        guard trackCanSend(sourceTrackKey) else { return [] }
        return allTrackKeys().filter {
            $0 != sourceTrackKey && isAllowedTrackSendRoute(from: sourceTrackKey, to: $0)
        }
    }

    private func trackLabel(forTrackKey trackKey: String) -> String {
        switch trackKey {
        case "input":
            return NSLocalizedString("Input Track", comment: "")
        case "sidetone":
            return NSLocalizedString("Sidetone Track", comment: "")
        case "masterBus1":
            return NSLocalizedString("Master Bus 1", comment: "")
        case "masterBus2":
            return NSLocalizedString("Master Bus 2", comment: "")
        default:
            if let hash = parseRemoteUserHash(from: trackKey) {
                return hearableUserName(for: hash)
            }
            return trackKey
        }
    }

    private func wouldCreateSendCycle(source sourceTrackKey: String, destination destinationTrackKey: String) -> Bool {
        guard sourceTrackKey != destinationTrackKey else { return true }

        var visited: Set<String> = []
        var pending: [String] = [destinationTrackKey]
        while let current = pending.popLast() {
            if current == sourceTrackKey {
                return true
            }
            if !visited.insert(current).inserted {
                continue
            }
            let audioTargets = (trackSendRoutesBySource[current] ?? [])
                .filter { $0.mode == .audio }
                .map(\.destination)
            pending.append(contentsOf: audioTargets)
        }
        return false
    }

    private func requiresMasterSendSelection(for trackKey: String) -> Bool {
        trackKey.hasPrefix("remoteUser:")
    }

    private func isMasterBusTrackKey(_ trackKey: String) -> Bool {
        trackKey == "masterBus1" || trackKey == "masterBus2"
    }

    private func isAllowedTrackSendRoute(from sourceTrackKey: String, to destinationTrackKey: String) -> Bool {
        if sourceTrackKey == "sidetone" {
            return false
        }
        if destinationTrackKey == "sidetone" {
            return sourceTrackKey == "input"
        }
        return true
    }

    private func wouldRemoveLastRequiredMasterSend(proposedMode: TrackSendMode?,
                                                   from sourceTrackKey: String,
                                                   to destinationTrackKey: String) -> Bool {
        guard requiresMasterSendSelection(for: sourceTrackKey),
              isMasterBusTrackKey(destinationTrackKey) else {
            return false
        }

        let currentMode = trackSendMode(from: sourceTrackKey, to: destinationTrackKey)
        guard currentMode == .audio, proposedMode != .audio else {
            return false
        }

        let currentMasterTargets = (trackSendRoutesBySource[sourceTrackKey] ?? [])
            .filter { $0.mode == .audio && isMasterBusTrackKey($0.destination) }
            .map(\.destination)
        return currentMasterTargets.count <= 1 && currentMasterTargets.contains(destinationTrackKey)
    }

    private func setTrackSendEnabled(_ enabled: Bool, from sourceTrackKey: String, to destinationTrackKey: String) {
        let targetMode: TrackSendMode? = enabled ? (trackSendMode(from: sourceTrackKey, to: destinationTrackKey) ?? .audio) : nil
        setTrackSendMode(targetMode, from: sourceTrackKey, to: destinationTrackKey)
    }

    private func setTrackSendMode(_ mode: TrackSendMode?, from sourceTrackKey: String, to destinationTrackKey: String) {
        guard trackCanSend(sourceTrackKey),
              sourceTrackKey != destinationTrackKey,
              isAllowedTrackSendRoute(from: sourceTrackKey, to: destinationTrackKey) else { return }
        if mode == .audio && wouldCreateSendCycle(source: sourceTrackKey, destination: destinationTrackKey) {
            return
        }
        if wouldRemoveLastRequiredMasterSend(proposedMode: mode,
                                             from: sourceTrackKey,
                                             to: destinationTrackKey) {
            return
        }

        let previousDestinations = Set(trackSendRoutesBySource[sourceTrackKey]?.map(\.destination) ?? [])
        AudioPluginRackManager.shared.setSendMode(mode, from: sourceTrackKey, to: destinationTrackKey)
        trackSendRoutesBySource = AudioPluginRackManager.shared.trackSendRoutesBySource
        let newDestinations = Set(trackSendRoutesBySource[sourceTrackKey]?.map(\.destination) ?? [])
        let affectedDestinations = previousDestinations.union(newDestinations).union([destinationTrackKey])
        syncSidetoneToggleFromTrackSends(sourceTrackKey: sourceTrackKey)
        syncAllTrackSendRouting()
        for destination in affectedDestinations {
            syncAudioUnitDSPChainForTrackKey(destination)
        }
    }

    private func syncTrackSendRoutingForTrackKey(_ key: String) {
        let incomingSources = incomingSendRoutes(forDestinationTrackKey: key, mode: .audio)
            .map(\.source)
            .compactMap(routingSourceKey(forTrackKey:))

        if key == "input" {
            MKAudio.shared().setInputTrackSendSourceKeys(incomingSources)
            return
        }
        if key == "sidetone" {
            MKAudio.shared().setSidetoneTrackSendSourceKeys(incomingSources)
            return
        }
        if key == "masterBus1" {
            MKAudio.shared().setRemoteBusSendSourceKeys(incomingSources)
            return
        }
        if key == "masterBus2" {
            MKAudio.shared().setRemoteBus2SendSourceKeys(incomingSources)
            return
        }
        if let hash = parseRemoteUserHash(from: key), let session = hashToSession[hash] {
            MKAudio.shared().setRemoteTrackSendSourceKeys(incomingSources, forSession: session)
        }
    }

    private func syncAllTrackSendRouting() {
        for key in allTrackKeys() {
            syncTrackSendRoutingForTrackKey(key)
        }
        syncInputTrackOutputRoutingMode()
        syncRemoteTrackOutputRoutingMode()
    }

    private func syncInputTrackOutputRoutingMode() {
        let targets = (trackSendRoutesBySource["input"] ?? [])
            .filter { $0.mode == .audio }
            .map(\.destination)
        var sendBusMask: UInt = 0
        if targets.contains("masterBus1") {
            sendBusMask |= 0x1
        }
        if targets.contains("masterBus2") {
            sendBusMask |= 0x2
        }
        MKAudio.shared().setInputTrackSendBusMask(sendBusMask)
    }

    private func syncRemoteTrackOutputRoutingMode() {
        for user in hearableUsers {
            let sourceKey = "remoteUser:\(user.id)"
            let targets = (trackSendRoutesBySource[sourceKey] ?? [])
                .filter { $0.mode == .audio }
                .map(\.destination)
            let usesTrackSendRouting = !targets.isEmpty
            var sendBusMask: UInt = 0
            if targets.contains("masterBus1") {
                sendBusMask |= 0x1
            }
            if targets.contains("masterBus2") {
                sendBusMask |= 0x2
            }
            MKAudio.shared().setRemoteTrackUsesSendRouting(usesTrackSendRouting, forSession: user.session)
            MKAudio.shared().setRemoteTrackSendBusMask(sendBusMask, forSession: user.session)
            MKAudio.shared().setBusAssignment(0, forSession: user.session)
        }
    }

    private func allTrackKeys() -> [String] {
        var keys: [String] = ["input", "sidetone", "masterBus1", "masterBus2"]
        keys.append(contentsOf: hearableUsers.map { "remoteUser:\($0.id)" })
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

    private func loadAudioUnit(for plugin: TrackPlugin) async -> Bool {
        guard !sharedRackManager.isSafeModeActive else {
            lastLoadErrorByPlugin[plugin.id] = NSLocalizedString("Safe Mode is active. Restart normally to load plugins.", comment: "")
            return false
        }
        guard plugin.source == .audioUnit else {
            pluginOperationMessage = NSLocalizedString("Only Audio Unit plugins can be loaded", comment: "")
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
            MumbleLogger.plugin.info("Plugin loaded: \(plugin.name) on trackKey=\(trackKey) loadedKey=\(loadedKey)")
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
        if sharedRackManager.isSafeModeActive {
            pluginOperationMessage = NSLocalizedString(
                "Safe Mode is active. Restart normally to load plugin editors.",
                comment: ""
            )
            return
        }
        selectedPluginID = plugin.id

        guard let trackKey = self.trackKey(containingPluginID: plugin.id) else {
            pluginOperationMessage = NSLocalizedString("Plugin not found in any track", comment: "")
            return
        }

        let pluginKey = "\(trackKey):\(plugin.id)"

        if let unit = loadedProcessor(for: trackKey, pluginID: plugin.id) {
            let targetPluginID = plugin.id
            let targetTrackKey = trackKey
            #if os(macOS)
            let sharedCachedController = PluginEditorWindowController.shared.cachedController(for: pluginKey)
            #else
            let sharedCachedController: PlatformViewController? = nil
            #endif
            if let cachedController = cachedPluginEditorControllers[pluginKey] ?? sharedCachedController {
                presentPluginEditor(controller: cachedController,
                                    pluginKey: pluginKey,
                                    pluginName: plugin.name,
                                    trackKey: targetTrackKey,
                                    pluginID: targetPluginID)
                return
            }
            unit.auAudioUnit.requestViewController { viewController in
                DispatchQueue.main.async {
                    guard let viewController else {
                        pluginOperationMessage = NSLocalizedString("Plugin UI is unavailable", comment: "")
                        return
                    }
                    cachedPluginEditorControllers[pluginKey] = viewController
                    #if os(macOS)
                    PluginEditorWindowController.shared.cacheController(viewController, for: pluginKey)
                    #endif
                    presentPluginEditor(controller: viewController,
                                        pluginKey: pluginKey,
                                        pluginName: plugin.name,
                                        trackKey: targetTrackKey,
                                        pluginID: targetPluginID)
                }
            }
        } else {
            pluginOperationMessage = NSLocalizedString("Plugin is not ready", comment: "")
            return
        }
    }

    private func presentPluginEditor(
        controller: PlatformViewController?,
        pluginKey: String,
        pluginName: String,
        trackKey: String,
        pluginID: String
    ) {
#if os(iOS)
        pluginEditorTitle = pluginName
        pluginEditorController = controller
        showingPluginEditor = true
#else
        let pluginSize = controller?.preferredContentSize ?? NSSize(width: 760, height: 540)
        let editorSize = NSSize(width: max(760, pluginSize.width), height: max(540, pluginSize.height + 49.0))
        PluginEditorWindowController.shared.show(
            pluginKey: pluginKey,
            rootView: AnyView(
                PluginEditorWindowContentView(
                    controller: controller,
                    snapshotProvider: { pluginEditorSnapshot(trackKey: trackKey, pluginID: pluginID) },
                    refreshAction: { refreshParameters(for: pluginID, trackKey: trackKey) },
                    parameterChangeAction: { parameterID, value in
                        setParameterValue(pluginID: pluginID, trackKey: trackKey, parameterID: parameterID, newValue: value)
                    },
                    sizeDidChange: { contentSize, minimumContentSize in
                        PluginEditorWindowController.shared.updateWindowSizing(
                            pluginKey: pluginKey,
                            contentSize: contentSize,
                            minimumContentSize: minimumContentSize
                        )
                    }
                )
            ),
            observedController: controller,
            preferredContentSize: editorSize,
            title: pluginName
        ) {
            snapshotAllPluginParameters()
            if selectedPluginID == pluginID {
                selectedPluginID = nil
            }
        }
#endif
    }

    private func pluginEditorWasOpen(for plugin: TrackPlugin, trackKey: String) -> Bool {
#if os(iOS)
        showingPluginEditor && selectedPluginID == plugin.id
#else
        PluginEditorWindowController.shared.isShowing(pluginKey: "\(trackKey):\(plugin.id)")
#endif
    }

    private func closePluginEditorIfNeeded(for plugin: TrackPlugin, trackKey: String) {
#if os(iOS)
        if showingPluginEditor && selectedPluginID == plugin.id {
            showingPluginEditor = false
            pluginEditorController = nil
            pluginEditorTitle = ""
        }
#else
        PluginEditorWindowController.shared.close(pluginKey: "\(trackKey):\(plugin.id)")
#endif
    }

    private func clearPluginEditorCache(for plugin: TrackPlugin, trackKey: String) {
        cachedPluginEditorControllers.removeValue(forKey: "\(trackKey):\(plugin.id)")
#if os(macOS)
        PluginEditorWindowController.shared.removeCachedController(for: "\(trackKey):\(plugin.id)")
#endif
    }

    private func unloadAudioUnit(for plugin: TrackPlugin) {
        if let trackKey = self.trackKey(containingPluginID: plugin.id) {
#if os(macOS)
            PluginEditorWindowController.shared.close(pluginKey: "\(trackKey):\(plugin.id)")
#endif
            clearPluginEditorCache(for: plugin, trackKey: trackKey)
            let loadedKey = loadedAudioUnitKey(trackKey: trackKey, pluginID: plugin.id)
            loadedAudioUnits[loadedKey] = nil
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

        if trackKey == "input" || trackKey == "sidetone" {
#if os(macOS)
            let stereoEnabled = UserDefaults.standard.bool(forKey: "AudioCaptureAllInputChannels")
                && UserDefaults.standard.bool(forKey: "AudioStereoInput")
            return stereoEnabled ? 2 : 1
#else
            return UserDefaults.standard.bool(forKey: "AudioStereoInput") ? 2 : 1
#endif
        }
        if trackKey == "masterBus1" || trackKey == "masterBus2" || trackKey.hasPrefix("remoteUser:") {
            return 2  // Stereo for master buses and user tracks
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

    private func isSharedManagedTrack(_ trackKey: String) -> Bool {
        !trackKey.hasPrefix("remoteUser:")
    }

    private func syncInputToSidetoneSend() {
        var routes = AudioPluginRackManager.shared.sendRoutes(forSourceTrackKey: "input")
            .filter { $0.destination != "sidetone" }
        if audioSidetoneEnabled {
            routes.append(TrackSendRoute(destination: "sidetone", mode: .audio))
        }
        AudioPluginRackManager.shared.setSendRoutes(routes, forSourceTrackKey: "input")
        trackSendRoutesBySource = AudioPluginRackManager.shared.trackSendRoutesBySource
    }

    private func syncSidetoneToggleFromTrackSends(sourceTrackKey: String) {
        guard sourceTrackKey == "input" else { return }
        let hasSidetoneSend = trackSendMode(from: "input", to: "sidetone") == .audio
        if audioSidetoneEnabled != hasSidetoneSend {
            audioSidetoneEnabled = hasSidetoneSend
        }
    }

    private func refreshSharedManagedTrackState() {
        syncLoadedStateFromSharedRackManager()
        loadSelectedTrackState()
        normalizeSelectedPluginSelection()
        rebuildProcessorStateMachine()
        syncAllTrackSendRouting()
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
        DispatchQueue.main.async {
            if let unit = loadedAudioUnits[loadedKey] {
                rebuildParameterState(pluginID: pluginID, unit: unit)
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

    private func parameterStateValue(pluginID: String, parameterID: UInt64, fallback: Float) -> Float {
        parameterStateByPlugin[pluginID]?.first(where: { $0.id == parameterID })?.value ?? fallback
    }

    private func setParameterValue(pluginID: String, parameterID: UInt64, newValue: Float) {
        setParameterValue(pluginID: pluginID, trackKey: selectedTrackKey, parameterID: parameterID, newValue: newValue)
    }

    private func setParameterValue(pluginID: String, trackKey: String, parameterID: UInt64, newValue: Float) {
        if isSharedManagedTrack(trackKey) {
            AudioPluginRackManager.shared.setParameterValue(
                trackKey: trackKey,
                pluginID: pluginID,
                parameterID: parameterID,
                newValue: newValue
            )
            if let sharedParameters = AudioPluginRackManager.shared.parameterStateByPlugin[pluginID] {
                parameterStateByPlugin[pluginID] = sharedParameters.map {
                    RuntimeParameter(
                        id: $0.id,
                        name: $0.name,
                        minValue: $0.minValue,
                        maxValue: $0.maxValue,
                        value: $0.value
                    )
                }
            }
            return
        }

        let loadedKey = loadedAudioUnitKey(trackKey: trackKey, pluginID: pluginID)
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
        updateSavedParameter(pluginID: pluginID, trackKey: trackKey, parameterID: parameterID, value: newValue)
    }

    private func updateSavedParameter(pluginID: String, trackKey: String, parameterID: UInt64, value: Float) {
        guard var chain = pluginChainByTrack[trackKey],
              let index = chain.firstIndex(where: { $0.id == pluginID }) else {
            return
        }
        chain[index].savedParameterValues[String(parameterID)] = value
        pluginChainByTrack[trackKey] = chain
        schedulePluginChainPersistence()
    }

    /// 从所有已加载的 AU 实例中抓取当前参数值，写入 savedParameterValues 并持久化。
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

    private func schedulePluginChainPersistence() {
        pendingPluginChainSaveWorkItem?.cancel()
        let workItem = DispatchWorkItem {
            savePluginChainState()
        }
        pendingPluginChainSaveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: workItem)
    }

    private func loadSelectedTrackState() {
        guard case .remoteUser(let hash) = selectedTrack, let session = hashToSession[hash] else {
            return
        }
        let trackState = remoteTrackSettings[Int(session)] ?? (enabled: false, gain: 1.0)
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

    private func refreshLiveTrackState(force: Bool = false) {
        if let manager = ServerModelManager.shared {
            listeningChannelIds = manager.listeningChannels
        }
        refreshRemoteSessionOrder(force: force)
    }

    private func refreshRemoteSessionOrder(force: Bool = false) {
        let sessions = MKAudio.shared().copyRemoteSessionOrder().map { $0.intValue }
        let didChange = sessions != remoteSessionOrder
        remoteSessionOrder = sessions
        refreshHearableUsers(force: force || didChange)
    }

    /// 从 ServerModelManager 同步当前监听频道（Mixer 独立窗口无 EnvironmentObject）
    private func initializeListeningChannels() {
        listeningChannelIds = ServerModelManager.shared?.listeningChannels ?? []
    }

    private func handleListeningChannelAdd(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let user = userInfo["user"] as? MKUser,
              let addChannels = userInfo["addChannels"] as? [NSNumber],
              user.session() == MUConnectionController.shared()?.serverModel?.connectedUser()?.session() else { return }
        for num in addChannels {
            listeningChannelIds.insert(num.uintValue)
        }
        refreshLiveTrackState(force: true)
    }

    private func handleListeningChannelRemove(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let user = userInfo["user"] as? MKUser,
              let removeChannels = userInfo["removeChannels"] as? [NSNumber],
              user.session() == MUConnectionController.shared()?.serverModel?.connectedUser()?.session() else { return }
        for num in removeChannels {
            listeningChannelIds.remove(num.uintValue)
        }
        refreshLiveTrackState(force: true)
    }

    /// 从 ServerModel 获取所有可听见的用户（同频道 + 监听频道），构建 session↔hash 映射
    private func refreshHearableUsers(force: Bool = false) {
        let previousSessions = Set(sessionToHash.keys)

        guard let serverModel = MUConnectionController.shared()?.serverModel,
              let connectedUser = serverModel.connectedUser() else {
            let hadUsers = !hearableUsers.isEmpty || !sessionToHash.isEmpty || !hashToSession.isEmpty
            hearableUsers = []
            sessionToHash = [:]
            hashToSession = [:]
            for session in previousSessions {
                MKAudio.shared().setRemoteTrackUsesSendRouting(false, forSession: session)
                MKAudio.shared().setRemoteTrackSendBusMask(0, forSession: session)
                MKAudio.shared().setBusAssignment(0, forSession: session)
            }
            if force || hadUsers {
                syncAllTrackSendRouting()
            }
            return
        }

        var users: [HearableUser] = []
        var newSessionToHash: [UInt: String] = [:]
        var newHashToSession: [String: UInt] = [:]
        var seen = Set<UInt>()

        let collectUsers: (MKChannel) -> Void = { channel in
            guard let userList = channel.users() as? [MKUser] else { return }
            for user in userList {
                let session = user.session()
                if session == connectedUser.session() { continue }
                guard !seen.contains(session) else { continue }
                seen.insert(session)
                let hash = user.userHash() ?? ""
                let stableKey = hash.isEmpty ? "session:\(session)" : hash
                let name = user.userName() ?? NSLocalizedString("Unknown", comment: "")
                users.append(HearableUser(id: stableKey, session: session, userName: name))
                newSessionToHash[session] = stableKey
                newHashToSession[stableKey] = session
            }
        }

        // 同频道用户
        if let myChannel = connectedUser.channel() {
            collectUsers(myChannel)
        }

        // 监听的频道用户
        for channelId in listeningChannelIds {
            if let channel = serverModel.channel(withId: channelId) {
                collectUsers(channel)
            }
        }

        let removedSessions = previousSessions.subtracting(newSessionToHash.keys)
        let usersChanged =
            force ||
            users != hearableUsers ||
            newSessionToHash != sessionToHash ||
            newHashToSession != hashToSession ||
            !removedSessions.isEmpty

        guard usersChanged else { return }

        hearableUsers = users
        sessionToHash = newSessionToHash
        hashToSession = newHashToSession

        for session in removedSessions {
            MKAudio.shared().setRemoteTrackUsesSendRouting(false, forSession: session)
            MKAudio.shared().setRemoteTrackSendBusMask(0, forSession: session)
            MKAudio.shared().setBusAssignment(0, forSession: session)
        }

        // 如果当前选中的用户轨已不在列表中，回到 input
        if case .remoteUser(let hash) = selectedTrack {
            if !users.contains(where: { $0.id == hash }) {
                selectedTrack = .input
            }
        }

        reconcileTrackSendDefaults()
        syncAllTrackSendRouting()
    }

    private func reconcileTrackSendDefaults() {
        let manager = AudioPluginRackManager.shared
        let activeRemoteTrackKeys = Set(hearableUsers.map { "remoteUser:\($0.id)" })
        var didChange = false

        for (sourceKey, routes) in manager.trackSendRoutesBySource {
            let sourceIsRemoteTrack = sourceKey.hasPrefix("remoteUser:")
            if sourceKey == "sidetone" || (sourceIsRemoteTrack && !activeRemoteTrackKeys.contains(sourceKey)) {
                manager.setSendRoutes([], forSourceTrackKey: sourceKey)
                didChange = true
                continue
            }

            let filteredRoutes = routes.filter { route in
                ((!route.destination.hasPrefix("remoteUser:")) || activeRemoteTrackKeys.contains(route.destination)) &&
                (route.destination != "sidetone" || (sourceKey == "input" && route.mode == .audio))
            }
            if filteredRoutes != routes {
                manager.setSendRoutes(filteredRoutes, forSourceTrackKey: sourceKey)
                didChange = true
            }
        }

        let currentInputRoutes = manager.sendRoutes(forSourceTrackKey: "input")
        let hasSidetoneSend = currentInputRoutes.contains { $0.destination == "sidetone" && $0.mode == .audio }
        if audioSidetoneEnabled != hasSidetoneSend {
            var normalizedInputRoutes = currentInputRoutes.filter { $0.destination != "sidetone" }
            if audioSidetoneEnabled {
                normalizedInputRoutes.append(TrackSendRoute(destination: "sidetone", mode: .audio))
            }
            manager.setSendRoutes(normalizedInputRoutes, forSourceTrackKey: "input")
            didChange = true
        }

        for user in hearableUsers {
            let sourceKey = "remoteUser:\(user.id)"
            let hasMasterAudioRoute = manager.sendRoutes(forSourceTrackKey: sourceKey)
                .contains { $0.mode == .audio && $0.destination == "masterBus1" }
            if !hasMasterAudioRoute && manager.sendRoutes(forSourceTrackKey: sourceKey).isEmpty {
                manager.setSendRoutes([TrackSendRoute(destination: "masterBus1", mode: .audio)], forSourceTrackKey: sourceKey)
                didChange = true
            }
        }

        if didChange {
            trackSendRoutesBySource = manager.trackSendRoutesBySource
        }
    }

    private func applyRemoteTrackPreview() {
        guard case .remoteUser(let hash) = selectedTrack, let session = hashToSession[hash] else { return }
        let trackKey = "remoteUser:\(hash)"
        let hasActivePlugins = (pluginChainByTrack[trackKey] ?? []).contains { !$0.bypassed }
        let gain = Float(pluginRemoteTrackGain)
        let enabled = hasActivePlugins || abs(gain - 1.0) > 0.0001
        remoteTrackSettings[Int(session)] = (enabled: enabled, gain: pluginRemoteTrackGain)
        MKAudio.shared().setRemoteTrackPreviewGain(gain, enabled: enabled, forSession: session)
    }

    private func hearableUserName(for hash: String) -> String {
        hearableUsers.first(where: { $0.id == hash })?.userName ?? hash.prefix(8).description
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

@MainActor
private final class PluginEditorMacSizeObserver: ObservableObject {
    @Published private(set) var contentSize: NSSize
    @Published private(set) var minimumContentSize: NSSize

    private weak var controller: NSViewController?
    private var preferredSizeObservation: NSKeyValueObservation?

    init(controller: NSViewController?) {
        self.controller = controller
        let initialSize = Self.resolveSize(for: controller)
        self.contentSize = initialSize
        self.minimumContentSize = initialSize

        guard let controller else { return }

        preferredSizeObservation = controller.observe(\.preferredContentSize, options: [.initial, .new]) { [weak self] controller, _ in
            DispatchQueue.main.async {
                self?.recordObservedSize(Self.resolveSize(for: controller))
            }
        }

        if let loadedView = controller.viewIfLoaded {
            loadedView.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleObservedViewFrameDidChange(_:)),
                name: NSView.frameDidChangeNotification,
                object: loadedView
            )
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private static func resolveSize(for controller: NSViewController?) -> NSSize {
        guard let controller else {
            return NSSize(width: 640, height: 420)
        }

        let preferred = controller.preferredContentSize
        if preferred.width > 10, preferred.height > 10 {
            return preferred
        }

        if let loadedView = controller.viewIfLoaded {
            let frame = loadedView.frame.size
            if frame.width > 10, frame.height > 10 {
                return frame
            }
        }

        return NSSize(width: 640, height: 420)
    }

    @objc private func handleObservedViewFrameDidChange(_ notification: Notification) {
        recordObservedSize(Self.resolveSize(for: controller))
    }

    private func recordObservedSize(_ size: NSSize) {
        contentSize = size
        minimumContentSize = NSSize(
            width: min(minimumContentSize.width, size.width),
            height: min(minimumContentSize.height, size.height)
        )
    }
}

private final class PluginEditorMacContainerViewController: NSViewController {
    private weak var embeddedController: NSViewController?

    override func loadView() {
        view = PluginEditorMacContainerView()
        view.translatesAutoresizingMaskIntoConstraints = false
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        focusEmbeddedPluginViewIfPossible()
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

        focusEmbeddedPluginViewIfPossible()
    }

    private func focusEmbeddedPluginViewIfPossible() {
        guard let childView = embeddedController?.view else { return }
        DispatchQueue.main.async { [weak self, weak childView] in
            guard let self, let childView else { return }
            self.view.window?.makeFirstResponder(childView)
        }
    }
}

private final class PluginEditorMacContainerView: NSView {
    override var acceptsFirstResponder: Bool { true }

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        window?.isMovableByWindowBackground = false
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
    let sizeDidChange: (NSSize, NSSize) -> Void

    @State private var selectedTab: Tab = .pluginUI
    @State private var snapshot: PluginEditorSnapshot
    @State private var liveParameterValues: [UInt64: Float] = [:]
    @State private var isEditingParameters = false
    @StateObject private var controllerSizeObserver: PluginEditorMacSizeObserver

    private let pluginEditorChromeHeight: CGFloat = 49.0
    private let parametersContentSize = NSSize(width: 640, height: 480)

    init(
        controller: NSViewController?,
        snapshotProvider: @escaping () -> PluginEditorSnapshot,
        refreshAction: @escaping () -> Void,
        parameterChangeAction: @escaping (UInt64, Float) -> Void,
        sizeDidChange: @escaping (NSSize, NSSize) -> Void
    ) {
        self.controller = controller
        self.snapshotProvider = snapshotProvider
        self.refreshAction = refreshAction
        self.parameterChangeAction = parameterChangeAction
        self.sizeDidChange = sizeDidChange
        _snapshot = State(initialValue: snapshotProvider())
        _controllerSizeObserver = StateObject(wrappedValue: PluginEditorMacSizeObserver(controller: controller))
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
                    .frame(
                        idealWidth: max(1, controllerSizeObserver.contentSize.width),
                        idealHeight: max(1, controllerSizeObserver.contentSize.height)
                    )
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
                                                liveParameterValues[parameter.id] = Float(newValue)
                                                parameterChangeAction(parameter.id, Float(newValue))
                                            }
                                        ),
                                        in: Double(parameter.minValue)...Double(parameter.maxValue),
                                        onEditingChanged: { editing in
                                            isEditingParameters = editing
                                            if !editing {
                                                refreshSnapshot()
                                            }
                                        }
                                    )
                                }
                            }
                        }
                    }
                    .padding(16)
                }
                .frame(minWidth: 520, idealWidth: parametersContentSize.width,
                       minHeight: 360, idealHeight: parametersContentSize.height)
            }
        }
        .onAppear {
            AppState.shared.setAutomationCurrentScreen("pluginEditor")
            if controller == nil {
                selectedTab = .parameters
            }
            refreshSnapshot()
            sizeDidChange(desiredWindowContentSize, minimumWindowContentSize)
        }
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in
            guard selectedTab == .parameters, !isEditingParameters else { return }
            refreshSnapshot()
        }
        .onChange(of: selectedTab) { _, _ in
            sizeDidChange(desiredWindowContentSize, minimumWindowContentSize)
        }
        .onChange(of: controllerSizeObserver.contentSize) { _, _ in
            guard selectedTab == .pluginUI else { return }
            sizeDidChange(desiredWindowContentSize, minimumWindowContentSize)
        }
        .onChange(of: controllerSizeObserver.minimumContentSize) { _, _ in
            guard selectedTab == .pluginUI else { return }
            sizeDidChange(desiredWindowContentSize, minimumWindowContentSize)
        }
    }

    private func refreshSnapshot() {
        refreshAction()
        snapshot = snapshotProvider()
        liveParameterValues = [:]
    }

    private func snapshotValue(for parameterID: UInt64, fallback: Float) -> Float {
        if let liveValue = liveParameterValues[parameterID] {
            return liveValue
        }
        return snapshot.parameters.first(where: { $0.id == parameterID })?.value ?? fallback
    }

    private var desiredWindowContentSize: NSSize {
        switch selectedTab {
        case .pluginUI:
            return NSSize(
                width: max(320, controllerSizeObserver.contentSize.width),
                height: max(180, controllerSizeObserver.contentSize.height + pluginEditorChromeHeight)
            )
        case .parameters:
            return parametersContentSize
        }
    }

    private var minimumWindowContentSize: NSSize {
        switch selectedTab {
        case .pluginUI:
            return NSSize(
                width: max(320, controllerSizeObserver.minimumContentSize.width),
                height: max(180, controllerSizeObserver.minimumContentSize.height + pluginEditorChromeHeight)
            )
        case .parameters:
            return NSSize(width: 520, height: 360)
        }
    }
}

@MainActor
final class PluginEditorWindowController: NSObject {
    static let shared = PluginEditorWindowController()

    private var windows: [String: NSWindow] = [:]
    private var closeHandlers: [String: () -> Void] = [:]
    private var sizeObservers: [String: NSKeyValueObservation] = [:]
    private var cachedControllers: [String: NSViewController] = [:]
    private var rememberedContentSizes: [String: NSSize] = [:]
    private var minimumContentSizes: [String: NSSize] = [:]
    private var rememberedMinimumContentSizes: [String: NSSize] = [:]

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
        let fittedSize = fittedContentSize(for: hostingController, fallback: targetSize)
        let restoredSize = rememberedContentSizes[pluginKey].map(normalizedSize(from:)) ?? fittedSize
        let minimumContentSize = rememberedMinimumContentSizes[pluginKey].map(normalizedSize(from:))
            ?? minimumContentSizes[pluginKey].map(normalizedSize(from:))
            ?? NSSize(width: 320, height: 180)

        if let window = windows[pluginKey] {
            window.title = title
            window.contentViewController = hostingController
            applyWindowSize(
                pluginKey: pluginKey,
                window: window,
                contentSize: restoredSize,
                minimumContentSize: minimumContentSize
            )
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
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.acceptsMouseMovedEvents = true
        window.isMovableByWindowBackground = false
        applyWindowSize(
            pluginKey: pluginKey,
            window: window,
            contentSize: restoredSize,
            minimumContentSize: minimumContentSize
        )
        window.center()
        window.isReleasedWhenClosed = false
        windows[pluginKey] = window
        closeHandlers[pluginKey] = onClose
        if let observedController {
            installSizeObserver(for: pluginKey, controller: observedController)
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePluginEditorWindowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePluginEditorWindowDidResize(_:)),
            name: NSWindow.didResizeNotification,
            object: window
        )
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close(pluginKey: String) {
        if let window = windows.removeValue(forKey: pluginKey) {
            closeHandlers.removeValue(forKey: pluginKey)
            sizeObservers.removeValue(forKey: pluginKey)
            rememberedContentSizes[pluginKey] = currentContentSize(for: window)
            if let minimumContentSize = minimumContentSizes[pluginKey] {
                rememberedMinimumContentSizes[pluginKey] = minimumContentSize
            }
            window.close()
        }
    }

    func isShowing(pluginKey: String) -> Bool {
        windows[pluginKey] != nil
    }

    func cachedController(for pluginKey: String) -> NSViewController? {
        cachedControllers[pluginKey]
    }

    func cacheController(_ controller: NSViewController, for pluginKey: String) {
        cachedControllers[pluginKey] = controller
    }

    func removeCachedController(for pluginKey: String) {
        cachedControllers.removeValue(forKey: pluginKey)
    }

    private func normalizedSize(from preferred: NSSize) -> NSSize {
        let width = preferred.width > 10 ? preferred.width : 960
        let height = preferred.height > 10 ? preferred.height : 620
        return NSSize(width: max(320, width), height: max(180, height))
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
        rememberedContentSizes[pluginKey] = currentContentSize(for: closing)
        if let minimumContentSize = minimumContentSizes[pluginKey] {
            rememberedMinimumContentSizes[pluginKey] = minimumContentSize
        }
        windows.removeValue(forKey: pluginKey)
        let handler = closeHandlers.removeValue(forKey: pluginKey)
        sizeObservers.removeValue(forKey: pluginKey)
        handler?()
    }

    @objc private func handlePluginEditorWindowDidResize(_ notification: Notification) {
        guard let resizedWindow = notification.object as? NSWindow,
              let pluginKey = windows.first(where: { $0.value == resizedWindow })?.key else { return }
        rememberedContentSizes[pluginKey] = currentContentSize(for: resizedWindow)
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
        let minimum = minimumContentSizes[pluginKey] ?? normalized
        applyWindowSize(pluginKey: pluginKey, window: window, contentSize: normalized, minimumContentSize: minimum)
    }

    func updateWindowSizing(pluginKey: String, contentSize: NSSize, minimumContentSize: NSSize) {
        let normalizedMinimum = normalizedSize(from: minimumContentSize)
        minimumContentSizes[pluginKey] = normalizedMinimum
        rememberedMinimumContentSizes[pluginKey] = normalizedMinimum
        guard let window = windows[pluginKey] else { return }
        let effectiveMinimum = minimumContentSizes[pluginKey] ?? normalizedMinimum
        applyWindowSize(
            pluginKey: pluginKey,
            window: window,
            contentSize: contentSize,
            minimumContentSize: effectiveMinimum
        )
    }

    private func applyWindowSize(pluginKey _: String, window: NSWindow, contentSize: NSSize, minimumContentSize: NSSize) {
        let normalizedMinimum = normalizedSize(from: minimumContentSize)
        let normalizedContent = normalizedSize(from: contentSize)
        let clamped = NSSize(
            width: max(normalizedMinimum.width, normalizedContent.width),
            height: max(normalizedMinimum.height, normalizedContent.height)
        )
        window.minSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: normalizedMinimum)).size
        resize(window: window, to: clamped)
    }

    private func fittedContentSize(for hostingController: NSHostingController<AnyView>, fallback: NSSize) -> NSSize {
        hostingController.view.layoutSubtreeIfNeeded()
        let fitting = hostingController.view.fittingSize
        if fitting.width > 10, fitting.height > 10 {
            return normalizedSize(from: fitting)
        }
        return normalizedSize(from: fallback)
    }

    private func currentContentSize(for window: NSWindow) -> NSSize {
        let contentRect = window.contentRect(forFrameRect: window.frame)
        return normalizedSize(from: contentRect.size)
    }
}
#endif

// MARK: - MixerSheetsModifier（拆分 body 以减轻 type-checker 压力）

private struct MixerSheetsModifier<BrowserSheet: View>: ViewModifier {
    @Binding var showingPluginBrowser: Bool
    @Binding var showingPluginEditor: Bool
    let pluginEditorController: PlatformViewController?
    let pluginEditorTitle: String
    @ViewBuilder let pluginBrowserSheet: () -> BrowserSheet
    let onPluginEditorDismiss: () -> Void

    func body(content: Content) -> some View {
        content
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
            }
#endif
            .sheet(isPresented: $showingPluginBrowser) {
                pluginBrowserSheet()
            }
#if os(iOS)
            .onChange(of: showingPluginEditor) {
                if !showingPluginEditor {
                    onPluginEditorDismiss()
                }
            }
#endif
            .onChange(of: showingPluginBrowser) { _, isPresented in
                if isPresented {
                    AppState.shared.setAutomationPresentedSheet("pluginBrowser")
                } else {
                    AppState.shared.clearAutomationPresentedSheet(ifMatches: "pluginBrowser")
                }
            }
#if os(iOS)
            .onChange(of: showingPluginEditor) { _, isPresented in
                if isPresented {
                    AppState.shared.setAutomationPresentedSheet("pluginEditor")
                } else {
                    AppState.shared.clearAutomationPresentedSheet(ifMatches: "pluginEditor")
                }
            }
#endif
    }
}
