import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension MeterDisplayTests {
    static let halfSecond = UInt64(halfSecondWindow)

    // MARK: - Staleness window

    @Test
    func sampleIsFreshAtTheWindowEdgeAndStaleOneNanosecondLater() throws {
        var model = try Self.tap()
        let sample = try Self.read(-12, sequence: 1)
        _ = try Self.signal(&model, sample, at: Self.ms(0))
        #expect(try Self.signal(&model, sample, at: Self.ms(500)) == .measured(levelDBFS: -22, peakHoldDBFS: -12))
        #expect(try Self.signal(&model, sample, at: Self.ms(500, plus: 1))
                == .unavailable(.stale(ageNanoseconds: Self.halfSecond + 1)))
        #expect(try Self.signal(&model, sample, at: Self.ms(9_000))
                == .unavailable(.stale(ageNanoseconds: 9 * Self.second)))
    }

    @Test(arguments: [Int64(1_000_000), 60_000_000_000])
    func shortestAndLongestWindowsHoldExactlyToTheirEdges(window: Int64) throws {
        var model = try Self.tap(window: window)
        let start = MeterInstant(nanoseconds: 7)
        let sample = try Self.read(-6, sequence: 1, at: start)
        _ = try model.update([sample], at: start)
        let edge = MeterInstant(nanoseconds: 7 + UInt64(window))
        guard case .measured = try Self.signal(&model, sample, at: edge) else {
            Issue.record("expected a measured signal at the window edge")
            return
        }
        #expect(try Self.signal(&model, sample, at: MeterInstant(nanoseconds: edge.nanoseconds + 1))
                == .unavailable(.stale(ageNanoseconds: UInt64(window) + 1)))
    }

    @Test
    func ageCountsFromTheFirstObservationOfASample() throws {
        var model = try Self.tap()
        var feed = try Feed()
        _ = try Self.signal(&model, feed.latest, at: Self.ms(0))
        try feed.publish(-20, at: Self.ms(100))
        _ = try Self.signal(&model, feed.latest, at: Self.ms(100))
        for time: UInt64 in [300, 450, 600] {
            guard case .measured = try Self.signal(&model, feed.latest, at: Self.ms(time)) else {
                Issue.record("expected a measured signal at \(time) ms")
                return
            }
        }
        #expect(try Self.signal(&model, feed.latest, at: Self.ms(600, plus: 1))
                == .unavailable(.stale(ageNanoseconds: Self.halfSecond + 1)))
    }

    @Test
    func newSampleEndsStalenessAndTheLevelKeptFallingMeanwhile() throws {
        var model = try Self.tap()
        var feed = try Feed()
        _ = try Self.signal(&model, feed.publish(-6), at: Self.ms(0))
        #expect(try Self.signal(&model, feed.latest, at: Self.ms(600))
                == .unavailable(.stale(ageNanoseconds: 600 * Self.millisecond)))
        #expect(try Self.signal(&model, feed.publish(-50, at: Self.ms(1_000)), at: Self.ms(1_000))
                == .measured(levelDBFS: -26, peakHoldDBFS: -6))
    }

    @Test
    func aNewSequenceOrANewStampIsANewSample() throws {
        var model = try Self.tap()
        _ = try Self.signal(&model, Self.read(-6, sequence: 1, frame: 0), at: Self.ms(0))
        let restamped = try Self.read(-6, sequence: 1, frame: 480, at: Self.ms(400))
        _ = try Self.signal(&model, restamped, at: Self.ms(400))
        #expect(try Self.signal(&model, restamped, at: Self.ms(900)) == .measured(levelDBFS: -16, peakHoldDBFS: -6))
        let regenerated = try Self.read(-6, sequence: 1, generation: 2, frame: 480, at: Self.ms(1_300))
        _ = try Self.signal(&model, regenerated, at: Self.ms(1_300))
        #expect(try Self.signal(&model, regenerated, at: Self.ms(1_800)) == .measured(levelDBFS: -16, peakHoldDBFS: -6))
        let resequenced = try Self.read(-6, sequence: 2, generation: 2, frame: 480, at: Self.ms(2_200))
        _ = try Self.signal(&model, resequenced, at: Self.ms(2_200))
        #expect(try Self.signal(&model, resequenced, at: Self.ms(2_700)) == .measured(levelDBFS: -16, peakHoldDBFS: -6))
        #expect(try Self.signal(&model, resequenced, at: Self.ms(2_700, plus: 1))
                == .unavailable(.stale(ageNanoseconds: Self.halfSecond + 1)))
    }

    @Test
    func staleTakesPrecedenceOverAnInvalidReading() throws {
        var model = try Self.tap()
        let sample = try Self.read(.nan, sequence: 1)
        #expect(try Self.signal(&model, sample, at: Self.ms(0)) == .unavailable(.invalidReading(.notANumber)))
        #expect(try Self.signal(&model, sample, at: Self.ms(500)) == .unavailable(.invalidReading(.notANumber)))
        #expect(try Self.signal(&model, sample, at: Self.ms(500, plus: 1))
                == .unavailable(.stale(ageNanoseconds: Self.halfSecond + 1)))
    }

    @Test
    func telemetryReasonsComeFirstAndNeverRefreshAnOldSample() throws {
        var model = try Self.tap()
        let sample = try Self.read(-6, sequence: 1)
        _ = try Self.signal(&model, sample, at: Self.ms(0))
        #expect(try Self.signal(&model, Self.missing(.staleGeneration), at: Self.ms(2_000))
                == .unavailable(.staleGeneration))
        #expect(try Self.signal(&model, Self.missing(.neverPublished), at: Self.ms(2_100))
                == .unavailable(.neverPublished))
        #expect(try Self.signal(&model, sample, at: Self.ms(2_200))
                == .unavailable(.stale(ageNanoseconds: 2_200 * Self.millisecond)))
    }

    // MARK: - Host time

    @Test
    func clockRegressionIsRefusedAndLeavesTheModelUnchanged() throws {
        var model = try Self.tap()
        var feed = try Feed()
        _ = try model.update([feed.publish(-6)], at: Self.ms(100))
        let before = model
        for regressed in [Self.ms(99), Self.ms(99, plus: 999_999), MeterInstant(nanoseconds: 0)] {
            #expect(Self.refusal { try model.update([feed.publish(3)], at: regressed) }
                    == .clockRegressed(last: Self.ms(100), now: regressed))
            #expect(model == before)
        }
        #expect(model.lastUpdate == Self.ms(100))
        #expect(Self.signals(try model.update([feed.latest], at: Self.ms(100)))
                == [.measured(levelDBFS: 3, peakHoldDBFS: 3)])
    }

    @Test
    func clockRegressionIsRefusedForSourcesThatAreNotMeasured() throws {
        for source in [MeterSource.faderTravelOnly, .gated(.permissionDenied)] {
            var model = try Self.model(source)
            _ = try model.update([], at: Self.ms(50))
            let before = model
            #expect(Self.refusal { try model.update([], at: Self.ms(49)) }
                    == .clockRegressed(last: Self.ms(50), now: Self.ms(49)))
            #expect(model == before)
        }
    }

    @Test
    func clockRegressionIsCheckedBeforeTheReads() throws {
        var model = try Self.tap(2)
        _ = try model.update([Self.missing(.neverPublished), Self.missing(.neverPublished)], at: Self.ms(10))
        #expect(Self.refusal { try model.update([], at: Self.ms(9)) }
                == .clockRegressed(last: Self.ms(10), now: Self.ms(9)))
        var fader = try Self.model(.faderTravelOnly)
        _ = try fader.update([], at: Self.ms(10))
        #expect(Self.refusal { try fader.update([Self.read(0, sequence: 1)], at: Self.ms(9)) }
                == .clockRegressed(last: Self.ms(10), now: Self.ms(9)))
    }

    @Test
    func rebindKeepsHostTimeMonotonic() throws {
        var model = try Self.tap()
        _ = try model.update([Self.missing(.neverPublished)], at: Self.ms(500))
        model.rebind(to: .gated(.sourceRemoved))
        #expect(model.lastUpdate == Self.ms(500))
        #expect(Self.refusal { try model.update([], at: Self.ms(400)) }
                == .clockRegressed(last: Self.ms(500), now: Self.ms(400)))
        #expect(try model.update([], at: Self.ms(500)) == .unavailable(.gated(.sourceRemoved)))
    }

    // MARK: - Channels

    @Test
    func channelCountMismatchIsRefusedAndLeavesTheModelUnchanged() throws {
        var model = try Self.tap(2)
        _ = try model.update([Self.read(-6, sequence: 1), Self.read(-9, sequence: 1)], at: Self.ms(100))
        let before = model
        for count in [0, 1, 3] {
            let reads = Array(repeating: try Self.read(0, sequence: 2), count: count)
            #expect(Self.refusal { try model.update(reads, at: Self.ms(900)) }
                    == .channelCountMismatch(expected: 2, received: count))
            #expect(model == before)
        }
        let display = try model.update([Self.read(-6, sequence: 1), Self.read(-9, sequence: 1)], at: Self.ms(200))
        #expect(Self.signals(display) == [.measured(levelDBFS: -8, peakHoldDBFS: -6),
                                          .measured(levelDBFS: -11, peakHoldDBFS: -9)])
        #expect(Self.clips(display) == [false, false])
    }

    @Test
    func sixtyFourChannelsAreShownInChannelOrderAndSixtyFiveReadsAreRefused() throws {
        var model = try Self.tap(MeterSource.maximumChannels)
        let levels = (0..<64).map { -Double($0) / 2 }
        let reads = try levels.map { try Self.read($0, sequence: 1) }
        let display = try model.update(reads, at: Self.ms(0))
        #expect(Self.signals(display) == levels.map { .measured(levelDBFS: $0, peakHoldDBFS: $0) })
        #expect(Self.clips(display) == [true] + Array(repeating: false, count: 63))
        let before = model
        #expect(Self.refusal { try model.update(reads + [Self.read(-1, sequence: 1)], at: Self.ms(1)) }
                == .channelCountMismatch(expected: 64, received: 65))
        #expect(Self.refusal { try model.update(Array(reads.dropLast()), at: Self.ms(1)) }
                == .channelCountMismatch(expected: 64, received: 63))
        #expect(model == before)
    }

    @Test
    func channelsAreTrackedIndependently() throws {
        var model = try Self.tap(3)
        var feeds = try [Feed(), Feed(), Feed()]
        _ = try model.update([feeds[0].publish(-6), feeds[1].publish(-12), feeds[2].publish(1)], at: Self.ms(0))
        let display = try model.update([feeds[0].publish(-6, at: Self.ms(600)), feeds[1].latest,
                                        Self.missing(.tooOld)], at: Self.ms(600))
        #expect(Self.signals(display) == [.measured(levelDBFS: -6, peakHoldDBFS: -6),
                                          .unavailable(.stale(ageNanoseconds: 600 * Self.millisecond)),
                                          .unavailable(.tooOld)])
        #expect(Self.clips(display) == [false, false, true])
        model.resetClip()
        let reset = try model.update(feeds.map(\.latest), at: Self.ms(600))
        #expect(Self.clips(reset) == [false, false, false])
        #expect(Self.signals(reset)[2] == .unavailable(.stale(ageNanoseconds: 600 * Self.millisecond)))
    }

    @Test
    func identicalInputsGiveIdenticalDisplaysAndModels() throws {
        func run() throws -> ([MeterDisplay], MeterDisplayModel) {
            var model = try Self.tap(2)
            var feeds = try [Feed(), Feed()]
            var displays: [MeterDisplay] = []
            for step in UInt64(0)..<60 {
                let now = Self.ms(step * 45)
                if step % 3 == 0 { try feeds[0].publish(-Double(step % 50), at: now) }
                if step % 7 == 0 { try feeds[1].publish(step % 14 == 0 ? .nan : -Double(step), at: now) }
                displays.append(try model.update(feeds.map(\.latest), at: now))
            }
            return (displays, model)
        }
        let first = try run()
        let second = try run()
        #expect(first.0 == second.0)
        #expect(first.1 == second.1)
    }
}
