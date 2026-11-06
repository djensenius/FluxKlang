import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension NeutralSnapshotTests {
    // MARK: - Device-ID allowlist

    @Test(arguments: [
        ("AppleUSBAudioEngine:Vendor:WING:ABCD1234:1", false),
        ("ABCD1234EF56", false),
        ("dev.4f2a9c1e", false),
        ("dev.wing-ab12cd", false),
        ("dev.mic-2024", false),
        ("6F1D2C8A-3B4E-4F50-9A61-7C8D9E0F1A2B", false),
        ("dev.Iface-a", false),
        ("dev.iface--a", false),
        ("dev.", false),
        ("iface-b", false),
        ("dev.iface-b", true),
        ("dev.phone-audio", true),
        ("dev.ctl-b.port-2", true)
    ])
    func deviceIDsAreExposedOnlyWhenTheyMatchTheAliasForm(raw: String, exposed: Bool) throws {
        var input = try Self.routeInput("rte.x", binding: .proposed, presence: .present)
        input.route.device = try DeviceID(raw)
        let snapshot = Snapshot.build(from: Snapshot.Inputs(graph: Self.emptyGraph, routes: [input]))
        let route = try #require(snapshot.route(RouteID(validated: "rte.x")))
        #expect(route.device?.rawValue == (exposed ? raw : nil))
        #expect(route.isDeviceWithheld == !exposed)
        let json = try #require(String(data: Self.encode(snapshot), encoding: .utf8))
        #expect(json.contains(raw) == exposed)
    }

    @Test(arguments: ["uid", "host", "evidence", "hardware"])
    func aliasesEqualToAnyKnownIdentityAreWithheld(source: String) throws {
        var other = try Self.routeInput("rte.other", binding: .confirmed, presence: .present)
        var inputs = Snapshot.Inputs(graph: Self.emptyGraph)
        switch source {
        case "uid": other.route.confirmedDeviceUID = "DEV.IFACE-B"
        case "host": other.route.confirmedHost = HostID(validated: "dev.iface-b")
        case "evidence": other.route.evidence = " dev.iface-b "
        default: inputs.hardwareIdentifiers = ["dev.iface-b"]
        }
        var input = try Self.routeInput("rte.x", binding: .confirmed, presence: .present)
        input.route.device = DeviceID(validated: "dev.iface-b")
        inputs.routes = [input, other]
        let snapshot = Snapshot.build(from: inputs)
        #expect(snapshot.route(RouteID(validated: "rte.x"))?.isDeviceWithheld == true)
        #expect(snapshot.route(RouteID(validated: "rte.x"))?.device == nil)
    }

    // MARK: - Invisible characters

    @Test(arguments: [
        ("a\u{E000}b\u{F8FF}c\u{F0000}", "abc"),
        ("a\u{0378}b\u{E01F0}c", "abc"),
        ("a\u{3164}b\u{115F}c\u{1160}d\u{FFA0}e\u{2800}f\u{16FE4}g", "abcdefg"),
        ("a\u{FE00}b\u{E0100}c\u{180B}", "abc"),
        ("\u{FE0F}a \u{FE0F}b\u{0301}\u{FE0E}", "a b\u{0301}"),
        ("✈\u{FE0F}x\u{FE0E}", "✈\u{FE0F}x"),
        ("A\u{FE0F}b\u{FE0E}1\u{FE0F}\u{20E3}", "Ab1\u{FE0F}\u{20E3}"),
        ("a\u{034F}b", "ab"),
        ("a\u{17B4}b\u{17B5}c\u{180F}d\u{2065}e", "abcde"),
        ("🏴\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F}", "🏴"),
        ("a\u{E0041}\u{E0001}b", "ab"),
        ("Line\u{0085}Next\u{2029}Para", "Line Next Para"),
        ("a\u{200B}b\u{2060}c\u{FEFF}d\u{00AD}e", "abcde"),
        ("👩\u{200D}💻", "👩\u{200D}💻"),
        ("❤\u{FE0F}\u{200D}🔥", "❤\u{FE0F}\u{200D}🔥"),
        ("می\u{200C}خواهم", "می\u{200C}خواهم"),
        ("a\u{200D}b", "a\u{200D}b"),
        (" \u{200D}x\u{200D} 1\u{200D}2\u{200D}", " x 12"),
        ("\u{200D}\u{200D}a\u{200D}\u{200D}b", "a\u{200D}b")
    ])
    func invisibleCharacterClassesAreRemoved(raw: String, expected: String) {
        let label = UntrustedLabel(raw)
        #expect(label.text == expected)
        #expect(label.wasSanitized == (raw != expected))
    }

    @Test func graphemesAreCappedAtEightScalars() {
        let flood = "e" + String(repeating: "\u{0301}", count: 40) + "x"
        let label = UntrustedLabel(flood)
        let expected = "\u{00E9}" + String(repeating: "\u{0301}", count: 7) + "x"
        #expect(label.text.unicodeScalars.elementsEqual(expected.unicodeScalars))
        #expect(label.text.allSatisfy { $0.unicodeScalars.count <= 8 })
        #expect(label.wasSanitized && !label.isTruncated)
        let family = "👨\u{200D}👩\u{200D}👧\u{200D}👦"
        #expect(UntrustedLabel(family).text == family && !UntrustedLabel(family).wasSanitized)
        let joined = String(repeating: "👩\u{200D}", count: 6) + "👩"
        let capped = UntrustedLabel(joined).text
        #expect(capped.unicodeScalars.count == 7 && capped.unicodeScalars.last != "\u{200D}")
    }

    // MARK: - Withheld free text

    @Test func knownIdentitiesAreRedactedFromEveryLabel() throws {
        let uid = "AppleUSBAudioEngine:Vendor:WING:ABCD1234:1"
        var route = try Self.routeInput("rte.a", binding: .confirmed, presence: .present)
        route.route.confirmedDeviceUID = uid
        route.route.confirmedHost = HostID(validated: "host.studio-mac")
        route.route.evidence = "loopback 2026-11-01"
        var node = try Self.node("node.a", label: "WING \(uid.lowercased()) on HOST.STUDIO-MAC")
        node.ports[0].label = "In (loopback 2026-11-01)"
        var inputs = try Snapshot.Inputs(
            graph: GraphDocument(id: GraphID(validated: "graph.r"), label: "Rig SN-778899", nodes: [node]),
            routes: [route],
            diagnostics: [Self.diagnostic("dgn.a", .error, summary: "\(uid) went missing")]
        )
        inputs.hardwareIdentifiers = ["SN-778899"]
        let snapshot = Snapshot.build(from: inputs)
        let marker = UntrustedLabel.withheldMarker
        #expect(snapshot.node(Self.nodeA)?.label.text == "WING \(marker) on \(marker)")
        #expect(snapshot.node(Self.nodeA)?.ports.first?.label?.text == "In (\(marker))")
        #expect(snapshot.graph.label?.text == "Rig \(marker)")
        #expect(snapshot.diagnostics.first?.summary.text == "\(marker) went missing")
        #expect(snapshot.truncation.sanitizedLabels == 4 && snapshot.truncation.truncatedLabels == 0)
        let json = try #require(String(data: Self.encode(snapshot), encoding: .utf8)).lowercased()
        for secret in [uid, "studio-mac", "loopback 2026", "778899"] {
            #expect(!json.contains(secret.lowercased()), "leaked \(secret)")
        }
    }

    @Test func invisibleCharactersInsideAUIDAreStrippedBeforeRedaction() {
        let uid = "AppleUSBAudioEngine:Vendor:WING:ABCD1234:1"
        let hidden = "A\u{FE0F}pple\u{034F}USB\u{17B4}AudioEngine:Vendor:WING:ABCD1234:1"
        let label = UntrustedLabel("Rig \(hidden)", withholding: [uid])
        #expect(label.text == "Rig \(UntrustedLabel.withheldMarker)")
        #expect(label.wasSanitized && !label.isTruncated)
    }

    @Test func removedPaddingDoesNotPushAUIDPastTheScanLimit() {
        let uid = "AppleUSBAudioEngine:Vendor:WING:ABCD1234:1"
        let label = UntrustedLabel(String(repeating: "\u{200B}", count: 4_084) + uid, withholding: [uid])
        #expect(label.text == UntrustedLabel.withheldMarker)
        #expect(label.wasSanitized && !label.isTruncated)
    }

    /// Four adjacent 1,000-byte copies shrink to one 10-byte marker, so whatever the
    /// scan keeps of the fifth copy would fit in a 200-byte label. The scan-cut tail
    /// window (the last 999 scalars) covers the cut copy and the padding before it,
    /// even a partial of only three bytes.
    @Test(arguments: [0, 88, 89])
    func aUIDCutByTheScanLimitLeavesNoPrefix(padding: Int) {
        let serial = Self.thousandByteSerial
        let raw = "Rig " + String(repeating: serial, count: 4) + String(repeating: "x", count: padding)
            + serial.lowercased()
        let label = UntrustedLabel(raw, maximumBytes: 200, withholding: [serial])
        let marker = UntrustedLabel.withheldMarker
        // Adjacent copies and the tail window merge into one marker.
        #expect(label.text == "Rig " + marker)
        #expect(label.isTruncated)
    }

    @Test func onlyWithheldStringsOfSixBytesOrMoreAreRedacted() throws {
        for (evidence, expected) in [(" ok ", "Mic ok"), ("studio", "Mic [withheld]")] {
            var route = try Self.routeInput("rte.a", binding: .confirmed, presence: .present)
            route.route.evidence = evidence
            let graph = try GraphDocument(
                id: GraphID(validated: "graph.r"), nodes: [Self.node("node.a", label: "Mic ok")]
            )
            var inputs = Snapshot.Inputs(graph: graph, routes: [route])
            let summary = "Mic " + evidence.trimmingCharacters(in: .whitespaces)
            inputs.diagnostics = try [Self.diagnostic("dgn.a", .info, summary: summary)]
            let snapshot = Snapshot.build(from: inputs)
            #expect(snapshot.diagnostics.first?.summary.text == expected)
            #expect(snapshot.node(Self.nodeA)?.label.text == "Mic ok")
        }
    }

    // MARK: - Dangling references

    @Test func danglingEdgesAndPortsAreDroppedAndCounted() throws {
        let graph = try GraphDocument(
            id: GraphID(validated: "graph.d"),
            nodes: [Self.node("node.a"), Self.node("node.b"), Self.node("node.z", ports: ["port.in", "port.x"])],
            edges: [
                Self.edge("edge.ab", from: "node.a", "port.out", to: "node.b", "port.in"),
                Self.edge("edge.az", from: "node.a", "port.out", to: "node.z", "port.in"),
                Self.edge("edge.ghost", from: "node.a", "port.ghost", to: "node.b", "port.in"),
                Self.edge("edge.missing", from: "node.q", "port.out", to: "node.b", "port.in")
            ]
        )
        var limits = Snapshot.Limits()
        limits.nodes = 2
        let snapshot = Snapshot.build(from: Snapshot.Inputs(graph: graph), limits: limits)
        #expect(snapshot.edges.map(\.id.rawValue) == ["edge.ab"])
        #expect(snapshot.truncation.edges == Snapshot.CategoryCount(
            offered: 4, kept: 1, droppedOverLimit: 0, droppedDuplicates: 0, droppedDangling: 3
        ))
        #expect(!snapshot.truncation.edges.isTruncated && snapshot.truncation.edges.dropped == 3)
        #expect(snapshot.truncation.ports == Snapshot.CategoryCount(
            offered: 6, kept: 4, droppedOverLimit: 0, droppedDuplicates: 0, droppedDangling: 2
        ))
    }

    @Test func diagnosticsKeepMissingSubjectsAndMarkThem() throws {
        let subjects: [(String, DiagnosticSubject?)] = [
            ("dgn.1", nil), ("dgn.2", .graph),
            ("dgn.3", .node(id: Self.nodeA)), ("dgn.4", .node(id: NodeID(validated: "node.gone"))),
            ("dgn.5", .port(node: Self.nodeA, port: Self.portOut)),
            ("dgn.6", .port(node: Self.nodeA, port: PortID(validated: "port.gone"))),
            ("dgn.7", .edge(id: EdgeID(validated: "edge.ab"))),
            ("dgn.8", .edge(id: EdgeID(validated: "e.x"))),
            ("dgn.9", .parameter(id: ParameterID(validated: "par.gain"))),
            ("dgn.a", .parameter(id: ParameterID(validated: "par.gone"))),
            ("dgn.b", .route(id: RouteID(validated: "rte.cue"))),
            ("dgn.c", .route(id: RouteID(validated: "rte.gone")))
        ]
        var inputs = try Self.sampleInputs()
        inputs.diagnostics = try subjects.map { try Self.diagnostic($0.0, .info, subject: $0.1) }
        let snapshot = Snapshot.build(from: inputs)
        #expect(snapshot.diagnostics.count == subjects.count)
        let missing: Set = ["dgn.4", "dgn.6", "dgn.8", "dgn.a", "dgn.c"]
        #expect(snapshot.diagnostics.map(\.subjectInSnapshot) == subjects.map { !missing.contains($0.0) })
    }

    // MARK: - Round 9: caseless identity refusal

    @Test(arguments: [
        ("dev.interfase-b", "dev.interfa\u{017F}e-b"), ("dev.kelvin-a", "dev.\u{212A}elvin-a"),
        ("dev.strasse-a", "dev.stra\u{00DF}e-a"), ("dev.strasse-a", "DEV.STRA\u{1E9E}E-A")
    ])
    func aliasesEqualToACaseVariantOfAnIdentityAreWithheld(device: String, identity: String) throws {
        var input = try Self.routeInput("rte.x", binding: .confirmed, presence: .present)
        input.route.device = try DeviceID(device)
        var inputs = Snapshot.Inputs(graph: Self.emptyGraph, routes: [input])
        inputs.hardwareIdentifiers = [identity]
        let snapshot = Snapshot.build(from: inputs)
        let route = try #require(snapshot.route(RouteID(validated: "rte.x")))
        #expect(route.device == nil && route.isDeviceWithheld)
        let json = try #require(String(data: Self.encode(snapshot), encoding: .utf8))
        #expect(!json.contains(device))
        #expect(RefusedIdentities([identity], terms: []).refuses(device))
        #expect(RefusedIdentities([device], terms: []).refuses(identity))
    }

    /// Contract IDs are ASCII, so non-ASCII spellings are compared on the identity
    /// form directly (both directions, equality path only).
    @Test(arguments: [
        ("dev.interfase-b", "dev.interfa\u{017F}e-b"), ("dev.\u{212A}elvin", "dev.kelvin"),
        ("dev.stra\u{00DF}e", "dev.strasse"), ("\u{212B}ngstrom", "\u{00C5}ngstrom"),
        ("\u{00C5}ngstrom", "a\u{030A}ngstrom"), ("A\u{030A}ngstrom", "\u{212B}ngstrom"),
        ("dev.\u{D55C}\u{AD6D}", "dev.\u{1112}\u{1161}\u{11AB}\u{1100}\u{116E}\u{11A8}"),
        ("dev.\u{03BF}\u{03B4}\u{03BF}\u{03C2}", "dev.\u{03BF}\u{03B4}\u{03BF}\u{03C3}"),
        ("dev.\u{03BF}\u{03B4}\u{03BF}\u{03C2}", "DEV.\u{039F}\u{0394}\u{039F}\u{03A3}")
    ])
    func identityFormsCompareCaselessly(lhs: String, rhs: String) {
        #expect(RefusedIdentities([lhs], terms: []).refuses(rhs))
        #expect(RefusedIdentities([rhs], terms: []).refuses(lhs))
        #expect(!RefusedIdentities([lhs], terms: []).refuses("dev.iface-b"))
    }

    @Test func labelRedactionAndAliasRefusalAgree() {
        let pairs = Self.caseFoldingPairs + Self.canonicalCasePairs + [("dev.iface-b", "dev.iface-c")]
        for (label, identity) in pairs {
            let redacted = UntrustedLabel(label, withholding: [identity]).text != label
            let terms = UntrustedTextSanitizer.withheldTerms([identity])
            #expect(RefusedIdentities([identity], terms: []).refuses(label) == redacted, "\(label)")
            #expect(RefusedIdentities([], terms: terms).refuses(label) == redacted, "\(label)")
        }
    }

    @Test func identitiesPastTheByteBoundRefuseThroughLabelRedaction() throws {
        var input = try Self.routeInput("rte.x", binding: .confirmed, presence: .present)
        input.route.device = DeviceID(validated: "dev.kick-b")
        var inputs = Snapshot.Inputs(graph: Self.emptyGraph, routes: [input])
        inputs.hardwareIdentifiers = ["DEV.\u{212A}ICK-B" + String(repeating: "\u{0001}", count: 200)]
        let route = try #require(Snapshot.build(from: inputs).route(RouteID(validated: "rte.x")))
        #expect(route.device == nil && route.isDeviceWithheld)
    }

    @Test func anOverCapIdentityDoesNotWithholdOtherRoutes() throws {
        var first = try Self.routeInput("rte.a", binding: .confirmed, presence: .present)
        first.route.device = DeviceID(validated: "dev.iface-b")
        first.route.evidence = String(repeating: "\u{AC01}", count: 30)
        var second = try Self.routeInput("rte.b", binding: .confirmed, presence: .present)
        second.route.device = DeviceID(validated: "dev.phone-audio")
        let snapshot = Snapshot.build(from: Snapshot.Inputs(graph: Self.emptyGraph, routes: [first, second]))
        #expect(snapshot.route(RouteID(validated: "rte.a"))?.device?.rawValue == "dev.iface-b")
        #expect(snapshot.route(RouteID(validated: "rte.b"))?.device?.rawValue == "dev.phone-audio")
    }

    @Test func anIdentityLongerThanAnyDeviceIDIsSkippedButStillRedacted() throws {
        let identity = "SN-" + String(repeating: "\u{AC01}", count: 20)
        #expect(identity.utf8.count == 63 && RefusedIdentities.form(identity) == nil)
        let decomposed = "sn-" + String(repeating: "\u{1100}\u{1161}\u{11A8}", count: 20)
        var input = try Self.routeInput("rte.x", binding: .confirmed, presence: .present)
        input.route.device = DeviceID(validated: "dev.iface-b")
        var inputs = Snapshot.Inputs(graph: Self.emptyGraph, routes: [input])
        inputs.graph.nodes = [try Self.node("node.a", label: "Rig " + decomposed)]
        inputs.hardwareIdentifiers = [identity]
        let snapshot = Snapshot.build(from: inputs)
        #expect(snapshot.route(RouteID(validated: "rte.x"))?.device?.rawValue == "dev.iface-b")
        #expect(snapshot.node(Self.nodeA)?.label.text == "Rig \(UntrustedLabel.withheldMarker)")
    }

    /// Identities of five bytes are too short to be withheld terms, so only the
    /// equality path can refuse `dev.a`; each needs the scalar filter and the trim.
    @Test(arguments: [
        "\u{0001}dev.a", "\u{E000} DEV.A\u{0007}", "dev.\u{2060}a", "\u{FEFF}DEV.A\u{00AD}", "dev.a\u{16FE4}"
    ])
    func theEqualityPathFiltersAndTrimsIdentities(identity: String) throws {
        #expect(UntrustedTextSanitizer.withheldTerm(identity) == nil)
        var input = try Self.routeInput("rte.x", binding: .confirmed, presence: .present)
        input.route.device = DeviceID(validated: "dev.a")
        var inputs = Snapshot.Inputs(graph: Self.emptyGraph, routes: [input])
        inputs.hardwareIdentifiers = [identity]
        let route = try #require(Snapshot.build(from: inputs).route(RouteID(validated: "rte.x")))
        #expect(route.device == nil && route.isDeviceWithheld)
    }
}

