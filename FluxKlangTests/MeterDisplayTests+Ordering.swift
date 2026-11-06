import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// #359 (follow-ups from the #348 delta review): reads consumed out of order. Across clock generations only the
/// classification time orders reads (m1): one from another generation classified before the latest sample was first
/// classified is ignored and counted. A frame regression within one generation (m2) and an older sequence at one
/// frame are ignored and counted too; the level, peak hold and clip latch are unchanged. `serialWindow` is a computed
/// literal (N1).
extension MeterDisplayTests {
    /// Each channel's ignored-read counts, in `MeterIgnoredRead.allCases` order.
    private static func ignored(_ model: MeterDisplayModel) -> [[UInt64]] {
        model.ignoredReads.map { counts in MeterIgnoredRead.allCases.map { counts[$0] } }
    }

    // MARK: - m1: a read from another generation, classified earlier and consumed late

    @Test
    func staleOtherGenerationReadConsumedLateNeverRestartsTheHoldOrRaisesTheLevel() throws {
        // 60 s window, 1 s hold, 20 dB/s: at 2 010 ms the -10 sample has fallen to -50 and its peak to -30.
        var model = try Self.longTap()
        let oldGeneration = try Self.read(-6, sequence: 1, generation: 1, frame: 480, at: Self.ms(0))
        let newGeneration = try Self.read(-10, sequence: 1, generation: 2, frame: 0, at: Self.ms(10))
        #expect(try Self.signal(&model, newGeneration, at: Self.ms(10)) == .measured(levelDBFS: -10, peakHoldDBFS: -10))
        var reference = model
        let late = try Self.signal(&model, oldGeneration, at: Self.ms(2_010))
        #expect(late == .measured(levelDBFS: -50, peakHoldDBFS: -30))
        #expect(Self.ignored(model) == [[1, 0, 0]])
        let reread = try Self.read(-10, sequence: 1, generation: 2, frame: 0, at: Self.ms(2_010))
        #expect(try Self.signal(&model, reread, at: Self.ms(2_010)) == late)
        #expect(try Self.signal(&reference, reread, at: Self.ms(2_010)) == late)
        #expect(try Self.signal(&model, reread, at: Self.ms(2_510)) == .measured(levelDBFS: -60, peakHoldDBFS: -40))
        #expect(Self.ignored(model) == [[1, 0, 0]])
    }

    @Test
    func staleOtherGenerationReadAtTheHeldPeakCannotRestartTheHold() throws {
        // 0 ns hold and 1 000 dB/s: a reading applied again would show at once.
        var model = try Self.tap(ballistics: Self.ballistics(hold: 0, decay: 1_000))
        let newGeneration = try Self.read(-8, sequence: 7, generation: 5, frame: 96, at: Self.ms(20))
        let oldGeneration = try Self.read(-8, sequence: 9, generation: 4, frame: 9_600, at: Self.ms(19))
        #expect(try Self.signal(&model, newGeneration, at: Self.ms(20)) == .measured(levelDBFS: -8, peakHoldDBFS: -8))
        #expect(try Self.signal(&model, oldGeneration, at: Self.ms(25)) == .measured(levelDBFS: -13, peakHoldDBFS: -13))
        #expect(try Self.signal(&model, newGeneration, at: Self.ms(30)) == .measured(levelDBFS: -18, peakHoldDBFS: -18))
        #expect(Self.ignored(model) == [[1, 0, 0]])
    }

    @Test
    func staleOtherGenerationReadNeverLatchesTheClipOrMakesTheLatestSampleFresh() throws {
        var model = try Self.tap()
        let newGeneration = try Self.read(-20, sequence: 1, generation: 2, at: Self.ms(100))
        let oldGeneration = try Self.read(3, sequence: 4, generation: 1, at: Self.ms(50))
        _ = try model.update([newGeneration], at: Self.ms(100))
        let edge = try model.update([oldGeneration], at: Self.ms(600))
        #expect(Self.signals(edge) == [.measured(levelDBFS: -30, peakHoldDBFS: -20)])
        #expect(Self.clips(edge) == [false])
        let past = try model.update([oldGeneration], at: Self.ms(600, plus: 1))
        #expect(Self.signals(past) == [.unavailable(.stale(ageNanoseconds: Self.halfSecond + 1))])
        #expect(Self.clips(past) == [false])
        #expect(Self.ignored(model) == [[2, 0, 0]])
    }

