import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// The canonical copy of `Examples/TouchOSC/address-table.json`, embedded because the test target may not see
/// `Examples/`. One test compares it byte for byte with the file when the checkout is present. The literal ends
/// without the file's final newline: a multi-line string literal drops it, and the comparison appends it.
private let touchOSCTableText = #"""
{
  "table": "fluxklang.osc.address-table",
  "namespace": "/fk/v1",
  "version": 1,
  "note": "Neutral addresses for any OSC client. Original work. Changes no hardware or console state.",
  "accepted": [
    {"control": "fader", "address": "/fk/v1/param/fader", "kind": "set", "args": ["float32"],
     "range": [-90, 10], "unit": "decibels", "example": [-6.5]},
    {"control": "fader-ramp", "address": "/fk/v1/param/fader/ramp", "kind": "ramp", "args": ["float32", "int32"],
     "range": [-90, 10], "unit": "decibels", "milliseconds": [0, 60000], "example": [-20.0, 250]},
    {"control": "mute", "address": "/fk/v1/param/mute", "kind": "set", "args": ["int32"],
     "range": [0, 1], "unit": "boolean", "example": [1]},
    {"control": "mute-ramp", "address": "/fk/v1/param/mute/ramp", "kind": "ramp", "args": ["int32", "int32"],
     "range": [0, 1], "unit": "boolean", "milliseconds": [0, 60000], "example": [0, 0]},
    {"control": "pan", "address": "/fk/v1/param/pan", "kind": "set", "args": ["float32"],
     "range": [-1, 1], "unit": "pan", "example": [0.25]},
    {"control": "pan-ramp", "address": "/fk/v1/param/pan/ramp", "kind": "ramp", "args": ["float32", "int32"],
     "range": [-1, 1], "unit": "pan", "milliseconds": [0, 60000], "example": [-1.0, 60000]},
    {"control": "send", "address": "/fk/v1/param/send", "kind": "set", "args": ["float32"],
     "range": [-90, 10], "unit": "decibels", "example": [-12.0]},
    {"control": "send-ramp", "address": "/fk/v1/param/send/ramp", "kind": "ramp", "args": ["float32", "int32"],
     "range": [-90, 10], "unit": "decibels", "milliseconds": [0, 60000], "example": [0.0, 1000]},
    {"control": "colour", "address": "/fk/v1/param/colour", "kind": "set", "args": ["int32"],
     "range": [1, 12], "unit": "index", "example": [7]},
    {"control": "colour-ramp", "address": "/fk/v1/param/colour/ramp", "kind": "ramp", "args": ["int32", "int32"],
     "range": [1, 12], "unit": "index", "milliseconds": [0, 60000], "example": [12, 10]},
    {"control": "go", "address": "/fk/v1/action/go", "kind": "trigger", "args": [], "example": []},
    {"control": "next", "address": "/fk/v1/action/next", "kind": "trigger", "args": ["impulse"],
     "example": ["impulse"]},
    {"control": "start", "address": "/fk/v1/transport/start", "kind": "start", "args": [], "example": []},
    {"control": "stop", "address": "/fk/v1/transport/stop", "kind": "stop", "args": [], "example": []},
    {"control": "locate", "address": "/fk/v1/transport/locate", "kind": "locate", "args": ["int32"],
     "ticks": [0, 9223372036854775807], "example": [96000]}
  ],
  "refused": [
    {"address": "/fk/v1/route/main", "refusal": "refusedFamily(route)"},
    {"address": "/fk/v1/patch/scene", "refusal": "refusedFamily(patch)"},
    {"address": "/fk/v1/draft/new", "refusal": "refusedFamily(draft)"},
    {"address": "/fk/v1/safety/mute", "refusal": "refusedFamily(safety)"},
    {"address": "/fk/v1/hazard/panic", "refusal": "refusedFamily(hazard)"},
    {"address": "/fk/v1/param/*", "refusal": "wildcardAddress"},
    {"address": "/fk/v1/unknown/fader", "refusal": "unknownFamily"},
    {"address": "/fk/v1/param/fader/ramp/extra/more", "refusal": "tooManySegments"},
    {"address": "/other/v1/param/fader", "refusal": "outsideNamespace"},
    {"address": "/fk/v1/param/fader/jump", "refusal": "unknownRoute"}
  ]
}
"""#

extension TouchOSCInteropFixture {
    /// The embedded canonical table text (without the file's final newline).
    static var tableText: String { touchOSCTableText }

    /// The operation each accepted row must map to with its example arguments, listed by hand.
    static var expectedOperations: [String: CommandOperation] {
        [
            "/fk/v1/param/fader": .set(
                ParameterCatalog.wingFaderDecibels, ParameterValue(value: -6.5, unit: .decibels)
            ),
            "/fk/v1/param/fader/ramp": .ramp(
                ParameterCatalog.wingFaderDecibels, ParameterValue(value: -20, unit: .decibels), milliseconds: 250
            ),
            "/fk/v1/param/mute": .set(ParameterCatalog.wingMute, ParameterValue(value: 1, unit: .boolean)),
            "/fk/v1/param/mute/ramp": .ramp(
                ParameterCatalog.wingMute, ParameterValue(value: 0, unit: .boolean), milliseconds: 0
            ),
            "/fk/v1/param/pan": .set(ParameterCatalog.wingPan, ParameterValue(value: 0.25, unit: .pan)),
            "/fk/v1/param/pan/ramp": .ramp(
                ParameterCatalog.wingPan, ParameterValue(value: -1, unit: .pan), milliseconds: 60_000
            ),
            "/fk/v1/param/send": .set(ParameterCatalog.wingSendDecibels, ParameterValue(value: -12, unit: .decibels)),
            "/fk/v1/param/send/ramp": .ramp(
                ParameterCatalog.wingSendDecibels, ParameterValue(value: 0, unit: .decibels), milliseconds: 1_000
            ),
            "/fk/v1/param/colour": .set(ParameterCatalog.wingColour, ParameterValue(value: 7, unit: .index)),
            "/fk/v1/param/colour/ramp": .ramp(
                ParameterCatalog.wingColour, ParameterValue(value: 12, unit: .index), milliseconds: 10
            ),
            "/fk/v1/action/go": .trigger(goAction),
            "/fk/v1/action/next": .trigger(nextAction),
            "/fk/v1/transport/start": .start,
            "/fk/v1/transport/stop": .stop,
            "/fk/v1/transport/locate": .locate(ticks: 96_000)
        ]
    }

    /// The typed refusal each refused row must produce, listed by hand next to the name the file gives it.
    static var expectedRefusals: [String: (name: String, refusal: OSC.NamespaceRefusal)] {
        [
            "/fk/v1/route/main": ("refusedFamily(route)", .refusedFamily(.route)),
            "/fk/v1/patch/scene": ("refusedFamily(patch)", .refusedFamily(.patch)),
            "/fk/v1/draft/new": ("refusedFamily(draft)", .refusedFamily(.draft)),
            "/fk/v1/safety/mute": ("refusedFamily(safety)", .refusedFamily(.safety)),
            "/fk/v1/hazard/panic": ("refusedFamily(hazard)", .refusedFamily(.hazard)),
            "/fk/v1/param/*": ("wildcardAddress", .wildcardAddress),
            "/fk/v1/unknown/fader": ("unknownFamily", .unknownFamily),
            "/fk/v1/param/fader/ramp/extra/more": ("tooManySegments", .tooManySegments(count: 7, limit: 6)),
            "/other/v1/param/fader": ("outsideNamespace", .outsideNamespace(segmentCount: 4)),
            "/fk/v1/param/fader/jump": ("unknownRoute", .unknownRoute(segmentCount: 5))
        ]
    }

    /// The checkout's copy of the table, found relative to this file, or `nil` when the checkout is absent.
    static func tableFileURL() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Examples/TouchOSC/address-table.json")
    }
}

extension TouchOSCInteropTests {
    @Test("The embedded table equals Examples/TouchOSC/address-table.json byte for byte",
          .enabled(if: FileManager.default.fileExists(atPath: Fixture.tableFileURL().path)))
    func theEmbeddedTableEqualsTheRepositoryFileByteForByte() throws {
        let file = try Data(contentsOf: Fixture.tableFileURL())
        #expect(Array(file) == Array((Fixture.tableText + "\n").utf8))
    }

    @Test("Every accepted table row maps its example packet to the exact hand-listed operation")
    func everyAcceptedRowMapsToItsExactOperation() throws {
        let rows = try Fixture.table().accepted
        let expected = Fixture.expectedOperations
        #expect(rows.count == 15)
        #expect(Set(rows.map(\.address)) == Set(expected.keys))
        for row in rows {
            let outcome = try Fixture.map(row.address, try Fixture.arguments(of: row))
            #expect(outcome == .success(try #require(expected[row.address])), "\(row.address)")
        }
    }

    @Test("The table lists the namespace prefix and only addresses under it")
    func theTableNamespaceAndAddressesAreUnderTheFkV1Prefix() throws {
        let table = try Fixture.table()
        #expect(table.namespace == "/fk/v1")
        for row in table.accepted {
            #expect(row.address.hasPrefix("/fk/v1/"), "\(row.address)")
        }
    }

    @Test("A set or ramp row lists exactly the catalog bounds and unit of the parameter it maps to")
    func tableRangesAndUnitsEqualTheCatalogDescriptorBounds() throws {
        let catalog = Fixture.catalog()
        var checked = 0
        for row in try Fixture.table().accepted where row.kind == "set" || row.kind == "ramp" {
            let outcome = try Fixture.map(row.address, try Fixture.arguments(of: row))
            guard case .success(let operation) = outcome else {
                Issue.record("\(row.address) did not map")
                continue
            }
            let id: ParameterID
            switch operation {
            case .set(let target, _), .ramp(let target, _, _): id = target
            case .bind, .recall, .trigger, .start, .stop, .locate, .panic, .safeMute, .propose, .editDraft:
                Issue.record("\(row.address) is not a parameter operation")
                continue
            }
            let descriptor = try #require(catalog[id])
            #expect(row.range == [descriptor.fields.lower, descriptor.fields.upper], "\(row.address)")
            #expect(row.unit == descriptor.fields.unit.rawValue, "\(row.address)")
            checked += 1
        }
        #expect(checked == 10)
    }

    @Test("Every row's milliseconds and ticks equal the mapper's bounds, at the bound and one past it")
    func tableMillisecondsAndTicksEqualWhatTheMapperEnforces() throws {
        var ramps = 0
        var locates = 0
        for row in try Fixture.table().accepted {
            let arguments = try Fixture.arguments(of: row)
            if let milliseconds = row.milliseconds {
                #expect(milliseconds.count == 2, "\(row.address)")
                guard case .success(.ramp(let target, let value, _)) = try Fixture.map(row.address, arguments) else {
                    Issue.record("\(row.address) did not map")
                    continue
                }
                for edge in milliseconds {
                    let outcome = try Fixture.map(row.address, [arguments[0], .int32(Int32(edge))])
                    #expect(outcome == .success(.ramp(target, value, milliseconds: edge)), "\(row.address)")
                }
                for past in [milliseconds[0] - 1, milliseconds[1] + 1] {
                    let refusal = try Fixture.refusal(row.address, [arguments[0], .int32(Int32(past))])
                    #expect(refusal == .rampMillisecondsOutOfRange(past), "\(row.address)")
                }
                ramps += 1
            }
            if let ticks = row.ticks {
                let lower = ticks[0]
                let upper = ticks[1]
                #expect(upper == Int64.max, "an int64 tick count is accepted up to its largest value")
                #expect(try Fixture.map(row.address, [.int64(lower)]) == .success(.locate(ticks: lower)))
                #expect(try Fixture.map(row.address, [.int64(upper)]) == .success(.locate(ticks: upper)))
                #expect(try Fixture.refusal(row.address, [.int64(lower - 1)]) == .negativeTicks)
                #expect(try Fixture.refusal(row.address, [.int32(Int32.max)]) == nil)
                locates += 1
            }
        }
        #expect(ramps == 5)
        #expect(locates == 1)
    }

    @Test("Every refused row refuses with its hand-listed typed refusal and the name the file gives it")
    func everyRefusedRowRefusesWithItsTypedNamespaceRefusal() throws {
        let rows = try Fixture.table().refused
        let expected = Fixture.expectedRefusals
        #expect(rows.count == 10)
        #expect(Set(rows.map(\.address)) == Set(expected.keys))
        for row in rows {
            let entry = try #require(expected[row.address])
            #expect(row.refusal == entry.name, "\(row.address)")
            #expect(try Fixture.refusal(row.address) == entry.refusal, "\(row.address)")
        }
    }

    @Test("A mutated accepted row refuses: an unknown family, a wildcard and a seventh segment")
    func aMutatedAcceptedRowRefusesWithTheTypedRefusal() throws {
        let fader: [OSC.Argument] = [.float32(0.5)]
        #expect(try Fixture.refusal("/fk/v1/prm/fader", fader) == .unknownFamily)
        #expect(try Fixture.refusal("/fk/v1/param/fad*", fader) == .wildcardAddress)
        #expect(try Fixture.refusal("/fk/v1/param/fader/ramp/a/b", fader) == .tooManySegments(count: 7, limit: 6))
        #expect(try Fixture.refusal("/fk/v1/param/fader", fader) == nil)
    }

    @Test("Every refused family refuses by name for any leaf and any arguments; no accepted row is under one")
    func everyRefusedFamilyIsRefusedByNameAndNoAcceptedRowUsesOne() throws {
        let table = try Fixture.table()
        for family in OSC.RefusedFamily.allCases {
            for leaf in ["x", "fader", "ramp"] {
                let address = "/fk/v1/\(family.rawValue)/\(leaf)"
                #expect(try Fixture.refusal(address) == .refusedFamily(family), "\(address)")
                #expect(try Fixture.refusal(address, [.int32(1)]) == .refusedFamily(family), "\(address)")
            }
            #expect(table.refused.contains { $0.refusal == "refusedFamily(\(family.rawValue))" })
            #expect(!table.accepted.contains { $0.address.hasPrefix("/fk/v1/\(family.rawValue)/") })
        }
    }

    @Test("A hazardous or structural parameter cannot be named in a route table, whatever its name")
    func aNonLiveParameterCannotBeRoutedUnderAnyName() throws {
        let hazardous = ParameterID(validated: "test.hazardous")
        let structural = ParameterID(validated: "test.structural")
        let catalog = try ParameterCatalog(ParameterCatalog.wing.parameters + [
            Fixture.descriptor(hazardous, controlClass: .hazardous),
            Fixture.descriptor(structural, controlClass: .structural)
        ])
        for (id, controlClass) in [(hazardous, ControlClass.hazardous), (structural, ControlClass.structural)] {
            #expect(throws: OSC.RouteTableRefusal.parameterNotLive(index: 0, controlClass: controlClass)) {
                try OSC.RouteTable(
                    parameters: [OSC.ParameterRoute(name: "fader", id: id)], actions: [], transport: [],
                    catalog: catalog
                )
            }
        }
    }
}

extension TouchOSCInteropFixture {
    static func descriptor(_ id: ParameterID, controlClass: ControlClass) throws -> ParameterDescriptor {
        try ParameterDescriptor(.init(
            id: id, unit: .normalized, lower: 0, upper: 1, defaultValue: 0, ceiling: nil, curve: .linear,
            ramp: .step, controlClass: controlClass, verification: .unverified
        ))
    }
}
