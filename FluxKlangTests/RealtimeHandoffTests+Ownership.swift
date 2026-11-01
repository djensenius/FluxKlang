import Foundation
import Synchronization
import Testing
@testable import FluxKlang

private typealias Root = RealtimeHandoffTests

private struct PayloadCase {
    let payload: KernelEventPayload
    let lane: EventLane
    let eventClass: EventClass
}

private struct Slot {
    let scope: UInt32
    let channel: UInt8
    let note: UInt8
}

/// One representative event for every payload case, with its expected lane and class.
private let payloadCases: [PayloadCase] = [
    PayloadCase(payload: .noteOff(channel: 0, note: 60), lane: .release, eventClass: .critical),
    PayloadCase(payload: .clockPulse, lane: .transport, eventClass: .general),
    PayloadCase(payload: .control(channel: 1, controller: 7, value: 100), lane: .state, eventClass: .general),
    PayloadCase(payload: .program(channel: 2, program: 5, bank: 1), lane: .state, eventClass: .general),
    PayloadCase(payload: .noteOn(channel: 3, note: 64, velocity: 100), lane: .content, eventClass: .general),
    PayloadCase(payload: .rampTo(parameter: 9, value: 0.5, durationFrames: 480), lane: .content,
                eventClass: .general)
]

private func event(_ payload: KernelEventPayload, scope: UInt32 = 0) -> KernelEvent {
    KernelEvent(frame: 0, scope: scope, sequence: 0, payload: payload)
}

/// Every stress spin gives up at this point (well inside the 1-minute `timeLimit`), recording a timeout.
private func stressDeadline() -> ContinuousClock.Instant {
    .now + .seconds(25)
}

/// Bounded spin: `true` once `condition` holds; `false`, after counting a timeout, once `deadline` passes.
private func spin(until deadline: ContinuousClock.Instant, timeouts: borrowing Atomic<Int>,
                  _ condition: () -> Bool) -> Bool {
    var spins = 0
    while !condition() {
        spins &+= 1
        if spins & 1_023 == 0, ContinuousClock.now >= deadline {
            timeouts.add(1, ordering: .relaxed)
            return false
        }
    }
    return true
}

/// Start barrier and completion signal for dedicated stress `Thread`s.
private final class ThreadGroup: @unchecked Sendable {
    let arrived = Atomic<Int>(0)
    let timeouts = Atomic<Int>(0)
    let finished = DispatchSemaphore(value: 0)
}

/// Runs each body on its own `Thread` behind a start barrier and waits, bounded, for all of them. Returns `false`
/// if the barrier or the join timed out. No task-runtime synchronisation is involved.
private func runOnThreads(deadline: ContinuousClock.Instant, _ bodies: [@Sendable () -> Void]) -> Bool {
    let group = ThreadGroup()
    for body in bodies {
        Thread {
            group.arrived.add(1, ordering: .acquiringAndReleasing)
            if spin(until: deadline, timeouts: group.timeouts, {
                group.arrived.load(ordering: .acquiring) >= bodies.count
            }) {
                body()
            }
            group.finished.signal()
        }.start()
    }
    let joinDeadline = DispatchTime.now() + .seconds(30)
    var joined = 0
    for _ in bodies where group.finished.wait(timeout: joinDeadline) == .success { joined += 1 }
    return joined == bodies.count && group.timeouts.load(ordering: .acquiring) == 0
}

/// Shared state for the publication test: a plain, non-atomic payload published by `request`.
private final class Publication: @unchecked Sendable {
    let flags: SafetyFlags
    let payload = UnsafeMutablePointer<Int>.allocate(capacity: 1)
    /// Taker → requester only, so it adds no happens-before edge from the requester's write to the taker's read.
    let acknowledged = Atomic<Int>(0)
    let timeouts = Atomic<Int>(0)
    /// Written by the taker thread only; read after the join.
    var mismatches = 0

    init(flags: SafetyFlags) {
        self.flags = flags
        payload.initialize(to: 0)
    }

    deinit {
        payload.deinitialize(count: 1)
        payload.deallocate()
    }
}

/// Shared state for the concurrent-requests test. Requesters and the taker hand off through these counters only.
private final class Contention: @unchecked Sendable {
    let flags: SafetyFlags
    let rounds: Int
    let scopes = 8
    let requesters = 4
    /// Round the requesters may run; the taker advances it after each round's final sweep.
    let round = Atomic<Int>(0)
    /// Requester round completions (cumulative).
    let completed = Atomic<Int>(0)
    /// Mid-round handshakes raised by requesters (cumulative, RMW only).
    let signalled = Atomic<Int>(0)
    /// The `signalled` value the taker loaded before its most recent completed sweep.
    let acknowledged = Atomic<Int>(0)
    let timeouts = Atomic<Int>(0)
    /// Written by the taker thread only; read after the join.
    var lost = 0
    var overlapped = 0