// MARK: - Round 12: bounded identity forms

extension NeutralSnapshotTests {
    /// Removed padding (ZWSP, a variation selector after a letter, a word joiner, a soft
    /// hyphen) never counts toward a bound, so a padded five-byte identity still refuses
    /// `dev.a` on the equality path, although it is too short to be a withheld term.
    /// The first case is Copilot's; Foundation trims a trailing ZWSP as whitespace, so the
    /// interior ZWSP case is the one the old raw-byte filter exposed.
    @Test(arguments: [
        ("dev.a", "\u{200B}", ""), ("dev.", "\u{200B}", "a"), ("dev.a", "\u{FE0F}", ""),
        ("", "\u{2060}", "DEV.A"), ("d", "\u{00AD}", "ev.a")
    ])
    func aPaddedShortIdentityStillRefusesItsAlias(head: String, padding: String, tail: String) throws {
        let identity = head + String(repeating: padding, count: 64) + tail
        #expect(identity.utf8.count > 128 && UntrustedTextSanitizer.withheldTerm(identity) == nil)
        var input = try Self.routeInput("rte.x", binding: .confirmed, presence: .present)
        input.route.device = DeviceID(validated: "dev.a")
        var inputs = Snapshot.Inputs(graph: Self.emptyGraph, routes: [input])
        inputs.hardwareIdentifiers = [identity]
        let snapshot = Snapshot.build(from: inputs)
        let route = try #require(snapshot.route(RouteID(validated: "rte.x")))
        #expect(route.device == nil && route.isDeviceWithheld)
        #expect(snapshot.truncation.withheldOverflow == 0 && !snapshot.truncation.isTruncated)
        let json = try #require(String(data: Self.encode(snapshot), encoding: .utf8))
        #expect(!json.contains("dev.a"))
    }

