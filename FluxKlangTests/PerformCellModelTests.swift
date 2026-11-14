import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

@Suite("Perform cell model (#102 P1)", .productionAccessAudit)
struct PerformCellModelTests {
    static let mainsID = ParameterID(validated: "par.mains.gain")
    static let otherID = ParameterID(validated: "par.verb.mix")

    /// A validated descriptor; the default is the mains level, -120...6 dB with a 0 dB ceiling.
    static func descriptor(id: ParameterID = mainsID, unit: ParameterUnit = .decibels, lower: Double = -120,
                           upper: Double = 6, ceiling: Double? = 0, curve: ParameterCurve = .faderTaper,
                           controlClass: ControlClass = .live) throws -> ParameterDescriptor {
        try ParameterDescriptor(.init(
            id: id, unit: unit, lower: lower, upper: upper, defaultValue: lower, ceiling: ceiling, curve: curve,
            ramp: .step, controlClass: controlClass, verification: .reported
        ))
    }

    /// One tap channel per read, all classified and shown at host time 0.
    static func meter(_ reads: [TelemetryRead<MeterTapValue>]) throws -> MeterDisplay {
        var model = try MeterDisplayModel(
            source: MeterSource.tap(channels: reads.count),
            staleness: MeterStalenessWindow.make(nanoseconds: 500_000_000),
            ballistics: MeterBallistics.make(peakHoldNanoseconds: 1_000_000_000, decayDecibelsPerSecond: 20,
                                             floorDBFS: -60, clipThresholdDBFS: 0)
        )
        let now = MeterInstant(nanoseconds: 0)
        let classified = try reads.map {
            try MeterClassifiedRead.classify($0, generation: 1, frame: 0, maximumAgeFrames: 24_000, at: now)
        }
        return try model.update(classified, at: now)
    }

    static func measured(_ dbfs: Double) -> TelemetryRead<MeterTapValue> {
        .measured(TelemetrySample(value: MeterTapValue(peakDBFS: dbfs),
                                  stamp: TelemetryStamp(clockGeneration: 1, frame: 0), sequence: 1))
    }

    /// Mains Level at -8 dB bound to "Fader 3", every fact at its default, signal -14.5 dBFS.
    static func input(_ edit: (inout PerformCellInput) throws -> Void = { _ in }) throws -> PerformCellInput {
        var input = try PerformCellInput(
            descriptor: descriptor(), value: ParameterValue(value: -8, unit: .decibels),
            labels: PerformCellLabels(cell: "Mains Level", binding: "Fader 3"), facts: PerformCellFacts(),
            meter: meter([measured(-14.5)])
        )
        try edit(&input)
        return input
    }

    static func model(previous: PerformCellModel? = nil,
                      _ edit: (inout PerformCellInput) throws -> Void = { _ in }) throws -> PerformCellModel {
        try PerformCellModel.make(input(edit), previous: previous)
    }

    static func refusal(_ input: PerformCellInput) -> PerformCellRefusal? {
        do {
            _ = try PerformCellModel.make(input, previous: nil)
            return nil
        } catch {
            return error
        }
    }

    /// `count` bytes of `unit` repeated, then `tail`.
    static func label(_ unit: String, _ count: Int, plus tail: String = "") -> String {
        String(repeating: unit, count: count) + tail
    }

    @Test func plainLiveCellHasNoStatesAndAcceptsInput() throws {
        let cell = try Self.model()
        #expect(cell.states.isEmpty)
        #expect(cell.inputResult == .accepted)
        #expect(cell.label == "Mains Level")
        #expect(cell.bindingLabel == "Fader 3")
        #expect(cell.hasBinding)
        #expect(cell.parameterID == Self.mainsID)
        #expect(cell.value == ParameterValue(value: -8, unit: .decibels))
        #expect(cell.signal == .channels([.measured(levelDBFS: -14.5, peakHoldDBFS: -14.5)]))
        #expect(!cell.announcesPickup)
        #expect(!cell.editMode)
        let unbound = try Self.model { $0.labels.binding = "" }
        #expect(!unbound.hasBinding)
    }

