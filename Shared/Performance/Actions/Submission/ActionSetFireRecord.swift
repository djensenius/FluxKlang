//
//  ActionSetFireRecord.swift
//  FluxKlang
//
//  What one atomic fire of an action set admitted (#107 A2): the set, its
//  cancel scope at the fire's generation, and one scheduler handle per
//  member in member order. Only the throwing factory below builds one, so a
//  record always matches its set member for member.
//

/// The outcome of submitting one fire decision.
enum ActionSetSubmission: Hashable, Sendable {
    /// Every member was admitted and registered.
    case fired(ActionSetFireRecord)
    /// The set was not ready (v1 drop and report); nothing was submitted. The report is returned unchanged.
    case dropped(ActionSetDropReport)
}

struct ActionSetFireRecord: Hashable, Sendable {
    struct Member: Hashable, Sendable {
        let action: ActionID
        let handle: TriggerHandle

        fileprivate init(action: ActionID, handle: TriggerHandle) {
            self.action = action
            self.handle = handle
        }
    }

    private let storedSet: ActionSetID
    private let storedScope: GenerationRequirement
    private let storedMembers: [Member]

    var set: ActionSetID { storedSet }
    /// The set's cancel-scope counter at the generation every member was stamped against.
    var cancelScope: GenerationRequirement { storedScope }
    /// One entry per set member, in member order.
    var members: [Member] { storedMembers }
    var handles: [TriggerHandle] { storedMembers.map(\.handle) }

    private init(set: ActionSetID, scope: GenerationRequirement, members: [Member]) {
        storedSet = set
        storedScope = scope
        storedMembers = members
    }

    /// Checks that `stamps` are one fire of `set`: one stamp per member in member order, each carrying
    /// exactly one cancel-scope requirement, the set's, at one shared generation. Returns that requirement.
    static func scope(of stamps: [TriggerStamp],
                      set: PerformanceActionSet) throws(ActionSetSubmitRefusal) -> GenerationRequirement {
        guard stamps.count == set.members.count, !stamps.isEmpty else {
            throw .memberCount(expected: set.members.count, actual: stamps.count)
        }
        let shared = try memberScope(stamps, at: 0, set: set)
        for index in stamps.indices.dropFirst() {
            guard try memberScope(stamps, at: index, set: set) == shared else { throw .memberMismatch(index: index) }
        }
        return shared
    }

    private static func memberScope(_ stamps: [TriggerStamp], at index: Int,
                                    set: PerformanceActionSet) throws(ActionSetSubmitRefusal) -> GenerationRequirement {
        let stamp = stamps[index]
        let scoped = stamp.requires.filter { $0.key.kind == .cancelScope }
        guard stamp.action == set.members[index], scoped.count == 1, let scope = scoped.first,
              scope.key == set.cancelScopeKey else {
            throw .memberMismatch(index: index)
        }
        return scope
    }

    /// Builds the record of an admitted fire; `handles[i]` must be the handle of `stamps[i]`.
    static func make(set: PerformanceActionSet, stamps: [TriggerStamp],
                     handles: [TriggerHandle]) throws(ActionSetSubmitRefusal) -> ActionSetFireRecord {
        let scope = try scope(of: stamps, set: set)
        guard handles.count == stamps.count else {
            throw .memberCount(expected: stamps.count, actual: handles.count)
        }
        var members: [Member] = []
        for (index, stamp) in stamps.enumerated() {
            guard handles[index].trigger == stamp.id else { throw .memberMismatch(index: index) }
            members.append(Member(action: stamp.action, handle: handles[index]))
        }
        return ActionSetFireRecord(set: set.id, scope: scope, members: members)
    }
}
