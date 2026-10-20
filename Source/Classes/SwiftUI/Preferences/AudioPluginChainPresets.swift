import Foundation

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
    var sidechainSourceKey: String?

    enum CodingKeys: String, CodingKey {
        case id, name, subtitle, source, identifier, bypassed, stageGain, autoLoad
        case savedParameterValues, sidechainSourceKey
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

struct AudioPluginChainPreset: Identifiable, Codable, Hashable {
    let id: String
    var name: String
    var slotCount: Int
    var plugins: [TrackPlugin]

    init(id: String, name: String, slotCount: Int, plugins: [TrackPlugin]) {
        self.id = id
        self.name = name
        self.slotCount = slotCount
        self.plugins = plugins
    }

    init(file: TrackChainPresetFile) {
        id = UUID().uuidString
        name = file.name
        slotCount = file.slotCount
        plugins = file.plugins.map { $0.makeTrackPlugin() }
    }

    func makeFile(sourceTrackKey: String, sourceTrackTitle: String) -> TrackChainPresetFile {
        TrackChainPresetFile(
            version: 1,
            exportedAt: Date(),
            name: name,
            sourceTrackKey: sourceTrackKey,
            sourceTrackTitle: sourceTrackTitle,
            slotCount: slotCount,
            plugins: plugins.map(TrackChainPresetPlugin.init(plugin:))
        )
    }

    static func uniqueName(_ requested: String, existing: [Self]) -> String {
        let trimmed = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? NSLocalizedString("Untitled Preset", comment: "Default effect chain preset name") : trimmed
        let names = Set(existing.map { $0.name.lowercased() })
        guard names.contains(base.lowercased()) else { return base }
        var suffix = 2
        while names.contains("\(base) \(suffix)".lowercased()) {
            suffix += 1
        }
        return "\(base) \(suffix)"
    }

    /// Presets describe settings; each application receives independent plugin instances.
    func makePlugins() -> [TrackPlugin] {
        plugins.map { plugin in
            TrackPlugin(
                id: UUID().uuidString,
                name: plugin.name,
                subtitle: plugin.subtitle,
                source: plugin.source,
                identifier: plugin.identifier,
                bypassed: plugin.bypassed,
                stageGain: plugin.stageGain,
                autoLoad: plugin.autoLoad,
                savedParameterValues: plugin.savedParameterValues,
                sidechainSourceKey: plugin.sidechainSourceKey
            )
        }
    }

    func matches(_ chain: [TrackPlugin]) -> Bool {
        guard chain.count == plugins.count else { return false }
        return zip(plugins, chain).allSatisfy { expected, actual in
            guard expected.source == actual.source,
                  Self.componentIdentity(expected.identifier, source: expected.source)
                    == Self.componentIdentity(actual.identifier, source: actual.source),
                  expected.bypassed == actual.bypassed,
                  Self.nearlyEqual(expected.stageGain, actual.stageGain),
                  expected.autoLoad == actual.autoLoad,
                  expected.sidechainSourceKey == actual.sidechainSourceKey else {
                return false
            }

            if expected.savedParameterValues.keys.sorted() != actual.savedParameterValues.keys.sorted() {
                return false
            }
            return expected.savedParameterValues.allSatisfy { key, value in
                guard let actualValue = actual.savedParameterValues[key] else { return false }
                return Self.nearlyEqual(value, actualValue)
            }
        }
    }

    func isAvailable(in identifiers: Set<String>) -> Bool {
        let available = Set(identifiers.map { Self.componentIdentity($0, source: .audioUnit) })
        return plugins.filter { $0.source == .audioUnit }.allSatisfy {
            available.contains(Self.componentIdentity($0.identifier, source: .audioUnit))
        }
    }

    private static func componentIdentity(_ identifier: String, source: PluginSource) -> String {
        guard source == .audioUnit else { return identifier }
        let parts = identifier.split(separator: ":", maxSplits: 4, omittingEmptySubsequences: false)
        guard parts.count >= 4, parts[0] == "au",
              let type = UInt32(parts[1]),
              let subtype = UInt32(parts[2]),
              let manufacturer = UInt32(parts[3]) else { return identifier }
        return "au:\(type):\(subtype):\(manufacturer)"
    }

    private static func nearlyEqual(_ lhs: Float, _ rhs: Float) -> Bool {
        guard lhs.isFinite, rhs.isFinite else { return false }
        return abs(lhs - rhs) <= max(0.00001, max(abs(lhs), abs(rhs)) * 0.00001)
    }

}

/// The shared on-disk format used by the preset library's import and export actions.
struct TrackChainPresetPlugin: Codable, Hashable {
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

struct TrackChainPresetFile: Codable, Hashable {
    let version: Int
    let exportedAt: Date
    let name: String
    let sourceTrackKey: String
    let sourceTrackTitle: String
    let slotCount: Int
    let plugins: [TrackChainPresetPlugin]
}