    /// Both sides use the same bounded pipeline: a padded compared value matches a plain
    /// identity, a padded identity matches a plain value, and a padded value that matches
    /// nothing is no longer refused by its raw length.
    @Test func paddedValuesAndIdentitiesShareOneBoundedForm() {
        let padded = "dev.a" + String(repeating: "\u{200B}", count: 64)
        let joined = "dev." + String(repeating: "\u{FE0F}\u{2060}\u{00AD}", count: 30) + "A"
        #expect(RefusedIdentities.form(padded) == RefusedIdentities.form("dev.a"))
        #expect(RefusedIdentities(["dev.a"], terms: []).refuses(padded))
        #expect(RefusedIdentities(["dev.a"], terms: []).refuses(joined))
        #expect(RefusedIdentities([joined], terms: []).refuses("dev.a"))
        #expect(!RefusedIdentities(["dev.b"], terms: []).refuses(padded))
        #expect(!RefusedIdentities(["dev.b"], terms: []).refuses(joined))
    }

    /// Bounded filtering completes at exactly `maximumIdentityScalars` kept scalars, so a
    /// long but finite identity still refuses `dev.a`. One more kept scalar and its form is
    /// unknown: as a compared value it is refused, and as a withheld identity it is counted
    /// in `withheldOverflow` instead of being dropped (its fail-closed term still refuses).
    @Test func anIdentityTooLongToFilterIsCountedNotDropped() throws {
        let limit = RefusedIdentities.maximumIdentityScalars
        let fits = String(repeating: " ", count: limit - 5) + "DEV.A"
        let over = String(repeating: " ", count: limit - 4) + "DEV.A"
        #expect(RefusedIdentities.identityForm(fits).scalars != nil && RefusedIdentities.identityForm(over) == .unknown)
        #expect(RefusedIdentities.none.refuses(over) && !RefusedIdentities.none.refuses("dev.a"))
        var input = try Self.routeInput("rte.x", binding: .confirmed, presence: .present)
        input.route.device = DeviceID(validated: "dev.a")
        var inputs = Snapshot.Inputs(graph: Self.emptyGraph, routes: [input])
        for (identity, overflow) in [(fits, 0), (over, 1)] {
            inputs.hardwareIdentifiers = [identity]
            let assembly = NeutralSnapshotAssembly(inputs: inputs, limits: Snapshot.Limits())
            #expect(assembly.withheld == (overflow == 0 ? [fits] : []) && assembly.withheldOverflow == overflow)
            let snapshot = Snapshot.build(from: inputs)
            #expect(snapshot.truncation.withheldOverflow == overflow)
            #expect(snapshot.truncation.isTruncated == (overflow > 0))
            let route = try #require(snapshot.route(RouteID(validated: "rte.x")))
            #expect(route.device == nil && route.isDeviceWithheld)
        }
    }
}

