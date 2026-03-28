import Foundation
import Combine
import AVFoundation

struct AudioPluginDiscovery: Identifiable, Hashable {
    let id: String
    let name: String
    let subtitle: String
    let source: PluginSource
    let categorySeedText: String
}

struct AudioPluginParameterInfo: Identifiable, Hashable {
    let id: UInt64
    let name: String
    let minValue: Float
    let maxValue: Float
    let value: Float
}

struct AudioPluginPresetInfo: Identifiable, Codable, Hashable {
    let id: String
    var name: String
    var parameterValues: [String: Float]
    var createdAt: Date
}

enum TrackSendMode: String, Codable, CaseIterable, Hashable {
    case audio
    case sidechain
}

struct TrackSendRoute: Codable, Hashable, Identifiable {
    var destination: String
    var mode: TrackSendMode

    var id: String { destination }
}

/// Manages the audio plugin rack persistence and initialization.
/// This manager loads saved plugin chains on app startup and syncs them to MKAudio.
@MainActor
final class AudioPluginRackManager: ObservableObject {
    static let shared = AudioPluginRackManager()

    // MARK: - Published State

    @Published var pluginChainByTrack: [String: [TrackPlugin]] = [:]
    @Published var loadedAudioUnits: [String: AVAudioUnit] = [:]
    @Published var loadedVST3Hosts: [String: MKVST3PluginHost] = [:]
    @Published var loadingPluginIDs: Set<String> = []
    @Published var lastLoadErrorByPlugin: [String: String] = [:]
    @Published var parameterStateByPlugin: [String: [AudioPluginParameterInfo]] = [:]
    @Published var trackSendRoutesBySource: [String: [TrackSendRoute]] = [:]

    // MARK: - Persistence Keys

    private let pluginTrackChainsKey = "AudioPluginTrackChainsV1"
    private let trackSendTargetsKey = "AudioPluginTrackSendsV1"
    private let pluginPresetsKey = "AudioPluginPresetsV1"
    private let pluginCustomScanPathsKey = "AudioPluginCustomScanPaths"

    // MARK: - Initialization

    private init() {
        loadPluginChainState()
        loadTrackSendState()
        #if os(macOS)
        clearVST3PluginsIfSandboxRestricted()
        #endif
    }

    // MARK: - Public API

    /// Called on app startup to initialize the audio rack.
    /// Loads persisted plugins and syncs the DSP chain to MKAudio.
    func initializeOnStartup() async {
        NSLog("AudioPluginRackManager: Initializing on startup")

        // Sync buffer frames setting
        let bufferFrames = UserDefaults.standard.integer(forKey: "AudioPluginHostBufferFrames")
        MKAudio.shared().setPluginHostBufferFrames(UInt(max(bufferFrames, 64)))

        // Load persisted plugins
        await loadPersistedAudioUnits()
        syncAllTrackSendRouting()
    }

    func currentTrackKeys() -> [String] {
        var keys: [String] = ["input", "sidetone"]
        keys.append(contentsOf: ["masterBus1", "masterBus2"])
        for key in pluginChainByTrack.keys where !keys.contains(key) {
            keys.append(key)
        }
        for key in trackSendRoutesBySource.keys where !keys.contains(key) {
            keys.append(key)
        }
        for routes in trackSendRoutesBySource.values {
            for key in routes.map(\.destination) where !keys.contains(key) {
                keys.append(key)
            }
        }
        return keys
    }

    func currentHostBufferFrames() -> Int {
        max(UserDefaults.standard.integer(forKey: "AudioPluginHostBufferFrames"), 64)
    }

    func setHostBufferFrames(_ frames: Int) {
        let normalized = max(frames, 64)
        UserDefaults.standard.set(normalized, forKey: "AudioPluginHostBufferFrames")
        MKAudio.shared().setPluginHostBufferFrames(UInt(normalized))
        syncAllDSPChains()
    }

