//
//  VersionCompatibilityMatrix.swift
//  FluxKlang
//
//  "A newer version is not presumed compatible" (#78, slice PLG6, slice B). The matrix
//  answers whether the plugin a restore would load into is a version the caller has
//  qualified, from caller-supplied evidence (PLG4's `QualifiedVersionEvidence`). It holds
//  no vendor knowledge, keeps no state and never looks at a blob, a file or a clock.
//

enum VersionCompatibilityMatrix {
    /// Only ranges for the target's identity count. Answers, in this order:
    /// - `.unknown` when no range names the identity (including no evidence at all);
    /// - `.notQualified(.unknownVendor)` when ranges name the identity but none with the target's
    ///   vendor tag (compared with `PluginVendorTag ==`, the UTF-8 byte comparison PLG4 defines);
    /// - `.qualified` when any matching range covers the version (both ends included);
    /// - `.notQualified(.newer)` when no matching range covers the version and it is above the
    ///   upper end of at least one of them (a version in a gap between two ranges is newer);
    /// - `.notQualified(.older)` otherwise (below every matching range).
    /// The answer does not depend on the order of the ranges.
    static func verdict(for target: PluginStateTarget, evidence: QualifiedVersionEvidence) -> CompatibilityVerdict {
        let sameIdentity = evidence.ranges.filter { $0.identity == target.identity }
        guard !sameIdentity.isEmpty else { return .unknown }
        let sameVendor = sameIdentity.filter { $0.vendorTag == target.vendorTag }
        guard !sameVendor.isEmpty else { return .notQualified(.unknownVendor) }
        if sameVendor.contains(where: { $0.covers(target.version) }) { return .qualified }
        if sameVendor.contains(where: { target.version > $0.upper }) { return .notQualified(.newer) }
        return .notQualified(.older)
    }
}
