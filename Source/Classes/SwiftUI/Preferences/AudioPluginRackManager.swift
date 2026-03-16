import Foundation
import Combine
import AVFoundation

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

    // MARK: - Persistence Keys

    private let pluginTrackChainsKey = "AudioPluginTrackChainsV1"

    // MARK: - Initialization

    private init() {
        loadPluginChainState()
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

        // Load VST3 or AU
        if plugin.source == .filesystem {
            return await loadVST3Plugin(plugin, loadedKey: loadedKey, trackKey: trackKey)
        } else {
            // For AU, we need the description - skip for now if not available
            // AU loading requires the AudioComponentDescription which needs scanning
            NSLog("AudioPluginRackManager: AU plugin '\(plugin.name)' needs manual loading via mixer UI")
            return false
        }
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

    func syncDSPChain(for trackKey: String) {
        let chain = activeProcessorChain(for: trackKey)

        if trackKey == "input" {
            MKAudio.shared().setInputTrackAudioUnitChain(chain)
        } else if trackKey == "remoteBus" {
            MKAudio.shared().setRemoteBusAudioUnitChain(chain)
        } else if let session = parseRemoteSessionID(from: trackKey) {
            MKAudio.shared().setRemoteTrackAudioUnitChain(chain, forSession: UInt(session))
        }

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
                    return ["audioUnit": audioUnit, "mix": mix] as NSDictionary
                } else if let vst3Host = loadedVST3Hosts[loadedKey] {
                    return ["vst3Host": vst3Host, "mix": mix] as NSDictionary
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

    // MARK: - Utility

    private func loadedAudioUnitKey(trackKey: String, pluginID: String) -> String {
        "\(trackKey):\(pluginID)"
    }

    private func channelCount(for trackKey: String) -> UInt {
        if trackKey == "input" {
            return 1
        }
        return 2
    }

    private func pluginSampleRate(for trackKey: String) -> Double {
        let sampleRate = MKAudio.shared().pluginSampleRate(forTrackKey: trackKey)
        return sampleRate > 0 ? Double(sampleRate) : 48_000
    }

    private func parseRemoteSessionID(from key: String) -> Int? {
        guard key.hasPrefix("remoteSession:") else { return nil }
        return Int(key.dropFirst("remoteSession:".count))
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