    init(flags: SafetyFlags, rounds: Int) {
        self.flags = flags
        self.rounds = rounds
    }

    /// Requests `flag` on this requester's 4 scopes each round: 2 before a handshake with the taker, 2 after.
    func requester(_ index: Int, deadline: ContinuousClock.Instant) {
        let flag = SafetyFlag.allCases[index % SafetyFlag.allCases.count]
        let mine = (0..<scopes).filter { $0 % (requesters / 2) == index / 2 }.map { UInt32($0) }
        for current in 0..<rounds {
            guard spin(until: deadline, timeouts: timeouts, { round.load(ordering: .acquiring) >= current }) else {
                return
            }
            for scope in mine.prefix(2) { _ = flags.request(flag, scope: scope) }
            // The taker's next sweep starts after an acquiring load of this value, so it must see both requests.
            let signal = signalled.add(1, ordering: .releasing).newValue
            guard spin(until: deadline, timeouts: timeouts, {
                acknowledged.load(ordering: .acquiring) >= signal
            }) else { return }
            for scope in mine.dropFirst(2) { _ = flags.request(flag, scope: scope) }
            completed.add(1, ordering: .releasing)
        }
    }

    /// Sweeps every scope until all requesters finish the round, acknowledging handshakes, then sweeps once more.
    func taker(deadline: ContinuousClock.Instant) {
        for current in 0..<rounds {
            var union = [SafetyFlagSet](repeating: [], count: scopes)
            var sweeps = 0
            while completed.load(ordering: .acquiring) < requesters * (current + 1) {
                let seen = signalled.load(ordering: .acquiring)
                sweep(flags, into: &union)
                acknowledged.store(seen, ordering: .releasing)
                sweeps &+= 1
                if sweeps & 1_023 == 0, ContinuousClock.now >= deadline {
                    timeouts.add(1, ordering: .relaxed)
                    return
                }
            }
            // Requests published before a handshake happen-before the acknowledging sweep, which ran before the
            // round completed; so this union is non-empty in every round unless a request was lost.
            if union.contains(where: { !$0.isEmpty }) { overlapped += 1 }
            sweep(flags, into: &union)
            lost += union.filter { $0 != [.panic, .allNotesOff] }.count
            round.store(current + 1, ordering: .releasing)
        }
    }
}

/// Takes every scope once, accumulating what each take returned.
private func sweep(_ flags: SafetyFlags, into union: inout [SafetyFlagSet]) {
    for scope in union.indices { union[scope].formUnion(flags.take(scope: UInt32(scope))) }
}

private func ownership(scopes: Int) -> NoteOwnership? {
    try? NoteOwnership(scopes: scopes)
}

private func safetyFlags(scopes: Int) -> SafetyFlags? {
    try? SafetyFlags(scopes: scopes)
}

private func flagSet(_ flag: SafetyFlag) -> SafetyFlagSet {
    SafetyFlagSet(rawValue: 1 << flag.rawValue)
}

/// Every owned (scope, channel, note) across all scopes, as a flat index.
private func ownedSet(_ owner: NoteOwnership) -> Set<Int> {
    var result = Set<Int>()
    for scope in 0..<owner.scopeCount {
        for channel in 0..<16 {
            for note in 0..<128
            where owner.isOwned(scope: UInt32(scope), channel: UInt8(channel), note: UInt8(note)) {
                result.insert((scope * 16 + channel) * 128 + note)
            }
        }
    }
    return result
}

extension RealtimeHandoffTests {
    struct OwnershipRules {
        @Test func laneAndClassDerivation() {
            for item in payloadCases {
                #expect(event(item.payload).lane == item.lane)
                #expect(event(item.payload).eventClass == item.eventClass)
            }
            #expect(EventLane.release.rawValue == 0)
            #expect(EventLane.release < .transport && EventLane.transport < .state && EventLane.state < .content)
            #expect(!(EventLane.content < .release))
            let sorted = payloadCases.map { event($0.payload).lane }.sorted()
            #expect(sorted == [.release, .transport, .state, .state, .content, .content])
            #expect(EventClass.allCases == [.general, .critical])
        }

