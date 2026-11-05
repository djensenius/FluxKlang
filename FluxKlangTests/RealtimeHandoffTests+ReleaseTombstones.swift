import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

private func noteOn(_ note: UInt8) -> KernelEventPayload { .noteOn(channel: 0, note: note, velocity: 100) }
private func noteOff(_ note: UInt8) -> KernelEventPayload { .noteOff(channel: 0, note: note) }
private func control(_ value: UInt32) -> KernelEventPayload { .control(channel: 0, controller: 7, value: value) }

/// Every `noteOn` payload in `emitted`.
private func noteOns(_ emitted: [CycleEmission]) -> [KernelEventPayload] {
    emitted.map(\.event.payload).filter { if case .noteOn = $0 { true } else { false } }
}

extension RealtimeHandoffTests {
    /// #64 E5a round 4: release tombstones make "release wins" deterministic across lanes. Each partial drain
    /// below delivers a `noteOff` from lane 0 or 1 before an earlier-stamped `noteOn` of the same key from the
    /// other lane (a fresh fan-in starts draining at lane 0; the first claim gets lane 0).
    struct CycleTombstones {
        /// Kills: no tombstone guard (the late `noteOn@990` sounds for ever after its release was already applied).
        @Test func blockCapacityPartialDrainCannotStickANote() throws {
            let rig = try CycleRig(blockCapacity: 1)
            let first = try #require(rig.events.claimProducer())
            let second = try #require(rig.events.claimProducer())
            #expect(rig.push(cycleEvent(999, noteOff(60)), first) == .ok)
            #expect(rig.push(cycleEvent(990, noteOn(60)), second) == .ok)
            let (released, releasedEmitted) = rig.run(1_000, 64)
            #expect(released.drained == 1 && releasedEmitted.map(\.event.payload) == [noteOff(60)])
            let (late, lateEmitted) = rig.run(1_064, 64)
            #expect(late.drained == 1 && late.discardedSuperseded == 1 && late.dispatched == 0 && lateEmitted.isEmpty)
            #expect(!rig.ownership.isOwned(scope: 0, channel: 0, note: 60) && rig.ownership.ownedCount(scope: 0) == 0)
            #expect(rig.run(1_128, 64).1.isEmpty && rig.ownership.ownedCount(scope: 0) == 0)
        }

        /// Kills: no tombstone guard, when the per-lane quota (not the buffer) splits the drain.
        @Test func perLaneQuotaPartialDrainCannotStickANote() throws {
            let rig = try CycleRig(perLaneQuota: 1)
            let first = try #require(rig.events.claimProducer())
            let second = try #require(rig.events.claimProducer())
            #expect(rig.push(cycleEvent(999, noteOff(60)), first) == .ok)
            #expect(rig.push(cycleEvent(980, control(1)), second) == .ok)
            #expect(rig.push(cycleEvent(990, noteOn(60)), second) == .ok)
            let (released, releasedEmitted) = rig.run(1_000, 64)
            #expect(released.drained == 2 && releasedEmitted.map(\.event.payload) == [control(1), noteOff(60)])
            let (late, lateEmitted) = rig.run(1_064, 64)
            #expect(late.drained == 1 && late.discardedSuperseded == 1 && late.dispatched == 0 && lateEmitted.isEmpty)
            #expect(!rig.ownership.isOwned(scope: 0, channel: 0, note: 60) && rig.ownership.ownedCount(scope: 0) == 0)
            #expect(rig.run(1_128, 64).1.isEmpty && rig.ownership.ownedCount(scope: 0) == 0)
        }

        /// Round 4b: ties go to the `noteOn` (a retrigger at its key's release frame is a new note), and a
        /// tombstone never suppresses another key. Kills: `<=` (the tie superseded).
        @Test func onsetAtTombstoneSoundsAndOtherKeysAreUnaffected() throws {
            let rig = try CycleRig(blockCapacity: 1)
            let first = try #require(rig.events.claimProducer())
            let second = try #require(rig.events.claimProducer())
            #expect(rig.push(cycleEvent(999, noteOff(60)), first) == .ok)
            #expect(rig.push(cycleEvent(999, noteOn(60)), second) == .ok)
            #expect(rig.push(cycleEvent(990, noteOn(61)), first) == .ok)
            #expect(rig.run(1_000, 64).1.map(\.event.payload) == [noteOff(60)])
            let (tie, tieEmitted) = rig.run(1_064, 64)
            #expect(tie.discardedSuperseded == 0 && noteOns(tieEmitted) == [noteOn(60)])
            let (other, otherEmitted) = rig.run(1_128, 64)
            #expect(other.discardedSuperseded == 0 && noteOns(otherEmitted) == [noteOn(61)])
            #expect(rig.ownership.isOwned(scope: 0, channel: 0, note: 60) && rig.ownership.ownedCount(scope: 0) == 2)
        }

