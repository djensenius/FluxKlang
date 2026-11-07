/// The traffic a caller wants to send to the console.
enum WingLeaseTraffic: Equatable, Sendable {
    case read
    case write(origin: WingLeaseOrigin, settingCount: Int)
    case restoreWrite(settingCount: Int)
}

/// The answer of the gate.
enum WingLeaseDecision: Equatable, Sendable {
    case permitted
    case refused(WingLeaseRefusal)
}

/// Non-consuming permission query. It neither records budget nor a tick. Writes and restore writes are decided by
/// calling `WingCompatibilityLease.applying` and discarding the successor, so the gate and the machine cannot
/// disagree. A permit is necessary, never sufficient, for a SET: the single-use `WingMixerWriteAuthorization` token
/// and the physical safeguards still apply.
enum WingLeaseGate {
    static func decide(
        _ traffic: WingLeaseTraffic,
        in lease: WingCompatibilityLease,
        at tick: WingLeaseTick
    ) -> WingLeaseDecision {
        switch traffic {
        case .read:
            // Reads are never tick-checked: a read after the grant expired is permitted.
            lease.phase == .unleased ? .refused(.readNotPermitted(phase: .unleased)) : .permitted
        case let .write(origin, settingCount):
            permit(.admitWrite(origin: origin, settingCount: settingCount), in: lease, at: tick)
        case let .restoreWrite(settingCount):
            permit(.admitRestoreWrite(settingCount: settingCount), in: lease, at: tick)
        }
    }

    private static func permit(
        _ event: WingLeaseEvent,
        in lease: WingCompatibilityLease,
        at tick: WingLeaseTick
    ) -> WingLeaseDecision {
        do {
            _ = try lease.applying(event, at: tick)
            return .permitted
        } catch {
            return .refused(error)
        }
    }
}
