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
    @Published var loadingPluginIDs: Set<String> = []
    @Published var lastLoadErrorByPlugin: [String: String] = [:]
    @Published var parameterStateByPlugin: [String: [AudioPluginParameterInfo]] = [:]
    @Published var trackSendRoutesBySource: [String: [TrackSendRoute]] = [:]

    // MARK: - Persistence Keys

    private let pluginTrackChainsKey = "AudioPluginTrackChainsV1"
    private let trackSendTargetsKey = "AudioPluginTrackSendsV1"
    private let pluginPresetsKey = "AudioPluginPresetsV1"
    private let dspPendingVerificationKey = "AudioPluginDSPPendingVerification"
    private let cleanExitKey = "AudioPluginCleanExit"

    /// Tracks that have been synced to DSP but not yet verified as running safely.
    private var dspVerificationTimer: Timer?

    // MARK: - Initialization

    private init() {
        loadPluginChainState()
        loadTrackSendState()
        removeLegacyFilesystemPlugins()
    }

    // MARK: - Public API

    /// Called on app startup to initialize the audio rack.
    /// Loads persisted plugins and syncs the DSP chain to MKAudio.
    func initializeOnStartup() async {
        NSLog("AudioPluginRackManager: Initializing on startup")

        // Crash sentinel: if the previous session crashed with plugins in DSP,
        // clear those plugin chains to prevent repeated crashes.
        recoverFromPluginCrashIfNeeded()

        // Sync buffer frames setting
        let bufferFrames = UserDefaults.standard.integer(forKey: "AudioPluginHostBufferFrames")
        MKAudio.shared().setPluginHostBufferFrames(UInt(max(bufferFrames, 64)))

        // Load persisted plugins
        await loadPersistedAudioUnits()
        syncAllTrackSendRouting()
    }

    /// Checks if the previous session crashed with plugins active in the DSP chain.
    /// If so, clears those tracks' plugin chains to prevent a crash loop.
    private func recoverFromPluginCrashIfNeeded() {
        // Check 1: DSP pending verification sentinel (set by new code)
        if let pendingTracks = UserDefaults.standard.stringArray(forKey: dspPendingVerificationKey),
           !pendingTracks.isEmpty {
            NSLog("AudioPluginRackManager: Previous session crashed with plugins active on: \(pendingTracks). Clearing chains.")
            for trackKey in pendingTracks {
                pluginChainByTrack[trackKey] = []
            }
            savePluginChainState()
            UserDefaults.standard.removeObject(forKey: dspPendingVerificationKey)
            return
        }

        // Check 2: Clean exit flag.
        // object(forKey:) returns nil on first-ever run → skip (don't clear on first install).
        // Returns false if previous session set it to false and never marked it true → crash detected.
        let cleanExitValue = UserDefaults.standard.object(forKey: cleanExitKey) as? Bool
        let hasPlugins = pluginChainByTrack.values.contains { !$0.isEmpty }

        if let wasClean = cleanExitValue, !wasClean, hasPlugins {
            NSLog("AudioPluginRackManager: Previous session did not exit cleanly with plugins present. Clearing all chains.")
            for trackKey in pluginChainByTrack.keys {
                pluginChainByTrack[trackKey] = []
            }
            savePluginChainState()
        }

        // Mark this session as not yet clean (will be marked clean after DSP verification)
        UserDefaults.standard.set(false, forKey: cleanExitKey)
    }

    /// Marks tracks as verified after audio has been running successfully.
    func markDSPVerified() {
        UserDefaults.standard.removeObject(forKey: dspPendingVerificationKey)
        UserDefaults.standard.set(true, forKey: cleanExitKey)
        dspVerificationTimer?.invalidate()
        dspVerificationTimer = nil
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
        availableAudioUnitPlugins()
    }

    func customScanPaths() -> [String] {
        []
    }

    func addCustomScanPath(_ path: String) {}

    func removeCustomScanPath(_ path: String) {}

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
                    guard plugin.source == .audioUnit else {
                        return false
                    }
                    let loadedKey = loadedAudioUnitKey(trackKey: trackKey, pluginID: plugin.id)
                    return loadedAudioUnits[loadedKey] == nil
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
        guard plugin.source == .audioUnit else {
            return false
        }

        // Find track key for this plugin
        let trackKey: String? = pluginChainByTrack.first(where: { _, chain in
            chain.contains(where: { $0.id == plugin.id })
        })?.key

        guard let trackKey else { return false }

        let loadedKey = loadedAudioUnitKey(trackKey: trackKey, pluginID: plugin.id)

        if loadedAudioUnits[loadedKey] != nil {
            return true
        }

        loadingPluginIDs.insert(plugin.id)

        defer {
            loadingPluginIDs.remove(plugin.id)
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

        // Crash sentinel: mark this track as pending verification before syncing to DSP.
        // If the app crashes before markDSPVerified() is called, the next launch
        // will detect the crash and clear these tracks' chains.
        if !chain.isEmpty {
            var pending = UserDefaults.standard.stringArray(forKey: dspPendingVerificationKey) ?? []
            if !pending.contains(trackKey) {
                pending.append(trackKey)
                UserDefaults.standard.set(pending, forKey: dspPendingVerificationKey)
            }
            scheduleDSPVerification()
        }

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

    /// Schedules a delayed verification that clears the crash sentinel.
    /// If audio runs for 5 seconds without crashing, the plugins are considered safe.
    private func scheduleDSPVerification() {
        dspVerificationTimer?.invalidate()
        dspVerificationTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.markDSPVerified()
                NSLog("AudioPluginRackManager: DSP verified safe after 5s")
            }
        }
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
                }
                return nil
            }
    }

    // MARK: - Parameter Helpers

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

    private func setParameterValue(pluginID: String, trackKey: String, parameterID: UInt64, newValue: Float) {
        let loadedKey = loadedAudioUnitKey(trackKey: trackKey, pluginID: pluginID)
        if let unit = loadedAudioUnits[loadedKey],
           let parameter = unit.auAudioUnit.parameterTree?.allParameters.first(where: { $0.address == parameterID }) {
            parameter.value = newValue
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

    private func removeLegacyFilesystemPlugins() {
        var modified = false
        for (trackKey, chain) in pluginChainByTrack {
            let filteredChain = chain.filter { $0.source != .filesystem }
            if filteredChain.count != chain.count {
                pluginChainByTrack[trackKey] = filteredChain
                modified = true
                NSLog("AudioPluginRackManager: Removed \(chain.count - filteredChain.count) legacy filesystem plugin(s) from track '\(trackKey)'")
            }
        }

        if modified {
            savePluginChainState()
            NSLog("AudioPluginRackManager: Saved cleaned plugin chain after removing legacy filesystem plugins")
        }
    }
}
