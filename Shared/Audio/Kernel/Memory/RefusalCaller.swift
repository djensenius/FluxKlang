// #768 K-RC1: refusal-accounting capability prerequisite, not yet required by counter-writing APIs.
// Protocol proof: docs/transformation/refusal-caller-ownership.md. Reference model; not RT-certified.
import Synchronization

private let refusalCallerLifetimeBudget: UInt64 = (1 << 38) - 1
private let refusalCallerIdentities = FanInIdentityAllocator(lastIssued: UInt64.max - refusalCallerLifetimeBudget)

/// One prepared logical caller, with one slot for its only token. Preparation is control-side; no minting,
/// allocation or retry occurs in `take` or `put`. Independent overlapping callers need independent roles.
///
/// The process can prepare exactly 2^38 - 1 roles over its lifetime. Dropping roles or tokens refunds nothing.
/// A dropped token strands its role. An empty slot is failure to acquire a capability, not a counted refusal;
/// there is no busy-drop wrapper or fallback token. Counter integration is deferred to K-RC2.
final class RefusalCaller: Sendable {
    private let identity: UInt64
    private let slot: Atomic<UInt64>

    private init(identity: UInt64) {
        self.identity = identity
        slot = Atomic(identity)
    }

    /// Control-side only: reserves one never-reissued identity, or nil permanently after lifetime exhaustion.
    static func prepare() -> RefusalCaller? {
        guard let identity = refusalCallerIdentities.reserve() else { return nil }
        return RefusalCaller(identity: identity)
    }

    /// One acquiring exchange. At most one holder; nil also covers a permanently stranded role.
    func take() -> RefusalCallerToken? {
        guard slot.exchange(0, ordering: .acquiring) == identity else { return nil }
        return RefusalCallerToken(identity: identity)
    }

    /// Consumes the token. A matching return publishes prior holder work with one releasing store.
    /// A foreign return strands its source and leaves this slot unchanged, whether available or held.
    func put(_ token: consuming RefusalCallerToken) -> KernelStatus {
        guard token.isIssued(by: identity) else { return .refused(.notOwner) }
        slot.store(identity, ordering: .releasing)
        return .ok
    }
}

/// Issuer-only scalar capability, used via exclusive `inout` borrows. No owning reference or hot-path destructor.
/// Noncopyable and explicitly non-Sendable: concurrent sharing is forbidden. Slot transfer is the supported
/// handoff; compiler-permitted exclusive `sending` transfers with their own HB edge are not claimed forbidden.
struct RefusalCallerToken: ~Copyable {
    private let issuedIdentity: UInt64

    fileprivate init(identity: UInt64) {
        issuedIdentity = identity
    }

    fileprivate func isIssued(by identity: UInt64) -> Bool { issuedIdentity == identity }
}

@available(*, unavailable)
extension RefusalCallerToken: Sendable {}
