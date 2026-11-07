import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// The exhaustive live-only guard and the operations a table can produce.
private struct LiveCase {
    let address: String
    let arguments: [OpenSoundControl.Argument]
    let expected: CommandOperation

    init(_ address: String, _ arguments: [OpenSoundControl.Argument], _ expected: CommandOperation) {
        self.address = address
        self.arguments = arguments
        self.expected = expected
    }
}

extension OSCNamespaceTests {
    // A switch without `default`: adding a `CommandOperation` case breaks this test target build.
    // swiftlint:disable:next cyclomatic_complexity
    private func caseName(_ operation: CommandOperation) -> String {
        switch operation {
        case .set: "set"
        case .ramp: "ramp"
        case .bind: "bind"
        case .recall: "recall"
        case .trigger: "trigger"
        case .start: "start"
        case .stop: "stop"
        case .locate: "locate"
        case .panic: "panic"
        case .safeMute: "safeMute"
        case .propose: "propose"
        case .editDraft: "editDraft"
        }
    }

    private static let caseNames = [
        "set", "ramp", "bind", "recall", "trigger", "start", "stop", "locate", "panic", "safeMute", "propose",
        "editDraft"
    ]

    @Test func everyOperationFixtureIsADistinctCaseInDeclarationOrder() throws {
        let names = try Fixture.everyOperation().map(caseName)
        #expect(names == Self.caseNames)
    }

    @Test func theSixLiveOperationsAreLive() throws {
        let operations = try Fixture.everyOperation()
        try #require(operations.count == 12)
        for index in [0, 1, 4, 5, 6, 7] {
            #expect(OSC.NamespaceLiveness.isLive(operations[index]), "\(Self.caseNames[index])")
        }
    }

    @Test func structuralSafetyAndProposalOperationsAreNotLive() throws {
        let operations = try Fixture.everyOperation()
        try #require(operations.count == 12)
        for index in [2, 3, 8, 9, 10, 11] {
            #expect(!OSC.NamespaceLiveness.isLive(operations[index]), "\(Self.caseNames[index])")
        }
    }

    @Test func theLiveGuardAgreesWithTheControlClassOfEveryOperation() throws {
        for operation in try Fixture.everyOperation() {
            let isLive = OSC.NamespaceLiveness.isLive(operation)
            if isLive {
                #expect(operation.controlClass == nil || operation.controlClass == .live, "\(caseName(operation))")
            }
            if let controlClass = operation.controlClass, controlClass != .live {
                #expect(!isLive, "\(caseName(operation))")
            }
            if operation.controlClass == .live { #expect(isLive, "\(caseName(operation))") }
        }
    }

    @Test func refusedFamiliesStandForTheirControlClass() {
        let expected: [OSC.RefusedFamily: ControlClass] = [
            .route: .structural, .patch: .structural, .draft: .proposal, .safety: .safety, .hazard: .hazardous
        ]
        for family in OSC.RefusedFamily.allCases {
            #expect(family.controlClass == expected[family], "\(family)")
            #expect(family.controlClass != .live)
        }
    }

    @Test func familyVocabulariesAreClosedWithStableRawValuesAndOrder() {
        #expect(OSC.NamespaceFamily.allCases.map(\.rawValue) == ["param", "action", "transport"])
        #expect(OSC.RefusedFamily.allCases.map(\.rawValue) == ["route", "patch", "draft", "safety", "hazard"])
        #expect(OSC.TransportVerb.allCases.map(\.rawValue) == ["start", "stop", "locate"])
        let live = Set(OSC.NamespaceFamily.allCases.map(\.rawValue))
        let refused = Set(OSC.RefusedFamily.allCases.map(\.rawValue))
        #expect(live.isDisjoint(with: refused))
    }

    @Test func everyAddressTheTableCanProduceMapsToALiveOperationInAnAllowedScope() throws {
        let value = ParameterValue(value: 0.5, unit: .decibels)
        let routes: [LiveCase] = [
            LiveCase("/fk/v1/param/fader", [.float32(0.5)], .set(ParameterCatalog.wingFaderDecibels, value)),
            LiveCase("/fk/v1/param/fader/ramp", [.float32(0.5), .int32(7)], .ramp(ParameterCatalog.wingFaderDecibels,
                value, milliseconds: 7)),
            LiveCase("/fk/v1/param/mute", [.int32(1)], .set(ParameterCatalog.wingMute, ParameterValue(value: 1,
                unit: .boolean))),
            LiveCase("/fk/v1/param/mute/ramp", [.int32(0), .int32(7)], .ramp(ParameterCatalog.wingMute,
                ParameterValue(value: 0, unit: .boolean), milliseconds: 7)),
            LiveCase("/fk/v1/param/pan", [.float32(-1)], .set(ParameterCatalog.wingPan, ParameterValue(value: -1,
                unit: .pan))),
            LiveCase("/fk/v1/param/pan/ramp", [.float32(1), .int32(7)], .ramp(ParameterCatalog.wingPan,
                ParameterValue(value: 1, unit: .pan), milliseconds: 7)),
            LiveCase("/fk/v1/action/go", [], .trigger(Fixture.goID)), LiveCase("/fk/v1/transport/start", [], .start),
            LiveCase("/fk/v1/transport/stop", [], .stop), LiveCase("/fk/v1/transport/locate", [.int32(9)],
                .locate(ticks: 9))
        ]
        for entry in routes {
            let (address, arguments, expected) = (entry.address, entry.arguments, entry.expected)
            let outcome = try Fixture.run(address, arguments)
            #expect(outcome == .operation(expected), "\(address)")
            #expect(OSC.NamespaceLiveness.isLive(expected))
            switch expected.scope {
            case .parameter, .action, .transport: break
            case .route, .patch, .draft, .safety: Issue.record("scope outside the live families: \(address)")
            }
        }
        #expect(routes.count == 10)
    }

    @Test func noPlausibleAddressMapsToAStructuralSafetyProposalOrHazardousOperation() throws {
        let families = ["param", "action", "transport", "route", "patch", "draft", "safety", "hazard", "bind", "recall",
                        "panic", "propose", "editDraft", "safeMute", "safe-mute"]
        let names = ["fader", "go", "start", "stop", "locate", "panic", "safe-mute", "bind", "x", "ramp"]
        let argumentShapes: [[OSC.Argument]] = [[], [.impulse], [.float32(1)], [.int32(1)], [.float32(1), .int32(5)]]
        var mapped = 0
        for family in families {
            for name in names {
                for arguments in argumentShapes {
                    for suffix in ["", "/ramp"] {
                        guard case .operation(let operation) = try Fixture.run("/fk/v1/\(family)/\(name)\(suffix)",
                            arguments) else {
                            continue
                        }
                        mapped += 1
                        #expect(OSC.NamespaceLiveness.isLive(operation))
                        #expect(operation.controlClass == nil || operation.controlClass == .live)
                        #expect(["param", "action", "transport"].contains(family))
                    }
                }
            }
        }
        #expect(mapped > 0)
    }
}
