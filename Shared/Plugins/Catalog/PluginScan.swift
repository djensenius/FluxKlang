//
//  PluginScan.swift
//  FluxKlang
//
//  The injected scanner boundary. A production scanner (later work) wraps the
//  OS component registry and any contained probe process; this module only
//  defines what a scanner is asked and what it may answer. A report describes
//  one complete pass: a component it omits is treated as not installed.
//

import Foundation

/// How deep a scan may go. Metadata only never instantiates a component.
enum PluginScanDepth: String, Hashable, Sendable {
    case metadataOnly
    /// Instantiates components to probe them, which can crash or hang.
    case instantiatingProbe
}

/// What the host is doing when a scan is requested.
enum PluginHostActivity: String, Hashable, Sendable {
    case idle
    /// A performance is running. Untrusted probes are refused until qualified containment exists.
    case performing
}

/// Why a component could be enumerated but not described.
enum PluginScanFailure: Hashable, Sendable {
    case metadataUnavailable
    case invalidMetadata(PluginDescriptorError)
    case validationFailed
}

/// Why a component is quarantined. Quarantine is sticky until explicitly released.
enum PluginQuarantineReason: String, Hashable, Sendable {
    case probeCrashed
    case probeTimedOut
}

enum PluginScanOutcome: Hashable, Sendable {
    case described(PluginDescriptor)
    case failed(PluginScanFailure)
    /// Only possible for an instantiating probe of a non-quarantined component.
    case probeCrashed
    /// Only possible for an instantiating probe of a non-quarantined component.
    case probeTimedOut
}

struct PluginScanEntry: Hashable, Sendable {
    let identity: PluginIdentity
    let outcome: PluginScanOutcome
}

/// What the catalog asks a scanner to do.
struct PluginScanRequest: Hashable, Sendable {
    let depth: PluginScanDepth
    /// Quarantined components the scanner must enumerate but never instantiate.
    let quarantined: Set<PluginID>
}

/// One complete pass. A cancelled or failed pass produces no report.
struct PluginScanReport: Hashable, Sendable {
    let entries: [PluginScanEntry]

    /// The probe failures in this pass, kept even when its metadata is discarded.
    var quarantineEvidence: [PluginQuarantineEvidence] {
        entries.compactMap { entry in
            switch entry.outcome {
            case .probeCrashed: PluginQuarantineEvidence(identity: entry.identity, reason: .probeCrashed)
            case .probeTimedOut: PluginQuarantineEvidence(identity: entry.identity, reason: .probeTimedOut)
            case .described, .failed: nil
            }
        }
    }
}

/// A probe crash or hang observed during a pass, whether or not the pass completed.
struct PluginQuarantineEvidence: Hashable, Sendable {
    let identity: PluginIdentity
    let reason: PluginQuarantineReason
}

/// A pass that ended without a report. Probe failures observed before it ended
/// travel with the error so that crash isolation survives cancellation.
enum PluginScannerError: Error, Equatable, Sendable {
    case cancelled(quarantine: [PluginQuarantineEvidence])
    case unavailable(quarantine: [PluginQuarantineEvidence])

    var quarantine: [PluginQuarantineEvidence] {
        switch self {
        case .cancelled(let evidence), .unavailable(let evidence): evidence
        }
    }
}

/// The only way the catalog learns about installed components.
protocol PluginComponentScanner: Sendable {
    func scan(_ request: PluginScanRequest) async throws(PluginScannerError) -> PluginScanReport
}
