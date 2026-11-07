import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

private func noteOn(_ note: UInt8) -> KernelEventPayload { .noteOn(channel: 0, note: note, velocity: 100) }
private func noteOff(_ note: UInt8) -> KernelEventPayload { .noteOff(channel: 0, note: note) }

/// Retires `predecessor` (default: `rig.cycle`), as render does after its last `run`, then prepares a `.replacingCycle`
/// replacement on `rig`'s fan-in, latch and ownership.
private func takeover(of rig: CycleRig, retiring predecessor: KernelCycle? = nil,
                      blockCapacity: Int = 64) throws -> KernelCycle {
    (predecessor ?? rig.cycle).retire()
    return try replacement(of: rig, blockCapacity: blockCapacity)
}

/// A `.replacingCycle` cycle on `rig`'s parts (sharing its fan-in's refusal table and `telemetry`), no retire first.
private func replacement(of rig: CycleRig, blockCapacity: Int = 64,
                         telemetry: KernelCycleTelemetryOutput? = nil) throws(KernelCycle.PreparationError)
    -> KernelCycle {
    let parts = KernelCycleParts(events: rig.events, faults: rig.faults, ownership: rig.ownership, safety: rig.safety,
                                 ramps: rig.ramps, telemetry: telemetry, admissionRefusals: rig.cycle.admissionRefusals)
    // A valid gate; `try!` keeps the typed throw to `PreparationError`.
    // swiftlint:disable:next force_try
    let gate = try! ClockPulseGate(maximumPulsesPerBlock: 4, staleTolerance: 48)
    return try KernelCycle(parts, pulses: gate, blockCapacity: blockCapacity, perLaneQuota: 64)
}

/// The preparation refusal, or `nil` when `make` built a cycle.
private func refusal(_ make: () throws(KernelCycle.PreparationError) -> KernelCycle) -> KernelCycle.PreparationError? {
    do {
        _ = try make()
        return nil
    } catch {
        return error
    }
}

/// Runs one 64-frame block of `cycle` and returns its result with everything it emitted.
private func takeoverRun(_ cycle: KernelCycle, _ blockStart: Int64) -> (KernelCycleResult, [CycleEmission]) {
    var emitted: [CycleEmission] = []
    let result = cycle.run(blockStart: blockStart, frames: 64) { emitted.append(CycleEmission(event: $0, frame: $1)) }
    return (result, emitted)
}

/// One note key a takeover releases.
private struct TakeoverKey: Equatable {
    let scope: UInt32
    let channel: UInt8
    let note: UInt8

    init(_ scope: UInt32, _ channel: UInt8, _ note: UInt8) {
        self.scope = scope
        self.channel = channel
        self.note = note
    }
}

/// Seven keys across two scopes and two words, in (scope, channel, note) order.
private let sevenKeys = [TakeoverKey(0, 0, 1), TakeoverKey(0, 0, 2), TakeoverKey(0, 0, 64), TakeoverKey(0, 0, 127),
                         TakeoverKey(0, 1, 3), TakeoverKey(1, 0, 5), TakeoverKey(1, 2, 6)]

/// A synthesized release of `key` at `frame`.
private func takeoverRelease(_ key: TakeoverKey, at frame: Int64) -> CycleEmission {
    CycleEmission(event: KernelEvent(frame: frame, scope: key.scope, sequence: KernelCycle.releaseSequence,
                                     payload: .noteOff(channel: key.channel, note: key.note)), frame: frame)
}

/// The keys of every synthesized release in `emitted`.
private func releasedKeys(_ emitted: [CycleEmission]) -> [TakeoverKey] {
    emitted.compactMap { emission in
        guard emission.event.sequence == KernelCycle.releaseSequence,
              case .noteOff(let channel, let note) = emission.event.payload else { return nil }
        return TakeoverKey(emission.event.scope, channel, note)
    }
}