        @Test(.timeLimit(.minutes(1)))
        func releaseAllEmitsOnlyOwnedNotesBounded() throws {
            let owner = try #require(ownership(scopes: 3))
            for channel in UInt8(0)..<16 {
                for note in UInt8(0)..<128 {
                    #expect(owner.noteOn(scope: 1, channel: channel, note: note) == .ok)
                }
            }
            #expect(owner.noteOn(scope: 2, channel: 0, note: 0) == .ok)
            #expect(owner.ownedCount(scope: 1) == 2_048)
            var emitted = Set<Int>()
            var emits = 0
            let full = owner.releaseAll(scope: 1) { channel, note in
                emits += 1
                emitted.insert(Int(channel) * 128 + Int(note))
            }
            #expect(full == 2_048 && emits == 2_048 && emitted.count == 2_048)
            #expect(owner.ownedCount(scope: 1) == 0)
            #expect(ownedSet(owner) == [(2 * 16 + 0) * 128 + 0])
            #expect(owner.releaseAll(scope: 1) { _, _ in emits += 1 } == 0 && emits == 2_048)

            let sparse: [(UInt8, UInt8)] = [(0, 0), (0, 63), (0, 64), (7, 1), (15, 127)]
            for (channel, note) in sparse { _ = owner.noteOn(scope: 0, channel: channel, note: note) }
            var released: [(UInt8, UInt8)] = []
            #expect(owner.releaseAll(scope: 0) { released.append(($0, $1)) } == sparse.count)
            #expect(released.map { Int($0.0) * 128 + Int($0.1) } == sparse.map { Int($0.0) * 128 + Int($0.1) })
            #expect(owner.ownedCount(scope: 0) == 0)
            #expect(ownedSet(owner) == [(2 * 16 + 0) * 128 + 0])

            for scope in [UInt32(3), 4, 255, 256, .max] {
                #expect(owner.releaseAll(scope: scope) { _, _ in emits += 1 } == 0)
            }
            #expect(emits == 2_048 && owner.ownedCount(scope: 2) == 1)
        }

        /// Each word is cleared before its notes are emitted: a re-entrant `noteOn` into the word being emitted
        /// survives the call, and one into a word not yet visited is released by the same call.
        @Test func releaseAllToleratesReentrantNoteOn() throws {
            let owner = try #require(ownership(scopes: 2))
            _ = owner.noteOn(scope: 1, channel: 4, note: 10)
            _ = owner.noteOn(scope: 1, channel: 9, note: 100)
            var emitted: [Int] = []
            let count = owner.releaseAll(scope: 1) { channel, note in
                emitted.append(Int(channel) * 128 + Int(note))
                if channel == 4, note == 10 {
                    #expect(owner.noteOn(scope: 1, channel: 4, note: 11) == .ok)
                    #expect(owner.noteOn(scope: 1, channel: 12, note: 5) == .ok)
                }
            }
            #expect(count == 3)
            #expect(emitted == [4 * 128 + 10, 9 * 128 + 100, 12 * 128 + 5])
            #expect(owner.isOwned(scope: 1, channel: 4, note: 11))
            #expect(!owner.isOwned(scope: 1, channel: 12, note: 5))
            #expect(ownedSet(owner) == [(1 * 16 + 4) * 128 + 11])
        }

        @Test func unownedNoteOffIsHarmlessNoOp() throws {
            let owner = try #require(ownership(scopes: 2))
            #expect(owner.noteOff(scope: 0, channel: 0, note: 60) == false)
            #expect(ownedSet(owner).isEmpty)
            #expect(owner.noteOn(scope: 0, channel: 0, note: 60) == .ok)
            #expect(owner.noteOn(scope: 0, channel: 0, note: 60) == .ok)
            #expect(owner.noteOn(scope: 0, channel: 0, note: 61) == .ok)
            #expect(owner.ownedCount(scope: 0) == 2)
            let before = ownedSet(owner)
            let unowned = [Slot(scope: 0, channel: 0, note: 62), Slot(scope: 0, channel: 1, note: 60),
                           Slot(scope: 1, channel: 0, note: 60), Slot(scope: 0, channel: 0, note: 124)]
            for slot in unowned {
                #expect(owner.noteOff(scope: slot.scope, channel: slot.channel, note: slot.note) == false)
                #expect(ownedSet(owner) == before)
            }
            #expect(owner.noteOff(scope: 0, channel: 0, note: 60) == true)
            #expect(owner.noteOff(scope: 0, channel: 0, note: 60) == false)
            #expect(ownedSet(owner) == [61])
        }