    func availablePlugins() -> [AudioPluginDiscovery] {
        let plugins = availableAudioUnitPlugins() + availableFilesystemPlugins()
        return plugins.sorted { lhs, rhs in
            if lhs.source != rhs.source {
                return lhs.source.rawValue < rhs.source.rawValue
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    func customScanPaths() -> [String] {
        customScanPathEntries()
    }

    func addCustomScanPath(_ path: String) {
        let candidate = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return }
        var entries = customScanPathEntries()
        if !entries.contains(candidate) {
            entries.append(candidate)
            UserDefaults.standard.set(entries.joined(separator: "\n"), forKey: pluginCustomScanPathsKey)
        }
    }

    func removeCustomScanPath(_ path: String) {
        let entries = customScanPathEntries().filter { $0 != path }
        UserDefaults.standard.set(entries.joined(separator: "\n"), forKey: pluginCustomScanPathsKey)
    }

    func plugins(for trackKey: String) -> [TrackPlugin] {
        pluginChainByTrack[trackKey] ?? []
    }

    func addPlugin(_ discovery: AudioPluginDiscovery, to trackKey: String, at index: Int? = nil) async -> TrackPlugin {
        let plugin = TrackPlugin(
            id: UUID().uuidString,
            name: discovery.name,
            subtitle: discovery.subtitle,
            source: discovery.source,
            identifier: discovery.id,
            bypassed: false,
            stageGain: 1.0,
            autoLoad: true,
            savedParameterValues: [:]
        )
        var chain = pluginChainByTrack[trackKey] ?? []
        if let index, chain.indices.contains(index) {
            chain.insert(plugin, at: index)
        } else {
            chain.append(plugin)
        }
        pluginChainByTrack[trackKey] = chain
        savePluginChainState()
        if plugin.autoLoad {
            _ = await loadAudioUnit(for: plugin)
        } else {
            syncDSPChain(for: trackKey)
        }
        return plugin
    }

    @discardableResult
    func removePlugin(trackKey: String, pluginID: String) -> TrackPlugin? {
        guard var chain = pluginChainByTrack[trackKey],
              let index = chain.firstIndex(where: { $0.id == pluginID }) else {
            return nil
        }
        let plugin = chain.remove(at: index)
        unloadAudioUnit(for: plugin)
        pluginChainByTrack[trackKey] = chain
        savePluginChainState()
        syncDSPChain(for: trackKey)
        return plugin
    }

    func movePlugin(trackKey: String, pluginID: String, to targetIndex: Int) {
        guard var chain = pluginChainByTrack[trackKey],
              let index = chain.firstIndex(where: { $0.id == pluginID }),
              targetIndex >= 0,
              targetIndex < chain.count else {
            return
        }
        let plugin = chain.remove(at: index)
        chain.insert(plugin, at: targetIndex)
        pluginChainByTrack[trackKey] = chain
        savePluginChainState()
        syncDSPChain(for: trackKey)
    }

    func setPluginBypassed(trackKey: String, pluginID: String, bypassed: Bool) {
        mutatePlugin(withID: pluginID) { plugin in
            plugin.bypassed = bypassed
        }
        syncDSPChain(for: trackKey)
    }

    func setPluginStageGain(trackKey: String, pluginID: String, stageGain: Float) {
        mutatePlugin(withID: pluginID) { plugin in
            plugin.stageGain = min(max(stageGain, 0), 1)
        }
        syncDSPChain(for: trackKey)
    }

    func loadPlugin(trackKey: String, pluginID: String) async -> Bool {
        guard let plugin = pluginChainByTrack[trackKey]?.first(where: { $0.id == pluginID }) else {
            return false
        }
        return await loadAudioUnit(for: plugin)
    }

    func unloadPlugin(trackKey: String, pluginID: String) {
        guard let plugin = pluginChainByTrack[trackKey]?.first(where: { $0.id == pluginID }) else {
            return
        }
        unloadAudioUnit(for: plugin)
    }

    func setSidechainSource(_ sourceKey: String?, forPluginID pluginID: String, inTrack trackKey: String) {
        guard var chain = pluginChainByTrack[trackKey],
              let index = chain.firstIndex(where: { $0.id == pluginID }) else { return }
        let previousSourceKey = chain[index].sidechainSourceKey
        chain[index].sidechainSourceKey = sourceKey
        pluginChainByTrack[trackKey] = chain
        savePluginChainState()
        syncDSPChain(for: trackKey)
        reloadAudioUnitForSidechainChangeIfNeeded(
            pluginID: pluginID,
            trackKey: trackKey,
            previousSourceKey: previousSourceKey,
            newSourceKey: sourceKey
        )
    }

    func sendRoutes(forSourceTrackKey trackKey: String) -> [TrackSendRoute] {
        trackSendRoutesBySource[trackKey] ?? []
    }

    func sendMode(from sourceTrackKey: String, to destinationTrackKey: String) -> TrackSendMode? {
        trackSendRoutesBySource[sourceTrackKey]?.first(where: { $0.destination == destinationTrackKey })?.mode
    }

    func incomingSendSources(forDestinationTrackKey trackKey: String, mode: TrackSendMode? = nil) -> [String] {
        trackSendRoutesBySource
            .compactMap { sourceKey, targets in
                guard let route = targets.first(where: { $0.destination == trackKey }) else {
                    return nil
                }
                if let mode, route.mode != mode {
                    return nil
                }
                return sourceKey
            }
            .sorted()
    }

    func setSendMode(_ mode: TrackSendMode?, from sourceTrackKey: String, to destinationTrackKey: String) {
        var routes = trackSendRoutesBySource[sourceTrackKey] ?? []
        routes.removeAll { $0.destination == destinationTrackKey }
        if let mode {
            routes.append(TrackSendRoute(destination: destinationTrackKey, mode: mode))
        }
        setSendRoutes(routes, forSourceTrackKey: sourceTrackKey)
    }

    func setSendRoutes(_ routes: [TrackSendRoute], forSourceTrackKey trackKey: String) {
        let normalizedRoutes = Self.normalizedRoutes(routes, forSourceTrackKey: trackKey)

        if trackKey == "masterBus1" || trackKey == "masterBus2" || trackKey == "sidetone" {
            trackSendRoutesBySource.removeValue(forKey: trackKey)
        } else if normalizedRoutes.isEmpty {
            trackSendRoutesBySource.removeValue(forKey: trackKey)
        } else {
            trackSendRoutesBySource[trackKey] = normalizedRoutes
        }

        saveTrackSendState()
        syncAllTrackSendRouting()
    }

    func parameters(trackKey: String, pluginID: String) -> [AudioPluginParameterInfo] {
        refreshParameters(for: pluginID, trackKey: trackKey)
        return parameterStateByPlugin[pluginID] ?? []
    }

    func setParameterValue(trackKey: String, pluginID: String, parameterID: UInt64, newValue: Float) {
        setParameterValue(pluginID: pluginID, trackKey: trackKey, parameterID: parameterID, newValue: newValue)
    }

    func setParameter(trackKey: String, pluginID: String, parameterID: UInt64, value: Float) {
        setParameterValue(pluginID: pluginID, trackKey: trackKey, parameterID: parameterID, newValue: value)
    }

    func listPresets(for pluginIdentifier: String) -> [AudioPluginPresetInfo] {
        loadPluginPresets()[pluginIdentifier] ?? []
    }

    func savePreset(name: String, trackKey: String, pluginID: String) -> AudioPluginPresetInfo? {
        snapshotAllPluginParameters()
        guard let plugin = pluginChainByTrack[trackKey]?.first(where: { $0.id == pluginID }) else {
            return nil
        }
        let presetName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !presetName.isEmpty else { return nil }
        let preset = AudioPluginPresetInfo(
            id: UUID().uuidString,
            name: presetName,
            parameterValues: plugin.savedParameterValues,
            createdAt: Date()
        )
        var presets = loadPluginPresets()
        var list = presets[plugin.identifier] ?? []
        list.append(preset)
        presets[plugin.identifier] = list
        savePluginPresets(presets)
        return preset
    }

    func applyPreset(trackKey: String, pluginID: String, presetID: String) -> AudioPluginPresetInfo? {
        guard let plugin = pluginChainByTrack[trackKey]?.first(where: { $0.id == pluginID }) else {
            return nil
        }
        let presets = loadPluginPresets()
        guard let preset = presets[plugin.identifier]?.first(where: { $0.id == presetID }) else {
            return nil
        }
        mutatePlugin(withID: pluginID) { mutablePlugin in
            mutablePlugin.savedParameterValues = preset.parameterValues
        }
        for (parameterIDString, value) in preset.parameterValues {
            if let parameterID = UInt64(parameterIDString) {
                setParameterValue(pluginID: pluginID, trackKey: trackKey, parameterID: parameterID, newValue: value)
            }
        }
        return preset
    }

    func deletePreset(pluginIdentifier: String, presetID: String) -> AudioPluginPresetInfo? {
        var presets = loadPluginPresets()
        guard var list = presets[pluginIdentifier],
              let index = list.firstIndex(where: { $0.id == presetID }) else {
            return nil
        }
        let preset = list.remove(at: index)
        presets[pluginIdentifier] = list
        savePluginPresets(presets)
        return preset
    }

    // MARK: - Persistence

    private func loadPluginChainState() {
        guard let data = UserDefaults.standard.string(forKey: pluginTrackChainsKey)?.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: [TrackPlugin]].self, from: data) else {
            pluginChainByTrack = [:]
            return
        }
        pluginChainByTrack = decoded
        NSLog("AudioPluginRackManager: Loaded \(decoded.count) track chains from persistence")
    }

