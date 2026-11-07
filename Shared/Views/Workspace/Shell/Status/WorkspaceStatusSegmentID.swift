//
//  WorkspaceStatusSegmentID.swift
//  FluxKlang
//
//  The vocabulary of the status strip (#99 W3): its six segments in their fixed
//  order and the three severities. Severity is text plus a glyph, never colour alone.
//

/// One segment of the status strip. The declaration order is the strip order.
enum WorkspaceStatusSegmentID: String, CaseIterable, Hashable, Sendable {
    case engine
    case devices
    case clock
    case peers
    case draft
    case safety

    /// The segment's name: the first word of its accessibility label.
    var title: String {
        switch self {
        case .engine: "Engine"
        case .devices: "Devices"
        case .clock: "Clock"
        case .peers: "Peers"
        case .draft: "Draft"
        case .safety: "Safety"
        }
    }

    /// Whether activating the segment opens a detail list. Safety does not: its Safe Mute and PANIC
    /// buttons are focus stops of their own.
    var opensDetailList: Bool {
        switch self {
        case .engine, .devices, .clock, .peers, .draft: true
        case .safety: false
        }
    }

    /// The index in `WorkspaceStatusProjection.segments`. Explicit, so that reordering the declarations
    /// cannot silently reorder the strip.
    var position: Int {
        switch self {
        case .engine: 0
        case .devices: 1
        case .clock: 2
        case .peers: 3
        case .draft: 4
        case .safety: 5
        }
    }
}

/// How much a segment needs the user's attention: `.normal < .attention < .error`.
enum WorkspaceStatusSeverity: Hashable, Sendable, Comparable, CaseIterable {
    case normal
    case attention
    case error

    /// 0, 1 and 2: the order of `<`.
    var rank: Int {
        switch self {
        case .normal: 0
        case .attention: 1
        case .error: 2
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rank < rhs.rank
    }

    /// The SF Symbol that accompanies the text, so that severity is never colour alone.
    var glyphName: String {
        switch self {
        case .normal: "checkmark.circle"
        case .attention: "exclamationmark.triangle"
        case .error: "exclamationmark.octagon"
        }
    }

    /// The severity as a word, for the accessibility value.
    var word: String {
        switch self {
        case .normal: "Normal"
        case .attention: "Attention"
        case .error: "Error"
        }
    }
}