    @Test
    func sameStaleReadConsumedAgainAfterANewerSampleStaysIgnored() throws {
        // 0 ns hold and 1 000 dB/s: a reading applied again would show at once.
        var model = try Self.tap(ballistics: Self.ballistics(hold: 0, decay: 1_000))
        let stale = try Self.read(-3, sequence: 4, generation: 1, frame: 9_600, at: Self.ms(0))
        _ = try model.update([Self.read(-10, sequence: 1, generation: 2, at: Self.ms(10))], at: Self.ms(10))
        #expect(try Self.signal(&model, stale, at: Self.ms(12)) == .measured(levelDBFS: -12, peakHoldDBFS: -12))
        let newer = try Self.read(-8, sequence: 2, generation: 2, frame: 480, at: Self.ms(20))
        #expect(try Self.signal(&model, newer, at: Self.ms(20)) == .measured(levelDBFS: -8, peakHoldDBFS: -8))
        #expect(try Self.signal(&model, stale, at: Self.ms(25)) == .measured(levelDBFS: -13, peakHoldDBFS: -13))
        #expect(Self.ignored(model) == [[2, 0, 0]])
    }

    @Test
    func otherGenerationClassifiedLaterIsAppliedWhicheverGenerationNumberItHas() throws {
        // A lower generation number classified later is a new sample: generations are compared only for equality.
        var lower = try Self.tap()
        _ = try lower.update([Self.read(-20, sequence: 1, generation: 2, at: Self.ms(10))], at: Self.ms(11))
        let lowerLater = try Self.read(-6, sequence: 1, generation: 1, at: Self.ms(11))
        #expect(try Self.signal(&lower, lowerLater, at: Self.ms(11)) == .measured(levelDBFS: -6, peakHoldDBFS: -6))
        #expect(Self.ignored(lower) == [[0, 0, 0]])
        // So is a higher one, and the new generation then orders its own frames and sequences.
        var higher = try Self.tap()
        _ = try higher.update([Self.read(-20, sequence: 9, generation: 1, frame: 960)], at: Self.ms(0))
        let higherLater = try Self.read(-6, sequence: 1, generation: 2, frame: 0, at: Self.ms(1))
        #expect(try Self.signal(&higher, higherLater, at: Self.ms(1)) == .measured(levelDBFS: -6, peakHoldDBFS: -6))
        let next = try Self.read(-3, sequence: 2, generation: 2, frame: 0, at: Self.ms(2))
        #expect(try Self.signal(&higher, next, at: Self.ms(2)) == .measured(levelDBFS: -3, peakHoldDBFS: -3))
        #expect(Self.ignored(higher) == [[0, 0, 0]])
    }

    @Test
    func otherGenerationClassifiedEarlierIsIgnoredWhicheverGenerationNumberItHas() throws {
        var model = try Self.tap()
        _ = try model.update([Self.read(-20, sequence: 1, generation: 1, at: Self.ms(10))], at: Self.ms(10))
        let higherEarlier = try Self.read(-3, sequence: 1, generation: 2, at: Self.ms(9))
        #expect(try Self.signal(&model, higherEarlier, at: Self.ms(10)) == .measured(levelDBFS: -20, peakHoldDBFS: -20))
        #expect(Self.ignored(model) == [[1, 0, 0]])
    }

