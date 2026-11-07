/// An explicit human grant to write WING settings: bound to one write origin, valid on the tick window
/// `issuedAt <= tick < expiry` (expiry is EXCLUSIVE; the last valid tick is `expiry - 1`) and limited to
/// `settingBudget` settings. Only `make` builds one, so no unvalidated grant exists.
struct WingLeaseGrant: Equatable, Sendable {
    let writeOrigin: WingLeaseOrigin
    let issuedAt: WingLeaseTick
    let expiry: WingLeaseTick
    let settingBudget: Int

    private init(writeOrigin: WingLeaseOrigin, issuedAt: WingLeaseTick, expiry: WingLeaseTick, settingBudget: Int) {
        self.writeOrigin = writeOrigin
        self.issuedAt = issuedAt
        self.expiry = expiry
        self.settingBudget = settingBudget
    }

    /// Checks, first failure wins: the grantor must be `.human`; the duration must be in
    /// `1 ... maximumDurationTicks`; the budget in `1 ... maximumSettingBudget`; and `issuedAt + durationTicks` must
    /// not overflow or exceed `maximumTick`. Controller and assistant origins can never grant, whatever `writeOrigin`.
    static func make(
        grantedBy: WingLeaseOrigin,
        writeOrigin: WingLeaseOrigin,
        issuedAt: WingLeaseTick,
        durationTicks: Int,
        settingBudget: Int
    ) throws(WingLeaseConstructionFault) -> WingLeaseGrant {
        guard grantedBy == .human else { throw .grantorNotHuman(grantedBy) }
        guard (WingLeaseLimits.minimumCount ... WingLeaseLimits.maximumDurationTicks).contains(durationTicks) else {
            throw .invalidDuration(durationTicks)
        }
        guard (WingLeaseLimits.minimumCount ... WingLeaseLimits.maximumSettingBudget).contains(settingBudget) else {
            throw .invalidBudget(settingBudget)
        }
        let (sum, overflow) = issuedAt.rawValue.addingReportingOverflow(durationTicks)
        guard !overflow, sum <= WingLeaseLimits.maximumTick, let expiry = try? WingLeaseTick(sum) else {
            throw .expiryOverflow
        }
        return WingLeaseGrant(
            writeOrigin: writeOrigin,
            issuedAt: issuedAt,
            expiry: expiry,
            settingBudget: settingBudget
        )
    }
}