    @Test func cellLabelAcceptsOneAndHundredTwentyEightBytesAndRefusesZeroAndOneTwentyNine() throws {
        let accepted = [
            "a", Self.label("a", 128), Self.label("é", 64), Self.label("日", 42, plus: "é"),
            Self.label("😀", 32), Self.label("e\u{301}", 42, plus: "ab")
        ]
        for text in accepted {
            #expect(text.utf8.count <= 128)
            #expect(try Self.model { $0.labels.cell = text }.label == text)
        }
        let refused: [(String, Int)] = [
            (Self.label("a", 129), 129), (Self.label("é", 64, plus: "a"), 129), (Self.label("é", 65), 130),
            (Self.label("日", 43), 129), (Self.label("😀", 32, plus: "a"), 129), (Self.label("e\u{301}", 43), 129)
        ]
        for (text, bytes) in refused {
            let result = Self.refusal(try Self.input { $0.labels.cell = text })
            #expect(result == .labelTooLong(bytes: bytes))
        }
        #expect(Self.refusal(try Self.input { $0.labels.cell = "" }) == .emptyLabel)
    }

    @Test func bindingLabelAcceptsEmptyAndHundredTwentyEightBytesAndRefusesOneTwentyNine() throws {
        for text in ["", "b", Self.label("b", 128), Self.label("é", 64), Self.label("😀", 32),
                     Self.label("e\u{301}", 42, plus: "ab")] {
            #expect(try Self.model { $0.labels.binding = text }.bindingLabel == text)
        }
        let refused: [(String, Int)] = [
            (Self.label("b", 129), 129), (Self.label("é", 65), 130), (Self.label("😀", 32, plus: "b"), 129),
            (Self.label("e\u{301}", 43), 129)
        ]
        for (text, bytes) in refused {
            let result = Self.refusal(try Self.input { $0.labels.binding = text })
            #expect(result == .bindingLabelTooLong(bytes: bytes))
        }
    }

    @Test func structuralClassIsNotPerformableWhileLiveAndHazardousAre() throws {
        let structural = try Self.input { $0.descriptor = try Self.descriptor(controlClass: .structural) }
        #expect(Self.refusal(structural) == .classNotPerformable(.structural))
        for controlClass in [ControlClass.live, .hazardous] {
            let accepted = try Self.model { $0.descriptor = try Self.descriptor(controlClass: controlClass) }
            #expect(accepted.descriptor.fields.controlClass == controlClass)
        }
    }

    @Test func shownValueIsCheckedByTheDescriptorAtItsBoundaries() throws {
        let accepted: [Double] = [-120, -8, 0]
        for value in accepted {
            let cell = try Self.model { $0.value = ParameterValue(value: value, unit: .decibels) }
            #expect(cell.value.value == value)
        }
        let cases: [(ParameterValue, ParameterValueError)] = [
            (ParameterValue(value: (-120.0).nextDown, unit: .decibels),
             .outOfRange((-120.0).nextDown, lower: -120, upper: 6)),
            (ParameterValue(value: 0.0.nextUp, unit: .decibels), .aboveCeiling(0.0.nextUp, ceiling: 0)),
            (ParameterValue(value: 6.0.nextUp, unit: .decibels), .outOfRange(6.0.nextUp, lower: -120, upper: 6)),
            (ParameterValue(value: -8, unit: .percent), .unitMismatch(expected: .decibels, found: .percent)),
            (ParameterValue(value: .nan, unit: .decibels), .nonFinite),
            (ParameterValue(value: .infinity, unit: .decibels), .nonFinite)
        ]
        for (value, error) in cases {
            #expect(Self.refusal(try Self.input { $0.value = value }) == .valueRefused(error))
        }
        let stepped = try Self.input {
            $0.descriptor = try Self.descriptor(unit: .index, lower: 1, upper: 12, ceiling: nil, curve: .stepped)
            $0.value = ParameterValue(value: 2.5, unit: .index)
        }
        #expect(Self.refusal(stepped) == .valueRefused(.notIntegral(2.5)))
    }