extension RealtimeHandoffTests {
    /// Copilot round 2 (4483068023): a `.replacingCycle` replacement takes over the shared `NoteOwnership` and
    /// releases what the retired cycle left sounding; it cuts notes short by design.
    struct CycleOrderingTakeover {
        /// Copilot's scenario: the retired cycle ran [0, 64) with `noteOn(9)` at 0 and buffered its `noteOff` at 128.
        /// The replacement sees an empty fan-in yet emits the release once, at its first `blockStart`, and clears
        /// the ownership. A `.freshFanIn` cycle over a new ownership with a note already marked takes nothing over.
        /// Kills: synthesis skipped; synthesis on `.freshFanIn` too; ownership not cleared.
        @Test func takeoverReleasesANoteWhoseNoteOffOnlyTheRetiredCycleBuffered() throws {
            let rig = try CycleRig()
            let token = try #require(rig.events.claimProducer())
            #expect(rig.push(cycleEvent(0, noteOn(9)), token) == .ok)
            #expect(rig.push(cycleEvent(128, noteOff(9)), token) == .ok)
            let (old, sounded) = rig.run(0, 64)
            #expect(sounded.map(\.event.payload) == [noteOn(9)] && old.pending == 1)
            let replacement = try takeover(of: rig)
            let (first, emitted) = takeoverRun(replacement, 64)
            #expect(emitted == [takeoverRelease(TakeoverKey(0, 0, 9), at: 64)])
            #expect(first.status == .ok && first.releasedNotes == 1)
            #expect(!rig.ownership.isOwned(scope: 0, channel: 0, note: 9))
            #expect(takeoverRun(replacement, 128).1.isEmpty)

            let ownership = try NoteOwnership(scopes: 2)
            #expect(ownership.noteOn(scope: 0, channel: 0, note: 9) == .ok)
            let parts = KernelCycleParts(events: rig.events, faults: rig.faults, ownership: ownership,
                                         safety: rig.safety, ramps: rig.ramps, start: .freshFanIn)
            let fresh = try KernelCycle(parts, pulses: ClockPulseGate(maximumPulsesPerBlock: 4, staleTolerance: 48),
                                        blockCapacity: 64, perLaneQuota: 64)
            let (freshResult, freshEmitted) = takeoverRun(fresh, 192)
            #expect(freshEmitted.isEmpty && freshResult.releasedNotes == 0)
            #expect(ownership.isOwned(scope: 0, channel: 0, note: 9))
        }

        /// The retired cycle's `noteOff` re-delivered after the takeover released its note is consumed once
        /// (counted, not emitted, nothing latched); a re-struck key then sounds and releases as usual. Kills: the
        /// takeover not recording its releases (double release); ownership not cleared.
        @Test func lateNoteOffAfterTakeoverIsConsumedOnceAndARestruckNoteReleases() throws {
            let rig = try CycleRig()
            let token = try #require(rig.events.claimProducer())
            #expect(rig.push(cycleEvent(0, noteOn(9)), token) == .ok)
            #expect(rig.push(cycleEvent(128, noteOff(9)), token) == .ok)
            _ = rig.run(0, 64)
            let replacement = try takeover(of: rig)
            #expect(takeoverRun(replacement, 64).1 == [takeoverRelease(TakeoverKey(0, 0, 9), at: 64)])
            #expect(rig.push(cycleEvent(128, noteOff(9)), token) == .ok)
            let (late, lateEmitted) = takeoverRun(replacement, 128)
            #expect(lateEmitted.isEmpty && late.status == .ok && late.releasedNotes == 0)
            #expect(late.discardedWhileSilenced == 1 && late.dispatched == 0)
            #expect(!rig.faults.isLatched(CycleRig.criticalScope))
            #expect(!rig.ownership.isOwned(scope: 0, channel: 0, note: 9))
            #expect(rig.push(cycleEvent(192, noteOn(9)), token) == .ok)
            #expect(rig.push(cycleEvent(200, noteOff(9)), token) == .ok)
            let (_, restruck) = takeoverRun(replacement, 192)
            #expect(restruck.map(\.event.payload) == [noteOn(9), noteOff(9)])
            #expect(!rig.ownership.isOwned(scope: 0, channel: 0, note: 9))
        }