        @Test func safetyFlagsAreIdempotentAndCannotExhaust() throws {
            let flags = try #require(safetyFlags(scopes: 2))
            #expect(flags.take(scope: 0).isEmpty)
            #expect(flags.request(.panic, scope: 0) == .ok)
            #expect(flags.request(.panic, scope: 0) == .ok)
            #expect(flags.take(scope: 0) == .panic)
            #expect(flags.take(scope: 0).isEmpty)
            #expect(flags.request(.allNotesOff, scope: 0) == .ok)
            #expect(flags.take(scope: 0) == .allNotesOff)
            for _ in 0..<1_000 {
                for flag in SafetyFlag.allCases { #expect(flags.request(flag, scope: 0) == .ok) }
            }
            #expect(flags.take(scope: 0) == [.panic, .allNotesOff])
            #expect(flags.take(scope: 0).isEmpty)
            #expect(flags.take(scope: 1).isEmpty)
            for flag in SafetyFlag.allCases { #expect(flagSet(flag).rawValue == 1 << flag.rawValue) }
        }

        @Test func outOfRangeChannelNoteScopeRefused() throws {
            #expect(NoteOwnership.maximumScopes == 256 && SafetyFlags.maximumScopes == 256)
            for count in Root.adversarialInts + [256, 257] {
                let valid = (1...256).contains(count)
                #expect((ownership(scopes: count) != nil) == valid)
                #expect((safetyFlags(scopes: count) != nil) == valid)
            }
            #expect(throws: NoteOwnership.PreparationError.scopeCountOutOfRange(0)) {
                try NoteOwnership(scopes: 0)
            }
            #expect(throws: SafetyFlags.PreparationError.scopeCountOutOfRange(257)) {
                try SafetyFlags(scopes: 257)
            }

            let count = 3
            let owner = try #require(ownership(scopes: count))
            let flags = try #require(safetyFlags(scopes: count))
            let badScopes: [UInt32] = [UInt32(count), UInt32(count + 1), 256, .max]
            let badChannels: [UInt8] = [16, 17, 128, .max]
            let badNotes: [UInt8] = [128, 129, .max]
            var attempts: [Slot] = badScopes.map { Slot(scope: $0, channel: 0, note: 0) }
            for scope in [UInt32(0), UInt32(count - 1)] {
                attempts += badChannels.map { Slot(scope: scope, channel: $0, note: 0) }
                attempts += badNotes.flatMap { [Slot(scope: scope, channel: 0, note: $0),
                                                Slot(scope: scope, channel: 15, note: $0)] }
            }
            for slot in attempts {
                let (scope, channel, note) = (slot.scope, slot.channel, slot.note)
                #expect(owner.noteOn(scope: scope, channel: channel, note: note) == .refused(.slotOutOfRange))
                #expect(owner.noteOff(scope: scope, channel: channel, note: note) == false)
                #expect(owner.isOwned(scope: scope, channel: channel, note: note) == false)
            }
            #expect(ownedSet(owner).isEmpty)
            for scope in badScopes {
                #expect(owner.ownedCount(scope: scope) == 0)
                for flag in SafetyFlag.allCases {
                    #expect(flags.request(flag, scope: scope) == .refused(.slotOutOfRange))
                }
                #expect(flags.take(scope: scope).isEmpty)
            }
            for scope in 0..<UInt32(count) { #expect(flags.take(scope: scope).isEmpty) }

            let last = UInt32(count - 1)
            #expect(owner.noteOn(scope: last, channel: 15, note: 127) == .ok)
            #expect(owner.isOwned(scope: last, channel: 15, note: 127))
            #expect(ownedSet(owner) == [((count - 1) * 16 + 15) * 128 + 127])
            #expect(owner.noteOff(scope: last, channel: 15, note: 127) == true)
            #expect(flags.request(.panic, scope: last) == .ok)
            #expect(flags.take(scope: last) == .panic)
        }

        @Test func scopesAndChannelsAreIsolated() throws {
            let count = 3
            for scope in 0..<count {
                for channel in [0, 1, 7, 15] {
                    for note in [0, 1, 63, 64, 127] {
                        let owner = try #require(ownership(scopes: count))
                        let slot = Slot(scope: UInt32(scope), channel: UInt8(channel), note: UInt8(note))
                        #expect(owner.noteOn(scope: slot.scope, channel: slot.channel, note: slot.note) == .ok)
                        #expect(ownedSet(owner) == [(scope * 16 + channel) * 128 + note])
                        for other in 0..<count {
                            #expect(owner.ownedCount(scope: UInt32(other)) == (other == scope ? 1 : 0))
                        }
                        var emitted: [Int] = []
                        _ = owner.releaseAll(scope: slot.scope) { emitted.append(Int($0) * 128 + Int($1)) }
                        #expect(emitted == [channel * 128 + note])
                    }
                }
            }

            let owner = try #require(ownership(scopes: count))
            for channel in UInt8(0)..<16 {
                for note in UInt8(0)..<128 { _ = owner.noteOn(scope: 1, channel: channel, note: note) }
            }
            #expect(owner.releaseAll(scope: 0) { _, _ in } == 0)
            #expect(owner.releaseAll(scope: 2) { _, _ in } == 0)
            #expect(owner.noteOff(scope: 0, channel: 0, note: 0) == false)
            #expect(owner.noteOff(scope: 2, channel: 15, note: 127) == false)
            #expect(owner.ownedCount(scope: 1) == 2_048)

            let flags = try #require(safetyFlags(scopes: count))
            #expect(flags.request(.panic, scope: 1) == .ok)
            #expect(flags.take(scope: 0).isEmpty && flags.take(scope: 2).isEmpty)
            #expect(flags.take(scope: 1) == .panic)
        }

        @Test func eventsAreBitwiseCopyable() {
            Root.requireBitwise(KernelEvent.self)
            Root.requireBitwise(KernelEventPayload.self)
            Root.requireBitwise(EventLane.self)
            Root.requireBitwise(EventClass.self)
            Root.requireBitwise(SafetyFlag.self)
            Root.requireBitwise(SafetyFlagSet.self)
            #expect(MemoryLayout<KernelEvent>.size <= 48)
            for item in payloadCases {
                let original = event(item.payload, scope: 7)
                let copy = original
                #expect(copy == original)
            }
            let nan = event(.rampTo(parameter: 1, value: .nan, durationFrames: 0))
            #expect(nan != nan)
            #expect(event(.rampTo(parameter: 1, value: 0.0, durationFrames: 0))
                    == event(.rampTo(parameter: 1, value: -0.0, durationFrames: 0)))
        }
    }

