import Foundation
import Testing
@testable import FluxKlang

extension ControlContractTests {
    struct MusicalIndexValidation {
        let fixture = MusicalFoundationFixture()

        /// Isolated coverage workload: count retained-record visits, not elapsed wall-clock time.
        @Test func retainedPassLookupWorkload() throws {
            let ledger = try fixture.ledger()
            var timeline = try fixture.timeline(ledger, loop: LoopRange(startTicks: 0, endTicks: 1_920),
                                                 history: 64, pins: 1)
            for pass: UInt32 in 1...63 {
                try fixture.observe(&timeline, .wrap, ledger, frame: Int64(pass) * 3_000, ticks: 0, pass: pass)
            }
            #expect(timeline.historyCount == 64)
            let pin = try timeline.reserve(.grid(960), origin: timeline.origin(atFrame: 189_000))
            #expect(pin.occurrence == MusicalOccurrence(pass: 63, ticks: 0))
            #expect(try timeline.project(pin).frame == 189_000)
        }

        @Test func retainedForwardPassLookupWorkload() throws {
            let ledger = try fixture.ledger()
            var timeline = try fixture.timeline(ledger, loop: LoopRange(startTicks: 0, endTicks: 1_920),
                                                 history: 64, pins: 1)
            for pass: UInt32 in 1...63 {
                try fixture.observe(&timeline, .wrap, ledger, frame: Int64(pass) * 3_000, ticks: 0, pass: pass)
            }
            try fixture.observe(&timeline, .primary, ledger, frame: 189_001)
            #expect(timeline.historyCount == 64)
            let pin = try timeline.reserve(.grid(960), origin: timeline.origin(atFrame: 189_001))
            #expect(pin.occurrence == MusicalOccurrence(pass: 63, ticks: 960))
            #expect(try timeline.project(pin).frame == 190_500)
        }

        @Test func indexPreservesPrecedenceWithoutPromotingTickSummaries() throws {
            let ledger = try fixture.ledger()
            let pinned = try fixture.clock(ledger, frame: 6_000, pass: 2)
            let recorded = try fixture.clock(ledger, frame: 6_750, ticks: 480, pass: 2)
            let current = try fixture.clock(ledger, frame: 6_751, ticks: 481, pass: 2)
            let occurrence = MusicalOccurrence(pass: 1, ticks: 1_920)
            var index = MusicalProjectionIndex()
            index.includeReservation(occurrence, originalTicks: 960, pass: 2, anchor: pinned.anchor)
            index.includeReservation(occurrence, originalTicks: 961, pass: 2, anchor: recorded.anchor)
            #expect(index.anchor(for: 2) == pinned.anchor)
            #expect(index.originalTicks[1] == 960)
            index.includeRecord(recorded, running: true)
            index.includeRecord(current, running: false)
            #expect(index.anchor(for: 2) == recorded.anchor)
            index.includeCurrent(current, running: true)
            #expect(index.anchor(for: 2) == current.anchor)
            #expect(index.anchor(for: 1) == nil && index.containsOriginalPass(1))
            #expect(index.retainedPasses == [2])
        }
    }
}
