//
//  StorageClass.swift
//  FluxKlang
//
//  The closed vocabulary of what the app stores (#124). A class says what kind of data a surface holds, and
//  `StoragePolicy` says where each class may live. Pure values: nothing here reads or writes any storage.
//

/// What a stored value is. The case order is the declaration order and the raw values are stable.
enum StorageClass: String, CaseIterable, Sendable {
    /// UI and behaviour choices. Stay in non-synced local preferences.
    case preference
    /// Home wiring and moves: the global studio connection map.
    case homeWiring
    /// Routing environments.
    case environment
    /// Equipment, presets, spatial layout, fader layout and routing snapshots.
    case catalog
    /// Pending patch drafts. A draft must lose authority before it travels (#122), so it stays local.
    case draft
    /// Assistant conversations.
    case history
    /// Plugin state. Never key-value.
    case pluginState
    /// Clips, audio and capture. Never key-value.
    case media
    /// Peer identities, grants and revocations. This device only.
    case trust
    /// Tokens and secrets. This device only.
    case credential
    /// Device routes, USB maps, hardware mode and host addresses.
    case hostLocalRoute
    /// Rebuildable data.
    case cache
}
