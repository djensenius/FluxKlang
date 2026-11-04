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
