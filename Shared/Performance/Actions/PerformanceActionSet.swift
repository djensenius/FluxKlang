//
//  PerformanceActionSet.swift
//  FluxKlang
//
//  A named, ordered set of prepared project actions fired together as one
//  performance gesture (#107 A1, media-contract.md §5.8, §6.4). A set is
//  declarative only: it never loads media and is not proof of readiness.
//

import Foundation

enum ActionSetTag: ContractIDTag {}
typealias ActionSetID = ContractID<ActionSetTag>

struct PerformanceActionSet: Codable, Hashable, Sendable, Identifiable {
    static let maximumMembers = 16
    static let maximumNameBytes = 128

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, name, members, cancelScope, extensions
    }

    let id: ActionSetID
    let name: String?
    /// Fired in this order; unique.
    let members: [ActionID]
    /// Exactly one scope per set; several sets may share one (a scene).
    let cancelScope: GenerationSubject
    var extensions: [String: JSONValue]?
    var unknownFields: [String: JSONValue] = [:]

    var cancelScopeKey: GenerationKey { GenerationKey(kind: .cancelScope, subject: cancelScope) }

    /// `cancelScope` defaults to the set's own ID.
    init(id: ActionSetID, name: String? = nil, members: [ActionID], cancelScope: GenerationSubject? = nil,
         extensions: [String: JSONValue]? = nil) throws(ActionSetRefusal) {
        self.id = id
        self.name = name
        self.members = members
        self.cancelScope = cancelScope ?? GenerationKey(.cancelScope, id).subject
        self.extensions = extensions
        try validate()
    }

    func validate() throws(ActionSetRefusal) {
        guard !members.isEmpty else { throw .emptySet }
        guard members.count <= Self.maximumMembers else { throw .tooManyMembers(members.count) }
        var seen = Set<ActionID>()
        for member in members where !seen.insert(member).inserted {
            throw .duplicateMember(member)
        }
        if let name {
            let bytes = name.utf8.count
            guard (1...Self.maximumNameBytes).contains(bytes) else { throw .invalidName(bytes) }
        }
    }

    init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: fields.decode(ActionSetID.self, forKey: .id),
                      name: fields.decodeIfPresent(String.self, forKey: .name),
                      members: fields.decode([ActionID].self, forKey: .members),
                      cancelScope: fields.decode(GenerationSubject.self, forKey: .cancelScope),
                      extensions: fields.decodeIfPresent([String: JSONValue].self, forKey: .extensions))
        unknownFields = try ExtensionFields.decode(from: decoder, knownKeys: CodingKeys.self)
    }

    func encode(to encoder: any Encoder) throws {
        try validate()
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(id, forKey: .id)
        try fields.encodeIfPresent(name, forKey: .name)
        try fields.encode(members, forKey: .members)
        try fields.encode(cancelScope, forKey: .cancelScope)
        try fields.encodeIfPresent(extensions, forKey: .extensions)
        try ExtensionFields.encode(unknownFields, to: encoder, knownKeys: CodingKeys.self)
    }
}
