//
//  MIDIClipInput.swift
//  FluxKlang
//
//  A clip as a performance input (#112 CL9): the clip's own `MIDIInputID` paired with the routing it plays
//  through. The note ledger keys every sounding note by input, so playing clip events under the clip's own
//  input is what lets a clip stop release exactly the clip's notes and nothing another input holds.
//

/// Why a clip input is refused.
enum MIDIClipOwnershipRefusal: Error, Equatable, Sendable {
    /// The rule at `index` (the first such rule, in rule order) matches events of `ruleInput`, not of the clip's
    /// own input: the clip would be routed as someone else's input.
    case foreignRoutingRule(index: Int, ruleInput: MIDIInputID, clipInput: MIDIInputID)
    /// A batch of `count` events exceeds `limit`; the ledger was not touched.
    case batchTooLarge(count: Int, limit: Int)
}

/// A clip's own input identity and its routing. Only `make` builds one: every routing rule matches the clip's input,
/// the fields are read-only, and the value never changes after creation. An empty routing is accepted: such a clip
/// routes nothing, so its Note Offs are benign unowned notes.
struct MIDIClipInput: Equatable, Sendable {
    var input: MIDIInputID { storedInput }
    var routing: MIDIRouting { storedRouting }

    // Private `let` storage behind get-only accessors: only this file can set it, so nothing skips `make`.
    private let storedInput: MIDIInputID
    private let storedRouting: MIDIRouting

    private init(input: MIDIInputID, routing: MIDIRouting) {
        storedInput = input
        storedRouting = routing
    }

    /// Pairs `input` with `routing`, refusing the first rule (in rule order) whose input is another one.
    static func make(input: MIDIInputID, routing: MIDIRouting) throws(MIDIClipOwnershipRefusal) -> MIDIClipInput {
        for (index, rule) in routing.rules.enumerated() where rule.input != input {
            throw .foreignRoutingRule(index: index, ruleInput: rule.input, clipInput: input)
        }
        return MIDIClipInput(input: input, routing: routing)
    }

    /// One performance event per clip event, in the same order, from the clip's input, with the message unchanged.
    /// Pure: no clock and no ledger.
    func performanceEvents(_ events: [MIDIClipEvent]) -> [MIDIPerformanceEvent] {
        events.map { MIDIPerformanceEvent(input: storedInput, message: $0.message) }
    }
}