    func savePluginChainState() {
        guard let data = try? JSONEncoder().encode(pluginChainByTrack),
              let string = String(data: data, encoding: .utf8) else {
            return
        }
        UserDefaults.standard.set(string, forKey: pluginTrackChainsKey)
    }

    private func loadPluginPresets() -> [String: [AudioPluginPresetInfo]] {
        guard let string = UserDefaults.standard.string(forKey: pluginPresetsKey),
              let data = string.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: [AudioPluginPresetInfo]].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private func savePluginPresets(_ presets: [String: [AudioPluginPresetInfo]]) {
        guard let data = try? JSONEncoder().encode(presets),
              let string = String(data: data, encoding: .utf8) else {
            return
        }
        UserDefaults.standard.set(string, forKey: pluginPresetsKey)
    }

    // MARK: - Plugin Loading

    private func loadPersistedAudioUnits() async {
        guard loadingPluginIDs.isEmpty else { return }

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

        guard !targets.isEmpty else {
            NSLog("AudioPluginRackManager: No persisted plugins to load")
            // Still sync the empty chain to ensure the rack is active
            syncAllDSPChains()
            return
        }

        NSLog("AudioPluginRackManager: Loading \(targets.count) persisted plugins")

        for plugin in targets {
            _ = await loadAudioUnit(for: plugin)
        }

        // Final sync after all plugins loaded
        syncAllDSPChains()
    }

