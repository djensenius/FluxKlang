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

/// Shared state for the `Thread`-based publication test: a plain, non-atomic payload published by `request`.
private final class Publication: @unchecked Sendable {
    let flags: SafetyFlags
    let payload = UnsafeMutablePointer<Int>.allocate(capacity: 1)
    /// Taker → requester only, so it adds no happens-before edge from the requester's write to the taker's read.
    let acknowledged = Atomic<Int>(0)
    /// Written by the taker thread only; read after both threads have finished.
    var mismatches = 0
    let requesterDone = DispatchSemaphore(value: 0)
    let takerDone = DispatchSemaphore(value: 0)

    init(flags: SafetyFlags) {
        self.flags = flags
        payload.initialize(to: 0)
    }

    deinit {
        payload.deinitialize(count: 1)
        payload.deallocate()
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
        /// Requesters and one spinning taker run each round concurrently; every (scope, flag) pair is requested
        /// exactly once per round by one requester, so a lost request is never repaired by a later one.
        @Test(.timeLimit(.minutes(1)))
        func stressConcurrentSafetyRequestsAreNeverLost() async throws {
            let (rounds, scopes, requesters) = (2_000, 8, 4)
            let flags = try #require(safetyFlags(scopes: scopes))
            let round = Atomic<Int>(0)
            let requested = Atomic<Int>(0)
            let (lost, overlapped) = await withTaskGroup(of: (Int, Int).self) { group in
                for requester in 0..<requesters {
                    group.addTask {
                        let flag = SafetyFlag.allCases[requester % SafetyFlag.allCases.count]
                        for current in 0..<rounds {
                            while round.load(ordering: .acquiring) < current { await Task.yield() }
                            for scope in 0..<scopes where scope % (requesters / 2) == requester / 2 {
                                _ = flags.request(flag, scope: UInt32(scope))
                            }
                            requested.add(1, ordering: .acquiringAndReleasing)
                        }
                        return (0, 0)
                    }
                }
                group.addTask {
                    var (lost, overlapped) = (0, 0)
                    for current in 0..<rounds {
                        var union = [SafetyFlagSet](repeating: [], count: scopes)
                        var sweeps = 0
                        while requested.load(ordering: .acquiring) < requesters * (current + 1) {
                            sweep(flags, into: &union)
                            sweeps += 1
                            if sweeps % 64 == 0 { await Task.yield() }
                        }
                        // A round overlapped when a take made while requesters were still running found a request.
                        if union.contains(where: { !$0.isEmpty }) { overlapped += 1 }
                        sweep(flags, into: &union)
                        lost += union.filter { $0 != [.panic, .allNotesOff] }.count
                        round.store(current + 1, ordering: .releasing)
                    }
                    return (lost, overlapped)
                }
                var total = (0, 0)
                for await part in group { total = (total.0 + part.0, total.1 + part.1) }
                return total
            }
            #expect(lost == 0)
            #expect(overlapped > 0)
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
            Thread {
                for current in 1...rounds {
                    state.payload.pointee = current
                    _ = state.flags.request(.panic, scope: 0)
                    while state.acknowledged.load(ordering: .acquiring) < current {}
                }
                state.requesterDone.signal()
            }.start()
            Thread {
                for current in 1...rounds {
                    while state.flags.take(scope: 0).isEmpty {}
                    if state.payload.pointee != current { state.mismatches += 1 }
                    state.acknowledged.store(current, ordering: .releasing)
                }
                state.takerDone.signal()
            }.start()
            state.requesterDone.wait()
            state.takerDone.wait()
            #expect(state.mismatches == 0)
        }
    }
}
