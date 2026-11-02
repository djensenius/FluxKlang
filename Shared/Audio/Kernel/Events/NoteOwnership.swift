import Synchronization

// #64 note ownership and safety flags. `NoteOwnership` records which notes each scope has sounding so a scope can
// always release exactly what it owns; `SafetyFlags` carries panic and all-notes-off requests that can never be
// exhausted or lost. Reference model; not RT-certified.

/// Render-owned record of sounding notes: a fixed bitset of 16 channels × 128 notes for each scope.
/// Reference model; not RT-certified.
///
/// Storage is one allocation of `scopes × 32` `UInt64` words made in `init` (word `channel * 2 + note / 64` of
/// the scope's 32, bit `note % 64`). A single thread (render) owns the instance, so the words are plain memory,
/// not atomics. Every hot-path method range-checks `scope`, `channel` and `note` and never traps.
final class NoteOwnership: @unchecked Sendable {
    enum PreparationError: Error, Equatable, Sendable {
        /// `scopes` is outside `1...maximumScopes`.
        case scopeCountOutOfRange(Int)
    }

    /// Largest scope count (inclusive): 256 scopes use 256 × 32 × 8 bytes = 64 KiB.
    static let maximumScopes = 256
    static let channels = 16
    static let notesPerChannel = 128
    /// Most notes one scope can own, and so the most `releaseAll` can emit: 16 × 128 = 2,048.
    static let maximumNotesPerScope = channels * notesPerChannel
    static let wordsPerScope = maximumNotesPerScope / UInt64.bitWidth

    let scopeCount: Int
    private let words: UnsafeMutablePointer<UInt64>

    init(scopes: Int) throws(PreparationError) {
        guard scopes >= 1, scopes <= Self.maximumScopes else { throw .scopeCountOutOfRange(scopes) }
        scopeCount = scopes
        let count = scopes * Self.wordsPerScope
        words = UnsafeMutablePointer<UInt64>.allocate(capacity: count)
        words.initialize(repeating: 0, count: count)
    }

    /// Control-side teardown only.
    deinit {
        words.deinitialize(count: scopeCount &* Self.wordsPerScope)
        words.deallocate()
    }

    /// Marks the note owned. A duplicate `noteOn` for an owned note is idempotent and returns `.ok`.
    /// Returns `.refused(.slotOutOfRange)` when `scope`, `channel` or `note` is out of range.
    func noteOn(scope: UInt32, channel: UInt8, note: UInt8) -> KernelStatus {
        guard let index = wordIndex(scope: scope, channel: channel, note: note) else {
            return .refused(.slotOutOfRange)
        }
        words[index] |= Self.bit(note)
        return .ok
    }

    /// Clears ownership and returns `true` if the note was owned. An unowned or out-of-range note is a harmless
    /// no-op that returns `false` and leaves ownership unchanged.
    func noteOff(scope: UInt32, channel: UInt8, note: UInt8) -> Bool {
        guard let index = wordIndex(scope: scope, channel: channel, note: note) else { return false }
        let bit = Self.bit(note)
        guard words[index] & bit != 0 else { return false }
        words[index] &= ~bit
        return true
    }

    /// Calls `emit(channel, note)` once for each owned note in `scope`, clears them and returns the count.
    /// Visits exactly 32 words, in order, and emits at most 2,048 notes; an out-of-range scope returns 0.
    ///
    /// Re-entrancy: each word is cleared before its notes are emitted. A `noteOn` from inside `emit` into the
    /// word being emitted or an earlier word stays owned after `releaseAll` returns. A `noteOn` into a word not
    /// yet visited is released (emitted and counted) by the same call. A re-entrant `noteOff` for a note in the
    /// word being emitted (already in the local copy) or an earlier word returns `false`, and a note still in the
    /// local copy is emitted anyway; for a note in a word not yet visited it returns `true` and that note is not
    /// emitted.
    func releaseAll(scope: UInt32, _ emit: (UInt8, UInt8) -> Void) -> Int {
        guard let base = scopeBase(scope) else { return 0 }
        var released = 0
        for offset in 0..<Self.wordsPerScope {
            var bits = words[base &+ offset]
            words[base &+ offset] = 0
            let channel = UInt8(truncatingIfNeeded: offset &>> 1)
            let high = UInt8(truncatingIfNeeded: (offset & 1) &<< 6)
            while bits != 0 {
                let low = UInt8(truncatingIfNeeded: bits.trailingZeroBitCount)
                bits &= bits &- 1
                emit(channel, high | low)
                released &+= 1
            }
        }
        return released
    }