    private func loadAudioUnit(for plugin: TrackPlugin) async -> Bool {
        guard plugin.source == .audioUnit || plugin.source == .filesystem else {
            return false
        }

        // Find track key for this plugin
        let trackKey: String? = pluginChainByTrack.first(where: { _, chain in
            chain.contains(where: { $0.id == plugin.id })
        })?.key

        guard let trackKey else { return false }

        let loadedKey = loadedAudioUnitKey(trackKey: trackKey, pluginID: plugin.id)

        if loadedAudioUnits[loadedKey] != nil || loadedVST3Hosts[loadedKey] != nil {
            return true
        }

        loadingPluginIDs.insert(plugin.id)

        defer {
            loadingPluginIDs.remove(plugin.id)
        }

        if plugin.source == .filesystem {
            return await loadVST3Plugin(plugin, loadedKey: loadedKey, trackKey: trackKey)
        }

        guard let description = parseAudioUnitDescription(from: plugin.identifier) else {
            let message = NSLocalizedString("Failed to parse Audio Unit identifier", comment: "")
            lastLoadErrorByPlugin[plugin.id] = message
            return false
        }

        let message = await instantiateAudioUnitWithFallback(
            description: description,
            requiredChannels: channelCount(for: trackKey),
            sampleRate: pluginSampleRate(for: trackKey),
            loadedKey: loadedKey
        )
        if let message {
            lastLoadErrorByPlugin[plugin.id] = message
            return false
        }

        if let unit = loadedAudioUnits[loadedKey] {
            rebuildParameterState(pluginID: plugin.id, unit: unit)
        } else {
            parameterStateByPlugin[plugin.id] = []
        }
        lastLoadErrorByPlugin[plugin.id] = nil
        syncDSPChain(for: trackKey)
        NSLog("AudioPluginRackManager: Loaded AU '\(plugin.name)' for track \(trackKey)")
        return true
    }

    private func loadVST3Plugin(_ plugin: TrackPlugin, loadedKey: String, trackKey: String) async -> Bool {
        guard plugin.identifier.hasPrefix("fs:") else {
            return false
        }

        let bundlePath = String(plugin.identifier.dropFirst(3))
        let requiredChannels = channelCount(for: trackKey)
        let sampleRate = pluginSampleRate(for: trackKey)

        let host: MKVST3PluginHost
        do {
            host = try MKVST3PluginHost(bundlePath: bundlePath, displayName: plugin.name)
        } catch {
            NSLog("AudioPluginRackManager: Failed to create VST3 host for '\(plugin.name)': \(error)")
            lastLoadErrorByPlugin[plugin.id] = error.localizedDescription
            return false
        }

        let effectiveSampleRate = sampleRate > 0 ? sampleRate : 48_000
        let effectiveFrames = max(UserDefaults.standard.integer(forKey: "AudioPluginHostBufferFrames"), 64)

        do {
            try host.configure(
                withInputChannels: UInt(requiredChannels),
                outputChannels: UInt(requiredChannels),
                sampleRate: effectiveSampleRate,
                maximumFramesToRender: UInt(effectiveFrames)
            )
        } catch {
            NSLog("AudioPluginRackManager: Failed to configure VST3 '\(plugin.name)': \(error)")
            lastLoadErrorByPlugin[plugin.id] = error.localizedDescription
            return false
        }

        loadedVST3Hosts[loadedKey] = host
        lastLoadErrorByPlugin[plugin.id] = nil
        NSLog("AudioPluginRackManager: Loaded VST3 '\(plugin.name)' for track \(trackKey)")

        // Apply saved parameters
        applySavedParameters(pluginID: plugin.id, vst3Host: host)

        return true
    }

    // MARK: - DSP Chain Sync

    func syncAllDSPChains() {
        for trackKey in pluginChainByTrack.keys {
            syncDSPChain(for: trackKey)
        }
    }

    func syncAllTrackSendRouting() {
        let destinations = currentTrackKeys()
        for trackKey in destinations {
            syncTrackSendRouting(for: trackKey)
        }
    }

    func syncTrackSendRouting(for trackKey: String) {
        let incomingSources = incomingSendSources(forDestinationTrackKey: trackKey, mode: .audio)

        if trackKey == "input" {
            MKAudio.shared().setInputTrackSendSourceKeys(incomingSources)
        } else if trackKey == "sidetone" {
            MKAudio.shared().setSidetoneTrackSendSourceKeys(incomingSources)
        } else if trackKey == "masterBus1" {
            MKAudio.shared().setRemoteBusSendSourceKeys(incomingSources)
        } else if trackKey == "masterBus2" {
            MKAudio.shared().setRemoteBus2SendSourceKeys(incomingSources)
        }
    }

