import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension NeutralSnapshotTests {
    static let nodeA = NodeID(validated: "node.a")
    static let portIn = PortID(validated: "port.in")
    static let portOut = PortID(validated: "port.out")
    static let emptyGraph = GraphDocument(id: GraphID(validated: "graph.empty"))
    /// A 1,000-byte withheld serial, under `UntrustedTextSanitizer.maximumWithheldBytes`.
    static let thousandByteSerial = "SERIAL-" + String(repeating: "7F3A", count: 248) + "9"
    static let golden = [
        #"{"diagnostics":[{"id":"dgn.a","severity":"error","subject":{"port":{"node":"node.a","#,
        #""port":"port.in"}},"subjectInSnapshot":true,"summary":{"isTruncated":false,"text":"S","#,
        #""wasSanitized":false}},{"id":"dgn.b","severity":"info","subjectInSnapshot":true,"#,
        #""summary":{"isTruncated":false,"text":"T","wasSanitized":false}},{"id":"dgn.c","#,
        #""severity":"warning","subject":{"graph":{}},"subjectInSnapshot":true,"#,
        #""summary":{"isTruncated":false,"text":"U","wasSanitized":false}}],"edges":[],"#,
        #""graph":{"id":"graph.g","revision":0},"limits":{"diagnostics":256,"edges":2048,"#,
        #""labelBytes":128,"nodes":4,"parameters":4096,"portsPerNode":256,"routes":256},"#,
        #""nodes":[{"id":"node.a","kind":"plugin","label":{"isTruncated":false,"text":"A","#,
        #""wasSanitized":false},"portCount":{"droppedDangling":0,"droppedDuplicates":0,"#,
        #""droppedOverLimit":0,"isTruncated":false,"kept":1,"offered":1},"#,
        #""ports":[{"direction":"input","id":"port.in","label":{"isTruncated":false,"text":"In","#,
        #""wasSanitized":false},"signal":"audio"}]}],"parameters":[],"#,
        #""routes":[{"availability":"deviceUnobserved","binding":"confirmed","channelCount":2,"#,
        #""device":"dev.interface-b","direction":"output","id":"rte.a","isDeviceWithheld":false,"#,
        #""role":"role.rte.a"}],"truncation":{"diagnostics":{"droppedDangling":0,"#,
        #""droppedDuplicates":0,"droppedOverLimit":0,"isTruncated":false,"kept":3,"offered":3},"#,
        #""edges":{"droppedDangling":0,"droppedDuplicates":0,"droppedOverLimit":0,"#,
        #""isTruncated":false,"kept":0,"offered":0},"isTruncated":false,"nodes":{"droppedDangling":0,"#,
        #""droppedDuplicates":0,"droppedOverLimit":0,"isTruncated":false,"kept":1,"offered":1},"#,
        #""parameters":{"droppedDangling":0,"droppedDuplicates":0,"droppedOverLimit":0,"#,
        #""isTruncated":false,"kept":0,"offered":0},"ports":{"droppedDangling":0,"#,
        #""droppedDuplicates":0,"droppedOverLimit":0,"isTruncated":false,"kept":1,"offered":1},"#,
        #""routes":{"droppedDangling":0,"droppedDuplicates":0,"droppedOverLimit":0,"#,
        #""isTruncated":false,"kept":1,"offered":1},"sanitizedLabels":0,"truncatedLabels":0,"#,
        #""withheldOverflow":0}}"#
    ].joined()

    static func encode(_ snapshot: NeutralSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(snapshot)
    }

    static func node(_ id: String, label: String = "Node", ports: [String] = ["port.in", "port.out"]) throws
        -> GraphNode {
        try GraphNode(
            id: NodeID(id), kind: .plugin, label: label,
            ports: ports.map { try GraphPort(id: PortID($0), direction: .input, signal: .audio, label: "Port \($0)") }
        )
    }

    static func edge(_ id: String, from node: String, _ port: String, to target: String, _ input: String) throws
        -> GraphEdge {
        try GraphEdge(
            id: EdgeID(id), from: PortAddress(node: NodeID(node), port: PortID(port)),
            to: PortAddress(node: NodeID(target), port: PortID(input))
        )
    }

    static func parameter(_ id: String, node: NodeID? = nil) throws -> ParameterDescriptor {
        try ParameterDescriptor(.init(
            id: ParameterID(id), node: node, unit: .decibels, lower: -90, upper: 10, defaultValue: 0, ceiling: nil,
            curve: .linear, ramp: .step, controlClass: .live, verification: .unverified
        ))
    }

    static func routeInput(_ id: String, binding: RouteBinding, presence: DevicePresence?) throws
        -> NeutralSnapshot.RouteInput {
        let route = try AudioRoute(
            id: RouteID(id), role: RoleID("role.\(id)"), device: DeviceID("dev.interface-b"),
            direction: .output, channels: [0, 1], binding: binding
        )
        return NeutralSnapshot.RouteInput(route: route, presence: presence)
    }

    static func diagnostic(_ id: String, _ severity: DiagnosticSeverity, summary: String = "Summary",
                           subject: DiagnosticSubject? = nil) throws -> NeutralDiagnosticRecord {
        try NeutralDiagnosticRecord(id: DiagnosticID(id), severity: severity, summary: summary, subject: subject)
    }

    static func sampleInputs() throws -> NeutralSnapshot.Inputs {
        let graph = try GraphDocument(
            id: GraphID(validated: "graph.main"), revision: ContractRevision(43), label: "Main",
            nodes: [Self.node("node.a", label: "Interface B"), Self.node("node.b"), Self.node("node.c")],
            edges: [
                Self.edge("edge.bc", from: "node.b", "port.out", to: "node.c", "port.in"),
                Self.edge("edge.ab", from: "node.a", "port.out", to: "node.b", "port.in")
            ]
        )
        return try NeutralSnapshot.Inputs(
            graph: graph,
            parameters: [Self.parameter("par.gain", node: nodeA), Self.parameter("par.pan")],
            routes: [
                Self.routeInput("rte.space", binding: .confirmed, presence: .missing),
                Self.routeInput("rte.mains", binding: .confirmed, presence: .present),
                Self.routeInput("rte.cue", binding: .proposed, presence: nil)
            ],
            diagnostics: [
                Self.diagnostic("dgn.stale", .warning),
                Self.diagnostic("dgn.space-lost", .error, subject: .route(id: RouteID(validated: "rte.space"))),
                Self.diagnostic("dgn.echo", .warning, subject: .node(id: NodeID(validated: "node.b")))
            ],
            project: NeutralSnapshot.ProjectIdentity(
                id: ProjectID(validated: "prj.example"), revision: ContractRevision(7)
            )
        )
    }
}
