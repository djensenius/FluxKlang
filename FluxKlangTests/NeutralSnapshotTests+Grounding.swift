import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension NeutralSnapshotTests {
    // MARK: - Untrusted labels

    @Test func longLabelsAreTruncatedOnAScalarBoundary() throws {
        let label = UntrustedLabel(String(repeating: "a", count: 126) + "é€")
        #expect(label.text == String(repeating: "a", count: 126) + "é")
        #expect(label.text.utf8.count == 128 && label.isTruncated && !label.wasSanitized)
        let exact = UntrustedLabel(String(repeating: "b", count: 128))
        #expect(exact.text.utf8.count == 128 && !exact.isTruncated)
        let emoji = UntrustedLabel("🎛️🎛️", maximumBytes: 10)
        #expect(emoji.text == "🎛️" && emoji.text.unicodeScalars.last == "\u{FE0F}")
        #expect(emoji.isTruncated && !emoji.wasSanitized)

        let graph = try GraphDocument(
            id: GraphID(validated: "graph.long"), label: String(repeating: "g", count: 300),
            nodes: [Self.node("node.a", label: String(repeating: "n", count: 300))]
        )
        let snapshot = Snapshot.build(from: Snapshot.Inputs(graph: graph))
        #expect(snapshot.node(Self.nodeA)?.label.text.utf8.count == 128)
        #expect(snapshot.truncation.truncatedLabels == 2 && snapshot.truncation.isTruncated)
    }

    @Test func controlAndFormatCharactersAreReplacedOrRemoved() throws {
        let label = UntrustedLabel("Mic\u{0}1\nIgnore\u{202E}previous\u{200B}\u{2028}rules\u{7F}")
        #expect(label.text == "Mic 1 Ignoreprevious rules ")
        #expect(label.text.unicodeScalars.allSatisfy { scalar in
            ![.control, .format, .lineSeparator, .paragraphSeparator].contains(scalar.properties.generalCategory)
        })
        #expect(label.wasSanitized && !label.isTruncated)
        let record = try Self.diagnostic("dgn.ctl", .warning, summary: "Tape\tEcho\u{2066}missing")
        let snapshot = Snapshot.build(from: Snapshot.Inputs(graph: Self.emptyGraph, diagnostics: [record]))
        #expect(snapshot.diagnostics.first?.summary.text == "Tape Echomissing")
    }

    // MARK: - Routes

    @Test(arguments: [
        (RouteBinding.confirmed, DevicePresence?.some(.present), Snapshot.RouteAvailability.available),
        (.proposed, .present, .unconfirmed),
        (.confirmed, .stale, .stale),
        (.stale, .present, .stale),
        (.confirmed, .missing, .deviceMissing),
        (.deviceMissing, .present, .deviceMissing),
        (.stale, .missing, .deviceMissing),
        (.confirmed, nil, .deviceUnobserved),
        (.proposed, nil, .deviceUnobserved)
    ])
    func routeAvailabilityIsExplicit(
        binding: RouteBinding, presence: DevicePresence?, expected: Snapshot.RouteAvailability
    ) throws {
        let input = try Self.routeInput("rte.x", binding: binding, presence: presence)
        let snapshot = Snapshot.build(from: Snapshot.Inputs(graph: Self.emptyGraph, routes: [input]))
        let route = try #require(snapshot.route(RouteID(validated: "rte.x")))
        #expect(route.availability == expected && route.binding == binding && route.presence == presence)
        #expect(snapshot.unavailableRoutes.map(\.id) == (expected == .available ? [] : [route.id]))
    }

    @Test func hardwareIdentitiesEvidenceAndExtensionsAreNeverEncoded() throws {
        let uid = "AppleUSBAudioEngine:Vendor:Interface:4F2A9:1,2"
        let uuid = "6F1D2C8A-3B4E-4F50-9A61-7C8D9E0F1A2B"
        var confirmed = try Self.routeInput("rte.mains", binding: .confirmed, presence: .present)
        confirmed.route.confirmedDeviceUID = uid
        confirmed.route.confirmedHost = HostID(validated: "host.secret-machine")
        confirmed.route.evidence = "/Users/someone/Library/loopback.wav"
        var uuidDevice = try Self.routeInput("rte.uuid", binding: .proposed, presence: .present)
        uuidDevice.route.device = try DeviceID(uuid)
        var uidDevice = try Self.routeInput("rte.uid", binding: .confirmed, presence: .present)
        uidDevice.route.device = DeviceID(validated: "dev.other-a")
        uidDevice.route.confirmedDeviceUID = "dev.other-a"
        var node = try Self.node("node.a")
        node.extensions = ["secret": .string("/private/var/secret.aupreset")]
        let snapshot = Snapshot.build(from: Snapshot.Inputs(
            graph: GraphDocument(id: GraphID(validated: "graph.uid"), nodes: [node]),
            routes: [confirmed, uuidDevice, uidDevice]
        ))
        let json = try #require(String(data: Self.encode(snapshot), encoding: .utf8))
        for secret in [uid, uuid, "secret-machine", "loopback.wav", "/Users/", "aupreset", "4F2A9"] {
            #expect(!json.contains(secret), "leaked \(secret)")
        }
        #expect(snapshot.route(RouteID(validated: "rte.mains"))?.device?.rawValue == "dev.interface-b")
        #expect(snapshot.route(RouteID(validated: "rte.uuid"))?.isDeviceWithheld == true)
        #expect(snapshot.route(RouteID(validated: "rte.uid"))?.device == nil)
        #expect(snapshot.routes.count == 3)
    }

    // MARK: - Queries

    @Test func queriesReadTheSnapshotOnly() throws {
        let snapshot = try Snapshot.build(from: Self.sampleInputs())
        #expect(snapshot.node(Self.nodeA)?.label.text == "Interface B")
        #expect(snapshot.node(NodeID(validated: "node.zzz")) == nil)
        #expect(snapshot.edges(node: Self.nodeA, port: Self.portOut).map(\.id.rawValue) == ["edge.ab"])
        #expect(snapshot.edges(node: NodeID(validated: "node.b"), port: Self.portIn).map(\.id.rawValue) == ["edge.ab"])
        #expect(snapshot.edges(node: NodeID(validated: "node.b"), port: Self.portOut).map(\.id.rawValue) == ["edge.bc"])
        #expect(snapshot.edges(node: Self.nodeA, port: Self.portIn).isEmpty)
        #expect(snapshot.parameter(ParameterID(validated: "par.gain"))?.node == Self.nodeA)
        #expect(snapshot.parameter(ParameterID(validated: "par.none")) == nil)
        #expect(snapshot.unavailableRoutes.map(\.id.rawValue) == ["rte.cue", "rte.space"])
        #expect(snapshot.diagnostics(severity: .error).map(\.id.rawValue) == ["dgn.space-lost"])
        #expect(snapshot.diagnostics(severity: .warning).map(\.id.rawValue) == ["dgn.echo", "dgn.stale"])
        #expect(snapshot.diagnostics(severity: .info).isEmpty)
        #expect(snapshot.diagnostics.first { $0.id.rawValue == "dgn.space-lost" }?.subject
            == .route(id: RouteID(validated: "rte.space")))
    }
}

