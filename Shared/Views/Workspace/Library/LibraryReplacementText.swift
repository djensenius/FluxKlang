//
//  LibraryReplacementText.swift
//  FluxKlang
//
//  The fixed English of a replacement plan's review (#101 REP1; library-inspector.md "Replace with..."): the
//  summary line, one line per dropped edge and the reason texts. Pure string builders over raw IDs: no
//  localisation, truncation or escaping. Nothing calls it yet.
//

/// Text builders for `LibraryReplacementPlan`.
enum LibraryReplacementText {
    /// `Replace nod.echo with Spring Reverb: keeps 2 edges, drops 1.`
    static func summary(replacing node: NodeID, name: String, kept: Int, dropped: Int) -> String {
        "Replace \(node) with \(name): keeps \(kept) \(edges(kept)), drops \(dropped)."
    }

    /// `Drops edg.echo-verb (nod.echo/out to nod.verb/in): The replacement has no port out.`
    static func dropLine(_ drop: LibraryReplacementDrop) -> String {
        let edge = drop.edge
        let from = "\(edge.from.node)/\(edge.from.port)"
        let target = "\(edge.to.node)/\(edge.to.port)"
        return "Drops \(edge.id) (\(from) to \(target)): \(drop.text)"
    }

    /// `The replacement has no port out.`
    static func portMissing(_ port: PortID) -> String {
        "The replacement has no port \(port)."
    }

    /// `Port out is an input on the replacement.` (the replacement's direction).
    static func directionChanged(_ port: PortID, now: PortDirection) -> String {
        "Port \(port) is \(now == .input ? "an input" : "an output") on the replacement."
    }

    /// `Port out carries midi on the replacement, not audio.`
    static func signalChanged(_ port: PortID, now: PortSignal, was: PortSignal) -> String {
        "Port \(port) carries \(now.rawValue) on the replacement, not \(was.rawValue)."
    }

    /// `Port out has 1 channel on the replacement, not 2.`
    static func channelsChanged(_ port: PortID, now: Int?, was: Int?) -> String {
        "Port \(port) has \(channels(now)) on the replacement, not \(was.map(String.init) ?? noCount)."
    }

    private static let noCount = "no channel count"

    private static func edges(_ count: Int) -> String { count == 1 ? "edge" : "edges" }

    private static func channels(_ count: Int?) -> String {
        guard let count else { return noCount }
        return count == 1 ? "1 channel" : "\(count) channels"
    }
}
