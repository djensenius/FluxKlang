import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension PerformCellModelTests {
    /// The fixed priority order, written out here as the oracle.
    static let priority: [PerformCellState] = [
        .resyncing, .notPermittedHere, .noTarget, .missingPlugin, .staleController, .hazardous,
        .waitingForPickup, .pendingRemoval, .engaged, .meterUnavailable
    ]

    /// The input result each state decides; the meter facet decides none.
    static let results: [PerformCellState: PerformInputResult] = [
        .resyncing: .droppedStaleIntent, .notPermittedHere: .rejectedPermission,
        .noTarget: .disabled(.noTarget), .missingPlugin: .storedNotRendered, .staleController: .noDeviceInput,
        .hazardous: .needsAuthorization, .waitingForPickup: .heldForPickup, .pendingRemoval: .accepted,
        .engaged: .accepted
    ]

    /// Makes `state` hold in `input` (and nothing else beyond what it needs).
    static func apply(_ state: PerformCellState, to input: inout PerformCellInput) throws {
        switch state {
        case .resyncing: input.facts.resyncing = true
        case .notPermittedHere: input.facts.permitted = false
        case .noTarget: input.facts.targetExists = false
        case .missingPlugin: input.facts.pluginMissing = true
        case .pendingRemoval: input.facts.pendingRemoval = true
        default: try applyBinding(state, to: &input)
        }
    }

    private static func applyBinding(_ state: PerformCellState, to input: inout PerformCellInput) throws {
        switch state {
        case .staleController: input.facts.controllerStale = true
        case .hazardous: input.descriptor = try descriptor(controlClass: .hazardous)
        case .waitingForPickup: input.facts.pickup = .waiting(hardware: 0.2)
        case .engaged: input.facts.pickup = .engaged(hardware: 0.5)
        case .meterUnavailable: input.meter = .unavailable(.neverPublished)
        default: break
        }
    }

    static func model(holding states: [PerformCellState]) throws -> PerformCellModel {
        try model { input in
            for state in states { try apply(state, to: &input) }
        }
    }

    static func compatible(_ first: PerformCellState, _ second: PerformCellState) -> Bool {
        let pair: Set<PerformCellState> = [first, second]
        return pair != [.engaged, .waitingForPickup] && pair != [.noTarget, .pendingRemoval]
    }

    @Test func tenStatesInPerformDocumentOrder() {
        #expect(PerformCellState.allCases == [
            .engaged, .staleController, .waitingForPickup, .hazardous, .pendingRemoval, .noTarget,
            .notPermittedHere, .resyncing, .missingPlugin, .meterUnavailable
        ])
        #expect(Set(PerformCellState.allCases) == Set(Self.priority))
        #expect(Self.results.count == 9)
    }

    @Test func eachStateAloneListsExactlyItselfWithItsInputResult() throws {
        for state in PerformCellState.allCases {
            let cell = try Self.model(holding: [state])
            #expect(cell.states == [state])
            #expect(cell.inputResult == Self.results[state] ?? .accepted)
        }
        #expect(try Self.model(holding: [.meterUnavailable]).inputResult == .accepted)
    }

    @Test func everyCompatiblePairListsPriorityOrderAndTheFirstDecidingResult() throws {
        var checked = 0
        for first in PerformCellState.allCases {
            for second in PerformCellState.allCases where first != second && Self.compatible(first, second) {
                let cell = try Self.model(holding: [first, second])
                let expected = Self.priority.filter { $0 == first || $0 == second }
                #expect(cell.states == expected)
                #expect(cell.inputResult == expected.compactMap { Self.results[$0] }.first ?? .accepted)
                checked += 1
            }
        }
        #expect(checked == 86)
    }

    @Test func namedPairsFollowTheRulings() throws {
        let rows: [([PerformCellState], PerformInputResult)] = [
            ([.notPermittedHere, .resyncing], .droppedStaleIntent),
            ([.noTarget, .notPermittedHere], .rejectedPermission),
            ([.missingPlugin, .noTarget], .disabled(.noTarget)),
            ([.staleController, .missingPlugin], .storedNotRendered),
            ([.hazardous, .staleController], .noDeviceInput),
            ([.waitingForPickup, .hazardous], .needsAuthorization),
            ([.pendingRemoval, .waitingForPickup], .heldForPickup),
            ([.engaged, .pendingRemoval], .accepted),
            ([.meterUnavailable, .resyncing], .droppedStaleIntent),
            ([.meterUnavailable, .engaged], .accepted),
            ([.hazardous, .meterUnavailable], .needsAuthorization)
        ]
        for (pair, result) in rows {
            #expect(try Self.model(holding: pair).inputResult == result)
            #expect(try Self.model(holding: pair.reversed()).inputResult == result)
        }
    }

    @Test func allCompatibleStatesAtOnceListInPriorityOrderAndResyncingDecides() throws {
        let everyOne: [PerformCellState] = [
            .meterUnavailable, .pendingRemoval, .waitingForPickup, .hazardous, .staleController,
            .missingPlugin, .notPermittedHere, .resyncing
        ]
        let all = try Self.model(holding: everyOne)
        #expect(all.states == [
            .resyncing, .notPermittedHere, .missingPlugin, .staleController, .hazardous, .waitingForPickup,
            .pendingRemoval, .meterUnavailable
        ])
        #expect(all.inputResult == .droppedStaleIntent)
        let other = try Self.model(holding: [.engaged, .noTarget, .meterUnavailable])
        #expect(other.states == [.noTarget, .engaged, .meterUnavailable])
        #expect(other.inputResult == .disabled(.noTarget))
    }

    @Test func hazardousComesFromTheDescriptorClassAlone() throws {
        let live = try Self.model()
        #expect(!live.states.contains(.hazardous))
        let hazardous = try Self.model { $0.descriptor = try Self.descriptor(controlClass: .hazardous) }
        #expect(hazardous.states == [.hazardous])
        #expect(hazardous.inputResult == .needsAuthorization)
    }

    @Test func pickupAnnouncementIsTrueOnlyOnTheTransitionIntoWaiting() throws {
        let first = try Self.model { $0.facts.pickup = .waiting(hardware: 0.2) }
        #expect(first.announcesPickup)
        let second = try Self.model(previous: first) { $0.facts.pickup = .waiting(hardware: 0.2) }
        #expect(!second.announcesPickup)
        let moved = try Self.model(previous: second) { $0.facts.pickup = .waiting(hardware: 0.4) }
        #expect(!moved.announcesPickup)
        let caught = try Self.model(previous: moved) { $0.facts.pickup = .engaged(hardware: 0.5) }
        #expect(!caught.announcesPickup)
        let again = try Self.model(previous: caught) { $0.facts.pickup = .waiting(hardware: 0.9) }
        #expect(again.announcesPickup)
        let once = try Self.model(previous: again) { $0.facts.pickup = .waiting(hardware: 0.9) }
        #expect(!once.announcesPickup)
    }

    @Test func pickupAnnouncementIgnoresOtherParametersAndNeverFiresWithoutWaiting() throws {
        let other = try Self.model {
            $0.descriptor = try Self.descriptor(id: Self.otherID)
            $0.facts.pickup = .waiting(hardware: 0.2)
        }
        #expect(other.announcesPickup)
        let sameValueOtherParameter = try Self.model(previous: other) { $0.facts.pickup = .waiting(hardware: 0.2) }
        #expect(sameValueOtherParameter.announcesPickup)
        let idle = try Self.model(previous: other)
        #expect(!idle.announcesPickup)
        #expect(idle.states.isEmpty)
        let noPrevious = try Self.model { $0.facts.pickup = .engaged(hardware: nil) }
        #expect(!noPrevious.announcesPickup)
        let busy = try Self.model(previous: idle) {
            $0.facts.pickup = .waiting(hardware: 0.2)
            $0.facts.resyncing = true
        }
        #expect(busy.announcesPickup)
        #expect(busy.states == [.resyncing, .waitingForPickup])
    }

    @Test func faderTravelOnlyMeterIsUnavailableWithItsReasonAndNoLevel() throws {
        let cell = try Self.model { $0.meter = .unavailable(.faderTravelOnly) }
        #expect(cell.signal == .unavailable(.faderTravelOnly))
        #expect(cell.signal.levelsDBFS.isEmpty)
        #expect(cell.states == [.meterUnavailable])
        #expect(cell.value == ParameterValue(value: -8, unit: .decibels))
        let moved = try Self.model {
            $0.value = ParameterValue(value: -3, unit: .decibels)
            $0.meter = .unavailable(.faderTravelOnly)
        }
        #expect(moved.signal == cell.signal)
        #expect(moved.value.value == -3)
    }

    @Test func aMeasuredSignalKeepsItsLevelsAndIsIndependentOfTheControlValue() throws {
        let cell = try Self.model()
        #expect(cell.signal.levelsDBFS == [-14.5])
        #expect(!cell.states.contains(.meterUnavailable))
        let louder = try Self.model {
            $0.value = ParameterValue(value: 0, unit: .decibels)
            $0.meter = try Self.meter([Self.measured(-30), Self.measured(-6)])
        }
        #expect(louder.signal.levelsDBFS == [-30, -6])
        #expect(louder.value.value == 0)
    }

    @Test func everyUnavailableReasonIsKeptAsGiven() throws {
        var reasons: [MeterUnavailableReason] = MeterSourceGate.allCases.map { .gated($0) }
        reasons += [.faderTravelOnly, .neverPublished, .invalidSlot, .staleGeneration, .tooOld,
                    .stale(ageNanoseconds: 7), .invalidReading(.notANumber), .invalidReading(.positiveInfinity)]
        for reason in reasons {
            let cell = try Self.model { $0.meter = .unavailable(reason) }
            #expect(cell.signal == .unavailable(reason))
            #expect(cell.states == [.meterUnavailable])
        }
    }

    @Test func channelsThatAreAllUnavailableShowTheFirstReasonAndSetTheFacet() throws {
        let slotFirst = try Self.model {
            $0.meter = try Self.meter([.unavailable(.neverPublished), .unavailable(.invalidSlot)])
        }
        #expect(slotFirst.signal == .unavailable(.neverPublished))
        #expect(slotFirst.states == [.meterUnavailable])
        let swapped = try Self.model {
            $0.meter = try Self.meter([.unavailable(.invalidSlot), .unavailable(.neverPublished)])
        }
        #expect(swapped.signal == .unavailable(.invalidSlot))
        #expect(swapped.signal.levelsDBFS.isEmpty)
    }

    @Test func mixedChannelsKeepEveryChannelSignalAndLeaveTheFacetOff() throws {
        let mixed = try Self.model {
            $0.meter = try Self.meter([.unavailable(.neverPublished), Self.measured(-20)])
        }
        #expect(mixed.signal == .channels([
            .unavailable(.neverPublished), .measured(levelDBFS: -20, peakHoldDBFS: -20)
        ]))
        #expect(mixed.signal.levelsDBFS == [-20])
        #expect(mixed.states.isEmpty)
    }
}
