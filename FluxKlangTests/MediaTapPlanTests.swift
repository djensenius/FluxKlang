import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// The capture tap plan (#109 IO3). Tap ids, roles and consumer specs are here; plans and policies are in
/// `MediaTapPlanTests+Policies`, refusal order in `+Order`, the claim table in `+Claims`. The extensions share the
/// builders below.
@Suite("Media tap plan")
struct MediaTapPlanTests {
    static let allContexts: [ExecutionContext] = [.render, .control, .ui, .midiReceive, .auHost, .worker]

    static func tap(_ value: Int = 1) throws -> MediaTapID {
        try MediaTapID.make(value)
    }

    static func spec(
        _ role: MediaTapRole,
        capacity: Int = 8,
        context: ExecutionContext = .worker
    ) throws -> MediaTapConsumerSpec {
        try MediaTapConsumerSpec.make(role: role, capacityBlocks: capacity, consumerContext: context)
    }

    /// The typed refusal `body` throws, or `nil` when it succeeds.
    static func refusal(_ body: () throws -> some Any) -> MediaTapRefusal? {
        do {
            _ = try body()
            return nil
        } catch let error as MediaTapRefusal {
            return error
        } catch {
            return nil
        }
    }

    @Test
    func tapIDAcceptsOneAndIntMaxAndRefusesZeroNegativeAndIntMin() throws {
        #expect(try Self.tap(1).rawValue == 1)
        #expect(try Self.tap(Int.max).rawValue == Int.max)
        #expect(Self.refusal { try MediaTapID.make(0) } == .invalidTap(0))
        #expect(Self.refusal { try MediaTapID.make(-1) } == .invalidTap(-1))
        #expect(Self.refusal { try MediaTapID.make(Int.min) } == .invalidTap(Int.min))
    }

    @Test
    func tapIDsOrderByRawValue() throws {
        #expect(try Self.tap(2) < Self.tap(3))
        #expect(try !(Self.tap(3) < Self.tap(2)))
        #expect(try !(Self.tap(3) < Self.tap(3)))
        #expect(try Self.tap(5) == Self.tap(5))
        #expect(try Self.tap(5) != Self.tap(6))
    }

    @Test
    func rolesAreOrderedPlaybackRecorderTuner() {
        #expect(MediaTapRole.allCases == [.playback, .recorder, .tuner])
        #expect(MediaTapRole.playback.rawValue == 0)
        #expect(MediaTapRole.recorder.rawValue == 1)
        #expect(MediaTapRole.tuner.rawValue == 2)
        #expect(MediaTapRole.playback < MediaTapRole.recorder)
        #expect(MediaTapRole.recorder < MediaTapRole.tuner)
        #expect(!(MediaTapRole.tuner < MediaTapRole.playback))
        #expect(!(MediaTapRole.recorder < MediaTapRole.recorder))
    }

    @Test(arguments: [MediaTapRole.playback, MediaTapRole.tuner])
    func capacityAcceptsOneAndTheKernelMaximumAndRefusesZeroAndOneMore(role: MediaTapRole) throws {
        let context = ExecutionContext.worker
        #expect(try Self.spec(role, capacity: 1, context: context).capacityBlocks == 1)
        #expect(try Self.spec(role, capacity: 65_536, context: context).capacityBlocks == 65_536)
        for bad in [0, -1, 65_537, Int.min, Int.max] {
            #expect(Self.refusal { try Self.spec(role, capacity: bad) } == .invalidCapacity(role, bad))
        }
    }

    @Test
    func recorderCapacityMinimumIsTwoAndTheMaximumIsTheKernelMaximum() throws {
        #expect(Self.refusal { try Self.spec(.recorder, capacity: 1) } == .invalidCapacity(.recorder, 1))
        #expect(Self.refusal { try Self.spec(.recorder, capacity: 0) } == .invalidCapacity(.recorder, 0))
        #expect(try Self.spec(.recorder, capacity: 2).capacityBlocks == 2)
        #expect(try Self.spec(.recorder, capacity: 65_536).capacityBlocks == 65_536)
        #expect(Self.refusal { try Self.spec(.recorder, capacity: 65_537) } == .invalidCapacity(.recorder, 65_537))
        #expect(KernelLimits.maximumCapacity == 65_536)
    }

    @Test
    func contextTableAcceptsExactlyTheDocumentedContextsPerRole() {
        let accepted: [MediaTapRole: [ExecutionContext]] = [
            .playback: [.worker],
            .recorder: [.worker],
            .tuner: [.control, .worker]
        ]
        for role in MediaTapRole.allCases {
            let expected = accepted[role] ?? []
            for context in Self.allContexts {
                let made = Self.refusal { try Self.spec(role, context: context) }
                #expect(made == (expected.contains(context) ? nil : .invalidContext(role)))
            }
        }
    }

    @Test
    func specKeepsItsFieldsExactly() throws {
        let made = try Self.spec(.tuner, capacity: 37, context: .control)
        #expect(made.role == .tuner)
        #expect(made.capacityBlocks == 37)
        #expect(made.consumerContext == .control)
    }

    @Test
    func specChecksTheContextBeforeTheCapacity() {
        #expect(Self.refusal { try Self.spec(.recorder, capacity: 0, context: .render) } == .invalidContext(.recorder))
        #expect(Self.refusal { try Self.spec(.tuner, capacity: 70_000, context: .ui) } == .invalidContext(.tuner))
        #expect(Self.refusal { try Self.spec(.playback, capacity: -4, context: .auHost) } == .invalidContext(.playback))
    }

    @Test
    func onlyTheRecorderLossIsCritical() throws {
        let plan = try MediaTapPlan.make(tap: Self.tap(), specs: [Self.spec(.playback)])
        #expect(plan.lossIsCritical(.recorder))
        #expect(!plan.lossIsCritical(.tuner))
        #expect(!plan.lossIsCritical(.playback))
        #expect(MediaTapRole.recorder.lossIsCritical)
        #expect(!MediaTapRole.tuner.lossIsCritical)
    }
}
