import Synchronization
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Records every call; answers with a fixed availability.
private final class TempoRecorder: TempoSharing, Sendable {
    enum Call: Equatable, Sendable {
        case availability
        case publish(TempoSharingUpdate)
    }

    private let answer: TempoSharingAvailability
    private let log = Mutex<[Call]>([])

    init(answer: TempoSharingAvailability) {
        self.answer = answer
    }

    var calls: [Call] { log.withLock { $0 } }

    func availability() -> TempoSharingAvailability {
        log.withLock { $0.append(.availability) }
        return answer
    }

    func publish(_ update: TempoSharingUpdate) -> TempoSharingOutcome {
        log.withLock { $0.append(.publish(update)) }
        return .published
    }
}

extension TimecodeMachineTests {
    @Test func machineTempoUpdateAcceptsTheRangeEdgesAndRefusesOneBeyond() throws {
        #expect(TempoSharingUpdate.tempoRange == 1...16_777_215)
        #expect(try TempoSharingUpdate.make(microsecondsPerQuarter: 1).microsecondsPerQuarter == 1)
        #expect(try TempoSharingUpdate.make(microsecondsPerQuarter: 16_777_215).microsecondsPerQuarter == 16_777_215)
        #expect(throws: TempoSharingError.tempoOutOfRange(0)) { try TempoSharingUpdate.make(microsecondsPerQuarter: 0) }
        #expect(throws: TempoSharingError.tempoOutOfRange(16_777_216)) {
            try TempoSharingUpdate.make(microsecondsPerQuarter: 16_777_216)
        }
        #expect(throws: TempoSharingError.tempoOutOfRange(-1)) {
            try TempoSharingUpdate.make(microsecondsPerQuarter: -1)
        }
        #expect(throws: TempoSharingError.tempoOutOfRange(Int.max)) {
            try TempoSharingUpdate.make(microsecondsPerQuarter: Int.max)
        }
    }

    @Test func machineTempoUpdateKeepsItsPositionUntouched() throws {
        let position = try SMPTETime(hours: 23, minutes: 59, seconds: 59, frames: 28, rate: .fps2997DropFrame)
        let update = try TempoSharingUpdate.make(microsecondsPerQuarter: 500_000, position: position)
        #expect(update.position == position)
        #expect(try TempoSharingUpdate.make(microsecondsPerQuarter: 500_000).position == nil)
    }

    @Test func machineNoTempoSharingAnswersUnavailableToEveryCall() throws {
        let sharing = NoTempoSharing()
        let update = try TempoSharingUpdate.make(microsecondsPerQuarter: 500_000)
        #expect(sharing.availability() == .unavailable)
        #expect(sharing.publish(update) == .unavailable)
        #expect(sharing.offer(update) == .unavailable)
        #expect(sharing.availability() == .unavailable)
        #expect(MemoryLayout<NoTempoSharing>.size == 0)
    }

    @Test func machineOfferSkipsPublishWhenThePeerIsUnavailable() throws {
        let recorder = TempoRecorder(answer: .unavailable)
        let update = try TempoSharingUpdate.make(microsecondsPerQuarter: 400_000)
        #expect(recorder.offer(update) == .unavailable)
        #expect(recorder.calls == [.availability])
    }

    @Test func machineOfferPublishesOnceWhenThePeerIsAvailable() throws {
        let recorder = TempoRecorder(answer: .available)
        let update = try TempoSharingUpdate.make(microsecondsPerQuarter: 400_000)
        #expect(recorder.offer(update) == .published)
        #expect(recorder.calls == [.availability, .publish(update)])
    }

    @Test func machineHostPathResultsAreIndependentOfAnyTempoOffer() throws {
        let receiver = try Self.deviceID(0x21)
        let policy = try Self.policy([Self.entry(.play)])
        let grant = try Self.grant([.play])
        let incoming = MMCMessage(deviceID: receiver, command: .play)
        let before = MMCIntentGate.evaluate(message: incoming, policy: policy, receiver: receiver)
        let built = try MMCSendBuilder.message(for: .play, grant: grant, now: 12)
        let update = try TempoSharingUpdate.make(microsecondsPerQuarter: 500_000)
        #expect(NoTempoSharing().offer(update) == .unavailable)
        #expect(TempoRecorder(answer: .unavailable).offer(update) == .unavailable)
        #expect(MMCIntentGate.evaluate(message: incoming, policy: policy, receiver: receiver) == before)
        #expect(try MMCSendBuilder.message(for: .play, grant: grant, now: 12) == built)
        guard case let .intent(intent) = before else {
            Issue.record("play must be admitted without any tempo integration")
            return
        }
        #expect(intent.command == .play)
    }
}
