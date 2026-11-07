// #109 IO3: the claim table that refuses a second consumer of one role on one tap. Pure Swift; no clock, no ring.

/// Which roles hold a claim on which taps, for at most `maximumTaps` distinct taps. A refused claim or release leaves
/// the table exactly as it was. Storage is a sorted array, so no output depends on hashing order.
struct MediaTapClaims: Equatable, Sendable {
    /// Most distinct taps one table may hold (inclusive).
    static let maximumTaps = 16

    private struct Entry: Equatable, Sendable {
        let tap: MediaTapID
        /// Bit `role.rawValue` is set while the role holds the tap.
        var roleMask: UInt8
    }

    private var entries: [Entry] = []

    init() {}

    /// Taps with at least one claim, ascending.
    var claimedTaps: [MediaTapID] {
        entries.map(\.tap)
    }

    /// Roles holding `tap`, in role order; empty for an unknown tap.
    func claimedRoles(on tap: MediaTapID) -> [MediaTapRole] {
        guard let entry = entries.first(where: { $0.tap == tap }) else { return [] }
        return MediaTapRole.allCases.filter { entry.roleMask & Self.bit(of: $0) != 0 }
    }

    func isClaimed(_ role: MediaTapRole, on tap: MediaTapID) -> Bool {
        claimedRoles(on: tap).contains(role)
    }

    /// Claims `role` on `tap`. Refuses `.alreadyClaimed` when the role holds the tap, otherwise `.tooManyTaps` when
    /// `tap` is new and the table already holds `maximumTaps` taps (the two cannot apply to one call).
    mutating func claim(_ role: MediaTapRole, on tap: MediaTapID) throws(MediaTapRefusal) {
        let bit = Self.bit(of: role)
        if let index = entries.firstIndex(where: { $0.tap == tap }) {
            guard entries[index].roleMask & bit == 0 else { throw .alreadyClaimed(tap, role) }
            entries[index].roleMask |= bit
            return
        }
        guard entries.count < Self.maximumTaps else { throw .tooManyTaps(entries.count + 1) }
        let position = entries.firstIndex(where: { $0.tap > tap }) ?? entries.endIndex
        entries.insert(Entry(tap: tap, roleMask: bit), at: position)
    }

    /// Releases `role` on `tap`; a tap with no claim left leaves the table. Refuses `.notClaimed` otherwise.
    mutating func release(_ role: MediaTapRole, on tap: MediaTapID) throws(MediaTapRefusal) {
        let bit = Self.bit(of: role)
        guard let index = entries.firstIndex(where: { $0.tap == tap }), entries[index].roleMask & bit != 0 else {
            throw .notClaimed(tap, role)
        }
        entries[index].roleMask &= ~bit
        if entries[index].roleMask == 0 {
            entries.remove(at: index)
        }
    }

    private static func bit(of role: MediaTapRole) -> UInt8 {
        1 << role.rawValue
    }
}