    struct OwnershipStress {
        /// Four requester `Thread`s and one spinning taker `Thread` run each round concurrently. Every
        /// (scope, flag) pair is requested exactly once per round by one requester, so a later request never
        /// repairs a lost one. Each requester also hands off mid-round, so overlap is guaranteed, not left to
        /// scheduling.
        @Test(.timeLimit(.minutes(1)))
        func stressConcurrentSafetyRequestsAreNeverLost() throws {
            let state = Contention(flags: try #require(safetyFlags(scopes: 8)), rounds: 2_000)
            let deadline = stressDeadline()
            let bodies: [@Sendable () -> Void] = (0..<state.requesters).map { index in
                { state.requester(index, deadline: deadline) }
            } + [{ state.taker(deadline: deadline) }]
            #expect(runOnThreads(deadline: deadline, bodies), "a thread timed out at the barrier or join")
            #expect(state.timeouts.load(ordering: .acquiring) == 0, "a bounded wait timed out")
            #expect(state.lost == 0)
            #expect(state.overlapped == state.rounds)
        }

        /// `request` (release) publishes the requester's earlier plain writes to the thread whose `take` (acquire)
        /// returns the flag. Uses `Thread`s so no task-runtime synchronisation hides a missing edge; a relaxed
        /// ordering shows up as a ThreadSanitizer race (non-zero exit) or a stale payload.
        /// Its value depends on a release + cross-module-optimisation + TSan lane: without TSan, a relaxed mutant on
        /// ARM almost always passes because the stale-payload window is tiny.
        @Test(.timeLimit(.minutes(1)))
        func stressRequestPublishesPriorWritesToTaker() throws {
            let rounds = 20_000
            let state = Publication(flags: try #require(safetyFlags(scopes: 1)))
            let deadline = stressDeadline()
            let requester: @Sendable () -> Void = {
                for current in 1...rounds {
                    state.payload.pointee = current
                    _ = state.flags.request(.panic, scope: 0)
                    guard spin(until: deadline, timeouts: state.timeouts, {
                        state.acknowledged.load(ordering: .acquiring) >= current
                    }) else { return }
                }
            }
            let taker: @Sendable () -> Void = {
                for current in 1...rounds {
                    guard spin(until: deadline, timeouts: state.timeouts, {
                        !state.flags.take(scope: 0).isEmpty
                    }) else { return }
                    if state.payload.pointee != current { state.mismatches += 1 }
                    state.acknowledged.store(current, ordering: .releasing)
                }
            }
            #expect(runOnThreads(deadline: deadline, [requester, taker]), "a thread timed out at the barrier or join")
            #expect(state.timeouts.load(ordering: .acquiring) == 0, "a bounded wait timed out")
            #expect(state.mismatches == 0)
        }
    }
}