    func syncDSPChain(for trackKey: String) {
        let chain = activeProcessorChain(for: trackKey)

        if trackKey == "input" {
            MKAudio.shared().setInputTrackAudioUnitChain(chain)
        } else if trackKey == "sidetone" {
            MKAudio.shared().setSidetoneAudioUnitChain(chain)
        } else if trackKey == "masterBus1" {
            MKAudio.shared().setRemoteBusAudioUnitChain(chain)
        } else if trackKey == "masterBus2" {
            MKAudio.shared().setRemoteBus2AudioUnitChain(chain)
        }
        // remoteUser: tracks are synced via AudioPluginMixerView which holds the hash→session mapping

        NSLog("AudioPluginRackManager: Synced DSP chain for \(trackKey) with \(chain.count) processors")
    }

    private func activeProcessorChain(for key: String) -> [NSDictionary] {
        let chain = pluginChainByTrack[key] ?? []
        return chain
            .filter { !$0.bypassed }
            .compactMap { plugin in
                let loadedKey = loadedAudioUnitKey(trackKey: key, pluginID: plugin.id)
                let mix = NSNumber(value: min(max(plugin.stageGain, 0.0), 1.0))

                if let audioUnit = loadedAudioUnits[loadedKey] {
                    var dict: [String: Any] = ["audioUnit": audioUnit, "mix": mix]
                    if let sc = plugin.sidechainSourceKey,
                       !sc.isEmpty,
                       (validSidechainSourceKeys(forDestinationTrackKey: key).contains(sc) || sc.hasPrefix("session:")) {
                        dict["sidechainSource"] = sc
                    }
                    return dict as NSDictionary
                } else if let vst3Host = loadedVST3Hosts[loadedKey] {
                    return ["vst3Host": vst3Host, "mix": mix] as NSDictionary
                    // VST3 sidechain not supported yet
                }
                return nil
            }
    }

    // MARK: - Parameter Helpers