        /// With nothing sounding the takeover emits and counts nothing, and ends at once: a `noteOn` queued after the
        /// first cycle proved the lanes empty sounds. Guards the empty case: a takeover that never ends.
        @Test func takeoverWithNothingSoundingEmitsNothing() throws {
            let rig = try CycleRig()
            let token = try #require(rig.events.claimProducer())
            let replacement = try takeover(of: rig)
            let (first, emitted) = takeoverRun(replacement, 0)
            #expect(emitted.isEmpty && first.releasedNotes == 0 && first.discardedWhileSilenced == 0)
            #expect(first.discardedDuringTakeover == 0)
            #expect(rig.push(cycleEvent(64, noteOn(9)), token) == .ok)
            #expect(takeoverRun(replacement, 64).1.map(\.event.payload) == [noteOn(9)])
        }

        /// At most `blockCapacity` (3) releases per cycle, in (scope, channel, note) order, the rest carried to the
        /// next cycle; bounds at N (3, one cycle), N + 1 (4, two) and 7 (three). In block 1 with 7 sounding the
        /// cursor is on scope 1: scope 0's `noteOn(100)` (before the cursor, fully released) sounds, scope 1's (at
        /// the cursor) is discarded and counted in `discardedDuringTakeover`; once the takeover ends both sound.
        /// Kills: the carry dropped; `noteOn`s decided in held scopes; the cursor test reversed; the discard counted
        /// elsewhere or not copied into the result.
        @Test func takeoverCarriesReleasesBeyondBlockCapacityInOrder() throws {
            for sounding in [3, 4, 7] {
                let rig = try CycleRig()
                let token = try #require(rig.events.claimProducer())
                for key in sevenKeys.prefix(sounding) {
                    #expect(rig.ownership.noteOn(scope: key.scope, channel: key.channel, note: key.note) == .ok)
                }
                let replacement = try takeover(of: rig, blockCapacity: 3)
                for block in 0..<4 {
                    let blockStart = Int64(block) * 64
                    let pushed = [cycleEvent(blockStart, noteOn(100), scope: 0),
                                  cycleEvent(blockStart, noteOn(100), scope: 1)]
                    if block == 1 || block == 3 {
                        for event in pushed { #expect(rig.push(event, token) == .ok) }
                    }
                    let chunk = sevenKeys.prefix(sounding).dropFirst(block * 3).prefix(3)
                    var expected = chunk.map { takeoverRelease($0, at: blockStart) }
                    let held = block == 1 && sounding > 6
                    if block == 1 || block == 3 {
                        let sounds = held ? Array(pushed.prefix(1)) : pushed
                        expected += sounds.map { CycleEmission(event: $0, frame: blockStart) }
                    }
                    let (result, emitted) = takeoverRun(replacement, blockStart)
                    #expect(emitted == expected && result.releasedNotes == chunk.count)
                    #expect(result.discardedDuringTakeover == (held ? 1 : 0) && result.discardedWhileSilenced == 0)
                }
                for key in sevenKeys.prefix(sounding) {
                    #expect(!rig.ownership.isOwned(scope: key.scope, channel: key.channel, note: key.note))
                }
            }
        }

        /// A panic (on scope 1) or a critical latch in the middle of a three-cycle takeover: block 1 releases its
        /// takeover chunk first, then the interruption releases the rest, so every key is released exactly once and
        /// the takeover ends (its next pass finds nothing); a later `noteOn` in scope 1 sounds.
        @Test func panicOrLatchMidTakeoverReleasesEveryNoteExactlyOnce() throws {
            for latch in [false, true] {
                let rig = try CycleRig()
                let token = try #require(rig.events.claimProducer())
                for key in sevenKeys {
                    #expect(rig.ownership.noteOn(scope: key.scope, channel: key.channel, note: key.note) == .ok)
                }
                let replacement = try takeover(of: rig, blockCapacity: 3)
                var emitted = takeoverRun(replacement, 0).1
                if latch {
                    #expect(rig.faults.raise(CycleRig.criticalScope, .criticalExhausted, frame: 64) == .ok)
                } else {
                    #expect(rig.safety.request(.panic, scope: 1) == .ok)
                }
                let (interrupted, interruptedEmitted) = takeoverRun(replacement, 64)
                emitted += interruptedEmitted
                #expect(interrupted.status == (latch ? .silenced(.scopeFaulted) : .silenced(.safetyMute)))
                #expect(interrupted.releasedNotes == 4)
                if latch {
                    #expect(rig.faults.acknowledge(try #require(rig.faults.observe(CycleRig.criticalScope))) != nil)
                }
                let (after, afterEmitted) = takeoverRun(replacement, 128)
                #expect(after.status == .ok && after.releasedNotes == 0 && afterEmitted.isEmpty)
                #expect(releasedKeys(emitted) == sevenKeys && emitted.count == sevenKeys.count)
                #expect(rig.push(cycleEvent(192, noteOn(100), scope: 1), token) == .ok)
                let (later, laterEmitted) = takeoverRun(replacement, 192)
                #expect(laterEmitted.map(\.event.payload) == [noteOn(100)] && later.discardedDuringTakeover == 0)
            }
        }

        /// A second replacement in the middle of a takeover: the first released three keys, retires, and the second
        /// takes the shared ownership over from scope 0 again, releasing only the four still sounding, each once.
        /// The takeover record is per cycle: a late `noteOff` for a key the first takeover released reaches the
        /// second as an ordinary unowned `noteOff` and is emitted (redundant, harmless), never latched.
        @Test func secondReplacementMidTakeoverReleasesTheRestOnce() throws {
            let rig = try CycleRig()
            let token = try #require(rig.events.claimProducer())
            for key in sevenKeys {
                #expect(rig.ownership.noteOn(scope: key.scope, channel: key.channel, note: key.note) == .ok)
            }
            let first = try takeover(of: rig, blockCapacity: 3)
            var emitted = takeoverRun(first, 0).1
            let second = try takeover(of: rig, retiring: first, blockCapacity: 3)
            for block in Int64(1)...3 {
                let (result, blockEmitted) = takeoverRun(second, block * 64)
                emitted += blockEmitted
                #expect(result.releasedNotes == [3, 1, 0][Int(block) - 1])
            }
            #expect(releasedKeys(emitted) == sevenKeys && emitted.count == sevenKeys.count)
            #expect(rig.push(cycleEvent(256, noteOff(1)), token) == .ok)
            let (late, lateEmitted) = takeoverRun(second, 256)
            #expect(lateEmitted.map(\.event.payload) == [noteOff(1)] && late.dispatched == 1)
            #expect(!rig.faults.isLatched(CycleRig.criticalScope))
        }

        /// `NoteOwnership.releaseFirst` edges: an empty scope, `limit` 0 or negative and an out-of-range scope release
        /// nothing; notes at both ends of a word and the last bit of the last scope (channel 15, note 127) are
        /// released in order across calls, fewer than `limit` when that is all. A takeover with notes only in the
        /// last scope's last bit releases them and ends (its cursor reaches the end).
        @Test func releaseFirstEdgesAndATakeoverEndingAtTheLastScope() throws {
            let ownership = try NoteOwnership(scopes: 2)
            var released: [TakeoverKey] = []
            #expect(ownership.releaseFirst(scope: 1, limit: 4) { released.append(TakeoverKey(1, $0, $1)) } == 0)
            for (channel, note) in [(UInt8(15), UInt8(127)), (15, 0), (0, 63), (0, 64)] {
                #expect(ownership.noteOn(scope: 1, channel: channel, note: note) == .ok)
            }
            for (scope, limit) in [(UInt32(1), 0), (1, -1), (2, 4), (0, 4)] {
                #expect(ownership.releaseFirst(scope: scope, limit: limit) { released.append(TakeoverKey(9, $0, $1)) }
                        == 0)
            }
            #expect(released.isEmpty && ownership.ownedCount(scope: 1) == 4)
            #expect(ownership.releaseFirst(scope: 1, limit: 2) { released.append(TakeoverKey(1, $0, $1)) } == 2)
            #expect(ownership.releaseFirst(scope: 1, limit: 5) { released.append(TakeoverKey(1, $0, $1)) } == 2)
            #expect(ownership.releaseFirst(scope: 1, limit: 5) { released.append(TakeoverKey(1, $0, $1)) } == 0)
            #expect(released == [TakeoverKey(1, 0, 63), TakeoverKey(1, 0, 64), TakeoverKey(1, 15, 0),
                                 TakeoverKey(1, 15, 127)])
            #expect(ownership.ownedCount(scope: 1) == 0)

