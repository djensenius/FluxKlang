/// Why `ControlPickupBook` refused a call. Every refusal leaves the book exactly as it was.
///
/// Pinned orders (first failure wins):
/// - `add`: `duplicateBinding` before `bookFull`.
/// - `record`: `tooManyUpdates` before any lookup; then the ids in ascending UTF-8 byte order, and per id
///   `bindingMissing`, then (unless the state is unchanged) `bindingUnavailable`, then `stateNotAllowed`.
/// - `hostChanged`: `tooManyTargets` before anything is built or changed.
enum ControlPickupBookRefusal: Error, Equatable, Sendable {
    /// A binding with this id is already in the book; a binding is never replaced in place.
    case duplicateBinding(BindingID)
    /// The book already holds `limit` bindings; nothing is evicted.
    case bookFull(limit: Int)
    /// No binding with this id is in the book.
    case bindingMissing(BindingID)
    /// One `record` call carried more updates than the book may hold bindings.
    case tooManyUpdates(Int)
    /// One `hostChanged` call named more targets than the parameter catalog may hold.
    case tooManyTargets(Int)
    /// The binding's controller was lost, so a change to its state is stale.
    case bindingUnavailable(BindingID)
    /// The proposed state is a waiting jump or relative binding, the unavailable state, or has a remembered
    /// position outside 0...1.
    case stateNotAllowed(BindingID)
}
