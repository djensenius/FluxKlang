//
//  StorageInventory.swift
//  FluxKlang
//
//  Every storage surface the app ships today, each classified exactly once (#124). The table restates literals
//  that live privately in the stores; it never reads them, so a later adapter replaces these copies with shared
//  constants. The table is written in its sort order: kind rank, then name UTF-8 bytes. Names are unique across
//  every kind. Surfaces that do not exist yet (plugin state, media, caches, peer trust) have no row; the class
//  policy already keeps them out of key-value storage.
//

enum StorageInventory {
    /// Where the surface is defined is in the comment of each group.
    static let shipped: [StorageInventoryEntry] = [
        // UserDefaults (`AppPersistence.defaults`).
        row(.userDefaultsKey, "assistant.copilot.model", .preference),  // AssistantProviderSettings
        row(.userDefaultsKey, "assistant.provider", .preference),  // AssistantProviderSettings
        row(.userDefaultsKey, "assistant.spokenReplies", .preference),  // AssistantChatController
        row(.userDefaultsKey, "fluxklang.appIcon", .preference),  // AppIconManager
        row(.userDefaultsKey, "fluxklang.lastHost", .hostLocalRoute),  // AppModel.lastHostKey, a WING address
        row(.userDefaultsKey, "fluxklang.reconnectAtLaunch", .preference),  // AppModel.reconnectAtLaunchKey
        row(.userDefaultsKey, "org.davidjensenius.FluxKlang.spotlightProtectionClass", .cache),  // FluxKlangEntities
        // Files that `JSONFileStore` writes and mirrors to key-value storage under `store.<name>`.
        row(.storeFile, "chain.json", .environment),  // EnvironmentStore legacy migration source
        row(.storeFile, "effects.json", .environment),  // EnvironmentStore legacy migration source
        row(.storeFile, "environments.json", .environment),  // EnvironmentStore
        row(.storeFile, "equipment.json", .catalog),  // EquipmentStore
        row(.storeFile, "fader-layout.json", .catalog),  // FaderLayoutStore
        row(.storeFile, "launch-control-xl.json", .hostLocalRoute),  // LaunchControlXLController
        row(.storeFile, "presets.json", .catalog),  // PresetStore
        row(.storeFile, "routing_snapshots.json", .catalog),  // RoutingSnapshotStore
        row(.storeFile, "spatial.json", .catalog),  // SpatialStore
        row(.storeFile, "studio-connections.json", .homeWiring),  // StudioConnectionsStore
        row(.keychainAccount, "github-copilot-token", .credential),  // KeychainAssistantCredentialStore
        // Local files outside the file store; `LocalNetwork/...` is relative to the app directory.
        row(.localFile, "LocalNetwork/local-network-grant", .hostLocalRoute),  // LocalNetworkGrantEvidence
        row(.localFile, "assistant-pending-studio-draft.json", .draft),  // PendingStudioPatchStore
        row(.localDirectory, "AssistantHistory", .history),  // LocalAssistantHistoryBackend
        row(.localDirectory, "LocalNetwork", .hostLocalRoute),  // LocalNetworkGrantEvidence
        row(.cloudKitZone, "FluxKlangAssistantHistory", .history)  // CloudKitAssistantHistoryBackend
    ]

    private static func row(_ kind: StorageSurface.Kind, _ name: String, _ storageClass: StorageClass)
        -> StorageInventoryEntry {
        StorageInventoryEntry(surface: StorageSurface(kind: kind, name: name), storageClass: storageClass)
    }

    /// The class of `surface` in the shipped table, or nil: an unknown surface has no class and is denied.
    static func classification(of surface: StorageSurface) -> StorageClass? {
        classification(of: surface, in: shipped)
    }

    /// The class of the first entry of `entries` for `surface`; a linear scan, never a dictionary.
    static func classification(of surface: StorageSurface, in entries: [StorageInventoryEntry]) -> StorageClass? {
        entries.first { $0.surface.kind == surface.kind && $0.surface.name.utf8.elementsEqual(surface.name.utf8) }?
            .storageClass
    }

    /// Sorted by kind rank, then name UTF-8 bytes; equal surfaces then differ by class raw value.
    static func sorted(_ entries: [StorageInventoryEntry]) -> [StorageInventoryEntry] {
        entries.sorted { lhs, rhs in
            if lhs.surface != rhs.surface { return lhs.surface.sortsBefore(rhs.surface) }
            return lhs.storageClass.rawValue < rhs.storageClass.rawValue
        }
    }

    /// Names are unique across ALL kinds: the first name used twice is refused as `.duplicateSurface`, naming the
    /// later of the pair when entries are ordered by name bytes, then kind rank (so input order never matters).
    static func validate(_ entries: [StorageInventoryEntry]) throws(KeyValueRefusal) {
        let byName = entries.sorted { lhs, rhs in
            let left = lhs.surface
            let right = rhs.surface
            if !left.name.utf8.elementsEqual(right.name.utf8) {
                return left.name.utf8.lexicographicallyPrecedes(right.name.utf8)
            }
            return left.kind.rawValue < right.kind.rawValue
        }
        for index in byName.indices.dropFirst()
        where byName[index - 1].surface.name.utf8.elementsEqual(byName[index].surface.name.utf8) {
            throw .duplicateSurface(byName[index].surface)
        }
    }

    /// Every surface in `surfaces` has a class in `entries`; otherwise the first unclassified one in sort order.
    static func requireClassified(
        _ surfaces: [StorageSurface],
        in entries: [StorageInventoryEntry] = shipped
    ) throws(KeyValueRefusal) {
        for surface in surfaces.sorted(by: { $0.sortsBefore($1) })
        where classification(of: surface, in: entries) == nil {
            throw .unclassified(surface)
        }
    }
}
