//
//  WingRouteAddressClass.swift
//  FluxKlang
//
//  The WING addresses a Studio apply writes (#62 AU7a), which
//  `WingDirectSendScope` admits under its one reserved route scope.
//

/// The address classes a Studio apply sends, parsed strictly from the shapes
/// `WingAddress` builds for it: `/<kind>/<index>/name`, `/fdr` and `/mute`;
/// `/<kind>/<index>/send/<bus>/on` and `/lvl`; `/<kind>/<index>/main/<main>/on`
/// and `/lvl`; `/ch/<channel>/in/conn/grp` and `/in`; and
/// `/io/out/<bank>/<connector>/grp` and `/in`. `kind` is a `WingNodeKind` raw value
/// and `bank` a `WingOutputConnectorBank` raw value. `index` is in `1...kind.count`,
/// `bus` in `1...WingNodeKind.bus.count`, `main` in `1...WingNodeKind.main.count`
/// and `connector` in `bank.connectorRange`, all canonical ASCII decimal.
/// Case-sensitive, with no extra segments. Pan and colour are not route classes:
/// Studio apply never writes them.
enum WingRouteAddressClass: Hashable, Sendable, CaseIterable {
    case name, fader, mute
    case sendOn, sendLevel, mainOn, mainLevel
    case channelSourceGroup, channelSourceIndex
    case outputSourceGroup, outputSourceIndex

    /// UTF-8 length of the longest valid address, `/bus/16/send/16/lvl`. Longer
    /// input is refused before it is split.
    static let maximumByteCount = 19

    init?(address: String) {
        guard address.utf8.count <= Self.maximumByteCount else { return nil }
        // Six splits cover the longest shapes; any remainder lands in a seventh segment, which is refused.
        let segments = address.split(separator: "/", maxSplits: 6, omittingEmptySubsequences: false)
        guard segments.count >= 4, segments[0].isEmpty else { return nil }
        let parsed = segments[1] == "io" ? Self.output(Array(segments[2...])) : Self.strip(Array(segments[1...]))
        guard let parsed else { return nil }
        self = parsed
    }

    /// `segments` is `[kind, index, leaf...]`, with at least one leaf segment.
    private static func strip(_ segments: [Substring]) -> Self? {
        guard let kind = WingNodeKind(rawValue: String(segments[0])),
              WingAddressClass.index(segments[1], in: 1...kind.count) != nil else { return nil }
        switch Array(segments[2...]) {
        case ["name"]: return .name
        case ["fdr"]: return .fader
        case ["mute"]: return .mute
        case ["in", "conn", "grp"] where kind == .channel: return .channelSourceGroup
        case ["in", "conn", "in"] where kind == .channel: return .channelSourceIndex
        case let tail where tail.count == 3 && tail[0] == "send"
            && WingAddressClass.index(tail[1], in: 1...WingNodeKind.bus.count) != nil:
            return leaf(tail[2], enabled: .sendOn, level: .sendLevel)
        case let tail where tail.count == 3 && tail[0] == "main"
            && WingAddressClass.index(tail[1], in: 1...WingNodeKind.main.count) != nil:
            return leaf(tail[2], enabled: .mainOn, level: .mainLevel)
        default: return nil
        }
    }

    /// `segments` is `["out", bank, connector, leaf]`.
    private static func output(_ segments: [Substring]) -> Self? {
        guard segments.count == 4, segments[0] == "out",
              let bank = WingOutputConnectorBank(rawValue: String(segments[1])),
              WingAddressClass.index(segments[2], in: bank.connectorRange) != nil else { return nil }
        switch segments[3] {
        case "grp": return .outputSourceGroup
        case "in": return .outputSourceIndex
        default: return nil
        }
    }

    private static func leaf(_ segment: Substring, enabled: Self, level: Self) -> Self? {
        switch segment {
        case "on": return enabled
        case "lvl": return level
        default: return nil
        }
    }
}
