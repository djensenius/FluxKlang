/// How many registry records sit in each state of the global engine gate.
///
/// Counts only; wording belongs to the status slices. The initializer is private, so a value is only ever built by
/// raising one counter of `none` at a time with `adding(_:)`.
struct DeviceRegistryPresenceGate: Hashable, Sendable {
    let present: Int
    let lost: Int
    let revalidating: Int
    let muted: Int

    private init(present: Int, lost: Int, revalidating: Int, muted: Int) {
        self.present = present
        self.lost = lost
        self.revalidating = revalidating
        self.muted = muted
    }

    /// No records: nothing blocks acquisition.
    static let none = DeviceRegistryPresenceGate(present: 0, lost: 0, revalidating: 0, muted: 0)

    /// Every counted record.
    var total: Int {
        present + lost + revalidating + muted
    }

    /// Records whose state denies a fresh engine acquisition.
    var blocked: Int {
        lost + revalidating + muted
    }

    /// The same answer as `DeviceRegistry.allowsEngineAcquisition`: true only when no record is blocked.
    var allowsEngineAcquisition: Bool {
        let denied = blocked
        return denied == 0
    }

    /// A copy with exactly one counter raised for `lifecycle`.
    func adding(_ lifecycle: DeviceLifecycle) -> DeviceRegistryPresenceGate {
        switch lifecycle {
        case .present:
            return DeviceRegistryPresenceGate(
                present: present + 1, lost: lost, revalidating: revalidating, muted: muted
            )
        case .lostMuted:
            return DeviceRegistryPresenceGate(
                present: present, lost: lost + 1, revalidating: revalidating, muted: muted
            )
        case .revalidating:
            return DeviceRegistryPresenceGate(
                present: present, lost: lost, revalidating: revalidating + 1, muted: muted
            )
        case .muted:
            return DeviceRegistryPresenceGate(
                present: present, lost: lost, revalidating: revalidating, muted: muted + 1
            )
        }
    }
}