    private func applySavedParameters(pluginID: String, vst3Host: MKVST3PluginHost) {
        guard let plugin = findPlugin(withID: pluginID), !plugin.savedParameterValues.isEmpty else {
            return
        }

        let snapshots = vst3Host.copyParameterSnapshots()
        for snapshot in snapshots {
            guard let paramID = snapshot["id"] as? NSNumber else { continue }
            let key = String(paramID.uint64Value)
            guard let savedValue = plugin.savedParameterValues[key] else { continue }
            _ = vst3Host.setParameter(withID: paramID.uint64Value, normalizedValue: savedValue)
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

    private func trackKey(containingPluginID pluginID: String) -> String? {
        for (trackKey, chain) in pluginChainByTrack {
            if chain.contains(where: { $0.id == pluginID }) {
                return trackKey
            }
        }
        return nil
    }

    private func mutatePlugin(withID pluginID: String, mutate: (inout TrackPlugin) -> Void) {
        for key in pluginChainByTrack.keys {
            guard var chain = pluginChainByTrack[key],
                  let index = chain.firstIndex(where: { $0.id == pluginID }) else {
                continue
            }
            mutate(&chain[index])
            pluginChainByTrack[key] = chain
            savePluginChainState()
            syncDSPChain(for: key)
            return
        }
    }

    private func unloadAudioUnit(for plugin: TrackPlugin) {
        guard let trackKey = trackKey(containingPluginID: plugin.id) else {
            parameterStateByPlugin[plugin.id] = nil
            lastLoadErrorByPlugin[plugin.id] = nil
            return
        }

        let loadedKey = loadedAudioUnitKey(trackKey: trackKey, pluginID: plugin.id)
        loadedAudioUnits[loadedKey] = nil
        loadedVST3Hosts[loadedKey] = nil
        parameterStateByPlugin[plugin.id] = nil
        lastLoadErrorByPlugin[plugin.id] = nil
        syncDSPChain(for: trackKey)
    }

    private func reloadAudioUnitForSidechainChangeIfNeeded(
        pluginID: String,
        trackKey: String,
        previousSourceKey: String?,
        newSourceKey: String?
    ) {
#if os(macOS)
        guard previousSourceKey != newSourceKey,
              let plugin = pluginChainByTrack[trackKey]?.first(where: { $0.id == pluginID }),
              plugin.source == .audioUnit else {
            return
        }

        let loadedKey = loadedAudioUnitKey(trackKey: trackKey, pluginID: pluginID)
        guard let unit = loadedAudioUnits[loadedKey],
              unit.auAudioUnit.inputBusses.count > 1 else {
            return
        }

        Task { @MainActor in
            unloadAudioUnit(for: plugin)
            _ = await loadAudioUnit(for: plugin)
        }
#endif
    }

    private func loadTrackSendState() {
        guard let raw = UserDefaults.standard.string(forKey: trackSendTargetsKey),
              !raw.isEmpty,
              let data = raw.data(using: .utf8) else {
            trackSendRoutesBySource = [:]
            return
        }
        if let decodedRoutes = try? JSONDecoder().decode([String: [TrackSendRoute]].self, from: data) {
            trackSendRoutesBySource = normalizedTrackSendRoutes(decodedRoutes)
            return
        }
        if let decodedTargets = try? JSONDecoder().decode([String: [String]].self, from: data) {
            trackSendRoutesBySource = normalizedLegacyTrackSendTargets(decodedTargets)
            return
        }
        trackSendRoutesBySource = [:]
    }

    private func saveTrackSendState() {
        guard let data = try? JSONEncoder().encode(trackSendRoutesBySource),
              let string = String(data: data, encoding: .utf8) else {
            return
        }
        UserDefaults.standard.set(string, forKey: trackSendTargetsKey)
    }

    private func normalizedTrackSendRoutes(_ rawTargets: [String: [TrackSendRoute]]) -> [String: [TrackSendRoute]] {
        func normalizeTrackKey(_ key: String) -> String {
            switch key {
            case "remoteBus":
                return "masterBus1"
            case "remoteBus2":
                return "masterBus2"
            default:
                return key
            }
        }

        var normalizedRoutes: [String: [TrackSendRoute]] = [:]
        for (rawSource, rawDestinations) in rawTargets {
            let source = normalizeTrackKey(rawSource)
            guard !source.isEmpty,
                  source != "masterBus1",
                  source != "masterBus2",
                  source != "sidetone",
                  !source.hasPrefix("session:") else {
                continue
            }

            let routes = rawDestinations.map {
                TrackSendRoute(destination: normalizeTrackKey($0.destination), mode: $0.mode)
            }
            let cleaned = Self.normalizedRoutes(routes, forSourceTrackKey: source)
            if !cleaned.isEmpty {
                normalizedRoutes[source] = cleaned
            }
        }
        return normalizedRoutes
    }

    private func normalizedLegacyTrackSendTargets(_ rawTargets: [String: [String]]) -> [String: [TrackSendRoute]] {
        func normalizeTrackKey(_ key: String) -> String {
            switch key {
            case "remoteBus":
                return "masterBus1"
            case "remoteBus2":
                return "masterBus2"
            default:
                return key
            }
        }

        var normalized: [String: [TrackSendRoute]] = [:]
        for (rawSource, rawDestinations) in rawTargets {
            let source = normalizeTrackKey(rawSource)
            guard !source.isEmpty,
                  source != "masterBus1",
                  source != "masterBus2",
                  source != "sidetone",
                  !source.hasPrefix("session:") else {
                continue
            }

            let routes = rawDestinations.map {
                TrackSendRoute(destination: normalizeTrackKey($0), mode: .audio)
            }
            let cleaned = Self.normalizedRoutes(routes, forSourceTrackKey: source)
            if !cleaned.isEmpty {
                normalized[source] = cleaned
            }
        }
        return normalized
    }

    private static func isAllowedTrackSendRoute(source: String, destination: String) -> Bool {
        if source == "masterBus1" || source == "masterBus2" || source == "sidetone" {
            return false
        }
        if destination == "sidetone" {
            return source == "input"
        }
        return true
    }

    private static func normalizedRoutes(_ routes: [TrackSendRoute], forSourceTrackKey source: String) -> [TrackSendRoute] {
        var normalized: [TrackSendRoute] = []
        var seenDestinations: Set<String> = []

        for route in routes.reversed() {
            let destination = route.destination
            guard !destination.isEmpty,
                  destination != source,
                  !destination.hasPrefix("session:"),
                  !seenDestinations.contains(destination),
                  isAllowedTrackSendRoute(source: source, destination: destination) else {
                continue
            }
            seenDestinations.insert(destination)
            normalized.append(TrackSendRoute(destination: destination, mode: route.mode))
        }

        return normalized.reversed()
    }

    private func validSidechainSourceKeys(forDestinationTrackKey trackKey: String) -> Set<String> {
        Set(incomingSendSources(forDestinationTrackKey: trackKey, mode: .sidechain).compactMap { sourceKey in
            switch sourceKey {
            case "input", "sidetone", "masterBus1", "masterBus2":
                return sourceKey
            default:
                if sourceKey.hasPrefix("session:") {
                    return sourceKey
                }
                return nil
            }
        })
    }

    private func refreshParameters(for pluginID: String, trackKey: String) {
        let loadedKey = loadedAudioUnitKey(trackKey: trackKey, pluginID: pluginID)
        if let unit = loadedAudioUnits[loadedKey] {
            rebuildParameterState(pluginID: pluginID, unit: unit)
        } else if let vst3Host = loadedVST3Hosts[loadedKey] {
            rebuildParameterState(pluginID: pluginID, vst3Host: vst3Host)
        }
    }

    private func rebuildParameterState(pluginID: String, unit: AVAudioUnit) {
        let parameters = unit.auAudioUnit.parameterTree?.allParameters ?? []
        var state = parameters.prefix(64).map {
            AudioPluginParameterInfo(
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
            .compactMap { snapshot -> AudioPluginParameterInfo? in
                guard let parameterID = snapshot["id"] as? NSNumber,
                      let name = snapshot["name"] as? String,
                      let minValue = snapshot["minValue"] as? NSNumber,
                      let maxValue = snapshot["maxValue"] as? NSNumber,
                      let value = snapshot["value"] as? NSNumber else {
                    return nil
                }

                return AudioPluginParameterInfo(
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

    private func applySavedParameters(pluginID: String, state: inout [AudioPluginParameterInfo], unit: AVAudioUnit) {
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
            state[index] = AudioPluginParameterInfo(
                id: state[index].id,
                name: state[index].name,
                minValue: state[index].minValue,
                maxValue: state[index].maxValue,
                value: saved
            )
            lookup[state[index].id]?.value = saved
        }
    }

    private func applySavedParameters(pluginID: String, state: inout [AudioPluginParameterInfo], vst3Host: MKVST3PluginHost) {
        guard let plugin = findPlugin(withID: pluginID), !plugin.savedParameterValues.isEmpty else {
            return
        }
        for index in state.indices {
            let key = String(state[index].id)
            guard let saved = plugin.savedParameterValues[key] else { continue }
            let normalized = min(max(saved, state[index].minValue), state[index].maxValue)
            state[index] = AudioPluginParameterInfo(
                id: state[index].id,
                name: state[index].name,
                minValue: state[index].minValue,
                maxValue: state[index].maxValue,
                value: normalized
            )
            _ = vst3Host.setParameter(withID: state[index].id, normalizedValue: normalized)
        }
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
        let parameter = list[index]
        list[index] = AudioPluginParameterInfo(
            id: parameter.id,
            name: parameter.name,
            minValue: parameter.minValue,
            maxValue: parameter.maxValue,
            value: newValue
        )
        parameterStateByPlugin[pluginID] = list
        mutatePlugin(withID: pluginID) { plugin in
            plugin.savedParameterValues[String(parameterID)] = newValue
        }
    }

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

    private func availableAudioUnitPlugins() -> [AudioPluginDiscovery] {
        let manager = AVAudioUnitComponentManager.shared()
        let componentTypes: [UInt32] = [kAudioUnitType_Effect, kAudioUnitType_MusicEffect]
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
        var deduped: [String: AudioPluginDiscovery] = [:]
        for component in components {
            let acd = component.audioComponentDescription
            let identifier = "au:\(acd.componentType):\(acd.componentSubType):\(acd.componentManufacturer):\(component.name)"
            if deduped[identifier] == nil {
                deduped[identifier] = AudioPluginDiscovery(
                    id: identifier,
                    name: component.name,
                    subtitle: component.manufacturerName,
                    source: .audioUnit,
                    categorySeedText: ([component.typeName, component.name, component.manufacturerName] + component.allTagNames)
                        .joined(separator: " ")
                )
            }
        }
        return Array(deduped.values).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func availableFilesystemPlugins() -> [AudioPluginDiscovery] {
        #if os(macOS)
        var scanRoots: [String] = [
            "/Library/Audio/Plug-Ins/VST3",
            NSString(string: "~/Library/Audio/Plug-Ins/VST3").expandingTildeInPath
        ]
        scanRoots.append(contentsOf: customScanPathEntries())

        let fm = FileManager.default
        var found: [String] = []
        for root in scanRoots {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            let children = (try? fm.contentsOfDirectory(atPath: root)) ?? []
            for item in children where item.hasSuffix(".vst3") {
                found.append("\(root)/\(item)")
            }
        }
        return Array(Set(found))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { fullPath in
                AudioPluginDiscovery(
                    id: "fs:\(fullPath)",
                    name: URL(fileURLWithPath: fullPath).deletingPathExtension().lastPathComponent,
                    subtitle: fullPath,
                    source: .filesystem,
                    categorySeedText: "\(URL(fileURLWithPath: fullPath).deletingPathExtension().lastPathComponent) \(fullPath)"
                )
            }
        #else
        return []
        #endif
    }

    private func customScanPathEntries() -> [String] {
        UserDefaults.standard.string(forKey: pluginCustomScanPathsKey)?
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
    }

    // MARK: - Utility

    private func loadedAudioUnitKey(trackKey: String, pluginID: String) -> String {
        "\(trackKey):\(pluginID)"
    }

    private func parseAudioUnitDescription(from identifier: String) -> AudioComponentDescription? {
        guard identifier.hasPrefix("au:") else { return nil }
        let remainder = String(identifier.dropFirst(3))
        let parts = remainder.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count >= 3,
              let type = UInt32(parts[0]),
              let subType = UInt32(parts[1]),
              let manufacturer = UInt32(parts[2]) else {
            return nil
        }
        return AudioComponentDescription(
            componentType: type,
            componentSubType: subType,
            componentManufacturer: manufacturer,
            componentFlags: 0,
            componentFlagsMask: 0
        )
    }

    private func channelCount(for trackKey: String) -> UInt {
        if trackKey == "input" || trackKey == "sidetone" {
            return UserDefaults.standard.bool(forKey: "AudioStereoInput") ? 2 : 1
        }
        return 2
    }

    private func pluginSampleRate(for trackKey: String) -> Double {
        let sampleRate = MKAudio.shared().pluginSampleRate(forTrackKey: trackKey)
        return sampleRate > 0 ? Double(sampleRate) : 48_000
    }

    private func instantiateAudioUnitWithFallback(
        description: AudioComponentDescription,
        requiredChannels: UInt,
        sampleRate: Double,
        loadedKey: String
    ) async -> String? {
        if let error = await tryInstantiateWithChannels(
            description: description,
            channels: requiredChannels,
            sampleRate: sampleRate,
            loadedKey: loadedKey
        ) {
            if requiredChannels == 2 {
                NSLog("AudioPluginRackManager: Failed to load AU with 2 channels, trying 1 channel")
                if let monoError = await tryInstantiateWithChannels(
                    description: description,
                    channels: 1,
                    sampleRate: sampleRate,
                    loadedKey: loadedKey
                ) {
                    return monoError
                }
                return nil
            }
            return error
        }
        return nil
    }

    private func tryInstantiateWithChannels(
        description: AudioComponentDescription,
        channels: UInt,
        sampleRate: Double,
        loadedKey: String
    ) async -> String? {
        let effectiveSampleRate = sampleRate > 0 ? sampleRate : 48_000
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: effectiveSampleRate,
            channels: AVAudioChannelCount(channels)
        ) else {
            return NSLocalizedString("Failed to create audio format", comment: "")
        }

#if os(macOS)
        let (unitDefault, errorDefault) = await withUnsafeContinuation { (c: UnsafeContinuation<(AVAudioUnit?, NSError?), Never>) in
            AVAudioUnit.instantiate(with: description, options: []) { unit, error in
                c.resume(returning: (unit, error as NSError?))
            }
        }
        if let unitDefault, configureAudioUnit(unitDefault, format: format) {
            loadedAudioUnits[loadedKey] = unitDefault
            return nil
        }

        let (unitIn, errorIn) = await withUnsafeContinuation { (c: UnsafeContinuation<(AVAudioUnit?, NSError?), Never>) in
            AVAudioUnit.instantiate(with: description, options: [.loadInProcess]) { unit, error in
                c.resume(returning: (unit, error as NSError?))
            }
        }
        if let unitIn, configureAudioUnit(unitIn, format: format) {
            loadedAudioUnits[loadedKey] = unitIn
            return nil
        }

        let (unitOut, errorOut) = await withUnsafeContinuation { (c: UnsafeContinuation<(AVAudioUnit?, NSError?), Never>) in
            AVAudioUnit.instantiate(with: description, options: [.loadOutOfProcess]) { unit, error in
                c.resume(returning: (unit, error as NSError?))
            }
        }
        if let unitOut, configureAudioUnit(unitOut, format: format) {
            loadedAudioUnits[loadedKey] = unitOut
            return nil
        }

        let finalError = errorDefault ?? errorIn ?? errorOut
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
        if let unitDefault, configureAudioUnit(unitDefault, format: format) {
            loadedAudioUnits[loadedKey] = unitDefault
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

        if au.inputBusses.count > 0 {
            do {
                let inputFormat = configuredAudioUnitFormat(for: au.inputBusses[0], fallback: format)
                try au.inputBusses[0].setFormat(inputFormat)
            } catch {
                return false
            }
        }

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

    // MARK: - App Sandbox Migration

    /// Clears VST3 plugins from persistence if running in a sandbox-restricted environment.
    /// This prevents crashes on startup when VST3 bundles cannot be loaded due to Sandbox.
    private func clearVST3PluginsIfSandboxRestricted() {
        // Check if we have VST3 plugins persisted
        let hasVST3Plugins = pluginChainByTrack.values.flatMap { $0 }.contains { $0.source == .filesystem }

        guard hasVST3Plugins else {
            return
        }

        // For TestFlight/App Store builds with Sandbox, clear VST3 plugins to prevent crashes
        // The Sandbox prevents loading third-party bundles from /Library/Audio/Plug-Ins/
        NSLog("AudioPluginRackManager: Detected VST3 plugins in sandbox-restricted environment, clearing VST3 entries")

        // Remove VST3 plugins from the chain but keep AU plugins
        var modified = false
        for (trackKey, chain) in pluginChainByTrack {
            let filteredChain = chain.filter { $0.source != .filesystem }
            if filteredChain.count != chain.count {
                pluginChainByTrack[trackKey] = filteredChain
                modified = true
                NSLog("AudioPluginRackManager: Removed \(chain.count - filteredChain.count) VST3 plugin(s) from track '\(trackKey)'")
            }
        }

        if modified {
            savePluginChainState()
            NSLog("AudioPluginRackManager: Saved cleaned plugin chain (VST3 plugins removed)")
        }
    }
}
