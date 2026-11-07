import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension PerformCellModelTests {
    struct SpokenRow {
        let value: String
        let hint: String

        static func expected(_ value: String, _ hint: String) -> SpokenRow {
            SpokenRow(value: value, hint: hint)
        }
    }

    static func unitModel(_ unit: ParameterUnit, lower: Double, upper: Double, ceiling: Double? = nil,
                          curve: ParameterCurve = .linear, value: Double) throws -> PerformCellModel {
        try model {
            $0.descriptor = try descriptor(unit: unit, lower: lower, upper: upper, ceiling: ceiling, curve: curve)
            $0.value = ParameterValue(value: value, unit: unit)
        }
    }

    @Test func accessibilityDescribesTheMainsLevelCellExactly() throws {
        let element = try Self.model { $0.labels.binding = "" }.accessibility
        #expect(element.label == "Mains Level")
        #expect(element.value == "-8 decibels")
        #expect(element.hint == "Range -120 to 6 decibels. Ceiling 0 decibels")
        #expect(element.actions.map(\.rawValue) == ["Set value...", "Reset to default"])
        #expect(element.statuses.isEmpty)
        #expect(element.announcement == nil)
    }

    @Test func hazardousHintAddsRequiresAuthorizationAfterTheCeiling() throws {
        let hazardous = try Self.model {
            $0.descriptor = try Self.descriptor(controlClass: .hazardous)
        }.accessibility
        #expect(hazardous.hint == "Range -120 to 6 decibels. Ceiling 0 decibels. Requires authorization")
        let noCeiling = try Self.model {
            $0.descriptor = try Self.descriptor(ceiling: nil, controlClass: .hazardous)
        }.accessibility
        #expect(noCeiling.hint == "Range -120 to 6 decibels. Requires authorization")
        let live = try Self.model { $0.descriptor = try Self.descriptor(ceiling: nil) }.accessibility
        #expect(live.hint == "Range -120 to 6 decibels")
    }

    struct ActionRow {
        let takesInput: Bool
        let hazardous: Bool
        let bound: Bool
        let edit: Bool
        let actions: [String]
    }

    static let actionRows: [ActionRow] = {
        let show = "Show binding"
        let set = ["Set value...", "Reset to default"]
        let learn = "Learn control..."
        return [
            ActionRow(takesInput: true, hazardous: false, bound: false, edit: false, actions: set),
            ActionRow(takesInput: true, hazardous: false, bound: true, edit: false, actions: [show] + set),
            ActionRow(takesInput: true, hazardous: false, bound: false, edit: true, actions: set + [learn]),
            ActionRow(takesInput: true, hazardous: false, bound: true, edit: true, actions: [show] + set + [learn]),
            ActionRow(takesInput: true, hazardous: true, bound: false, edit: false, actions: set),
            ActionRow(takesInput: true, hazardous: true, bound: true, edit: false, actions: [show] + set),
            ActionRow(takesInput: true, hazardous: true, bound: false, edit: true, actions: set),
            ActionRow(takesInput: true, hazardous: true, bound: true, edit: true, actions: [show] + set),
            ActionRow(takesInput: false, hazardous: false, bound: false, edit: false, actions: []),
            ActionRow(takesInput: false, hazardous: false, bound: true, edit: false, actions: [show]),
            ActionRow(takesInput: false, hazardous: false, bound: false, edit: true, actions: []),
            ActionRow(takesInput: false, hazardous: false, bound: true, edit: true, actions: [show]),
            ActionRow(takesInput: false, hazardous: true, bound: false, edit: false, actions: []),
            ActionRow(takesInput: false, hazardous: true, bound: true, edit: false, actions: [show]),
            ActionRow(takesInput: false, hazardous: true, bound: false, edit: true, actions: []),
            ActionRow(takesInput: false, hazardous: true, bound: true, edit: true, actions: [show])
        ]
    }()

    /// Each state held alone, and whether a cell in it takes input.
    static let inputCases: [(state: PerformCellState?, takesInput: Bool)] = [
        (nil, true), (.resyncing, false), (.notPermittedHere, false), (.noTarget, false),
        (.missingPlugin, true), (.staleController, true), (.waitingForPickup, true)
    ]

    @Test func actionsForEveryInputStateByHazardBindingAndEditMode() throws {
        var checked = 0
        for (state, takesInput) in Self.inputCases {
            for row in Self.actionRows where row.takesInput == takesInput {
                if (state == .staleController || state == .waitingForPickup) && !row.bound { continue }
                let cell = try Self.model {
                    $0.labels.binding = row.bound ? "Fader 3" : ""
                    $0.facts.editMode = row.edit
                    if let state { try Self.apply(state, to: &$0) }
                    if row.hazardous { $0.descriptor = try Self.descriptor(controlClass: .hazardous) }
                }
                #expect(cell.accessibility.actions.map(\.rawValue) == row.actions)
                checked += 1
            }
        }
        #expect(checked == 48)
    }

    @Test func everyInputResultOffersTheMutatingActionsOnlyWhenItTakesInput() throws {
        let results: [(state: PerformCellState?, result: PerformInputResult)] = [
            (nil, .accepted), (.resyncing, .droppedStaleIntent), (.notPermittedHere, .rejectedPermission),
            (.noTarget, .disabled(.noTarget)), (.missingPlugin, .storedNotRendered),
            (.staleController, .noDeviceInput), (.waitingForPickup, .heldForPickup)
        ]
        for (state, result) in results {
            let cell = try Self.model { if let state { try Self.apply(state, to: &$0) } }
            #expect(cell.inputResult == result)
            let offersSet = cell.accessibility.actions.contains(.setValue)
            #expect(offersSet == Self.inputCases.first { $0.state == state }?.takesInput)
        }
        let hazardous = try Self.model { $0.descriptor = try Self.descriptor(controlClass: .hazardous) }
        #expect(hazardous.inputResult == .needsAuthorization)
        #expect(hazardous.accessibility.actions.contains(.setValue))
    }

    @Test func learnControlIsWithheldFromAHazardousCellEvenInEditMode() throws {
        let hazardous = try Self.model {
            $0.descriptor = try Self.descriptor(controlClass: .hazardous)
            $0.facts.editMode = true
        }
        #expect(hazardous.inputResult == .needsAuthorization)
        #expect(hazardous.accessibility.actions == [.showBinding, .setValue, .resetToDefault])
        let live = try Self.model { $0.facts.editMode = true }
        #expect(live.accessibility.actions == [.showBinding, .setValue, .resetToDefault, .learnControl])
    }

    @Test func showBindingIsOfferedInEveryNonInputStateButOnlyWithABinding() throws {
        for state in [PerformCellState.resyncing, .notPermittedHere, .noTarget] {
            #expect(try Self.model(holding: [state]).accessibility.actions == [.showBinding])
            let unbound = try Self.model {
                $0.labels.binding = ""
                try Self.apply(state, to: &$0)
            }
            #expect(unbound.accessibility.actions.isEmpty)
        }
    }

    @Test func valueAndRangeTextForEveryUnit() throws {
        let rows: [(PerformCellModel, SpokenRow)] = [
            (try Self.unitModel(.decibels, lower: -90, upper: 10, value: -8.5),
             .expected("-8.5 decibels", "Range -90 to 10 decibels")),
            (try Self.unitModel(.percent, lower: 0, upper: 100, ceiling: 80, value: 30),
             .expected("30 percent", "Range 0 to 100 percent. Ceiling 80 percent")),
            (try Self.unitModel(.normalized, lower: 0, upper: 1, value: 0.5), .expected("0.5", "Range 0 to 1")),
            (try Self.unitModel(.pan, lower: -1, upper: 1, value: -0.25), .expected("-0.25", "Range -1 to 1")),
            (try Self.unitModel(.index, lower: 1, upper: 12, curve: .stepped, value: 3),
             .expected("3", "Range 1 to 12")),
            (try Self.unitModel(.boolean, lower: 0, upper: 1, curve: .stepped, value: 1),
             .expected("on", "Range off to on")),
            (try Self.unitModel(.boolean, lower: 0, upper: 1, curve: .stepped, value: 0),
             .expected("off", "Range off to on"))
        ]
        for (cell, expected) in rows {
            #expect(cell.accessibility.value == expected.value)
            #expect(cell.accessibility.hint == expected.hint)
        }
    }

    @Test func numberTextWritesExactDecimalsWithoutExponentOrTrailingZero() {
        let rows: [(Double, String)] = [
            (0, "0"), (-0.0, "0"), (1, "1"), (-8, "-8"), (0.1, "0.1"), (-8.5, "-8.5"), (123_456.789, "123456.789"),
            (1e-5, "0.00001"), (-2.5e-7, "-0.00000025"), (1.5e20, "150000000000000000000"),
            (1e16, "10000000000000000"), (0.000123, "0.000123"), (1.25e-5, "0.0000125")
        ]
        for (number, text) in rows { #expect(PerformNumberText.text(number) == text) }
        let largest = PerformNumberText.text(Double.greatestFiniteMagnitude)
        #expect(largest.utf8.count == 309)
        #expect(largest.hasPrefix("17976931348623157"))
        #expect(largest.dropFirst(17).allSatisfy { $0 == "0" })
        let smallest = PerformNumberText.text(Double.leastNonzeroMagnitude)
        #expect(smallest.utf8.count == 326)
        #expect(smallest.hasPrefix("0.000") && smallest.hasSuffix("05"))
        #expect(PerformNumberText.text(-Double.greatestFiniteMagnitude).hasPrefix("-17976931348623157"))
    }

    @Test func statusesListEachHoldingStateInPriorityOrderWithExactTexts() throws {
        let cell = try Self.model(holding: [
            .meterUnavailable, .waitingForPickup, .hazardous, .staleController, .missingPlugin,
            .noTarget, .notPermittedHere, .resyncing
        ])
        #expect(cell.accessibility.statuses == [
            "Resyncing...", "Not in your permissions", "No target", "Plugin missing: value kept",
            "Controller stale", "Waiting for pickup", "Signal unavailable: never published"
        ])
        let pending = try Self.model(holding: [.pendingRemoval, .meterUnavailable])
        #expect(pending.accessibility.statuses == [
            "Pending removal in draft", "Signal unavailable: never published"
        ])
        let quiet = try Self.model(holding: [.engaged, .hazardous])
        #expect(quiet.accessibility.statuses.isEmpty)
    }

    @Test func signalStatusNamesEveryUnavailableReason() throws {
        var rows: [(MeterUnavailableReason, String)] = [
            (.faderTravelOnly, "fader travel only"), (.neverPublished, "never published"),
            (.invalidSlot, "invalid slot"), (.staleGeneration, "stale generation"), (.tooOld, "too old"),
            (.stale(ageNanoseconds: 9), "stale"), (.invalidReading(.notANumber), "invalid reading"),
            (.gated(.noRoute), "no route"), (.gated(.notMeasured), "not measured"),
            (.gated(.unmapped), "unmapped"), (.gated(.deviceMissing), "device missing"),
            (.gated(.lostMuted), "route lost or muted"), (.gated(.sourceRemoved), "source removed"),
            (.gated(.permissionDenied), "permission denied"), (.gated(.hardwareUnavailable), "hardware unavailable")
        ]
        #expect(rows.count == 7 + MeterSourceGate.allCases.count)
        rows.append((.invalidReading(.positiveInfinity), "invalid reading"))
        for (reason, text) in rows {
            let cell = try Self.model { $0.meter = .unavailable(reason) }
            #expect(cell.accessibility.statuses == ["Signal unavailable: " + text])
        }
    }

    @Test func pickupAnnouncementNamesTheBindingOnceAndTheValueNeverReadsTheSignal() throws {
        let first = try Self.model {
            $0.labels.binding = "Fader 3"
            $0.facts.pickup = .waiting(hardware: 0.2)
        }
        #expect(first.accessibility.announcement == "Fader 3 waiting for pickup")
        #expect(first.accessibility.statuses == ["Waiting for pickup"])
        let second = try Self.model(previous: first) {
            $0.labels.binding = "Fader 3"
            $0.facts.pickup = .waiting(hardware: 0.2)
        }
        #expect(second.accessibility.announcement == nil)
        #expect(second.accessibility.value == "-8 decibels")
        #expect(first.signal.levelsDBFS == [-14.5])
        #expect(!first.accessibility.value.contains("14.5"))
        #expect(!first.accessibility.hint.contains("14.5"))
    }

    @Test func labelIsTheCellLabelVerbatimIncludingMultiByteText() throws {
        let text = Self.label("é", 5, plus: "日😀")
        let element = try Self.model { $0.labels.cell = text }.accessibility
        #expect(element.label == text)
        #expect(element.label.utf8.count == 17)
    }
}
