//
//  NeutralSnapshot+Routes.swift
//  FluxKlang
//
//  Route selection, availability and the device-ID allowlist.
//

import Foundation

extension NeutralSnapshotAssembly {
    /// Unavailable routes win over available ones at the cap, so problems stay visible.
    func routes(_ routes: [NeutralSnapshot.RouteInput]) -> Selection<NeutralSnapshot.Route> {
        let selection = Self.select(routes, limit: limits.routes, id: \.route.id, priority: { input in
            Self.availability(of: input) == .available ? 1 : 0
        })
        let refused = RefusedIdentities(withheld, terms: redacted)
        let kept = selection.kept.map { input in
            let route = input.route
            let exposed = Self.isNeutralDeviceAlias(route.device.rawValue, refused: refused)
            return NeutralSnapshot.Route(
                id: route.id, role: route.role, device: exposed ? route.device : nil, isDeviceWithheld: !exposed,
                direction: route.direction, channelCount: route.channels.count, binding: route.binding,
                presence: input.presence, availability: Self.availability(of: input)
            )
        }
        return (kept, selection.count)
    }

    static func availability(of input: NeutralSnapshot.RouteInput) -> NeutralSnapshot.RouteAvailability {
        if input.route.binding == .deviceMissing || input.presence == .missing { return .deviceMissing }
        if input.route.binding == .stale || input.presence == .stale { return .stale }
        guard input.presence == .present else { return .deviceUnobserved }
        return input.route.binding == .confirmed ? .available : .unconfirmed
    }

    /// The allowlist for exposing a `DeviceID`. The contracts and examples name
    /// devices by project alias (`dev.iface-a`, `dev.ctl-b`, `dev.phone-audio`).
    /// An ID is exposed only when:
    /// - it starts with `dev.` and is at most 64 bytes long;
    /// - its dot-separated segments each start with `a`–`z` and use only `a`–`z`, `0`–`9` and single hyphens;
    /// - none of its hyphen-separated tokens looks like a serial number (four or more digits, or six or
    ///   more hex digits including a digit);
    /// - it is not equal, under canonical caseless matching (`RefusedIdentities`), to any
    ///   withheld UID, host, evidence string or hardware identifier.
    ///
    /// Anything else, including UUIDs and CoreAudio UIDs, is withheld, and a device ID
    /// refused by the form is also redacted from every label (`withheldFields(of:)`).
    /// The 64-byte bound is checked on the original ID before any match form is built.
    static func isNeutralDeviceAlias(_ raw: String, refused: RefusedIdentities) -> Bool {
        guard raw.hasPrefix("dev."), raw.utf8.count <= 64, !refused.refuses(raw) else { return false }
        let segments = raw.dropFirst(4).split(separator: ".", omittingEmptySubsequences: false)
        return segments.allSatisfy(isAliasSegment)
    }

    private static func isAliasSegment(_ segment: Substring) -> Bool {
        guard let first = segment.first, ("a"..."z").contains(first) else { return false }
        let tokens = segment.split(separator: "-", omittingEmptySubsequences: false)
        return tokens.allSatisfy { token in
            !token.isEmpty && token.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) }
                && !looksLikeSerial(token)
        }
    }

    private static func looksLikeSerial(_ token: Substring) -> Bool {
        let digits = token.count { ("0"..."9").contains($0) }
        return digits >= 4 || (token.count >= 6 && digits > 0 && token.allSatisfy(\.isHexDigit))
    }
}

