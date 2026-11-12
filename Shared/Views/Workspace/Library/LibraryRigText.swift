//
//  LibraryRigText.swift
//  FluxKlang
//
//  The fixed English of the Library rig list (#99 LIB3; library-inspector.md "Library": status words are always
//  text): kind, status, detail and selected text and the VoiceOver labels. Pure string builders: no localisation,
//  truncation or escaping. Nothing calls it yet.
//

enum LibraryRigText {
    static let kind = "Rig"
    static let selected = "Selected"
    static let noDevices = "No devices"
    static let allMatched = "all matched"

    static func status(_ status: LibraryRigStatus) -> String {
        switch status {
        case .full: "Full"
        case .partial: "Partial"
        case .manualRemote: "Manual or remote"
        }
    }

    /// "No devices", or "N device(s)" followed by each non-zero count in the order missing, stale, ambiguous,
    /// renumbered, or ", all matched" when every device is matched.
    static func detail(_ counts: LibraryRigCounts) -> String {
        let total = counts.total
        guard total > 0 else { return noDevices }
        var text = total == 1 ? "1 device" : "\(total) devices"
        if counts.matched == total { return "\(text), \(allMatched)" }
        let parts = [("missing", counts.missing), ("stale", counts.stale),
                     ("ambiguous", counts.ambiguous), ("renumbered", counts.renumbered)]
        for (word, count) in parts where count > 0 {
            text += ", \(count) \(word)"
        }
        return text
    }

    /// "<title>, Rig, <status>, <detail>", plus ", Selected" for the selected row.
    static func accessibilityLabel(
        title: String, status: LibraryRigStatus, detail: String, isSelected: Bool
    ) -> String {
        let label = "\(title), \(kind), \(Self.status(status)), \(detail)"
        return isSelected ? "\(label), \(selected)" : label
    }
}