    @Test
    func otherGenerationIsOrderedByClassificationNotByItsFrameOrSequence() throws {
        var model = try Self.tap()
        _ = try model.update([Self.read(-20, sequence: 1, generation: 2, frame: 0, at: Self.ms(10))], at: Self.ms(10))
        let laterFrameAndSequence = try Self.read(-3, sequence: 99, generation: 1, frame: 96_000, at: Self.ms(5))
        #expect(try Self.signal(&model, laterFrameAndSequence, at: Self.ms(10))
                == .measured(levelDBFS: -20, peakHoldDBFS: -20))
        #expect(Self.ignored(model) == [[1, 0, 0]])
    }

    @Test
    func otherGenerationClassifiedAtTheSameInstantIsAppliedAndTheLaterConsumedReadWins() throws {
        var model = try Self.longTap()
        let latest = try Self.read(-6, sequence: 1, generation: 2, at: Self.ms(10))
        _ = try model.update([latest], at: Self.ms(10))
        // A lower reading from the other generation at the same instant is applied as the new latest sample...
        let sameInstant = try Self.read(-20, sequence: 1, generation: 1, at: Self.ms(10))
        #expect(try Self.signal(&model, sameInstant, at: Self.ms(510)) == .measured(levelDBFS: -16, peakHoldDBFS: -6))
        // ...and the first read, consumed after it at the same classification time, wins back: it is latest again,
        // so it is applied again and restarts the hold at the held peak.
        #expect(try Self.signal(&model, latest, at: Self.ms(1_010)) == .measured(levelDBFS: -6, peakHoldDBFS: -6))
        #expect(try Self.signal(&model, latest, at: Self.ms(2_010)) == .measured(levelDBFS: -26, peakHoldDBFS: -6))
        #expect(Self.ignored(model) == [[0, 0, 0]])
        // The tie is at the first classification only: 1 ns earlier is ignored.
        let justBefore = try Self.read(-1, sequence: 1, generation: 1, at: Self.ms(9, plus: 999_999))
        #expect(try Self.signal(&model, justBefore, at: Self.ms(2_010)) == .measured(levelDBFS: -26, peakHoldDBFS: -6))
        #expect(Self.ignored(model) == [[1, 0, 0]])
    }

    @Test
    func classificationOrderIsAgainstTheEarliestClassificationOfTheLatestSample() throws {
        // A reread of the latest sample classified later does not move its first classification, so another
        // generation classified between the two is later than it and applied.
        var model = try Self.tap()
        _ = try model.update([Self.read(-20, sequence: 1, generation: 2, at: Self.ms(10))], at: Self.ms(20))
        _ = try model.update([Self.read(-20, sequence: 1, generation: 2, at: Self.ms(20))], at: Self.ms(20))
        let between = try Self.read(-6, sequence: 1, generation: 1, at: Self.ms(15))
        #expect(try Self.signal(&model, between, at: Self.ms(20)) == .measured(levelDBFS: -6, peakHoldDBFS: -6))
        #expect(Self.ignored(model) == [[0, 0, 0]])
    }

    @Test
    func earlierRereadOfTheLatestSampleMovesTheOrderSoAnOtherGenerationReadBetweenIsApplied() throws {
        // B is latest, first read at 20; a reread of B classified at 12 makes B known latest since 12, so a
        // generation-A read classified at 15 is later than B and applied.
        var model = try Self.tap()
        let latestB = try Self.read(-20, sequence: 1, generation: 2, at: Self.ms(20))
        _ = try model.update([latestB], at: Self.ms(20))
        _ = try model.update([Self.read(-20, sequence: 1, generation: 2, at: Self.ms(12))], at: Self.ms(20))
        let readA = try Self.read(-6, sequence: 1, generation: 1, at: Self.ms(15))
        #expect(try Self.signal(&model, readA, at: Self.ms(20)) == .measured(levelDBFS: -6, peakHoldDBFS: -6))
        #expect(Self.ignored(model) == [[0, 0, 0]])
    }

    // MARK: - m2: a frame regression within one generation

    @Test
    func frameRegressionWithinAGenerationIsIgnoredAndCountedAndNothingElseChanges() throws {
        var model = try Self.tap(ballistics: Self.ballistics(hold: 0, decay: 1_000))
        let latest = try Self.read(-10, sequence: 5, frame: 960, at: Self.ms(0))
        _ = try model.update([latest], at: Self.ms(0))
        var reference = model
        // A higher sequence and a higher reading at an earlier frame of the same generation.
        let regressed = try Self.read(-1, sequence: 6, frame: 959, at: Self.ms(3))
        #expect(try Self.signal(&model, regressed, at: Self.ms(3)) == .measured(levelDBFS: -13, peakHoldDBFS: -13))
        #expect(Self.ignored(model) == [[0, 1, 0]])
        for time: UInt64 in [3, 4, 500] {
            #expect(try Self.signal(&model, latest, at: Self.ms(time))
                    == Self.signal(&reference, latest, at: Self.ms(time)))
        }
        for time: UInt64 in [500, 600] {
            let display = try model.update([regressed], at: Self.ms(time, plus: 1))
            #expect(display == (try reference.update([latest], at: Self.ms(time, plus: 1))))
        }
        #expect(Self.ignored(model) == [[0, 3, 0]])
        #expect(Self.ignored(reference) == [[0, 0, 0]])
    }

    @Test
    func olderSequenceAtTheSameFrameIsCountedApartFromAFrameRegression() throws {
        var model = try Self.tap()
        _ = try model.update([Self.read(-10, sequence: 5, frame: 480)], at: Self.ms(0))
        #expect(try Self.signal(&model, Self.read(-1, sequence: 4, frame: 480), at: Self.ms(0))
                == .measured(levelDBFS: -10, peakHoldDBFS: -10))
        #expect(try Self.signal(&model, Self.read(-1, sequence: 4, frame: 479), at: Self.ms(0))
                == .measured(levelDBFS: -10, peakHoldDBFS: -10))
        #expect(Self.ignored(model) == [[0, 1, 1]])
        // The same sample again is a reread, not an ignored read.
        _ = try model.update([Self.read(-10, sequence: 5, frame: 480)], at: Self.ms(0))
        #expect(Self.ignored(model) == [[0, 1, 1]])
    }

    @Test
    func laterFrameOrSequenceIsAppliedAndNotCounted() throws {
        var model = try Self.tap()
        _ = try model.update([Self.read(-10, sequence: 5, frame: 480)], at: Self.ms(0))
        #expect(try Self.signal(&model, Self.read(-4, sequence: 1, frame: 481), at: Self.ms(0))
                == .measured(levelDBFS: -4, peakHoldDBFS: -4))
        #expect(try Self.signal(&model, Self.read(-2, sequence: 2, frame: 481), at: Self.ms(0))
                == .measured(levelDBFS: -2, peakHoldDBFS: -2))
        #expect(Self.ignored(model) == [[0, 0, 0]])
    }

    // MARK: - Counts

    @Test
    func countsArePerChannelInChannelOrderAndARebindResetsThem() throws {
        var model = try Self.tap(3)
        let first = try [Self.read(-10, sequence: 5, generation: 2, frame: 480, at: Self.ms(1)),
                         Self.read(-10, sequence: 5, frame: 480), Self.read(-10, sequence: 5, frame: 480)]
        _ = try model.update(first, at: Self.ms(1))
        let second = try [Self.read(-1, sequence: 6, generation: 1, frame: 480), Self.read(-1, sequence: 6, frame: 479),
                          Self.read(-1, sequence: 4, frame: 480)]
        let display = try model.update(second, at: Self.ms(1))
        #expect(Self.signals(display) == Array(repeating: .measured(levelDBFS: -10, peakHoldDBFS: -10), count: 3))
        #expect(Self.ignored(model) == [[1, 0, 0], [0, 1, 0], [0, 0, 1]])
        let totals = model.ignoredReads.map(\.total)
        #expect(totals == [1, 1, 1])
        #expect(model.ignoredReads.map(\.classifiedBeforeLatest) == [1, 0, 0])
        #expect(model.ignoredReads.map(\.frameRegressed) == [0, 1, 0])
        #expect(model.ignoredReads.map(\.sequenceRegressed) == [0, 0, 1])
        model.rebind(to: model.source)
        #expect(Self.ignored(model) == [[0, 0, 0], [0, 0, 0], [0, 0, 0]])
        model.rebind(to: .faderTravelOnly)
        #expect(model.ignoredReads.isEmpty)
    }

    @Test
    func countsAccumulateAndTotalSumsEveryReason() throws {
        var model = try Self.tap()
        _ = try model.update([Self.read(-10, sequence: 5, generation: 3, frame: 480, at: Self.ms(1))], at: Self.ms(1))
        let olderReads = try [Self.read(-1, sequence: 1, generation: 2), Self.read(-1, sequence: 1, generation: 3),
                              Self.read(-1, sequence: 1, generation: 3, frame: 480),
                              Self.read(-1, sequence: 2, generation: 2)]
        for read in olderReads {
            _ = try model.update([read], at: Self.ms(1))
        }
        #expect(Self.ignored(model) == [[2, 1, 1]])
        #expect(model.ignoredReads.map(\.total) == [4])
    }

    @Test
    func unavailableReadsAreNotCounted() throws {
        var model = try Self.tap()
        _ = try model.update([Self.read(-10, sequence: 5)], at: Self.ms(0))
        for reason in [TelemetryUnavailable.neverPublished, .invalidSlot, .staleGeneration, .tooOld] {
            _ = try model.update([Self.missing(reason)], at: Self.ms(0))
        }
        #expect(Self.ignored(model) == [[0, 0, 0]])
    }

    // MARK: - N1: serialWindow

    @Test
    func serialWindowIsOneThroughTwoToTheSixtyThreeMinusOne() {
        #expect(MeterChannelState.serialWindow == 1...(UInt64(1) << 63) - 1)
        #expect(!MeterChannelState.serialWindow.contains(0))
        #expect(!MeterChannelState.serialWindow.contains(UInt64(1) << 63))
    }
}
