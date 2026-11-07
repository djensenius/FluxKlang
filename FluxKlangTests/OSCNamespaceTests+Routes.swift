import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Route table construction: bounds, names, targets, catalog class and check order.
extension OSCNamespaceTests {
    private func tableRefusal(
        parameters: [OSC.ParameterRoute]? = nil, actions: [OSC.ActionRoute]? = nil,
        transport: [OSC.TransportVerb] = []
    ) throws -> TableRefusal? {
        let catalog = try Fixture.catalog()
        do {
            _ = try OSC.RouteTable(
                parameters: parameters ?? Fixture.parameterRoutes(), actions: actions ?? Fixture.actionRoutes(),
                transport: transport, catalog: catalog
            )
            return nil
        } catch { return error }
    }

    private func parameter(_ name: String, _ id: ParameterID = ParameterCatalog.wingMute) -> OSC.ParameterRoute {
        OSC.ParameterRoute(name: name, id: id)
    }

    private func action(_ name: String, _ id: String = "act.go") throws -> OSC.ActionRoute {
        OSC.ActionRoute(name: name, id: try ActionID(id))
    }

    private func actions(count: Int) throws -> [OSC.ActionRoute] {
        try (0..<count).map { try action("a\($0)", "act.\($0)") }
    }

    @Test func theFixtureTableKeepsEveryRouteAndTheCatalogUnit() throws {
        let table = try Fixture.table()
        #expect(table.parameterRouteCount == 3 && table.actionRouteCount == 1)
        #expect(table.enabledTransport == [.start, .stop, .locate])
        let fader = try #require(table.parameterTarget(named: Array("fader".utf8)))
        #expect(fader.id == ParameterCatalog.wingFaderDecibels && fader.unit == .decibels)
        #expect(table.parameterTarget(named: Array("mute".utf8))?.unit == .boolean)
        #expect(table.parameterTarget(named: Array("pan".utf8))?.unit == .pan)
        #expect(table.actionID(named: Array("go".utf8)) == Fixture.goID)
        #expect(table.parameterTarget(named: Array("go".utf8)) == nil && table.actionID(named: Array("fader".utf8)) ==
            nil)
    }

    @Test func anEmptyTableIsRefused() throws {
        #expect(try tableRefusal(parameters: [], actions: [], transport: []) == .emptyTable)
        #expect(try tableRefusal(parameters: [], actions: [], transport: [.stop]) == nil)
        #expect(try tableRefusal(parameters: [], actions: Fixture.actionRoutes(), transport: []) == nil)
    }

    @Test func aTableOf128EntriesIsAccepted() throws {
        #expect(try tableRefusal(parameters: Fixture.parameterRoutes(), actions: actions(count: 125)) == nil)
        #expect(try tableRefusal(parameters: Fixture.parameterRoutes(), actions: actions(count: 124),
            transport: [.start]) == nil)
        #expect(try tableRefusal(parameters: [], actions: actions(count: 128)) == nil)
    }

    @Test func aTableOf129EntriesIsRefused() throws {
        let limit = 128
        #expect(try tableRefusal(parameters: Fixture.parameterRoutes(), actions: actions(count: 126)) ==
            .tooManyRoutes(count: 129, limit: limit))
        #expect(try tableRefusal(parameters: [], actions: actions(count: 129)) == .tooManyRoutes(count: 129,
            limit: limit))
        let transportCounts = try tableRefusal(
            parameters: Fixture.parameterRoutes(), actions: actions(count: 125), transport: [.start]
        )
        #expect(transportCounts == .tooManyRoutes(count: 129, limit: limit))
    }

    @Test func theEntryTotalSaturatesInsteadOfOverflowing() {
        #expect(OSC.RouteTable.entryTotal(parameters: 1, actions: 2, transport: 3) == 6)
        #expect(OSC.RouteTable.entryTotal(parameters: Int.max, actions: 1, transport: 0) == Int.max)
        #expect(OSC.RouteTable.entryTotal(parameters: 1, actions: Int.max, transport: 0) == Int.max)
        #expect(OSC.RouteTable.entryTotal(parameters: Int.max - 1, actions: 1, transport: 1) == Int.max)
        #expect(OSC.RouteTable.entryTotal(parameters: 0, actions: 0, transport: Int.max) == Int.max)
        #expect(OSC.RouteTable.entryTotal(parameters: 64, actions: 64, transport: 0) == 128)
    }

    @Test func invalidParameterNamesReportTheirIndexAndByteCount() throws {
        let cases: [(String, Int)] = [
            ("", 0), ("Fader", 5), ("fa der", 6), ("fa.der", 6), ("fa\u{E9}", 4), ("fa/der", 6),
            (Fixture.repeated("a", 33), 33), ("fa:der", 6), ("FADER", 5), ("fa+", 3)
        ]
        for (name, byteCount) in cases {
            let refusal = try tableRefusal(parameters: [parameter("fader"), parameter(name, ParameterCatalog.wingPan)])
            #expect(refusal == .invalidName(family: .param, index: 1, byteCount: byteCount), "\(byteCount)")
        }
    }

    @Test func invalidActionNamesReportTheActionFamily() throws {
        let refusal = try tableRefusal(actions: [action("go"), action("Go", "act.two")])
        #expect(refusal == .invalidName(family: .action, index: 1, byteCount: 2))
        #expect(try tableRefusal(actions: [action("")]) == .invalidName(family: .action, index: 0, byteCount: 0))
    }

    @Test func aNameOf32BytesIsAcceptedAnd33IsRefused() throws {
        let longest = Fixture.repeated("a", 32)
        #expect(try tableRefusal(parameters: [parameter(longest)]) == nil)
        #expect(try tableRefusal(actions: [action(longest)]) == nil)
        #expect(try tableRefusal(parameters: [parameter(longest + "a")]) == .invalidName(family: .param, index: 0,
            byteCount: 33))
        #expect(try tableRefusal(actions: [action(longest + "a")]) == .invalidName(family: .action, index: 0,
            byteCount: 33))
        #expect(try tableRefusal(parameters: [parameter("a_0-z9")]) == nil)
    }

    @Test func namesAreComparedAsBytesNotCharacters() throws {
        let precomposed = try tableRefusal(parameters: [parameter("caf\u{E9}")])
        let decomposed = try tableRefusal(parameters: [parameter("cafe\u{301}")])
        #expect(precomposed == .invalidName(family: .param, index: 0, byteCount: 5))
        #expect(decomposed == .invalidName(family: .param, index: 0, byteCount: 6))
    }

    @Test func aDuplicateNameIsRefusedPerFamily() throws {
        let params = try tableRefusal(parameters: [parameter("fader"), parameter("pan", ParameterCatalog.wingPan),
            parameter("fader", ParameterCatalog.wingColour)])
        #expect(params == .duplicateName(family: .param, index: 2))
        let acts = try tableRefusal(actions: [action("go"), action("go", "act.two")])
        #expect(acts == .duplicateName(family: .action, index: 1))
        #expect(try tableRefusal(parameters: [parameter("same")], actions: [action("same")]) == nil)
    }

    @Test func aDuplicateTargetIsRefusedPerFamily() throws {
        let params = try tableRefusal(parameters: [parameter("a"), parameter("b")])
        #expect(params == .duplicateTarget(family: .param, index: 1))
        let acts = try tableRefusal(actions: [action("go"), action("also")])
        #expect(acts == .duplicateTarget(family: .action, index: 1))
    }

    @Test func anUnknownCatalogParameterIsRefused() throws {
        let unknown = try ParameterID("wing.unknown")
        let refusal = try tableRefusal(parameters: [parameter("fader", ParameterCatalog.wingFaderDecibels),
            parameter("x", unknown)])
        #expect(refusal == .unknownParameter(index: 1))
    }

    @Test func structuralAndHazardousCatalogParametersCanNeverBeRouted() throws {
        let structural = try tableRefusal(parameters: [parameter("fader", ParameterCatalog.wingFaderDecibels),
            parameter("s", Fixture.structuralID)])
        #expect(structural == .parameterNotLive(index: 1, controlClass: .structural))
        let hazardous = try tableRefusal(parameters: [parameter("hazard", Fixture.hazardousID)])
        #expect(hazardous == .parameterNotLive(index: 0, controlClass: .hazardous))
    }

    @Test func aDuplicateTransportVerbIsRefused() throws {
        #expect(try tableRefusal(transport: [.start, .stop, .start]) == .duplicateTransport(index: 2))
        #expect(try tableRefusal(transport: [.locate, .locate]) == .duplicateTransport(index: 1))
        #expect(try tableRefusal(transport: [.locate, .stop, .start]) == nil)
    }

    @Test func tooManyEntriesBeatAnInvalidName() throws {
        let refusal = try tableRefusal(parameters: [parameter("Bad")], actions: actions(count: 128))
        #expect(refusal == .tooManyRoutes(count: 129, limit: 128))
    }

    @Test func anInvalidNameBeatsADuplicateNameInAnotherList() throws {
        let refusal = try tableRefusal(
            parameters: [parameter("fader"), parameter("fader", ParameterCatalog.wingPan)], actions: [action("Go")]
        )
        #expect(refusal == .invalidName(family: .action, index: 0, byteCount: 2))
    }

    @Test func aDuplicateNameBeatsADuplicateTarget() throws {
        let refusal = try tableRefusal(parameters: [
            parameter("fader"), parameter("pan"), parameter("fader", ParameterCatalog.wingPan)
        ])
        #expect(refusal == .duplicateName(family: .param, index: 2))
        let crossed = try tableRefusal(
            parameters: [parameter("a"), parameter("b")], actions: [action("go"), action("go", "act.two")]
        )
        #expect(crossed == .duplicateName(family: .action, index: 1))
    }

    @Test func aDuplicateTargetBeatsAnUnknownParameterWhereverItIs() throws {
        let unknown = try ParameterID("wing.unknown")
        let after = try tableRefusal(parameters: [parameter("a"), parameter("b"), parameter("c", unknown)])
        #expect(after == .duplicateTarget(family: .param, index: 1))
        let before = try tableRefusal(parameters: [parameter("c", unknown), parameter("a"), parameter("b")])
        #expect(before == .duplicateTarget(family: .param, index: 2))
        let actions = try tableRefusal(
            parameters: [parameter("c", unknown)], actions: [action("go"), action("stop")]
        )
        #expect(actions == .duplicateTarget(family: .action, index: 1))
    }

    @Test func anUnknownParameterBeatsAParameterThatIsNotLive() throws {
        let unknown = try ParameterID("wing.unknown")
        let refusal = try tableRefusal(parameters: [parameter("s", Fixture.structuralID), parameter("u", unknown)])
        #expect(refusal == .unknownParameter(index: 1))
    }

    @Test func aParameterThatIsNotLiveBeatsADuplicateTransportVerb() throws {
        let refusal = try tableRefusal(parameters: [parameter("s", Fixture.structuralID)], transport: [.start, .start])
        #expect(refusal == .parameterNotLive(index: 0, controlClass: .structural))
    }

    @Test func parametersAreCheckedBeforeActionsForTheSameCheck() throws {
        let refusal = try tableRefusal(parameters: [parameter("Bad")], actions: [action("Worse")])
        #expect(refusal == .invalidName(family: .param, index: 0, byteCount: 3))
    }

    @Test func tablesFromTheSameInputsAreEqualWhateverTheListOrder() throws {
        let first = try Fixture.table()
        let second = try Fixture.table()
        let permuted = try Fixture.table(parameters: Array(Fixture.parameterRoutes().reversed()), transport: [.locate,
            .start,
            .stop])
        #expect(first == second && first == permuted)
        let other = try Fixture.table(transport: [.start])
        #expect(first != other)
    }

    @Test func anActionAddressWithAnExtraSegmentIsAnUnknownRoute() throws {
        try Fixture.expectRefusals([("/fk/v1/action/go/x", .unknownRoute(segmentCount: 5))])
    }

    @Test func aTransportAddressWithAnExtraSegmentIsAnUnknownRoute() throws {
        try Fixture.expectRefusals([
            ("/fk/v1/transport/start/x", .unknownRoute(segmentCount: 5)),
            ("/fk/v1/transport/locate/x", .unknownRoute(segmentCount: 5))
        ], [.int32(1)])
    }

    @Test func aParameterAddressWithAnUnlistedLastSegmentIsAnUnknownRoute() throws {
        try Fixture.expectRefusals([
            ("/fk/v1/param/fader/slide", .unknownRoute(segmentCount: 5)),
            ("/fk/v1/param/fader/Ramp", .invalidSegment(index: 4, byteOffset: 0))
        ], [.float32(1), .int32(1)])
    }

    @Test func aParameterAddressWithSixSegmentsIsAnUnknownRoute() throws {
        try Fixture.expectRefusals([
            ("/fk/v1/param/fader/ramp/extra", .unknownRoute(segmentCount: 6))
        ], [.float32(1), .int32(1)])
    }

    @Test func routeCountsReportParametersAndActionsSeparately() throws {
        let table = try Fixture.table()
        #expect(table.parameterRouteCount == 3)
        #expect(table.actionRouteCount == 1)
        let actionsOnly = try Fixture.table(parameters: [], actions: Fixture.actionRoutes(), transport: [])
        #expect(actionsOnly.parameterRouteCount == 0)
        #expect(actionsOnly.actionRouteCount == 1)
    }
}
