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
        ("a\u{3164}b\u{115F}c\u{1160}d\u{FFA0}e\u{2800}f", "abcdef"),
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
        #expect(label.text == "e" + String(repeating: "\u{0301}", count: 7) + "x")
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
    /// scan keeps of the fifth copy would fit in a 200-byte label.
    @Test(arguments: [
        (0, ""), (88, String(repeating: "x", count: 88)), (89, String(repeating: "x", count: 89) + "ser")
    ])
    func aUIDCutByTheScanLimitLeavesNoPrefix(padding: Int, tail: String) {
        let serial = Self.thousandByteSerial
        let raw = "Rig " + String(repeating: serial, count: 4) + String(repeating: "x", count: padding)
            + serial.lowercased()
        let label = UntrustedLabel(raw, maximumBytes: 200, withholding: [serial])
        let marker = UntrustedLabel.withheldMarker
        // Adjacent copies merge into one marker.
        #expect(label.text == "Rig " + marker + tail)
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
}
