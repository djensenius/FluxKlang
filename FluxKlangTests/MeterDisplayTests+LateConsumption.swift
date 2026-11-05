import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Copilot round 1: a read classified fresh and consumed late is aged from its classification time, by any model.
/// Each read below is classified once and then held back; nothing is reclassified just before the update.
extension MeterDisplayTests {
    /// The host time the held-back reads are classified at; their window edge is 1.5 s.
    static let heldBackClassification = ms(1_000)

    // MARK: - Late consumption (window edge N and N + 1 ns from the classification)

    @Test
    func readHeldBackFromANewModelIsAgedFromItsClassification() throws {
        let cached = try Self.read(3, sequence: 1, at: Self.heldBackClassification)
        var atEdge = try Self.tap()
        let edge = try atEdge.update([cached], at: Self.ms(1_500))
        #expect(Self.signals(edge) == [.measured(levelDBFS: 3, peakHoldDBFS: 3)])
        #expect(Self.clips(edge) == [true])
        var pastEdge = try Self.tap()
        let past = try pastEdge.update([cached], at: Self.ms(1_500, plus: 1))
        #expect(Self.signals(past) == [.unavailable(.stale(ageNanoseconds: Self.halfSecond + 1))])
        #expect(Self.clips(past) == [false])
    }

    @Test
    func readHeldBackAcrossARebindIsAgedFromItsClassification() throws {
        let cached = try Self.read(-6, sequence: 1, at: Self.heldBackClassification)
        var model = try Self.tap()
        #expect(try Self.signal(&model, cached, at: Self.ms(1_000)) == .measured(levelDBFS: -6, peakHoldDBFS: -6))
        model.rebind(to: model.source)
        #expect(try Self.signal(&model, cached, at: Self.ms(1_500)) == .measured(levelDBFS: -6, peakHoldDBFS: -6))
        model.rebind(to: model.source)
        #expect(try Self.signal(&model, cached, at: Self.ms(1_500, plus: 1))
                == .unavailable(.stale(ageNanoseconds: Self.halfSecond + 1)))
        model.rebind(to: .faderTravelOnly)
        model.rebind(to: try MeterSource.tap(channels: 1))
        #expect(try Self.signal(&model, cached, at: Self.ms(3_601_000))
                == .unavailable(.stale(ageNanoseconds: 3_600 * Self.second)))
    }

    @Test
    func readHeldBackFromARunningModelIsAgedFromItsClassification() throws {
        func running() throws -> MeterDisplayModel {
            var model = try Self.tap()
            _ = try model.update([Self.read(-30, sequence: 1, at: Self.ms(1_000))], at: Self.ms(1_000))
            return model
        }
        let cached = try Self.read(-6, sequence: 2, at: Self.heldBackClassification)
        var atEdge = try running()
        #expect(try Self.signal(&atEdge, cached, at: Self.ms(1_500)) == .measured(levelDBFS: -6, peakHoldDBFS: -6))
        var pastEdge = try running()
        #expect(try Self.signal(&pastEdge, cached, at: Self.ms(1_500, plus: 1))
                == .unavailable(.stale(ageNanoseconds: Self.halfSecond + 1)))
        // The late read fed nothing: the next fresh reading meets the running level and peak, not −6 dBFS.
        #expect(try Self.signal(&pastEdge, Self.read(-50, sequence: 3, at: Self.ms(1_600)), at: Self.ms(1_600))
                == .measured(levelDBFS: -42, peakHoldDBFS: -30))
    }

    @Test
    func olderReadOfASampleAlreadySeenMakesItOlderAndANewerReadNeverYounger() throws {
        let cached = try Self.read(-6, sequence: 1, at: Self.heldBackClassification)
        let reread = try Self.read(-6, sequence: 1, at: Self.ms(1_400))
        func seenThroughTheLaterRead() throws -> MeterDisplayModel {
            var model = try Self.tap()
            _ = try model.update([reread], at: Self.ms(1_400))
            return model
        }
        var atEdge = try seenThroughTheLaterRead()
        #expect(try Self.signal(&atEdge, cached, at: Self.ms(1_500)) == .measured(levelDBFS: -8, peakHoldDBFS: -6))
        var pastEdge = try seenThroughTheLaterRead()
        #expect(try Self.signal(&pastEdge, cached, at: Self.ms(1_500, plus: 1))
                == .unavailable(.stale(ageNanoseconds: Self.halfSecond + 1)))
        #expect(try Self.signal(&pastEdge, reread, at: Self.ms(1_500, plus: 1))
                == .unavailable(.stale(ageNanoseconds: Self.halfSecond + 1)))
    }

    @Test
    func readStaleOnArrivalChangesNothingAndItsSampleStaysStale() throws {
        var model = try Self.tap()
        let cached = try Self.read(3, sequence: 1, at: Self.heldBackClassification)
        let arrival = try model.update([cached], at: Self.ms(1_600))
        #expect(Self.signals(arrival) == [.unavailable(.stale(ageNanoseconds: 600 * Self.millisecond))])
        let reread = try model.update([Self.read(3, sequence: 1, at: Self.ms(1_700))], at: Self.ms(1_700))
        #expect(Self.signals(reread) == [.unavailable(.stale(ageNanoseconds: 700 * Self.millisecond))])
        #expect(Self.clips(reread) == [false])
        let next = try model.update([Self.read(-50, sequence: 2, at: Self.ms(1_800))], at: Self.ms(1_800))
        #expect(Self.signals(next) == [.measured(levelDBFS: -50, peakHoldDBFS: -50)])
        #expect(Self.clips(next) == [false])
    }

    @Test
    func reclassifyingAStalledSampleEveryUpdateStillAgesItFromItsFirstClassification() throws {
        var model = try Self.tap()
        let stalled = Self.raw(-6, sequence: 1, generation: 3, frame: 0)
        for time: UInt64 in [0, 100, 250, 500] {
            let now = Self.ms(time)
            guard case .measured = try Self.signal(&model, Self.classified(stalled, frame: 0, at: now), at: now) else {
                Issue.record("expected a measured signal at \(time) ms")
                return
            }
        }
        let past = Self.ms(500, plus: 1)
        #expect(try Self.signal(&model, Self.classified(stalled, frame: 0, at: past), at: past)
                == .unavailable(.stale(ageNanoseconds: Self.halfSecond + 1)))
    }

    // MARK: - Classification after the update

    @Test
    func readClassifiedAfterTheUpdateIsRefusedAndChangesNothing() throws {
        var model = try Self.tap(2)
        let first = Self.ms(100)
        _ = try model.update([Self.read(-6, sequence: 1, at: first), Self.read(-9, sequence: 1, at: first)], at: first)
        let before = model
        let onTime = try Self.read(-3, sequence: 2, at: Self.ms(200))
        let future = try Self.read(0, sequence: 2, at: Self.ms(200, plus: 1))
        #expect(Self.refusal { try model.update([onTime, future], at: Self.ms(200)) }
                == .classifiedAfterUpdate(channel: 1, classifiedAt: Self.ms(200, plus: 1), now: Self.ms(200)))
        #expect(model == before)
        let missing = try Self.missing(.neverPublished, at: Self.ms(300))
        #expect(Self.refusal { try model.update([missing, future], at: Self.ms(200)) }
                == .classifiedAfterUpdate(channel: 0, classifiedAt: Self.ms(300), now: Self.ms(200)))
        #expect(model == before)
        let display = try model.update([onTime, Self.read(0, sequence: 2, at: Self.ms(200))], at: Self.ms(200))
        #expect(Self.signals(display) == [.measured(levelDBFS: -3, peakHoldDBFS: -3),
                                          .measured(levelDBFS: 0, peakHoldDBFS: 0)])
        #expect(Self.clips(display) == [false, true])
    }

    @Test
    func classificationTimeIsCheckedAfterTheClockTheSourceAndTheChannelCount() throws {
        let future = try Self.read(-6, sequence: 1, at: Self.ms(300))
        var model = try Self.tap(2)
        _ = try model.update([Self.missing(.neverPublished), Self.missing(.neverPublished)], at: Self.ms(200))
        #expect(Self.refusal { try model.update([future, future], at: Self.ms(100)) }
                == .clockRegressed(last: Self.ms(200), now: Self.ms(100)))
        #expect(Self.refusal { try model.update([future], at: Self.ms(200)) }
                == .channelCountMismatch(expected: 2, received: 1))
        var fader = try Self.model(.faderTravelOnly)
        #expect(Self.refusal { try fader.update([future], at: Self.ms(200)) }
                == .readsForUnmeasuredSource(.faderTravelOnly, count: 1))
    }
}
