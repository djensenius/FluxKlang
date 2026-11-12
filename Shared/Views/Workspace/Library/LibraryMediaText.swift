//
//  LibraryMediaText.swift
//  FluxKlang
//
//  The fixed English of the Library charts and media list and the Templates placeholder (#99 LIB4): section titles,
//  kind and status words, the Locate title, the title of an asset with a blank label and the VoiceOver label. Pure
//  string builders: no localisation, truncation or escaping. Nothing calls it yet.
//

enum LibraryMediaText {
    static let sectionTitle = "Charts & media"
    static let unnamedAsset = "Unnamed asset"
    static let available = "Available"
    static let staleBookmark = "Stale bookmark"
    static let locate = "Locate..."
    static let templatesTitle = "Templates"
    static let templatesPlaceholder = "(none yet)"

    static func kind(_ media: AssetMedia) -> String {
        switch media {
        case .document: "Chart"
        case .audio: "Audio"
        case .midi: "MIDI"
        }
    }

    static func status(_ status: LibraryMediaStatus) -> String {
        switch status {
        case .available: available
        case .staleBookmark: staleBookmark
        }
    }

    /// "<title>, <kind text>, <status text>"; never the actions.
    static func accessibilityLabel(title: String, kindText: String, statusText: String) -> String {
        "\(title), \(kindText), \(statusText)"
    }
}
