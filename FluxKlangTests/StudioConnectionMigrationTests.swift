import Foundation
import Testing
@testable import FluxKlang

struct StudioConnectionMigrationTests {
    private final class MemoryCloudStore: CloudKeyValueStore, @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String: Data] = [:]

        func data(forKey key: String) -> Data? { lock.withLock { storage[key] } }
        func setData(_ data: Data, forKey key: String) { lock.withLock { storage[key] = data } }
        @discardableResult func synchronize() -> Bool { true }
    }

    @Test func rejectsMixerChannelsOutsidePhysicalLocalInputs() {
        let synth = Equipment(name: "Synth")
        let environment = RoutingEnvironment(
            name: "Legacy",
            studioSetup: StudioSetup(devices: [
                StudioDeviceProfile(
                    device: .equipment(synth.id),
                    name: synth.name,
                    role: .instrument,
                    patches: [
                        StudioPortPatch(
                            device: .equipment(synth.id),
                            side: .output,
                            port: 0,
                            connector: .wingInput(WingSource(group: .local, index: 24))
                        ),
                        StudioPortPatch(
                            device: .equipment(synth.id),
                            side: .output,
                            port: 1,
                            connector: .wingInput(WingSource(group: .local, index: 25))
                        )
                    ]
                )
            ])
        )

        let migrated = GlobalStudioConnections.migratingLegacy(
            environments: [environment],
            activeID: environment.id,
            equipment: [synth]
        )

        #expect(migrated.home.inputs.map(\.connector) == [24])
        #expect(migrated.migrationIssues.map(\.message) == [
            "Legacy Local input 25 is outside the physical 1...24 range."
        ])
    }

    @MainActor
    @Test func storeRepairsPersistedOutOfRangeLegacyInputs() async throws {
        let cloud = MemoryCloudStore()
        let fileStore = JSONFileStore(cloud: cloud)
        let fileName = "studio-connections-\(UUID().uuidString).json"
        let synth = Equipment(name: "Synth", outputs: ["L", "R"], isStereo: true)
        let persisted = StudioConnectionsStore.Persisted(
            connections: GlobalStudioConnections(home: StudioHomeConnections(inputs: [
                StudioInputConnection(connector: 24, equipmentID: synth.id, outputPort: 0),
                StudioInputConnection(connector: 25, equipmentID: synth.id, outputPort: 1)
            ])),
            initialized: true,
            confirmedOutputDefaultsVersion: 1
        )
        let cloudKey = "store." + fileName.replacingOccurrences(of: ".", with: "_")
        cloud.setData(try JSONEncoder().encode(persisted), forKey: cloudKey)
        let store = StudioConnectionsStore(
            fileStore: fileStore,
            fileName: fileName,
            outputDefaults: nil
        )

        await store.load(equipment: [synth], environments: [], activeID: nil)

        #expect(store.connections.home.inputs.map(\.connector) == [24])
        let repaired = try #require(cloud.data(forKey: cloudKey))
        let decoded = try JSONDecoder().decode(StudioConnectionsStore.Persisted.self, from: repaired)
        #expect(decoded.connections.home.inputs.map(\.connector) == [24])
    }
}
