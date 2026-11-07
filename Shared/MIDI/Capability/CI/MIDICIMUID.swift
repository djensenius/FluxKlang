/// A MIDI-CI MUID: 28 bits, 0...0x0FFFFEFF assignable, 0x0FFFFFFF the broadcast MUID. 0x0FFFFF00...0x0FFFFFFE are
/// reserved and cannot be built. Only `make` and `allocate` construct one; the storage is private.
struct MIDICIMUID: Hashable, Comparable, Sendable {
    static let maximumAssignable: UInt32 = 0x0FFF_FEFF
    static let broadcast = MIDICIMUID(validated: 0x0FFF_FFFF)

    private let storage: UInt32

    var rawValue: UInt32 { storage }
    var isBroadcast: Bool { storage == Self.broadcast.storage }

    private init(validated storage: UInt32) {
        self.storage = storage
    }

    static func make(_ raw: UInt32) throws(MIDICIRefusal) -> MIDICIMUID {
        guard raw <= maximumAssignable || raw == broadcast.storage else { throw .invalidMUID(raw) }
        return MIDICIMUID(validated: raw)
    }

    static func < (lhs: MIDICIMUID, rhs: MIDICIMUID) -> Bool {
        lhs.storage < rhs.storage
    }

    /// The first candidate, in the caller's order, that is assignable and not in `inUse`. Reserved, broadcast and
    /// over-28-bit candidates are skipped. The caller supplies the candidates (no randomness here); the work is
    /// linear in `candidates.count`.
    static func allocate(candidates: [UInt32], inUse: Set<MIDICIMUID>) throws(MIDICIRefusal) -> MIDICIMUID {
        for raw in candidates where raw <= maximumAssignable {
            let muid = MIDICIMUID(validated: raw)
            if !inUse.contains(muid) { return muid }
        }
        throw .noFreeMUID
    }
}
