import Foundation

@main
struct AudioPluginChainPresetTests {
    static func main() throws {
        try legacyTrackPluginsRetainDefaults()
        try savedLibraryRoundTripsAndPreservesSettings()
        matchingRecognizesSettingsAndEdits()
        availabilityUsesComponentIdentity()
        savedNamesRemainUnique()
        try exportImportRoundTripsAndPreservesSettings()
        try originalPresetFileRemainsImportable()
        print("Audio plugin chain presets: all regression checks passed")
    }

    private static func samplePreset(id: String = "custom", name: String = "My microphone") -> AudioPluginChainPreset {
        AudioPluginChainPreset(id: id, name: name, slotCount: 12, plugins: [
            TrackPlugin(id: "first", name: "First", subtitle: "Vendor", source: .audioUnit,
                        identifier: "au:1:2:3:First", bypassed: true, stageGain: 0.4,
                        autoLoad: false, savedParameterValues: ["42": -9, "0": 120], sidechainSourceKey: "input"),
            TrackPlugin(id: "second", name: "Second", subtitle: "Vendor", source: .audioUnit,
                        identifier: "au:1:4:3:Second", savedParameterValues: ["0": 0.3]),
            TrackPlugin(id: "third", name: "Legacy", subtitle: "Local", source: .filesystem,
                        identifier: "/plugins/Legacy.component", bypassed: false, stageGain: 1.2,
                        autoLoad: true, savedParameterValues: ["11": 0.5], sidechainSourceKey: "masterBus1")
        ])
    }

