//
//  StateQualification.swift
//  FluxKlang
//
//  Decides whether an opaque snapshot may be restored into the CURRENT plugin
//  (#77, slice PLG4). The decision looks only at the identity, the vendor tag, the
//  versions and the storage class, never at the blob. Version compatibility is
//  evidence the caller supplies: this model holds no vendor knowledge, never
//  presumes a newer version compatible and does not presume an older one either.
//

/// The plugin a restore would load into: what the host sees now.
struct PluginStateTarget: Hashable, Sendable {
    let identity: PluginIdentity
    let version: PluginVersion
    let vendorTag: PluginVendorTag
}

enum QualificationEvidenceError: Error, Hashable, Sendable {
    case invertedRange(lower: PluginVersion, upper: PluginVersion)
    case tooManyRanges(count: Int, limit: Int)
}

/// Caller-supplied evidence that, for one plugin and one vendor tag, every version
/// from `lower` to `upper` (both inclusive) restores each other's state.
struct QualifiedVersionRange: Hashable, Sendable {
    let identity: PluginIdentity
    let vendorTag: PluginVendorTag
    let lower: PluginVersion
    let upper: PluginVersion

    init(
        identity: PluginIdentity, vendorTag: PluginVendorTag, lower: PluginVersion, upper: PluginVersion
    ) throws(QualificationEvidenceError) {
        guard lower <= upper else { throw .invertedRange(lower: lower, upper: upper) }
        self.identity = identity
        self.vendorTag = vendorTag
        self.lower = lower
        self.upper = upper
    }

    func covers(_ version: PluginVersion) -> Bool {
        (lower...upper).contains(version)
    }
}

/// A bounded set of qualified ranges. The order never matters: a decision is made
/// when ANY single range covers both versions.
struct QualifiedVersionEvidence: Hashable, Sendable {
    static let maximumRanges = 256
    static let none = QualifiedVersionEvidence()

    let ranges: [QualifiedVersionRange]

    private init() {
        ranges = []
    }

    init(ranges: [QualifiedVersionRange]) throws(QualificationEvidenceError) {
        guard ranges.count <= Self.maximumRanges else {
            throw .tooManyRanges(count: ranges.count, limit: Self.maximumRanges)
        }
        self.ranges = ranges
    }
}

/// Why a restore is not qualified. Payloads carry both sides so a caller can show them.
enum StateRefusal: Hashable, Sendable {
    case missingBlob
    case identityMismatch(captured: PluginIdentity, current: PluginIdentity)
    case vendorMismatch(captured: PluginVendorTag, current: PluginVendorTag)
    case versionNotQualified(captured: PluginVersion, current: PluginVersion)
    case storageClassUnsuitable(StateStorageClass, for: StatePurpose)
}

/// The outcome of qualifying one snapshot for one purpose. `refusals` is empty
/// exactly when the snapshot is qualified. Only `evaluate` builds one.
///
/// Order of `refusals` (fixed, independent of argument and evidence order):
/// identity, vendor, version, storage class. A missing snapshot is reported alone.
struct StateQualification: Hashable, Sendable {
    let refusals: [StateRefusal]

    var isQualified: Bool { refusals.isEmpty }

    private init(refusals: [StateRefusal]) {
        self.refusals = refusals
    }

    static func evaluate(
        snapshot: PluginStateSnapshot?, target: PluginStateTarget, purpose: StatePurpose,
        evidence: QualifiedVersionEvidence
    ) -> StateQualification {
        guard let snapshot else { return StateQualification(refusals: [.missingBlob]) }
        var refusals: [StateRefusal] = []
        if snapshot.identity != target.identity {
            refusals.append(.identityMismatch(captured: snapshot.identity, current: target.identity))
        }
        if snapshot.vendorTag != target.vendorTag {
            refusals.append(.vendorMismatch(captured: snapshot.vendorTag, current: target.vendorTag))
        }
        if !versionsQualify(snapshot, target, evidence) {
            refusals.append(.versionNotQualified(captured: snapshot.version, current: target.version))
        }
        if !snapshot.storageClass.suits(purpose) {
            refusals.append(.storageClassUnsuitable(snapshot.storageClass, for: purpose))
        }
        return StateQualification(refusals: refusals)
    }

    /// Equal versions always qualify. Otherwise one range for the snapshot's own
    /// identity and vendor tag must cover both versions; a range for the target
    /// that the snapshot does not share is never usable.
    private static func versionsQualify(
        _ snapshot: PluginStateSnapshot, _ target: PluginStateTarget, _ evidence: QualifiedVersionEvidence
    ) -> Bool {
        if snapshot.version == target.version { return true }
        return evidence.ranges.contains { range in
            range.identity == snapshot.identity && range.identity == target.identity
                && range.vendorTag == snapshot.vendorTag && range.vendorTag == target.vendorTag
                && range.covers(snapshot.version) && range.covers(target.version)
        }
    }
}
