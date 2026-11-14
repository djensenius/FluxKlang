import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// The neutral OSC namespace `/fk/v1`: closed address grammar, validated route table, atomic mapping
/// to live-only command operations, and the exhaustive live guard (#89, slice O2a).
@Suite("OSC neutral namespace mapping", .productionAccessAudit)
struct OSCNamespaceTests {
    typealias Fixture = OSCNamespaceFixture
    typealias OSC = OpenSoundControl
    typealias Refusal = OpenSoundControl.NamespaceRefusal
    typealias TableRefusal = OpenSoundControl.RouteTableRefusal
    typealias Outcome = OSCNamespaceFixture.Outcome
}

/// Shared fixture of the namespace suites. No globals are mutated; every value is built per call.
enum OSCNamespaceFixture {
    typealias OSC = OpenSoundControl

    /// One mapping attempt: the operation, or the typed refusal.
    enum Outcome: Equatable {
        case operation(CommandOperation)
        case refused(OpenSoundControl.NamespaceRefusal)
    }

    static let structuralID = ParameterID(validated: "test.structural")
    static let hazardousID = ParameterID(validated: "test.hazardous")
    static let goID = ActionID(validated: "act.go")

    /// `ParameterCatalog.wing` plus one structural and one hazardous descriptor.
    static func catalog() throws -> ParameterCatalog {
        let wing = ParameterCatalog.wing.parameters
        return try ParameterCatalog(wing + [
            descriptor(structuralID, controlClass: .structural), descriptor(hazardousID, controlClass: .hazardous)
        ])
    }

    static func descriptor(_ id: ParameterID, controlClass: ControlClass) throws -> ParameterDescriptor {
        try ParameterDescriptor(.init(
            id: id, unit: .normalized, lower: 0, upper: 1, defaultValue: 0, ceiling: nil, curve: .linear,
            ramp: .step, controlClass: controlClass, verification: .unverified
        ))
    }

    static func parameterRoutes() -> [OSC.ParameterRoute] {
        [
            OSC.ParameterRoute(name: "fader", id: ParameterCatalog.wingFaderDecibels),
            OSC.ParameterRoute(name: "mute", id: ParameterCatalog.wingMute),
            OSC.ParameterRoute(name: "pan", id: ParameterCatalog.wingPan)
        ]
    }

    static func actionRoutes() -> [OSC.ActionRoute] { [OSC.ActionRoute(name: "go", id: goID)] }

    static func table(
        parameters: [OSC.ParameterRoute]? = nil, actions: [OSC.ActionRoute]? = nil,
        transport: [OSC.TransportVerb] = [.start, .stop, .locate]
    ) throws -> OSC.RouteTable {
        try OSC.RouteTable(
            parameters: parameters ?? parameterRoutes(), actions: actions ?? actionRoutes(), transport: transport,
            catalog: catalog()
        )
    }

    static func mapper() throws -> OSC.ControlMapper { OSC.ControlMapper(table: try table()) }

    static func message(_ address: String, _ arguments: [OSC.Argument] = []) throws -> OSC.Message {
        OSC.Message(address: try OSC.AddressPattern(address), arguments: arguments)
    }

    /// Maps one message and asserts the attempt left the message and the mapper's behaviour unchanged.
    static func run(
        _ address: String, _ arguments: [OSC.Argument] = [], mapper: OSC.ControlMapper? = nil
    ) throws -> Outcome {
        let mapper = try mapper ?? Self.mapper()
        let message = try message(address, arguments)
        let canary = try self.message("/fk/v1/param/fader", [.float32(0.5)])
        let canaryBefore = attempt(mapper, canary)
        let outcome = attempt(mapper, message)
        let rebuilt = try self.message(address, arguments)
        #expect(message == rebuilt)
        #expect(attempt(mapper, canary) == canaryBefore)
        #expect(attempt(mapper, message) == outcome)
        return outcome
    }

    static func attempt(_ mapper: OSC.ControlMapper, _ message: OSC.Message) -> Outcome {
        do { return .operation(try mapper.map(message)) } catch { return .refused(error) }
    }

    static func refusal(
        _ address: String, _ arguments: [OSC.Argument] = [], mapper: OSC.ControlMapper? = nil
    ) throws -> OSC.NamespaceRefusal? {
        if case .refused(let refusal) = try run(address, arguments, mapper: mapper) { return refusal }
        return nil
    }

    /// Asserts that each address maps to exactly the paired refusal.
    static func expectRefusals(
        _ cases: [(address: String, refusal: OSC.NamespaceRefusal)], _ arguments: [OSC.Argument] = [],
        mapper: OSC.ControlMapper? = nil, sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        for (address, refusal) in cases {
            let outcome = try run(address, arguments, mapper: mapper)
            #expect(outcome == .refused(refusal), "\(address)", sourceLocation: sourceLocation)
        }
    }

    /// `count` copies of `character`, for building bounded names.
    static func repeated(_ character: Character, _ count: Int) -> String { String(repeating: character, count: count) }

    /// One operation of each of the 12 `CommandOperation` cases.
    static func everyOperation() throws -> [CommandOperation] {
        let value = ParameterValue(value: 0.5, unit: .normalized)
        let parameter = ParameterCatalog.wingMute
        return [
            .set(parameter, value), .ramp(parameter, value, milliseconds: 10), .bind(try RouteID("route.a")),
            .recall(try PatchID("patch.a")), .trigger(goID), .start, .stop, .locate(ticks: 1), .panic, .safeMute,
            .propose(try DraftID("draft.a")), .editDraft(try DraftID("draft.a"))
        ]
    }
}
