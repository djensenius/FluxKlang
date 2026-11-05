import Foundation

extension ControlRecord where Fields == ControlBindingGroupFields {
    /// The members' bindings in declared order, checked as one group. `bindings` may hold other bindings and its
    /// order is irrelevant. First failure wins: the supplied count, duplicate supplied IDs, then per member in
    /// declared order: present, same source and profile as the first member, and a target no earlier member writes.
    /// A duplicate ID refuses the group even when no member uses it: an ambiguous binding set is refused whole
    /// rather than trusted in part.
    func members(in bindings: [ControlBinding]) throws(ControlBindingGroupRefusal) -> [ControlBinding] {
        guard bindings.count <= Fields.maximumBindings else { throw .tooManyBindings(bindings.count) }
        var byID: [BindingID: ControlBinding] = [:]
        for binding in bindings {
            guard byID.updateValue(binding, forKey: binding.id) == nil else { throw .duplicateBinding(binding.id) }
        }
        var targets = Set<ParameterID>()
        var members: [ControlBinding] = []
        for id in fields.members {
            guard let member = byID[id] else { throw .memberMissing(id) }
            if let first = members.first {
                guard member.source == first.source else {
                    throw .mixedSource(id, expected: first.source, found: member.source)
                }
                guard member.profile == first.profile else {
                    throw .mixedProfile(id, expected: first.profile, found: member.profile)
                }
            }
            guard targets.insert(member.target).inserted else { throw .duplicateTarget(member.target) }
            members.append(member)
        }
        return members
    }

    /// Fans one decoded input out to every member in declared order, each resolved against host truth with its own
    /// step, range and pickup state. A refused member target refuses only that member; the others still resolve.
    /// Group-level refusals produce no output and always come first, in a fixed order: every `members(in:)` check
    /// (so `memberMissing`), then `stateMissing`, and only then each member's own target checks against host truth.
    /// States for non-members are ignored.
    func resolve(
        input: ControlInput, bindings: [ControlBinding], truth: ControlHostTruth, states: [BindingID: PickupState]
    ) throws(ControlBindingGroupRefusal) -> [ControlGroupMemberResolution] {
        let members = try members(in: bindings)
        var pending: [(ControlBinding, PickupState)] = []
        for member in members {
            guard let state = states[member.id] else { throw .stateMissing(member.id) }
            pending.append((member, state))
        }
        return pending.map { member, state in
            let outcome: ControlGroupMemberOutcome
            do throws(ControlBindingRefusal) {
                outcome = .resolved(try member.resolve(input: input, truth: truth, state: state))
            } catch {
                outcome = .refused(error)
            }
            return ControlGroupMemberResolution(binding: member.id, outcome: outcome)
        }
    }
}
