/// Why an Active Sensing policy or observer call was refused. A refused call changes nothing.
///
/// Check order inside the observer: `invalidTimeout`, then `tickRegressed`, then `deadlineOverflow`.
enum ActiveSensingRefusal: Error, Equatable, Sendable {
    /// The timeout is outside `1...ActiveSensingPolicy.maximumTimeoutTicks`; carries the rejected value.
    case invalidTimeout(UInt64)
    /// The stamp is earlier than the last accepted stamp; carries both values (equal stamps are accepted).
    case tickRegressed(last: UInt64, found: UInt64)
    /// `stamp + timeoutTicks` does not fit in `UInt64`.
    case deadlineOverflow
}