    /// `false` for an unowned or out-of-range note.
    func isOwned(scope: UInt32, channel: UInt8, note: UInt8) -> Bool {
        guard let index = wordIndex(scope: scope, channel: channel, note: note) else { return false }
        return words[index] & Self.bit(note) != 0
    }

    /// Number of notes `scope` owns; 0 for an out-of-range scope.
    func ownedCount(scope: UInt32) -> Int {
        guard let base = scopeBase(scope) else { return 0 }
        var count = 0
        for offset in 0..<Self.wordsPerScope {
            count &+= words[base &+ offset].nonzeroBitCount
        }
        return count
    }

    private func scopeBase(_ scope: UInt32) -> Int? {
        guard scope < UInt32(truncatingIfNeeded: scopeCount) else { return nil }
        return Int(scope) &* Self.wordsPerScope
    }

    private func wordIndex(scope: UInt32, channel: UInt8, note: UInt8) -> Int? {
        guard let base = scopeBase(scope), Int(channel) < Self.channels, Int(note) < Self.notesPerChannel else {
            return nil
        }
        return base &+ Int(channel) &* 2 &+ Int(note &>> 6)
    }

    private static func bit(_ note: UInt8) -> UInt64 {
        1 &<< UInt64(note & 63)
    }
}

/// A safety request a scope can raise from any context. Reference model; not RT-certified.
enum SafetyFlag: UInt8, Sendable, BitwiseCopyable, CaseIterable {
    case panic, allNotesOff
}

/// The set of pending safety requests; bit `n` is the `SafetyFlag` whose raw value is `n`.
/// Reference model; not RT-certified.
struct SafetyFlagSet: OptionSet, Sendable, BitwiseCopyable {
    let rawValue: UInt8

    static let panic = SafetyFlagSet(rawValue: 1 &<< SafetyFlag.panic.rawValue)
    static let allNotesOff = SafetyFlagSet(rawValue: 1 &<< SafetyFlag.allNotesOff.rawValue)
}

/// Per-scope pending safety requests. Requests are idempotent bits, not a queue, so they cannot be exhausted or
/// overflow, and a request is never lost: it stays set until render takes it. Reference model; not RT-certified.
///
/// Storage is one `UnsafeMutablePointer<Atomic<UInt8>>` with one atomic byte per scope, allocated and
/// initialised in `init` and deinitialised in `deinit` (`Atomic` is `~Copyable`, so it cannot live in an
/// `Array`). One byte per scope keeps scopes independent: no scope's request contends with another's.
/// `request` is a releasing fetch-or and `take` an acquiring exchange with 0, so writes made before a request
/// happen-before the reads of the render cycle whose `take` returns it.
final class SafetyFlags: @unchecked Sendable {
    enum PreparationError: Error, Equatable, Sendable {
        /// `scopes` is outside `1...maximumScopes`.
        case scopeCountOutOfRange(Int)
    }

    /// Largest scope count (inclusive); matches `NoteOwnership.maximumScopes`.
    static let maximumScopes = NoteOwnership.maximumScopes

    let scopeCount: Int
    private let flags: UnsafeMutablePointer<Atomic<UInt8>>

    init(scopes: Int) throws(PreparationError) {
        guard scopes >= 1, scopes <= Self.maximumScopes else { throw .scopeCountOutOfRange(scopes) }
        scopeCount = scopes
        flags = UnsafeMutablePointer<Atomic<UInt8>>.allocate(capacity: scopes)
        for offset in 0..<scopes {
            (flags + offset).initialize(to: Atomic(0))
        }
    }

    /// Control-side teardown only.
    deinit {
        flags.deinitialize(count: scopeCount)
        flags.deallocate()
    }

    /// Sets `flag` for `scope`. Safe from any context and idempotent. Returns `.ok`, or
    /// `.refused(.slotOutOfRange)` for an out-of-range scope.
    func request(_ flag: SafetyFlag, scope: UInt32) -> KernelStatus {
        guard scope < UInt32(truncatingIfNeeded: scopeCount) else { return .refused(.slotOutOfRange) }
        flags[Int(scope)].bitwiseOr(1 &<< flag.rawValue, ordering: .releasing)
        return .ok
    }

    /// Render: atomically takes and clears every pending request for `scope`; empty for an out-of-range scope.
    func take(scope: UInt32) -> SafetyFlagSet {
        guard scope < UInt32(truncatingIfNeeded: scopeCount) else { return [] }
        return SafetyFlagSet(rawValue: flags[Int(scope)].exchange(0, ordering: .acquiring))
    }
}