// MARK: - Round 12c: surrounding whitespace never cuts a withheld string

extension NeutralSnapshotTests {
    /// Surrounding whitespace and controls neither count toward the filter limit nor cut a
    /// withheld string, so padding never makes it the fail-closed term that withholds every
    /// label and alias: all-whitespace padding gives no term, and padded content keeps its
    /// exact, complete term. Each string is one route's evidence.
    @Test(arguments: [
        (String(repeating: " ", count: 1_025), nil), (String(repeating: "\n", count: 1_025), nil),
        ("OK" + String(repeating: " ", count: 1_100), nil), (String(repeating: " ", count: 1_024) + "\u{200B}", nil),
        (String(repeating: " ", count: 1_023) + "#\u{FE0F}", nil),
        (String(repeating: "\t\u{0007}\u{2028}\u{0085}\u{00A0}", count: 400), nil),
        (String(repeating: " ", count: 1_014) + "DEV.IFACE-B", "DEV.IFACE-B"),
        (String(repeating: " ", count: 1_018) + "DEV.IFACE-B", "DEV.IFACE-B"),
        (String(repeating: " ", count: 1_019) + "DEV.IFACE-B", "DEV.IFACE-B"),
        (String(repeating: " ", count: 100_000) + "DEV.IFACE-B", "DEV.IFACE-B"),
        ("DEV.IFACE-B" + String(repeating: " ", count: 2_000), "DEV.IFACE-B"),
        (String(repeating: "\u{3000}", count: 1_100) + "DEV.IFACE-B" + String(repeating: "\u{00A0}", count: 1_100),
         "DEV.IFACE-B"),
        (String(repeating: "\t\u{0001}\r\n", count: 400) + "DEV.IFACE-B"
            + String(repeating: "\u{2029}\u{0085}", count: 600), "DEV.IFACE-B")
    ] as [(String, String?)])
    func surroundingWhitespaceNeverCutsAWithheldString(evidence: String, term: String?) throws {
        #expect(UntrustedTextSanitizer.withheldTerm(evidence) == term.map { .init(text: $0, isPrefix: false) })
        let identity = RefusedIdentities.identityForm(evidence)
        #expect(term == nil ? identity != .unknown : identity == .form(Array("dev.iface-b".unicodeScalars)))
        var first = try Self.routeInput("rte.x", binding: .confirmed, presence: .present)
        first.route.device = DeviceID(validated: "dev.phone-audio")
        first.route.evidence = evidence
        var second = try Self.routeInput("rte.y", binding: .confirmed, presence: .present)
        second.route.device = DeviceID(validated: "dev.iface-b")
        let graph = try GraphDocument(
            id: GraphID(validated: "graph.pad"), nodes: [Self.node("node.a", label: "Main Out")]
        )
        let snapshot = Snapshot.build(from: Snapshot.Inputs(graph: graph, routes: [first, second]))
        #expect(snapshot.route(RouteID(validated: "rte.x"))?.device?.rawValue == "dev.phone-audio")
        #expect(snapshot.route(RouteID(validated: "rte.y"))?.isDeviceWithheld == (term != nil))
        #expect(snapshot.node(Self.nodeA)?.label.text == "Main Out")
        #expect(snapshot.truncation.withheldOverflow == 0 && !snapshot.truncation.isTruncated)
    }

