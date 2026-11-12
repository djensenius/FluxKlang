//
//  ActionsV1Record.swift
//  FluxKlang
//
//  The media contract v1 trace's optional top-level `actions` header (#107 ACT1): the declared actions, validated
//  fail-closed and encoded deterministically. Pure: it writes no file and has no `seq`.
//

import Foundation

/// The `actions` header of a contract v1 trace. Built only by `make`; the caller's order is kept, never sorted.
///
/// Checked here: the list is non-empty, at most `maximumActions` long and has no repeated `actionId`. Left to the
/// checker and the future assembler: that every trigger and readiness record names a declared action, the
/// readiness transitions, and that a `ready` `timeStretch` action has `adapterCapabilities.timeStretch`.
struct ActionsV1Record: Hashable, Sendable {
    /// `ActionReadiness`'s capacity.
    static let maximumActions = 4096

    let actions: [ActionV1Record]

    /// Builds the header from `actions`, or throws the first refusal in the order `ActionsV1RecordRefusal`
    /// documents.
    static func make(_ actions: [ActionV1Record]) throws(ActionsV1RecordRefusal) -> ActionsV1Record {
        guard !actions.isEmpty else { throw .empty }
        guard actions.count <= maximumActions else { throw .tooManyActions(count: actions.count) }
        var seen = Set<ActionID>()
        for action in actions {
            guard seen.insert(action.id).inserted else { throw .duplicateActionID(action.id) }
        }
        return ActionsV1Record(actions: actions)
    }

    private init(actions: [ActionV1Record]) {
        self.actions = actions
    }

    /// Compact UTF-8 JSON with sorted keys and unescaped slashes (`ContractCoding`): one array of the member
    /// objects in the caller's order. Identical input encodes to identical bytes. The output is bounded by the
    /// input: at most 4096 members of at most a few hundred bytes each.
    func encodedJSON() throws -> Data {
        try ContractCoding.makeEncoder().encode(self)
    }
}

extension ActionsV1Record: Encodable {
    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(actions)
    }
}