    @Test func hardwarePositionAcceptsZeroAndOneAndRefusesOutsideAndNonFinite() throws {
        for hardware in [nil, 0, 0.2, 1] as [Double?] {
            _ = try Self.model { $0.facts.pickup = .engaged(hardware: hardware) }
            _ = try Self.model { $0.facts.pickup = .waiting(hardware: hardware) }
        }
        for hardware in [(0.0).nextDown, (1.0).nextUp, -1, 2, .nan, .infinity, -.infinity] {
            let engaged = try Self.input { $0.facts.pickup = .engaged(hardware: hardware) }
            let waiting = try Self.input { $0.facts.pickup = .waiting(hardware: hardware) }
            #expect(Self.refusal(engaged) == .invalidHardwarePosition)
            #expect(Self.refusal(waiting) == .invalidHardwarePosition)
        }
    }

    @Test func pickupAndStaleFactsNeedABinding() throws {
        let pickups: [PickupState] = [.engaged(hardware: 0.5), .waiting(hardware: nil), .unavailable]
        for pickup in pickups {
            let unbound = try Self.input {
                $0.labels.binding = ""
                $0.facts.pickup = pickup
                $0.facts.controllerStale = true
            }
            #expect(Self.refusal(unbound) == .bindingFactsWithoutBinding)
        }
        let staleOnly = try Self.input { $0.labels.binding = ""; $0.facts.controllerStale = true }
        #expect(Self.refusal(staleOnly) == .bindingFactsWithoutBinding)
        let pickupOnly = try Self.input { $0.labels.binding = ""; $0.facts.pickup = .engaged(hardware: nil) }
        #expect(Self.refusal(pickupOnly) == .bindingFactsWithoutBinding)
        let bound = try Self.model { $0.facts.controllerStale = true; $0.facts.pickup = .unavailable }
        #expect(bound.states == [.staleController])
        let unboundClear = try Self.model { $0.labels.binding = "" }
        #expect(unboundClear.states.isEmpty)
    }

    @Test func unavailablePickupRequiresAStaleController() throws {
        let missing = try Self.input { $0.facts.pickup = .unavailable }
        #expect(Self.refusal(missing) == .pickupUnavailableWithoutStaleController)
        let stale = try Self.model { $0.facts.pickup = .unavailable; $0.facts.controllerStale = true }
        #expect(stale.states == [.staleController])
        #expect(stale.pickup == .unavailable)
    }

    @Test func pendingRemovalNeedsATargetWhileEitherAloneIsAccepted() throws {
        let both = try Self.input { $0.facts.pendingRemoval = true; $0.facts.targetExists = false }
        #expect(Self.refusal(both) == .pendingRemovalWithoutTarget)
        #expect(try Self.model { $0.facts.pendingRemoval = true }.states == [.pendingRemoval])
        #expect(try Self.model { $0.facts.targetExists = false }.states == [.noTarget])
    }

    @Test func aChannelDisplayWithoutChannelsIsRefused() throws {
        let empty = try Self.input { $0.meter = .channels([]) }
        #expect(Self.refusal(empty) == .meterHasNoChannels)
    }

    @Test func everyRefusalBuildsNoModelAndLeavesInputsAndPreviousUnchanged() throws {
        let previous = try Self.model { $0.facts.pickup = .waiting(hardware: 0.2); $0.facts.resyncing = true }
        let previousCopy = previous
        let bad = try Self.input {
            $0.facts.pickup = .waiting(hardware: 0.2)
            $0.facts.permitted = false
            $0.labels.cell = ""
        }
        let badCopy = bad
        for _ in 0..<2 {
            #expect(throws: PerformCellRefusal.emptyLabel) { try PerformCellModel.make(bad, previous: previous) }
        }
        #expect(bad == badCopy)
        #expect(previous == previousCopy)
        #expect(previous.states == [.resyncing, .waitingForPickup])
        #expect(previous.announcesPickup)
        var fixed = bad
        fixed.labels.cell = "Mains Level"
        let again = try PerformCellModel.make(fixed, previous: previous)
        #expect(again.states == [.notPermittedHere, .waitingForPickup])
        #expect(!again.announcesPickup)
    }

