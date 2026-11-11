//
//  PerformBindingListRefusal.swift
//  FluxKlang
//
//  Typed refusals of the perform "Bindings..." list (#102 PBL1). Nothing calls it yet.
//

/// Why `PerformBindingList.make` builds no list. The checks run in the order the cases are declared, each over the
/// whole input before the next, and the first failing check decides. There is no partial list: a row is never
/// dropped, merged or clamped. Binding ids need no check of their own: the pickup book already holds them distinct,
/// ascending by UTF-8 bytes and at most `ControlBindingLimit.maximumBindings`.
enum PerformBindingListRefusal: Error, Hashable, Sendable {
    /// More than `PerformBindingList.maximumGroups` groups; checked before anything is sorted or read.
    case tooManyGroups(Int)
    /// The availability report holds another number of entries than the book holds bindings.
    case availabilityCountMismatch(book: Int, report: Int)
    /// Book and report are both ascending by binding id bytes. At the first position where the report names another
    /// binding or another source, this is the book's binding.
    case availabilityMismatch(BindingID)
    /// A group id appears more than once; the smallest repeated id by UTF-8 bytes.
    case duplicateGroup(BindingGroupID)
    /// A group names a binding the book does not hold (for example a deleted one). Walking groups ascending by id
    /// bytes and members in declared order, the first such member.
    case unknownGroupMember(group: BindingGroupID, member: BindingID)
    /// A binding is a member of two groups, so its row has no single group. In the same walk, the first member that
    /// an earlier group already holds.
    case bindingInSeveralGroups(BindingID)
    /// The caller's label for a source that a binding uses is empty or longer than
    /// `PerformBindingList.controlLabelBytes`. Walking bindings ascending by id bytes, the first such source.
    case invalidControlLabel(ControlSourceID, bytes: Int)
}