// MARK: - Round 12b: early-out, prefix terms, trailing padding

extension NeutralSnapshotTests {
    /// A trimmed source of more than `maximumIdentityFormBytes` scalars is too long without
    /// building its form, complete or not, and is not counted. One that is cut by the filter
    /// but whose kept core still fits is unknown and counted.
    @Test func identityFormsTooLongToFitAreNotCounted() throws {
        let limit = RefusedIdentities.maximumIdentityFormBytes
        let dees = { (count: Int) in String(repeating: "d", count: count) }
        let spaces = { (count: Int) in String(repeating: " ", count: count) }
        let cases: [(String, RefusedIdentities.IdentityForm)] = [
            (dees(limit), .form(Array(dees(limit).unicodeScalars))), (dees(limit + 1), .tooLong),
            (spaces(800) + dees(limit), .form(Array(dees(limit).unicodeScalars))),
            (String(repeating: "\u{00E9}", count: 65), .tooLong), (String(repeating: "Q7", count: 570), .tooLong),
            (spaces(896) + dees(limit + 1), .unknown), (spaces(895) + dees(limit + 2), .tooLong)
        ]
        for (identity, expected) in cases {
            #expect(RefusedIdentities.identityForm(identity) == expected, "\(identity.unicodeScalars.count)")
        }
        var input = try Self.routeInput("rte.x", binding: .confirmed, presence: .present)
        input.route.evidence = String(repeating: "Q7", count: 570)
        let snapshot = Snapshot.build(from: Snapshot.Inputs(graph: Self.emptyGraph, routes: [input]))
        #expect(snapshot.truncation.withheldOverflow == 0 && !snapshot.truncation.isTruncated)
    }

