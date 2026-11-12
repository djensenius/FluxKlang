//
//  LibraryPatchText.swift
//  FluxKlang
//
//  The fixed English of the Library patch list (#99 LIB2): kind text, detail text, the two reasons, the title of a
//  patch with a blank label and the VoiceOver labels. Pure string builders: no localisation, truncation or
//  escaping. Nothing calls it yet.
//

enum LibraryPatchText {
    static let patchKind = "Patch"
    static let variationKind = "Variation"
    static let unnamedPatchTitle = "Unnamed patch"
    static let noVariations = "No variations"
    static let noDeltas = "No deltas"
    static let preparedSuffix = ", prepared"
    /// The sentence the Inspector states table uses for a newer-version value (library-inspector.md).
    static let newerVersionReason = "Contains fields from a newer version (kept)"
    static let unreadableReason = "Variations could not be read"

    static func variationCount(_ count: Int) -> String {
        switch count {
        case 0: noVariations
        case 1: "1 variation"
        default: "\(count) variations"
        }
    }

    static func deltaCount(_ count: Int, isPrepared: Bool) -> String {
        let text = switch count {
        case 0: noDeltas
        case 1: "1 delta"
        default: "\(count) deltas"
        }
        return isPrepared ? text + preparedSuffix : text
    }

    /// "<title>, <kind text>, <detail text>"; never the actions.
    static func accessibilityLabel(title: String, kindText: String, detailText: String) -> String {
        "\(title), \(kindText), \(detailText)"
    }
}