/// Identities a device ID must not equal. Every comparison is canonical caseless
/// matching (`UntrustedTextSanitizer.caselessForm`, Unicode D145), never lowercasing,
/// so `ſ`, `K`, `ß`/`ss`, the three `Å` spellings and decomposed Hangul all compare
/// equal. A device ID is refused when either:
/// - its identity form equals that of a withheld identity whose form fits
///   `maximumIdentityFormBytes`, or
/// - a label made of the device ID would be redacted by the prepared withheld terms.
///   This covers longer identities through the label limits (prefix and fail-closed
///   terms included), and makes refusal and label redaction agree by construction.
///
/// The identity form (`identityForm`) is one bounded pipeline for both sides: the
/// label preparation (`filterScalars` keeping at most `maximumIdentityScalars`,
/// `sourceForm`, trimmed) in caseless form. The bound applies to the NORMALIZED
/// form, never to the raw bytes: removed padding (ZWSP, U+2060, U+00AD, a variation
/// selector after a letter) does not count, so `dev.a` padded to 197 bytes is still
/// the identity `dev.a`, on either side. Short identities stay here even though they
/// are too short to be withheld terms (`minimumRedactedBytes`).
///
/// An exposable device ID is ASCII and at most `DeviceID.maximumLength` bytes
/// (`ContractID.validate`), so its form is that long at most. An identity whose form
/// is longer can never equal one, and is skipped on the equality path; the term path
/// still refuses and redacts by it. An identity whose bounded filtering cannot
/// complete has no known form: as a device ID it is refused, and as a withheld
/// identity it is counted in `Truncation.withheldOverflow` (`NeutralSnapshotAssembly`).
///
/// Cost: filtering is linear in the raw input, as for withheld terms; the caseless
/// form is built from at most `maximumIdentityScalars` counted scalars (3× that with
/// kept joiners and selectors), the same order as preparing a withheld term.
///
/// Over-withholding is by design: a term inside an alias refuses it (evidence
/// `confirmed` refuses `dev.confirmed-a`).
struct RefusedIdentities {
    static let none = RefusedIdentities([], terms: [])
    /// The longest form that can equal an exposable device ID.
    static let maximumIdentityFormBytes = DeviceID.maximumLength
    /// Counted scalars bounded filtering keeps before it gives up, the bound withheld
    /// terms are prepared with (`maximumWithheldBytes`).
    static let maximumIdentityScalars = UntrustedTextSanitizer.maximumWithheldBytes

    private let forms: Set<[Unicode.Scalar]>
    private let terms: [UntrustedTextSanitizer.WithheldTerm]

    init(_ identities: [String], terms: [UntrustedTextSanitizer.WithheldTerm]) {
        forms = Set(identities.compactMap(Self.form))
        self.terms = terms
    }

    func refuses(_ raw: String) -> Bool {
        guard let form = Self.form(raw) else { return true }
        if forms.contains(form) { return true }
        let marker = UntrustedLabel.withheldMarker
        return UntrustedTextSanitizer.redactMatchForm(of: raw, withheld: terms, marker: marker, scanIsComplete: true)
            .changed
    }

    /// The identity form when it fits `maximumIdentityFormBytes`, else nil (it cannot
    /// equal a device ID, or bounded filtering could not complete).
    static func form(_ raw: String) -> [Unicode.Scalar]? {
        guard let form = identityForm(raw), fits(form) else { return nil }
        return form
    }

    /// Whether a form is short enough to equal an exposable device ID.
    static func fits(_ form: [Unicode.Scalar]) -> Bool {
        form.reduce(0) { $0 + UTF8.width($1) } <= maximumIdentityFormBytes
    }

    /// The bounded identity pipeline, with no bound on the raw bytes. Nil only when
    /// filtering stops at `maximumIdentityScalars` kept scalars, so the form is unknown.
    static func identityForm(_ raw: String) -> [Unicode.Scalar]? {
        let filtered = UntrustedTextSanitizer.filterScalars(raw.unicodeScalars, keeping: maximumIdentityScalars)
        guard filtered.isComplete else { return nil }
        let source = UntrustedTextSanitizer.sourceForm(filtered.text).trimmingCharacters(in: .whitespacesAndNewlines)
        return UntrustedTextSanitizer.caselessForm(source.unicodeScalars)
    }
}
