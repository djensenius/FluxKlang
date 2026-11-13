import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

@Suite(.productionAccessAudit)
struct MIDIClockTempoTests {
    static let nanos = HostTimebase(numer: 1, denom: 1)

    @Test
    func proposalsAreRateLimitedToOnePerQuarterWithADeadband() throws {
        func tempo(_ micros: Int64) -> MIDIClockTempoEstimate { .init(microsPerQuarter: micros, clamped: false) }
        var proposer = MIDIClockTempoProposer()
        let first = try proposer.offer(tempo(500_000), atTicks: 15_360, pulseIndex: 24)
        #expect(first == ExternalTempoProposal(microsPerQuarter: 500_000, atTicks: 15_360))
        #expect(first?.bumpReason == .externalTempo)
        #expect(try proposer.offer(tempo(600_000), atTicks: 30_080, pulseIndex: 47) == nil)
        #expect(try proposer.offer(tempo(500_499), atTicks: 30_720, pulseIndex: 48) == nil)
        #expect(try proposer.offer(tempo(499_500), atTicks: 31_360, pulseIndex: 49)?.microsPerQuarter == 499_500)
        #expect(try proposer.offer(tempo(499_999), atTicks: 46_720, pulseIndex: 73) == nil)
        #expect(try proposer.offer(tempo(500_000), atTicks: 46_720, pulseIndex: 73)?.microsPerQuarter == 500_000)
        #expect(proposer.lastProposal == ExternalTempoProposal(microsPerQuarter: 500_000, atTicks: 46_720))
        let segment = try #require(try proposer.lastProposal?.segment())
        #expect(segment.fields.atTicks == 46_720 && segment.fields.microsPerQuarter == 500_000)
    }

    @Test
    func proposerRefusalsAreTyped() throws {
        var proposer = MIDIClockTempoProposer()
        let good = MIDIClockTempoEstimate(microsPerQuarter: 500_000, clamped: false)
        for micros: Int64 in [59_999, 3_000_001] {
            #expect(throws: MIDIClockError.tempoOutOfRange(micros)) {
                try proposer.offer(.init(microsPerQuarter: micros, clamped: true), atTicks: 0, pulseIndex: 0)
            }
        }
        #expect(throws: MIDIClockError.negativeTicks(-1)) { try proposer.offer(good, atTicks: -1, pulseIndex: 0) }
        #expect(throws: MIDIClockError.negativePulse(-1)) { try proposer.offer(good, atTicks: 0, pulseIndex: -1) }
        _ = try proposer.offer(good, atTicks: 0, pulseIndex: 10)
        #expect(throws: MIDIClockError.nonMonotonicPulse(previous: 10, current: 9)) {
            try proposer.offer(good, atTicks: 0, pulseIndex: 9)
        }
        #expect(try proposer.offer(.init(microsPerQuarter: 60_000, clamped: false), atTicks: .max, pulseIndex: .max)
                == ExternalTempoProposal(microsPerQuarter: 60_000, atTicks: .max))
    }

    @Test
    func restartsAndLocatesStartANewPulseGeneration() throws {
        let tempo = MIDIClockTempoEstimate(microsPerQuarter: 500_000, clamped: false)
        func running() throws -> MIDIClockTempoProposer {
            var proposer = MIDIClockTempoProposer()
            _ = try proposer.offer(tempo, atTicks: 15_360, pulseIndex: 24)
            #expect(try proposer.offer(tempo, atTicks: 31_360, pulseIndex: 49) == nil)
            return proposer
        }
        var restarted = try running()
        restarted.observe(.started)
        #expect(try restarted.offer(tempo, atTicks: 0, pulseIndex: 0) == .init(microsPerQuarter: 500_000, atTicks: 0))
        var jumped = try running()
        jumped.observe(.pulse(ticks: 3_840, host: HostStamp(ticks: 9), located: true))
        #expect(try jumped.offer(tempo, atTicks: 3_840, pulseIndex: 6)?.atTicks == 3_840)
        var located = try running()
        located.observe(.located(ticks: 0))
        #expect(try located.offer(tempo, atTicks: 0, pulseIndex: 0) != nil)
        var relocated = try running()
        relocated.observe(.continued(ticks: 0, relocated: true))
        #expect(try relocated.offer(tempo, atTicks: 0, pulseIndex: 0) != nil)

        var resumed = try running()
        for event: MIDIClockFollowerEvent in [.stopped(ticks: 32_000), .continued(ticks: 32_000, relocated: false),
                                              .pulse(ticks: 32_000, host: HostStamp(ticks: 9), located: false)] {
            resumed.observe(event)
        }
        #expect(throws: MIDIClockError.nonMonotonicPulse(previous: 49, current: 0)) {
            try resumed.offer(tempo, atTicks: 0, pulseIndex: 0)
        }
        #expect(try resumed.offer(tempo, atTicks: 32_000, pulseIndex: 50) == nil)
        resumed.reset()
        #expect(try resumed.offer(tempo, atTicks: 0, pulseIndex: 0) != nil)
    }

    @Test
    func followerEventsKeepTheProposerUsableAcrossStart() throws {
        var follower = try MIDIClockFollower()
        var estimator = try MIDIClockTempoEstimator(timebase: Self.nanos)
        var proposer = MIDIClockTempoProposer()
        var proposals: [ExternalTempoProposal] = []
        var host: UInt64 = 0
        for message in [MIDIClockMessage.start] + Array(repeating: .clock, count: 60) + [.start]
            + Array(repeating: .clock, count: 30) {
            if message == .clock { host += 20_000_000 }
            let event = try follower.receive(message, at: HostStamp(ticks: host))
            if let event { proposer.observe(event) }
            guard case let .pulse(ticks, _, _) = event else { continue }
            _ = try estimator.observePulse(at: HostStamp(ticks: host))
            guard let estimate = estimator.estimate else { continue }
            if let proposal = try proposer.offer(estimate, atTicks: ticks, pulseIndex: ticks / 640) {
                proposals.append(proposal)
            }
        }
        #expect(proposals == [.init(microsPerQuarter: 480_000, atTicks: 15_360),
                              .init(microsPerQuarter: 480_000, atTicks: 0)])
    }

    @Test
    func followedPulsesYieldIdenticalProposalsOnReplay() throws {
        func run() throws -> [ExternalTempoProposal] {
            var follower = try MIDIClockFollower()
            var estimator = try MIDIClockTempoEstimator(timebase: Self.nanos)
            var proposer = MIDIClockTempoProposer()
            var proposals: [ExternalTempoProposal] = []
            _ = try follower.receive(.start, at: HostStamp(ticks: 0))
            var host = HostStamp(ticks: 1_000)
            for index in 0..<200 {
                if index > 0 { host = HostStamp(ticks: host.ticks + (index < 100 ? 20_000_000 : 20_100_000)) }
                guard case let .pulse(ticks, _, _) = try follower.receive(.clock, at: host) else { continue }
                _ = try estimator.observePulse(at: host)
                guard let estimate = estimator.estimate else { continue }
                if let proposal = try proposer.offer(estimate, atTicks: ticks, pulseIndex: ticks / 640) {
                    proposals.append(proposal)
                }
            }
            return proposals
        }
        let proposals = try run()
        #expect(proposals == (try run()))
        #expect(proposals.first == ExternalTempoProposal(microsPerQuarter: 480_000, atTicks: 15_360))
        #expect(proposals.last?.microsPerQuarter == 482_400)
    }
}
