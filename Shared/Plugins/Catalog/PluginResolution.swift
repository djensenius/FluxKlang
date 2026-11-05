//
//  PluginResolution.swift
//  FluxKlang
//
//  Resolving a project's plugin reference against the catalog. A reference
//  resolves only to its exact identity. A component that is quarantined,
//  missing, failed, unscanned or awaiting a fresh description yields a
//  placeholder that keeps the reference, never a look-alike substitute.
//

import Foundation

/// A project's reference to a plugin, retained verbatim whatever the catalog says.
struct PluginReference: Hashable, Sendable {
    let identity: PluginIdentity
    let lastKnownName: String
    let lastKnownVersion: PluginVersion?

    init(
        identity: PluginIdentity, lastKnownName: String, lastKnownVersion: PluginVersion?
    ) throws(PluginDescriptorError) {
        guard PluginDescriptor.isValidName(lastKnownName) else { throw .invalidName }
        self.identity = identity
        self.lastKnownName = lastKnownName
        self.lastKnownVersion = lastKnownVersion
    }
}

enum PluginPlaceholderReason: Hashable, Sendable {
    case notScanned
    case notInstalled
    case failed(PluginScanFailure)
    case quarantined(PluginQuarantineReason)
    case needsRescan
}

struct PluginPlaceholder: Hashable, Sendable {
    let reference: PluginReference
    let reason: PluginPlaceholderReason
    let lastKnown: PluginDescriptor?
}

enum PluginResolutionOutcome: Hashable, Sendable {
    case available(PluginDescriptor, versionChanged: Bool)
    case placeholder(PluginPlaceholder)
}

/// A resolution is only as current as the generation it was made under.
struct PluginResolution: Hashable, Sendable {
    let generation: Generation
    let outcome: PluginResolutionOutcome
}

extension PluginCatalog {
    func resolve(_ reference: PluginReference) -> PluginResolution {
        PluginResolution(generation: generation, outcome: outcome(for: reference))
    }

    private func outcome(for reference: PluginReference) -> PluginResolutionOutcome {
        let entry = entries[reference.identity.id].flatMap { $0.identity == reference.identity ? $0 : nil }
        func placeholder(_ reason: PluginPlaceholderReason) -> PluginResolutionOutcome {
            .placeholder(PluginPlaceholder(reference: reference, reason: reason, lastKnown: entry?.lastKnown))
        }
        if let reason = entry?.quarantine { return placeholder(.quarantined(reason)) }
        guard scanState == .scanned else { return placeholder(.notScanned) }
        guard let entry else { return placeholder(.notInstalled) }
        switch entry.presence {
        case .missing:
            return placeholder(.notInstalled)
        case .failed(let failure):
            return placeholder(.failed(failure))
        case .needsRescan:
            return placeholder(.needsRescan)
        case .installed:
            guard let descriptor = entry.lastKnown else { return placeholder(.needsRescan) }
            let changed = reference.lastKnownVersion.map { $0 != descriptor.version } ?? false
            return .available(descriptor, versionChanged: changed)
        }
    }
}