    /// The defects of `make`, declared in the order the refusals must be checked.
    enum Defect: CaseIterable {
        case notPerformable, badValue, emptyLabel, longLabel, longBinding, noBinding, badHardware,
             unavailablePickup, pendingWithoutTarget, noChannels
    }

    static func expected(_ defect: Defect) -> PerformCellRefusal {
        switch defect {
        case .notPerformable: .classNotPerformable(.structural)
        case .badValue: .valueRefused(.outOfRange(99, lower: -120, upper: 6))
        case .emptyLabel: .emptyLabel
        case .longLabel: .labelTooLong(bytes: 129)
        case .longBinding: .bindingLabelTooLong(bytes: 129)
        case .noBinding: .bindingFactsWithoutBinding
        case .badHardware: .invalidHardwarePosition
        case .unavailablePickup: .pickupUnavailableWithoutStaleController
        case .pendingWithoutTarget: .pendingRemovalWithoutTarget
        case .noChannels: .meterHasNoChannels
        }
    }

    static func applyDefect(_ defect: Defect, to input: inout PerformCellInput) throws {
        switch defect {
        case .notPerformable: input.descriptor = try descriptor(controlClass: .structural)
        case .badValue: input.value = ParameterValue(value: 99, unit: .decibels)
        case .emptyLabel: input.labels.cell = ""
        case .longLabel: input.labels.cell = label("a", 129)
        case .longBinding: input.labels.binding = label("b", 129)
        case .noBinding:
            input.labels.binding = ""
            input.facts.controllerStale = true
        case .badHardware: input.facts.pickup = .engaged(hardware: 2)
        case .unavailablePickup: input.facts.pickup = .unavailable
        case .pendingWithoutTarget:
            input.facts.pendingRemoval = true
            input.facts.targetExists = false
        case .noChannels: input.meter = .channels([])
        }
    }

    /// Defect pairs that write the same field, so no input can hold both.
    static func exclusive(_ first: Defect, _ second: Defect) -> Bool {
        let pair: Set<Defect> = [first, second]
        let exclusivePairs: [Set<Defect>] = [
            [.emptyLabel, .longLabel], [.longBinding, .noBinding], [.badHardware, .unavailablePickup],
            [.noBinding, .unavailablePickup]
        ]
        return exclusivePairs.contains(pair)
    }

    @Test func eachDefectAloneIsRefusedWithItsOwnRefusal() throws {
        for defect in Defect.allCases {
            let input = try Self.input { try Self.applyDefect(defect, to: &$0) }
            #expect(Self.refusal(input) == Self.expected(defect))
        }
    }

    @Test func refusalOrderHoldsForEveryPairOfDefectsHeldAtOnceInBothApplicationOrders() throws {
        let all = Defect.allCases
        var pairs = 0
        for (index, first) in all.enumerated() {
            for second in all[(index + 1)...] where !Self.exclusive(first, second) {
                for order in [[first, second], [second, first]] {
                    let input = try Self.input { input in
                        for defect in order { try Self.applyDefect(defect, to: &input) }
                    }
                    #expect(Self.refusal(input) == Self.expected(first))
                }
                pairs += 1
            }
        }
        #expect(pairs == 41)
    }

    @Test func aBindingMissingOutranksAnUnavailablePickupWithoutAStaleController() throws {
        let input = try Self.input {
            $0.labels.binding = ""
            $0.facts.pickup = .unavailable
        }
        #expect(!input.facts.controllerStale)
        #expect(Self.refusal(input) == .bindingFactsWithoutBinding)
    }

    @Test func everyDefectTogetherReportsTheFirstOne() throws {
        let input = try Self.input { input in
            for defect in Defect.allCases.reversed() { try Self.applyDefect(defect, to: &input) }
        }
        #expect(Self.refusal(input) == .classNotPerformable(.structural))
    }
}