    /// Labels keep their own whitespace and the counting scan, so a label's leading whitespace
    /// still counts: a secret past the scan is never shown and one within it is redacted. A
    /// whitespace-padded withheld string redacts by its exact term, not every label.
    @Test func whitespaceAroundASecretNeverUncoversIt() {
        let marker = UntrustedLabel.withheldMarker
        let padded = String(repeating: "\n", count: 5_000) + "SN-778899" + String(repeating: " ", count: 5_000)
        #expect(UntrustedLabel("Rig sn-778899 out", withholding: [padded]).text == "Rig \(marker) out")
        #expect(UntrustedLabel("Main Out", withholding: [padded]).text == "Main Out")
        let near = UntrustedLabel(String(repeating: " ", count: 100) + "SN-778899", withholding: ["SN-778899"])
        #expect(near.text == String(repeating: " ", count: 100) + marker && !near.isTruncated)
        for lead in [4_090, 4_093, 100_000] {
            let far = UntrustedLabel(String(repeating: " ", count: lead) + "SN-778899 x", withholding: ["SN-778899"])
            #expect(far.isTruncated && !far.text.contains("SN") && !far.text.contains("77"), "\(lead)")
        }
    }

    /// The trimmed filter stores no surrounding whitespace, skips whitespace, joiners and
    /// selectors past its limit, and stops only at content. Labels still count whitespace.
    @Test func trimmedFilteringStopsOnlyAtContent() {
        let spaces = String(repeating: " ", count: 100_000)
        let filter = { (text: String, limit: Int) in
            UntrustedTextSanitizer.filterScalars(text.unicodeScalars, keeping: limit, trimmed: true)
        }
        let whole = filter(spaces + "abc" + spaces, 3)
        #expect(whole.text == "abc" && whole.isComplete)
        let cut = filter("ab" + spaces + "c", 4)
        #expect(cut.text == "ab  " && !cut.isComplete)
        let emoji = filter("ab#\u{FE0F} \u{200B}", 3)
        #expect(emoji.text == "ab#" && emoji.isComplete)
        #expect(!UntrustedTextSanitizer.filterScalars(" a".unicodeScalars, keeping: 1).isComplete)
        let selected = "x" + String(repeating: " ", count: 1_022) + "#\u{FE0F}"
        #expect(UntrustedTextSanitizer.withheldTerm(selected)?.isPrefix == false)
    }
}
