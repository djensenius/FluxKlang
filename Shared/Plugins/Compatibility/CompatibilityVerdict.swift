//
//  CompatibilityVerdict.swift
//  FluxKlang
//
//  The answer of the version compatibility matrix (#78, slice PLG6, slice B). A verdict
//  is evidence-based and never optimistic: the only way to `qualified` is a range the
//  caller supplied. Pure values.
//

/// Why a version is not qualified although evidence for its plugin exists.
enum NotQualifiedReason: Hashable, Sendable, CaseIterable {
    /// Above at least one qualified range for this identity and vendor tag, and in none.
    /// A newer version is not presumed compatible, whatever its number.
    case newer
    /// Below every qualified range for this identity and vendor tag.
    case older
    /// The evidence for this plugin names other vendor tags only.
    case unknownVendor
}

enum CompatibilityVerdict: Hashable, Sendable {
    /// A supplied range for this identity and vendor tag covers the version, both ends included.
    case qualified
    case notQualified(NotQualifiedReason)
    /// No evidence names this plugin at all. Never `qualified`.
    case unknown
}
