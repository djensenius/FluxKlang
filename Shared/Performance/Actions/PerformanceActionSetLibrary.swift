//
//  PerformanceActionSetLibrary.swift
//  FluxKlang
//
//  The project's action sets and their resolution against its persisted
//  `ProjectMediaAction`s. Codable only: the `ProjectDocument` slot is #54's.
//

import Foundation

/// A set whose members all resolved, in member order.
struct ResolvedActionSet: Hashable, Sendable {
    let set: PerformanceActionSet
    let actions: [ProjectMediaAction]

    var mediaKinds: Set<ActionMedia> { Set(actions.map(\.policy.media)) }
}

struct PerformanceActionSetLibrary: Codable, Hashable, Sendable {
    static let maximumSets = 256

    enum CodingKeys: String, CodingKey, CaseIterable {
        case sets, extensions
    }

    let sets: [PerformanceActionSet]
    var extensions: [String: JSONValue]?
    var unknownFields: [String: JSONValue] = [:]

    init(sets: [PerformanceActionSet] = [], extensions: [String: JSONValue]? = nil) throws(ActionSetRefusal) {
        self.sets = sets
        self.extensions = extensions
        try validate()
    }

    func validate() throws(ActionSetRefusal) {
        guard sets.count <= Self.maximumSets else { throw .tooManySets(sets.count) }
        var seen = Set<ActionSetID>()
        for set in sets {
            guard seen.insert(set.id).inserted else { throw .duplicateSet(set.id) }
            try set.validate()
        }
    }

    /// Checks that every set resolves against `actions`.
    func validate(against actions: [ProjectMediaAction]) throws(ActionSetRefusal) {
        try validate()
        let index = try Self.index(actions)
        for set in sets { _ = try Self.resolve(set, index: index) }
    }

    func resolve(_ id: ActionSetID, in actions: [ProjectMediaAction]) throws(ActionSetRefusal) -> ResolvedActionSet {
        guard let set = sets.first(where: { $0.id == id }) else { throw .unknownSet(id) }
        return try Self.resolve(set, index: Self.index(actions))
    }

    private static func index(_ actions: [ProjectMediaAction]) throws(ActionSetRefusal)
        -> [ActionID: ProjectMediaAction] {
        var index: [ActionID: ProjectMediaAction] = [:]
        for action in actions {
            guard index.updateValue(action, forKey: action.id) == nil else { throw .ambiguousProjectAction(action.id) }
        }
        return index
    }

    private static func resolve(_ set: PerformanceActionSet,
                                index: [ActionID: ProjectMediaAction]) throws(ActionSetRefusal) -> ResolvedActionSet {
        var actions: [ProjectMediaAction] = []
        for member in set.members {
            guard let action = index[member] else { throw .unknownMember(member) }
            actions.append(action)
        }
        return ResolvedActionSet(set: set, actions: actions)
    }

    init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(sets: fields.decode([PerformanceActionSet].self, forKey: .sets),
                      extensions: fields.decodeIfPresent([String: JSONValue].self, forKey: .extensions))
        unknownFields = try ExtensionFields.decode(from: decoder, knownKeys: CodingKeys.self)
    }

    func encode(to encoder: any Encoder) throws {
        try validate()
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(sets, forKey: .sets)
        try fields.encodeIfPresent(extensions, forKey: .extensions)
        try ExtensionFields.encode(unknownFields, to: encoder, knownKeys: CodingKeys.self)
    }
}