    private static func legacyTrackPluginsRetainDefaults() throws {
        let data = Data(#"{"id":"legacy","name":"Old EQ","subtitle":"Apple","source":"audioUnit","identifier":"au:1:2:3:Old EQ"}"#.utf8)
        let plugin = try JSONDecoder().decode(TrackPlugin.self, from: data)
        precondition(!plugin.bypassed && plugin.stageGain == 1 && plugin.autoLoad)
        precondition(plugin.savedParameterValues.isEmpty && plugin.sidechainSourceKey == nil)
        let decoded = try JSONDecoder().decode(TrackPlugin.self, from: JSONEncoder().encode(plugin))
        precondition(decoded == plugin)
    }

    private static func savedLibraryRoundTripsAndPreservesSettings() throws {
        let preset = samplePreset()
        let empty = AudioPluginChainPreset(id: "dry", name: "Dry", slotCount: 8, plugins: [])
        let library = [preset, empty]
        let decoded = try JSONDecoder().decode([AudioPluginChainPreset].self, from: JSONEncoder().encode(library))
        precondition(decoded == library)

        // A previous library entry's optional description is safely ignored.
        let oldEntry = Data(#"{"id":"saved","name":"Desk","detail":"Earlier description","slotCount":8,"plugins":[]}"#.utf8)
        let oldDecoded = try JSONDecoder().decode(AudioPluginChainPreset.self, from: oldEntry)
        precondition(oldDecoded.id == "saved" && oldDecoded.name == "Desk" && oldDecoded.plugins.isEmpty)

        let firstApplication = preset.makePlugins()
        let secondApplication = preset.makePlugins()
        let allIDs = preset.plugins.map(\.id) + firstApplication.map(\.id) + secondApplication.map(\.id)
        precondition(Set(allIDs).count == allIDs.count)
        precondition(preset.matches(firstApplication) && preset.matches(secondApplication))
        assertSameSettings(preset.plugins, firstApplication)
    }

    private static func matchingRecognizesSettingsAndEdits() {
        let preset = samplePreset()
        var chain = preset.makePlugins()
        chain[0].name = "Localized filter name"
        chain[0].subtitle = "Localized vendor name"
        chain[0].identifier = "au:1:2:3:Another localized name:with punctuation"
        chain[0].savedParameterValues["0"]! += 0.0001 // Float roundoff when reading the AU.
        precondition(preset.matches(chain))

        func rejectsEdit(_ edit: (inout [TrackPlugin]) -> Void) {
            var edited = chain
            edit(&edited)
            precondition(!preset.matches(edited))
        }
        rejectsEdit { $0.swapAt(0, 1) }
        rejectsEdit { $0.removeLast() }
        rejectsEdit { $0[0].source = .filesystem }
        rejectsEdit { $0[0].identifier = "au:1:9:3:Other" }
        rejectsEdit { $0[0].bypassed.toggle() }
        rejectsEdit { $0[0].stageGain = 0.5 }
        rejectsEdit { $0[0].autoLoad.toggle() }
        rejectsEdit { $0[0].sidechainSourceKey = "masterBus1" }
        rejectsEdit { $0[0].savedParameterValues["0"] = 250 }
        rejectsEdit { $0[0].savedParameterValues.removeValue(forKey: "0") }
        rejectsEdit { $0[0].savedParameterValues["9999"] = 0.123 }
        rejectsEdit { $0[0].savedParameterValues["0"] = .infinity }
        rejectsEdit { $0[0].stageGain = .nan }
        rejectsEdit { $0[2].identifier = "/plugins/Other.component" }
    }

    private static func availabilityUsesComponentIdentity() {
        let preset = samplePreset()
        let identifiers: Set<String> = ["au:1:2:3:Localized first", "au:1:4:3:Localized second"]
        precondition(preset.isAvailable(in: identifiers))
        precondition(!preset.isAvailable(in: Set(identifiers.dropFirst())))
        precondition(!preset.isAvailable(in: []))
        let empty = AudioPluginChainPreset(id: "empty", name: "Dry", slotCount: 8, plugins: [])
        precondition(empty.isAvailable(in: []) && empty.matches([]))
        let legacyPreset = AudioPluginChainPreset(id: "legacy", name: "Legacy", slotCount: 8,
                                                 plugins: [preset.plugins[2]])
        precondition(legacyPreset.isAvailable(in: []))
    }

    private static func savedNamesRemainUnique() {
        let library = [samplePreset(name: "Desk"), samplePreset(name: "Desk 2"), samplePreset(name: "DESK 3")]
        precondition(AudioPluginChainPreset.uniqueName(" Desk\n", existing: []) == "Desk")
        precondition(AudioPluginChainPreset.uniqueName("desk", existing: library) == "desk 4")
        precondition(AudioPluginChainPreset.uniqueName("Stage", existing: library) == "Stage")
        let unnamed = AudioPluginChainPreset.uniqueName(" \n", existing: [])
        precondition(!unnamed.isEmpty)
        precondition(AudioPluginChainPreset.uniqueName("", existing: [samplePreset(name: unnamed)]) == "\(unnamed) 2")
    }

    private static func exportImportRoundTripsAndPreservesSettings() throws {
        let preset = samplePreset(name: "Desk USB · 麦克风")
        let startedAt = Date()
        let file = preset.makeFile(sourceTrackKey: "input", sourceTrackTitle: "Microphone")
        precondition(file.version == 1 && file.name == preset.name && file.slotCount == preset.slotCount)
        precondition(file.sourceTrackKey == "input" && file.sourceTrackTitle == "Microphone")
        precondition(file.exportedAt >= startedAt && file.exportedAt <= Date())

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(file)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        precondition(Set(json.keys) == ["version", "exportedAt", "name", "sourceTrackKey", "sourceTrackTitle", "slotCount", "plugins"])
        let dateString = json["exportedAt"] as! String
        precondition(ISO8601DateFormatter().date(from: dateString) != nil)
        let exportedPlugins = json["plugins"] as! [[String: Any]]
        precondition(exportedPlugins.allSatisfy { $0["id"] == nil })

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(TrackChainPresetFile.self, from: data)
        let firstImport = AudioPluginChainPreset(file: decoded)
        let secondImport = AudioPluginChainPreset(file: decoded)
        precondition(firstImport.id != preset.id && firstImport.id != secondImport.id)
        precondition(firstImport.name == preset.name && firstImport.slotCount == preset.slotCount)
        precondition(firstImport.matches(preset.plugins) && preset.matches(firstImport.plugins))
        assertSameSettings(preset.plugins, firstImport.plugins)
        let ids = preset.plugins.map(\.id) + firstImport.plugins.map(\.id) + secondImport.plugins.map(\.id)
        precondition(Set(ids).count == ids.count)
        let reexported = firstImport.makeFile(sourceTrackKey: "output", sourceTrackTitle: "Speakers")
        precondition(reexported.name == file.name && reexported.slotCount == file.slotCount && reexported.plugins == file.plugins)
        precondition(reexported.sourceTrackKey == "output" && reexported.sourceTrackTitle == "Speakers")
    }

    private static func originalPresetFileRemainsImportable() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/track-chain-preset-v1.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let file = try decoder.decode(TrackChainPresetFile.self, from: Data(contentsOf: fixture))
        precondition(file.version == 1 && file.exportedAt == Date(timeIntervalSince1970: 1_760_976_000))
        precondition(file.name == "Original microphone chain" && file.slotCount == 16)
        precondition(file.sourceTrackKey == "input" && file.sourceTrackTitle == "Microphone Input")
        let imported = AudioPluginChainPreset(file: file)
        precondition(imported.name == file.name && imported.slotCount == 16 && imported.plugins.count == 2)
        precondition(imported.plugins[0].bypassed && !imported.plugins[0].autoLoad)
        precondition(imported.plugins[0].stageGain == 0.75 && imported.plugins[0].savedParameterValues == ["0": -12, "42": 0.25])
        precondition(imported.plugins[0].sidechainSourceKey == "masterBus2")
        precondition(imported.plugins[1].sidechainSourceKey == nil && imported.plugins[1].source == .filesystem)
        precondition(imported.makeFile(sourceTrackKey: file.sourceTrackKey, sourceTrackTitle: file.sourceTrackTitle).plugins == file.plugins)
    }

    private static func assertSameSettings(_ expected: [TrackPlugin], _ actual: [TrackPlugin]) {
        precondition(expected.map(TrackChainPresetPlugin.init(plugin:)) == actual.map(TrackChainPresetPlugin.init(plugin:)))
    }
}