    /// An identity cut by the filter whose kept core still fits is refused through its prefix
    /// term, not the equality path: only routes that term matches are withheld.
    @Test(arguments: [(1_014, 0, "DEV.IFACE"), (0, 1_014, "DEV.IFACE-B")])
    func aLongIdentityRefusesThroughItsPrefixTerm(lead: Int, trail: Int, term: String) throws {
        let identity = String(repeating: " ", count: lead) + "DEV.IFACE-B" + String(repeating: " ", count: trail)
        #expect(RefusedIdentities.identityForm(identity) == .unknown)
        #expect(UntrustedTextSanitizer.withheldTerm(identity) == .init(text: term, isPrefix: true))
        var first = try Self.routeInput("rte.x", binding: .confirmed, presence: .present)
        first.route.device = DeviceID(validated: "dev.iface-b")
        var second = try Self.routeInput("rte.y", binding: .confirmed, presence: .present)
        second.route.device = DeviceID(validated: "dev.phone-audio")
        var inputs = Snapshot.Inputs(graph: Self.emptyGraph, routes: [first, second])
        inputs.hardwareIdentifiers = [identity]
        let snapshot = Snapshot.build(from: inputs)
        let withheld = try #require(snapshot.route(RouteID(validated: "rte.x")))
        #expect(withheld.device == nil && withheld.isDeviceWithheld)
        #expect(snapshot.route(RouteID(validated: "rte.y"))?.device?.rawValue == "dev.phone-audio")
        #expect(snapshot.truncation.withheldOverflow == 1 && snapshot.truncation.isTruncated)
    }