            let rig = try CycleRig()
            let token = try #require(rig.events.claimProducer())
            #expect(rig.ownership.noteOn(scope: 1, channel: 15, note: 127) == .ok)
            let replacement = try takeover(of: rig, blockCapacity: 1)
            #expect(takeoverRun(replacement, 0).1 == [takeoverRelease(TakeoverKey(1, 15, 127), at: 0)])
            #expect(rig.push(cycleEvent(64, noteOn(100), scope: 1), token) == .ok)
            let (after, emitted) = takeoverRun(replacement, 64)
            #expect(emitted.map(\.event.payload) == [noteOn(100)] && after.releasedNotes == 0)
        }

        /// Copilot round 4 (4487174433): with one release per cycle over scope 0's two notes and scope 1's three,
        /// the `noteOn`s held in scope 1 in blocks 1–3 are discarded and accumulate in the published telemetry,
        /// which keeps the sum once the takeover ends and scope 1 sounds again. Kills: the discards not accumulated.
        @Test func takeoverDiscardsAccumulateInTelemetry() throws {
            let slots = try kernelCycleTelemetrySlots()
            let output = KernelCycleTelemetryOutput(slots: slots, slot: 1, clockGeneration: 0)
            let rig = try CycleRig(telemetry: output)
            let token = try #require(rig.events.claimProducer())
            for key in [TakeoverKey(0, 0, 1), TakeoverKey(0, 0, 2), TakeoverKey(1, 0, 5), TakeoverKey(1, 0, 6),
                        TakeoverKey(1, 0, 7)] {
                #expect(rig.ownership.noteOn(scope: key.scope, channel: key.channel, note: key.note) == .ok)
            }
            rig.cycle.retire()
            let successor = try replacement(of: rig, blockCapacity: 1, telemetry: output)
            var discarded: [Int] = []
            for block in Int64(0)...5 {
                if (1...3).contains(block) || block == 5 {
                    #expect(rig.push(cycleEvent(block * 64, noteOn(100), scope: 1), token) == .ok)
                }
                let (result, emitted) = takeoverRun(successor, block * 64)
                discarded.append(result.discardedDuringTakeover)
                #expect(emitted.contains { $0.event.payload == noteOn(100) } == (block == 5))
            }
            #expect(discarded == [0, 1, 1, 1, 0, 0])
            #expect(successor.telemetry.discardedDuringTakeover == 3)
            #expect(try #require(successor.latestTelemetry()).value.discardedDuringTakeover == 3)
            #expect(KernelCycleTelemetry.saturatingAdd(.max - 1, 3) == .max)
        }
    }

    /// Round 2g (delta review 304c1cec, Copilot 🔵): release history survives replacement. The tombstones live in
    /// the shared `NoteOwnership`, a retiring cycle records its pending `noteOff`s, and preparation enforces both
    /// the retirement and `.replacingCycle` over a used ownership.
    struct CycleOrderingRetirement {
        /// Finding 1: lane 0's `noteOff(60)` at 999 is applied in block 1000 (tombstone 999); lane 1's earlier
        /// `noteOn(60)` at 990 arrives in block 1128, 138 frames late but within tolerance. With or without a
        /// replacement in between it is superseded, never sounds and is never owned. Kills: the decider allocating
        /// its own tombstone table.
        @Test func replacementKeepsReleaseHistorySoALateNoteOnNeverSticks() throws {
            for replaced in [false, true] {
                let rig = try CycleRig()
                let first = try #require(rig.events.claimProducer()), second = try #require(rig.events.claimProducer())
                #expect(rig.push(cycleEvent(999, noteOff(60)), first) == .ok)
                #expect(rig.run(1_000, 64).1.map(\.event.payload) == [noteOff(60)])
                let cycle = replaced ? try takeover(of: rig) : rig.cycle
                #expect(takeoverRun(cycle, 1_064).1.isEmpty)
                #expect(rig.push(cycleEvent(990, noteOn(60)), second) == .ok)
                let (late, emitted) = takeoverRun(cycle, 1_128)
                #expect(emitted.isEmpty && late.discardedSuperseded == 1)
                #expect(!rig.ownership.isOwned(scope: 0, channel: 0, note: 60))
            }
        }

        /// Finding 2: lane 1's `noteOff(60)` at 1100 is drained in block 1000 but not due, so it is pending when the
        /// cycle retires; lane 0 then pushes `noteOn(60)` at 1050. Unreplaced, the release applies in block 1064;
        /// replaced, `retire()` records it, and either way the `noteOn` is superseded in block 1128 and never owned.
        /// A pending `noteOn(61)` (with its `noteOff`) is dropped with the retired cycle: it never sounds or sticks.
        /// Kills: `retire()` recording nothing.
        @Test func retiredCyclesPendingNoteOffStillSupersedesALaterArrivingNoteOn() throws {
            for replaced in [false, true] {
                let rig = try CycleRig()
                let first = try #require(rig.events.claimProducer()), second = try #require(rig.events.claimProducer())
                for event in [cycleEvent(1_100, noteOff(60)), cycleEvent(1_100, noteOn(61)),
                              cycleEvent(1_120, noteOff(61))] {
                    #expect(rig.push(event, second) == .ok)
                }
                #expect(rig.run(1_000, 64).0.pending == 3)
                let cycle = replaced ? try takeover(of: rig) : rig.cycle
                let due = takeoverRun(cycle, 1_064).1.map(\.event.payload)
                #expect(due == (replaced ? [] : [noteOff(60), noteOn(61), noteOff(61)]))
                #expect(rig.push(cycleEvent(1_050, noteOn(60)), first) == .ok)
                let (late, emitted) = takeoverRun(cycle, 1_128)
                #expect(emitted.isEmpty && late.discardedSuperseded == 1)
                for note in UInt8(60)...61 { #expect(!rig.ownership.isOwned(scope: 0, channel: 0, note: note)) }
            }
        }

        /// Preparation over a shared ownership: a `.replacingCycle` before the live cycle retires, and a `.freshFanIn`
        /// over an ownership any cycle used (even retired), are typed refusals that change nothing (the live cycle
        /// keeps running); a stale retire of an already retired cycle does not release its replacement's claim.
        /// Kills: the retirement or the fresh check skipped; the claim never recorded; `retire()` not handing the
        /// claim back; a stale retire releasing any claim.
        @Test func preparationEnforcesRetirementAndTakeoverOverAUsedOwnership() throws {
            let rig = try CycleRig()
            let token = try #require(rig.events.claimProducer())
            let fresh = KernelCycleParts(events: rig.events, faults: rig.faults, ownership: rig.ownership,
                                         safety: rig.safety, ramps: rig.ramps, start: .freshFanIn)
            let gate = try ClockPulseGate(maximumPulsesPerBlock: 4, staleTolerance: 48)
            #expect(refusal { () throws(KernelCycle.PreparationError) in try replacement(of: rig) }
                    == .ownershipClaim(.predecessorNotRetired))
            #expect(refusal { () throws(KernelCycle.PreparationError) in
                try KernelCycle(fresh, pulses: gate, blockCapacity: 64, perLaneQuota: 64)
            } == .ownershipClaim(.alreadyUsed))
            #expect(rig.push(cycleEvent(0, noteOn(9)), token) == .ok)
            #expect(rig.run(0, 64).1.map(\.event.payload) == [noteOn(9)])
            rig.cycle.retire()
            #expect(refusal { () throws(KernelCycle.PreparationError) in
                try KernelCycle(fresh, pulses: gate, blockCapacity: 64, perLaneQuota: 64)
            } == .ownershipClaim(.alreadyUsed))
            let next = try replacement(of: rig)
            rig.cycle.retire()
            #expect(refusal { () throws(KernelCycle.PreparationError) in try replacement(of: rig) }
                    == .ownershipClaim(.predecessorNotRetired))
            #expect(takeoverRun(next, 64).1 == [takeoverRelease(TakeoverKey(0, 0, 9), at: 64)])
            next.retire()
            #expect(refusal { () throws(KernelCycle.PreparationError) in try replacement(of: rig) } == nil)
        }

        /// Finding 8: the retired cycle's `noteOff(9)` re-delivered into a silenced (panic) cycle after the takeover
        /// released note 9 is consumed there (not emitted) and clears the takeover record, so a later unowned
        /// `noteOff(9)` is an ordinary one (emitted), not consumed again. Kills: the silenced consume keeping the bit.
        @Test func lateNoteOffInASilencedCycleIsConsumedAndClearsTheTakeoverRecord() throws {
            let rig = try CycleRig()
            let token = try #require(rig.events.claimProducer())
            #expect(rig.push(cycleEvent(0, noteOn(9)), token) == .ok)
            #expect(rig.push(cycleEvent(128, noteOff(9)), token) == .ok)
            _ = rig.run(0, 64)
            let replacement = try takeover(of: rig)
            #expect(takeoverRun(replacement, 64).1 == [takeoverRelease(TakeoverKey(0, 0, 9), at: 64)])
            #expect(rig.push(cycleEvent(130, noteOff(9)), token) == .ok)
            #expect(rig.safety.request(.panic, scope: 0) == .ok)
            let (silenced, silencedEmitted) = takeoverRun(replacement, 128)
            #expect(silenced.status == .silenced(.safetyMute) && silencedEmitted.isEmpty)
            #expect(silenced.discardedWhileSilenced == 1)
            #expect(rig.push(cycleEvent(200, noteOff(9)), token) == .ok)
            let (later, laterEmitted) = takeoverRun(replacement, 192)
            #expect(laterEmitted.map(\.event.payload) == [noteOff(9)])
            #expect(later.dispatched == 1 && later.discardedWhileSilenced == 0)
        }

        /// Re-strike, release, then the late `noteOff`: after the takeover released note 9 it is struck and released
        /// again (both emitted, as owned), and the retired cycle's late `noteOff(9)` is still consumed once, so no
        /// second `noteOff` follows the re-struck note's. Kills: a re-strike clearing the takeover record (the
        /// round 2f draft called that behaviour-neutral; it is not).
        @Test func restruckNoteReleasedThenLateNoteOffIsConsumedOnce() throws {
            let rig = try CycleRig()
            let token = try #require(rig.events.claimProducer())
            #expect(rig.push(cycleEvent(0, noteOn(9)), token) == .ok)
            #expect(rig.push(cycleEvent(128, noteOff(9)), token) == .ok)
            _ = rig.run(0, 64)
            let replacement = try takeover(of: rig)
            #expect(takeoverRun(replacement, 64).1 == [takeoverRelease(TakeoverKey(0, 0, 9), at: 64)])
            #expect(rig.push(cycleEvent(130, noteOn(9)), token) == .ok)
            #expect(rig.push(cycleEvent(140, noteOff(9)), token) == .ok)
            #expect(takeoverRun(replacement, 128).1.map(\.event.payload) == [noteOn(9), noteOff(9)])
            #expect(rig.push(cycleEvent(150, noteOff(9)), token) == .ok)
            let (late, lateEmitted) = takeoverRun(replacement, 192)
            #expect(lateEmitted.isEmpty && late.discardedWhileSilenced == 1 && late.dispatched == 0)
            #expect(!rig.ownership.isOwned(scope: 0, channel: 0, note: 9))
        }

        /// Round 2h (delta review): a `run` after `retire()` does nothing and says so, even with a replacement live:
        /// it drains nothing (the replacement drains `noteOn(10)`), emits nothing, keeps the panic for the
        /// replacement, leaves the shared ownership (note 9 for the takeover) and its own telemetry alone; a second
        /// `retire()` releases nothing. Kills: the retired flag ignored.
        @Test func runAfterRetireDoesNothingAndLeavesTheReplacementAlone() throws {
            let rig = try CycleRig()
            let token = try #require(rig.events.claimProducer())
            #expect(rig.push(cycleEvent(0, noteOn(9)), token) == .ok)
            #expect(rig.run(0, 64).1.map(\.event.payload) == [noteOn(9)])
            let successor = try takeover(of: rig)
            rig.cycle.retire()
            #expect(refusal { () throws(KernelCycle.PreparationError) in try replacement(of: rig) }
                    == .ownershipClaim(.predecessorNotRetired))
            #expect(rig.push(cycleEvent(64, noteOn(10)), token) == .ok)
            #expect(rig.safety.request(.panic, scope: 1) == .ok)
            let telemetry = rig.cycle.telemetry
            let (stray, strayEmitted) = rig.run(64, 64)
            #expect(stray.retired && stray.status == .refused(.notOwner) && strayEmitted.isEmpty)
            #expect(stray.drained == 0 && stray.releasedNotes == 0 && stray.pending == 0)
            #expect(rig.cycle.telemetry == telemetry)
            #expect(rig.ownership.isOwned(scope: 0, channel: 0, note: 9))
            let (live, liveEmitted) = takeoverRun(successor, 64)
            #expect(!live.retired && live.status == .silenced(.safetyMute) && live.drained == 1)
            #expect(liveEmitted == [takeoverRelease(TakeoverKey(0, 0, 9), at: 64)] && live.discardedWhileSilenced == 1)
        }

        /// Copilot round 4 (4487174356): a `.freshFanIn` preparation reads the never-claimed claim word, then another
        /// cycle claims, sounds note 9 (set directly: the racer never runs) and retires before it claims. Its claim
        /// from that stale state is `.alreadyUsed` and changes nothing. A `.replacingCycle` claim from the retired
        /// snapshot (taken while the word was free) is `.predecessorNotRetired` once `next` holds the word. `racer`
        /// and `next` share `rig.events` while `rig.cycle` lives. A replacement takes note 9 over; a stale release
        /// of a handed-back claim releases nothing, and its non-empty loss never replaces the one the holder left
        /// (round 2j). Kills: the claim compare-exchanging from a re-read word (check-then-claim); a stale release
        /// releasing any claim; the loss stored without the `== claim.held` guard.
        @Test func freshClaimRacingAClaimRunRetireIsRefused() throws {
            let rig = try CycleRig()
            let ownership = try NoteOwnership(scopes: 2)
            let stale = ownership.cycleClaimState()
            #expect(NoteOwnership.cycleClaimRefusal(stale, fresh: true) == nil)
            let parts = KernelCycleParts(events: rig.events, faults: rig.faults, ownership: ownership,
                                         safety: rig.safety, ramps: rig.ramps,
                                         admissionRefusals: rig.cycle.admissionRefusals)
            let gate = try ClockPulseGate(maximumPulsesPerBlock: 4, staleTolerance: 48)
            let racer = try KernelCycle(parts, pulses: gate, blockCapacity: 64, perLaneQuota: 64)
            #expect(ownership.noteOn(scope: 0, channel: 0, note: 9) == .ok)
            racer.retire()
            let retired = ownership.cycleClaimState()
            #expect(throws: NoteOwnership.CycleClaimRefusal.alreadyUsed) {
                try ownership.claimForCycle(fresh: true, from: stale)
            }
            let next = try KernelCycle(parts, pulses: gate, blockCapacity: 64, perLaneQuota: 64)
            #expect(throws: NoteOwnership.CycleClaimRefusal.predecessorNotRetired) {
                try ownership.claimForCycle(fresh: false, from: retired)
            }
            #expect(takeoverRun(next, 0).1 == [takeoverRelease(TakeoverKey(0, 0, 9), at: 0)])
            let direct = try NoteOwnership(scopes: 1)
            let stray = KernelRetirementLoss(noteOns: 0, controls: 0, programs: 1, ramps: 0, clockPulses: 0)
            let left = KernelRetirementLoss(noteOns: 0, controls: 0, programs: 0, ramps: 0, clockPulses: 1)
            let held = try direct.claimForCycle(fresh: true, from: direct.cycleClaimState())
            direct.releaseCycleClaim(held, loss: KernelRetirementLoss())
            let holder = try direct.claimForCycle(fresh: false, from: direct.cycleClaimState())
            direct.releaseCycleClaim(held, loss: stray)
            #expect(throws: NoteOwnership.CycleClaimRefusal.predecessorNotRetired) {
                try direct.claimForCycle(fresh: false, from: direct.cycleClaimState())
            }
            direct.releaseCycleClaim(holder, loss: left)
            direct.releaseCycleClaim(held, loss: stray)
            #expect(try direct.claimForCycle(fresh: false, from: direct.cycleClaimState()).inherited == left)
        }
    }
}
