//
//  LibraryReplacementDrop.swift
//  FluxKlang
//
//  The edges a replacement plan keeps and the edges it drops, with the reason for each drop (#101 REP1;
//  library-inspector.md "Replace with..." lists dropped edges in review). Plain values built only by
//  `LibraryReplacementPlan.make`. Nothing calls it yet.
//

/// Why an edge cannot move to the replacement. A port is checked in this order and the first failure is reported.
enum LibraryReplacementDropReason: Hashable, Sendable, CaseIterable {
    /// The layout has no port with that ID.
    case portMissing
    case directionChanged
    case signalChanged
    case channelsChanged
}

/// An edge the replacement cannot take over. It is not reconnected and nothing bridges its two sides.
struct LibraryReplacementDrop: Hashable, Sendable {
    /// The edge as it is in the graph.
    let edge: GraphEdge
    let reason: LibraryReplacementDropReason
    /// The reason in words: `The replacement has no port out.`
    let text: String
}

/// An edge the replacement keeps: the same edge ID, conversion, feedback and extensions, with each endpoint on the
/// old node moved to the replacement.
struct LibraryReplacementKeptEdge: Hashable, Sendable {
    /// The edge as it is in the graph.
    let original: GraphEdge
    /// The edge to connect after the old node is removed.
    let rewritten: GraphEdge
}
