//
//  LibraryPluginText.swift
//  FluxKlang
//
//  The fixed English of the Library plugin list (#99 LIB1; library-inspector.md "Library": status words are always
//  text): kind, status and reason text, the title of a row with no name and the VoiceOver labels. Pure string
//  builders: no localisation, truncation or escaping. Used by `LibrarySectionView`.
//

enum LibraryPluginText {
    static let namelessTitle = "Unnamed plugin"
    static let scanRowTitle = "(scan)"
    static let notScannedText = "Not scanned"
    static let scanRowAccessibilityLabel = "Plugin catalog, not scanned"

    static func kind(_ kind: PluginComponentKind) -> String {
        switch kind {
        case .effect: "Effect"
        case .musicEffect: "Music effect"
        case .instrument: "Instrument"
        case .generator: "Generator"
        case .midiProcessor: "MIDI processor"
        }
    }

    static func status(_ status: LibraryPluginStatus) -> String {
        switch status {
        case .installed: "Installed"
        case .missing: "Missing"
        case .incompatible: "Incompatible"
        case .failed: "Scan failed"
        case .needsRescan: "Needs rescan"
        case .quarantined: "Quarantined"
        }
    }

    /// Why a status is what it is; nil for the statuses that carry no reason.
    static func reason(of status: LibraryPluginStatus) -> String? {
        switch status {
        case .incompatible(.wrongKind): "Wrong kind of plugin"
        case .incompatible(.wrongPorts): "Ports do not match"
        case .quarantined(.probeCrashed): "Crashed while probed"
        case .quarantined(.probeTimedOut): "Timed out while probed"
        case .installed, .missing, .failed, .needsRescan: nil
        }
    }

    /// "<title>, <kind>, <status>", plus ": <reason>" when there is one.
    static func accessibilityLabel(title: String, kind: PluginComponentKind, status: LibraryPluginStatus) -> String {
        let label = "\(title), \(Self.kind(kind)), \(Self.status(status))"
        return reason(of: status).map { "\(label): \($0)" } ?? label
    }
}