        /// Reviewer repro: one producer's noteOn@0, noteOff@100, noteOn@100, noteOff@200 is an ordinary retrigger;
        /// all four are delivered in order and nothing is left owned. Kills: `<=` (the second onset superseded).
        @Test func sameFrameRetriggerFromOneProducerSounds() throws {
            let rig = try CycleRig()
            let token = try #require(rig.events.claimProducer())
            for (sequence, (frame, payload)) in [(0, noteOn(60)), (100, noteOff(60)), (100, noteOn(60)),
                                                 (200, noteOff(60))].enumerated() {
                #expect(rig.push(cycleEvent(Int64(frame), payload, sequence: UInt64(sequence)), token) == .ok)
            }
            var emitted: [UInt64] = []
            var superseded = 0
            for blockStart in stride(from: Int64(0), to: 256, by: 64) {
                let (result, events) = rig.run(blockStart, 64)
                emitted += events.map(\.event.sequence)
                superseded += result.discardedSuperseded
            }
            #expect(emitted == [0, 1, 2, 3] && superseded == 0)
            #expect(rig.ownership.ownedCount(scope: 0) == 0)
        }

        /// The same retrigger split across drains: lane 0's `noteOff@100` is applied a block before lane 1's
        /// `noteOn@100` arrives (late, within tolerance); it still sounds and its own `noteOff@200` releases it.
        /// Kills: `<=`.
        @Test func crossDrainSameFrameRetriggerSounds() throws {
            let rig = try CycleRig(blockCapacity: 1)
            let first = try #require(rig.events.claimProducer())
            let second = try #require(rig.events.claimProducer())
            #expect(rig.push(cycleEvent(100, noteOff(60)), first) == .ok)
            #expect(rig.push(cycleEvent(100, noteOn(60)), second) == .ok)
            #expect(rig.push(cycleEvent(200, noteOff(60)), second) == .ok)
            #expect(rig.run(64, 64).1.map(\.event.payload) == [noteOff(60)])
            let (late, lateEmitted) = rig.run(128, 64)
            #expect(late.discardedSuperseded == 0 && noteOns(lateEmitted) == [noteOn(60)])
            #expect(rig.ownership.isOwned(scope: 0, channel: 0, note: 60))
            #expect(rig.run(192, 64).1.map(\.event.payload) == [noteOff(60)])
            #expect(rig.ownership.ownedCount(scope: 0) == 0)
        }

        /// Retrigger: lane 0's owned note is released by lane 1's `noteOff@999`; lane 0's late `noteOn@990` then
        /// arrives and is discarded. Kills: no tombstone guard (the retriggered note would stick).
        @Test func lateRetriggerAfterCrossLaneReleaseIsDiscarded() throws {
            let rig = try CycleRig(blockCapacity: 1)
            let first = try #require(rig.events.claimProducer())
            let second = try #require(rig.events.claimProducer())
            #expect(rig.push(cycleEvent(900, noteOn(60)), first) == .ok)
            #expect(noteOns(rig.run(896, 64).1) == [noteOn(60)])
            #expect(rig.ownership.isOwned(scope: 0, channel: 0, note: 60))
            #expect(rig.push(cycleEvent(999, noteOff(60)), second) == .ok)
            #expect(rig.push(cycleEvent(990, noteOn(60)), first) == .ok)
            #expect(rig.run(1_000, 64).1.map(\.event.payload) == [noteOff(60)])
            #expect(!rig.ownership.isOwned(scope: 0, channel: 0, note: 60))
            let (late, lateEmitted) = rig.run(1_064, 64)
            #expect(late.discardedSuperseded == 1 && lateEmitted.isEmpty)
            #expect(!rig.ownership.isOwned(scope: 0, channel: 0, note: 60) && rig.ownership.ownedCount(scope: 0) == 0)
        }

        /// A release applied while silenced still records its tombstone; a panic keeps tombstones but records none
        /// for synthesized releases. Kills: tombstones only on decided `noteOff`s; synthesized releases recording.
        @Test func silencedReleasesRecordAndSynthesizedReleasesDoNot() throws {
            let rig = try CycleRig(blockCapacity: 1)
            let first = try #require(rig.events.claimProducer())
            let second = try #require(rig.events.claimProducer())
            #expect(rig.push(cycleEvent(60, noteOn(61)), first) == .ok)
            #expect(noteOns(rig.run(0, 64).1) == [noteOn(61)])
            #expect(rig.push(cycleEvent(99, noteOff(60)), second) == .ok)
            #expect(rig.push(cycleEvent(90, noteOn(60)), first) == .ok)
            #expect(rig.safety.request(.panic, scope: 0) == .ok)
            let (muted, mutedEmitted) = rig.run(64, 64)
            #expect(muted.status == .silenced(.safetyMute) && muted.releasedNotes == 1 && mutedEmitted.count == 1)
            let (late, lateEmitted) = rig.run(128, 64)
            #expect(late.discardedSuperseded == 1 && lateEmitted.isEmpty)
            #expect(rig.push(cycleEvent(150, noteOn(61)), first) == .ok)
            #expect(noteOns(rig.run(192, 64).1) == [noteOn(61)])
            #expect(rig.ownership.isOwned(scope: 0, channel: 0, note: 61) && rig.ownership.ownedCount(scope: 0) == 1)
        }
    }
}
