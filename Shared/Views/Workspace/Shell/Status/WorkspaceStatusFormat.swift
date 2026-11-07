//
//  WorkspaceStatusFormat.swift
//  FluxKlang
//
//  The few sentences the status strip builds from numbers and lists (#99 W3).
//  Integer-only: no floating point, no locale, no Foundation.
//

/// One line of a capped list and whether it is lost (a missing device, a disconnected peer). A plain value
/// with no invariant, so it keeps its memberwise initialiser.
struct WorkspaceStatusListEntry: Hashable, Sendable {
    let text: String
    let isLost: Bool
}

enum WorkspaceStatusFormat {
    /// `hertz` as kilohertz with up to three decimals and no trailing zeros: 48000 is "48 kHz", 44100 is
    /// "44.1 kHz", 47999 is "47.999 kHz" and 1 is "0.001 kHz". Total for every `Int`; the status projection
    /// only passes validated rates (1...768_000), and a negative value keeps its sign.
    static func kilohertz(_ hertz: Int) -> String {
        let sign = hertz < 0 ? "-" : ""
        let magnitude = hertz.magnitude
        let whole = magnitude / 1_000
        let remainder = magnitude % 1_000
        guard remainder != 0 else { return "\(sign)\(whole) kHz" }
        let digits = String(remainder)
        var fraction = String(repeating: "0", count: 3 - digits.count) + digits
        while fraction.hasSuffix("0") { fraction.removeLast() }
        return "\(sign)\(whole).\(fraction) kHz"
    }

    /// The first `limit` items joined by ", ", then ", and N more" with N the exact number of items left
    /// out. `limit` is one of the named positive constants; nothing is dropped without being counted.
    static func summary(_ items: [String], limit: Int) -> String {
        let shown = items.prefix(limit)
        let head = shown.joined(separator: ", ")
        let hidden = items.count - shown.count
        guard hidden > 0 else { return head }
        return "\(head), and \(hidden) more"
    }

    /// `summary(_:limit:)` over the texts of `entries` and, when at least one HIDDEN entry is lost, a final
    /// ", K <lostWord>" with K the exact number of hidden lost entries: "P1, P2, P3, and 1 more, 1 disconnected".
    /// Without it a lost item behind "and N more" would leave the sentence unchanged, and the announcer
    /// would speak the sentence the listener already heard as a new error. Lost entries that are listed are
    /// not counted again, and nothing is added when no hidden entry is lost.
    static func summary(_ entries: [WorkspaceStatusListEntry], limit: Int, lostWord: String) -> String {
        let list = summary(entries.map(\.text), limit: limit)
        let hiddenLost = entries.dropFirst(limit).filter(\.isLost).count
        guard hiddenLost > 0 else { return list }
        return "\(list), \(hiddenLost) \(lostWord)"
    }

    /// "1 stale command discarded" or "N stale commands discarded".
    static func staleCommands(_ count: Int) -> String {
        count == 1 ? "1 stale command discarded" : "\(count) stale commands discarded"
    }
}