    /// Filtering stops only at a scalar it would keep, so removable padding after the last
    /// counted scalar never makes the form unknown.
    @Test func trailingRemovablePaddingKeepsTheFormKnown() throws {
        let identity = String(repeating: " ", count: 1_019) + "DEV.A" + "\u{200B}"
        #expect(RefusedIdentities.identityForm(identity) == .form(Array("dev.a".unicodeScalars)))
        #expect(UntrustedTextSanitizer.filterScalars("abc\u{200B}\u{2060}".unicodeScalars, keeping: 3).isComplete)
        #expect(!UntrustedTextSanitizer.filterScalars("abc\u{200B}d".unicodeScalars, keeping: 3).isComplete)
        var input = try Self.routeInput("rte.x", binding: .confirmed, presence: .present)
        input.route.device = DeviceID(validated: "dev.a")
        var inputs = Snapshot.Inputs(graph: Self.emptyGraph, routes: [input])
        inputs.hardwareIdentifiers = [identity]
        let snapshot = Snapshot.build(from: inputs)
        let route = try #require(snapshot.route(RouteID(validated: "rte.x")))
        #expect(route.device == nil && route.isDeviceWithheld)
        #expect(snapshot.truncation.withheldOverflow == 0 && !snapshot.truncation.isTruncated)
    }
}
