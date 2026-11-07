//
//  PreferencePrivacyTests+Inventory.swift
//  FluxKlangTests
//
//  The inventory of every storage surface the app ships (#124 PR1): each surface classified exactly once, the
//  sort order, the duplicate and unknown-surface refusals, and the agreement of the inventory with the key-value
//  allowlist and with the class policy. The literals below are the ONE restated copy of what the app's stores keep
//  privately; no test reads a source file or a real store.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension PreferencePrivacyTests {
    /// A surface as the app declares it today, in the order the stores are usually read (NOT sorted).
    struct RealSurface {
        let kind: StorageSurface.Kind
        let name: String
        let storageClass: StorageClass
        let surface: StorageSurface

        init(_ kind: StorageSurface.Kind, _ name: String, _ storageClass: StorageClass) {
            self.kind = kind
            self.name = name
            self.storageClass = storageClass
            surface = StorageSurface(kind: kind, name: name)
        }
    }

    /// Restated from: `AssistantProviderSettings` (`assistant.provider`, `assistant.copilot.model`, Keychain account
    /// `github-copilot-token`), `AssistantChatController` (`assistant.spokenReplies`), `AppIcon` (`fluxklang.appIcon`),
    /// `AppModel+Permissions` (`fluxklang.reconnectAtLaunch`), `AppModel` (`fluxklang.lastHost`), `FluxKlangEntities`
    /// (spotlight protection class), the stores `EnvironmentStore` (`environments.json`, legacy `effects.json` and
    /// `chain.json`), `StudioConnectionsStore`, `EquipmentStore`, `PresetStore`, `SpatialStore`, `FaderLayoutStore`,
    /// `RoutingSnapshotStore`, `LaunchControlXLController`, `PendingStudioPatchStore`, `AssistantHistoryStore`
    /// (`AssistantHistory` directory, zone `FluxKlangAssistantHistory`) and `LocalNetworkGrantEvidence`.
    static let realSurfaces: [RealSurface] = [
        RealSurface(.userDefaultsKey, "fluxklang.appIcon", .preference),
        RealSurface(.userDefaultsKey, "fluxklang.reconnectAtLaunch", .preference),
        RealSurface(.userDefaultsKey, "fluxklang.lastHost", .hostLocalRoute),
        RealSurface(.userDefaultsKey, "assistant.provider", .preference),
        RealSurface(.userDefaultsKey, "assistant.copilot.model", .preference),
        RealSurface(.userDefaultsKey, "assistant.spokenReplies", .preference),
        RealSurface(.userDefaultsKey, "org.davidjensenius.FluxKlang.spotlightProtectionClass", .cache),
        RealSurface(.storeFile, "environments.json", .environment),
        RealSurface(.storeFile, "effects.json", .environment),
        RealSurface(.storeFile, "chain.json", .environment),
        RealSurface(.storeFile, "studio-connections.json", .homeWiring),
        RealSurface(.storeFile, "equipment.json", .catalog),
        RealSurface(.storeFile, "presets.json", .catalog),
        RealSurface(.storeFile, "spatial.json", .catalog),
        RealSurface(.storeFile, "fader-layout.json", .catalog),
        RealSurface(.storeFile, "routing_snapshots.json", .catalog),
        RealSurface(.storeFile, "launch-control-xl.json", .hostLocalRoute),
        RealSurface(.localFile, "assistant-pending-studio-draft.json", .draft),
        RealSurface(.localFile, "LocalNetwork/local-network-grant", .hostLocalRoute),
        RealSurface(.localDirectory, "AssistantHistory", .history),
        RealSurface(.localDirectory, "LocalNetwork", .hostLocalRoute),
        RealSurface(.cloudKitZone, "FluxKlangAssistantHistory", .history),
        RealSurface(.keychainAccount, "github-copilot-token", .credential)
    ]

    static var realEntries: [StorageInventoryEntry] {
        realSurfaces.map { StorageInventoryEntry(surface: $0.surface, storageClass: $0.storageClass) }
    }

    /// The location each kind of surface lives in.
    static func location(of kind: StorageSurface.Kind) -> StorageLocation {
        switch kind {
        case .userDefaultsKey, .storeFile, .localFile, .localDirectory: .localFile
        case .keychainAccount: .keychainThisDeviceOnly
        case .cloudKitZone: .privateCloudDatabase
        }
    }

    @Test func theInventoryHasTwentyThreeSurfacesInSixKinds() {
        #expect(StorageInventory.shipped.count == 23)
        #expect(Self.realSurfaces.count == 23)
        let counts = StorageSurface.Kind.allCases.map { kind in
            StorageInventory.shipped.filter { $0.surface.kind == kind }.count
        }
        #expect(counts == [7, 10, 1, 2, 2, 1])
    }

    @Test func everyRealSurfaceHasTheClassOfTheRulings() {
        for real in Self.realSurfaces {
            #expect(StorageInventory.classification(of: real.surface) == real.storageClass, "\(real.name)")
        }
    }

    @Test func theLaunchControlFileAndTheHostAddressAreHostLocalRoutes() {
        let launch = StorageSurface(kind: .storeFile, name: "launch-control-xl.json")
        let host = StorageSurface(kind: .userDefaultsKey, name: "fluxklang.lastHost")
        #expect(StorageInventory.classification(of: launch) == .hostLocalRoute)
        #expect(StorageInventory.classification(of: host) == .hostLocalRoute)
        let token = StorageSurface(kind: .keychainAccount, name: "github-copilot-token")
        #expect(StorageInventory.classification(of: token) == .credential)
    }

    @Test func everyShippedEntryIsARealSurfaceAndEveryRealSurfaceIsShippedExactlyOnce() {
        for real in Self.realSurfaces {
            let matches = StorageInventory.shipped.filter { $0.surface == real.surface }
            #expect(matches.count == 1, "\(real.name)")
        }
        for entry in StorageInventory.shipped {
            #expect(Self.realSurfaces.contains { $0.surface == entry.surface }, "\(entry.surface.name)")
        }
    }

    @Test func surfaceNamesAreUniqueAcrossEveryKind() throws {
        #expect(Set(StorageInventory.shipped.map(\.surface.name)).count == 23)
        #expect(Self.refusal { try StorageInventory.validate(StorageInventory.shipped) } == nil)
        #expect(Self.refusal { try StorageInventory.validate([]) } == nil)
    }

    @Test func theShippedTableIsSortedByKindRankThenNameBytes() throws {
        #expect(StorageInventory.shipped == StorageInventory.sorted(StorageInventory.shipped))
        #expect(StorageInventory.shipped == StorageInventory.sorted(Self.realEntries))
        let first = try #require(StorageInventory.shipped.first)
        #expect(first.surface == StorageSurface(kind: .userDefaultsKey, name: "assistant.copilot.model"))
        let last = try #require(StorageInventory.shipped.last)
        #expect(last.surface == StorageSurface(kind: .cloudKitZone, name: "FluxKlangAssistantHistory"))
    }

    @Test func nameBytesOrderUppercaseBeforeLowercaseWithinAKind() {
        let names = StorageInventory.shipped.filter { $0.surface.kind == .localFile }.map(\.surface.name)
        #expect(names == ["LocalNetwork/local-network-grant", "assistant-pending-studio-draft.json"])
        let stores = StorageInventory.shipped.filter { $0.surface.kind == .storeFile }.map(\.surface.name)
        #expect(stores == [
            "chain.json", "effects.json", "environments.json", "equipment.json", "fader-layout.json",
            "launch-control-xl.json", "presets.json", "routing_snapshots.json", "spatial.json",
            "studio-connections.json"
        ])
    }

    @Test func sortingTheSweepGivesTheShippedTableWhateverTheInputOrder() {
        let entries = Self.realEntries
        #expect(StorageInventory.sorted(entries) == StorageInventory.shipped)
        #expect(StorageInventory.sorted(entries.reversed()) == StorageInventory.shipped)
        for seed in UInt64(1)...12 {
            #expect(StorageInventory.sorted(Self.shuffled(entries, seed: seed)) == StorageInventory.shipped)
        }
    }

    @Test func theSameSurfaceListedWithTwoClassesSortsByClassName() {
        let surface = StorageSurface(kind: .storeFile, name: "x.json")
        let cache = StorageInventoryEntry(surface: surface, storageClass: .cache)
        let catalog = StorageInventoryEntry(surface: surface, storageClass: .catalog)
        #expect(StorageInventory.sorted([catalog, cache]) == [cache, catalog])
        #expect(StorageInventory.sorted([cache, catalog]) == [cache, catalog])
    }

    @Test func namesThatDifferInBytesAreDifferentSurfacesEvenWhenCanonicallyEqual() {
        let composed = StorageSurface(kind: .storeFile, name: "caf\u{E9}.json")
        let decomposed = StorageSurface(kind: .storeFile, name: "cafe\u{301}.json")
        #expect(composed != decomposed)
        #expect(Set([composed, decomposed]).count == 2)
        let entries = [StorageInventoryEntry(surface: composed, storageClass: .cache)]
        #expect(StorageInventory.classification(of: composed, in: entries) == .cache)
        #expect(StorageInventory.classification(of: decomposed, in: entries) == nil)
        let both = entries + [StorageInventoryEntry(surface: decomposed, storageClass: .catalog)]
        #expect(StorageInventory.sorted(both).map(\.surface) == [decomposed, composed])
    }

    @Test func aNameUsedByTwoKindsIsRefusedAsADuplicateWhateverTheOrder() throws {
        let extra = StorageInventoryEntry(
            surface: StorageSurface(kind: .localFile, name: "chain.json"), storageClass: .draft)
        let expected = KeyValueRefusal.duplicateSurface(extra.surface)
        for seed in UInt64(1)...6 {
            let entries = Self.shuffled(StorageInventory.shipped + [extra], seed: seed)
            #expect(Self.refusal { try StorageInventory.validate(entries) } == expected)
        }
        #expect(Self.refusal { try StorageInventory.validate(Array((StorageInventory.shipped + [extra]).reversed())) }
            == expected)
    }

    @Test func theSameSurfaceTwiceIsAlsoADuplicate() throws {
        let first = try #require(StorageInventory.shipped.first)
        let entries = StorageInventory.shipped + [first]
        #expect(Self.refusal { try StorageInventory.validate(entries) } == .duplicateSurface(first.surface))
    }

    @Test func anUnknownSurfaceHasNoClass() {
        let unknown = [
            StorageSurface(kind: .storeFile, name: "unknown.json"),
            StorageSurface(kind: .userDefaultsKey, name: "chain.json"),
            StorageSurface(kind: .storeFile, name: "Chain.json"),
            StorageSurface(kind: .storeFile, name: "chain.jso"),
            StorageSurface(kind: .storeFile, name: ""),
            StorageSurface(kind: .localFile, name: "AssistantHistory"),
            StorageSurface(kind: .cloudKitZone, name: "AssistantHistory")
        ]
        for surface in unknown { #expect(StorageInventory.classification(of: surface) == nil, "\(surface.name)") }
    }

    @Test func classificationTakesTheFirstMatchOfTheEntriesItIsGiven() {
        let surface = StorageSurface(kind: .storeFile, name: "a.json")
        let entries = [
            StorageInventoryEntry(surface: surface, storageClass: .catalog),
            StorageInventoryEntry(surface: surface, storageClass: .media)
        ]
        #expect(StorageInventory.classification(of: surface, in: entries) == .catalog)
        #expect(StorageInventory.classification(of: surface, in: []) == nil)
    }

    @Test func requireClassifiedNamesTheFirstUnclassifiedSurfaceInSortOrder() throws {
        let known = StorageInventory.shipped.map(\.surface)
        #expect(Self.refusal { try StorageInventory.requireClassified(known) } == nil)
        #expect(Self.refusal { try StorageInventory.requireClassified([]) } == nil)
        let late = StorageSurface(kind: .localFile, name: "z.bin")
        let early = StorageSurface(kind: .storeFile, name: "a.json")
        for order in Self.permutations([late, early, try #require(known.first)]) {
            #expect(Self.refusal { try StorageInventory.requireClassified(order) } == .unclassified(early))
        }
    }

    @Test func everySurfaceKindLivesInALocationItsClassPermits() {
        for entry in StorageInventory.shipped {
            let location = Self.location(of: entry.surface.kind)
            #expect(StoragePolicy.permits(entry.storageClass, location), "\(entry.surface.name)")
        }
    }

    @Test func theAllowlistAgreesWithTheInventoryForEveryStoreFile() throws {
        let legacy: Set<String> = ["chain.json", "effects.json"]
        var allowlisted = 0
        for entry in StorageInventory.shipped where entry.surface.kind == .storeFile {
            let key = try KeyValueKey.storeFile(named: entry.surface.name)
            let listed = KeyValueAllowlist.shipped.entry(for: key)
            let wanted = StoragePolicy.isKeyValueEligible(entry.storageClass) && !legacy.contains(entry.surface.name)
            #expect((listed != nil) == wanted, "\(entry.surface.name)")
            if let listed {
                #expect(listed.storageClass == entry.storageClass, "\(entry.surface.name)")
                allowlisted += 1
            }
        }
        #expect(allowlisted == KeyValueAllowlist.shipped.entries.count)
        #expect(allowlisted == 7)
    }
}
