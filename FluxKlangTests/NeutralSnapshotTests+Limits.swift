import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension NeutralSnapshotTests {
    @Test func duplicatePortsAreDroppedAndCounted() throws {
        let node = try Self.node("node.a", ports: ["port.b", "port.a", "port.b", "port.c"])
        let snapshot = Snapshot.build(from: Snapshot.Inputs(graph: GraphDocument(
            id: GraphID(validated: "graph.p"), nodes: [node]
        )))
        #expect(snapshot.node(Self.nodeA)?.ports.map(\.id.rawValue) == ["port.a", "port.c"])
        #expect(snapshot.truncation.ports == Snapshot.CategoryCount(
            offered: 4, kept: 2, droppedOverLimit: 0, droppedDuplicates: 2
        ))
    }

    @Test func tiesUnderCapsBreakByIDAfterDroppingDuplicates() throws {
        let records = try ["dgn.1", "dgn.4", "dgn.2", "dgn.1", "dgn.5", "dgn.3"].map {
            try Self.diagnostic($0, .warning)
        }
        let routes = try ["rte.c", "rte.a", "rte.a", "rte.d", "rte.b"].map {
            try Self.routeInput($0, binding: .confirmed, presence: .present)
        }
        var limits = Snapshot.Limits()
        limits.diagnostics = 2
        limits.routes = 2
        for _ in 0..<5 {
            let snapshot = Snapshot.build(
                from: Snapshot.Inputs(
                    graph: Self.emptyGraph, routes: routes.shuffled(), diagnostics: records.shuffled()
                ),
                limits: limits
            )
            #expect(snapshot.diagnostics.map(\.id.rawValue) == ["dgn.2", "dgn.3"])
            #expect(snapshot.truncation.diagnostics == Snapshot.CategoryCount(
                offered: 6, kept: 2, droppedOverLimit: 2, droppedDuplicates: 2
            ))
            #expect(snapshot.routes.map(\.id.rawValue) == ["rte.b", "rte.c"])
            #expect(snapshot.truncation.routes.droppedDuplicates == 2)
            #expect(snapshot.truncation.routes.droppedOverLimit == 1)
        }
    }

    @Test func portLabelsAreSanitizedAndCounted() throws {
        var node = try Self.node("node.a", label: "Plain")
        node.ports[0].label = "In\u{202E}\u{0}" + String(repeating: "x", count: 200)
        node.ports[1].label = nil
        let snapshot = Snapshot.build(from: Snapshot.Inputs(graph: GraphDocument(
            id: GraphID(validated: "graph.s"), nodes: [node]
        )))
        let label = try #require(snapshot.node(Self.nodeA)?.ports.first?.label)
        #expect(label.text.hasPrefix("In x") && label.text.utf8.count == 128)
        #expect(label.isTruncated && label.wasSanitized)
        #expect(snapshot.node(Self.nodeA)?.ports.last?.label == nil)
        #expect(snapshot.truncation.sanitizedLabels == 1 && snapshot.truncation.truncatedLabels == 1)
    }

    @Test func nonPositiveLimitsAreClampedToKeepNothing() throws {
        let limits = Snapshot.Limits(
            nodes: 0, portsPerNode: -1, edges: -5, parameters: 0, routes: -1, diagnostics: 0, labelBytes: -3
        )
        let snapshot = try Snapshot.build(from: Self.sampleInputs(), limits: limits)
        #expect(snapshot.nodes.isEmpty && snapshot.edges.isEmpty && snapshot.parameters.isEmpty)
        #expect(snapshot.routes.isEmpty && snapshot.diagnostics.isEmpty)
        #expect(snapshot.truncation.nodes.droppedOverLimit == 3 && snapshot.truncation.edges.droppedDangling == 2)
        #expect(snapshot.truncation.routes.droppedOverLimit == 3 && snapshot.truncation.diagnostics.isTruncated)
        #expect(snapshot.graph.label == UntrustedLabel("Main", maximumBytes: 0))
        #expect(snapshot.graph.label?.text == "" && snapshot.graph.label?.isTruncated == true)
        #expect(UntrustedLabel("abc", maximumBytes: -1) == UntrustedLabel("abc", maximumBytes: 0))
    }

    @Test func encodedShapeIsPinned() throws {
        var port = GraphPort(id: Self.portIn, direction: .input, signal: .audio, label: "In")
        port.extensions = ["x": .string("dropped")]
        let node = GraphNode(id: Self.nodeA, kind: .plugin, label: "A", ports: [port])
        var limits = Snapshot.Limits()
        limits.nodes = 4
        let inputs = try Snapshot.Inputs(
            graph: GraphDocument(id: GraphID(validated: "graph.g"), nodes: [node]),
            routes: [Self.routeInput("rte.a", binding: .confirmed, presence: nil)],
            diagnostics: [
                Self.diagnostic("dgn.a", .error, summary: "S", subject: .port(node: Self.nodeA, port: Self.portIn)),
                Self.diagnostic("dgn.b", .info, summary: "T"),
                Self.diagnostic("dgn.c", .warning, summary: "U", subject: .graph)
            ]
        )
        let data = try Self.encode(Snapshot.build(from: inputs, limits: limits))
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json == Self.golden)
    }

    // MARK: - Round 10: graphemes of the final text

    /// The label postcondition: every grapheme of the final text has at most eight
    /// scalars, the text fits the byte cap, and it is non-empty when the input had an
    /// admissible grapheme.
    static func meetsLabelPostcondition(_ raw: String, withholding: [String] = [], maximumBytes: Int = 128) -> Bool {
        let label = UntrustedLabel(raw, maximumBytes: maximumBytes, withholding: withholding)
        let admissible = !UntrustedLabel(raw, maximumBytes: 1_000_000, withholding: withholding).text.isEmpty
        return label.text.allSatisfy { $0.unicodeScalars.count <= UntrustedTextSanitizer.maximumScalarsPerGrapheme }
            && label.text.utf8.count <= maximumBytes && label.text.isEmpty != admissible
    }

    @Test func cappedPrependRunsDoNotMergeIntoAnOversizedGrapheme() {
        let prepends = { (count: Int) in String(repeating: "\u{0D4E}", count: count) }
        let raw = String(repeating: prepends(8) + "a", count: 6) + "b"
        let label = UntrustedLabel(raw)
        #expect(Self.meetsLabelPostcondition(raw))
        // Each oversized run loses only its excess Prepend scalar; the 22-byte graphemes then
        // fill the 128-byte cap after five copies.
        #expect(label.text == String(repeating: prepends(7) + "a", count: 5) && label.isTruncated)
        #expect(UntrustedLabel(raw, maximumBytes: 512).text == String(repeating: prepends(7) + "a", count: 6) + "b")
    }

    @Test func anOversizedPrependRunKeepsTheTextAfterIt() {
        let prepends = { (count: Int) in String(repeating: "\u{0D4E}", count: count) }
        let acutes = { (count: Int) in String(repeating: "\u{0301}", count: count) }
        let cases = [
            ("Rig " + prepends(9) + " ab", "Rig " + prepends(7) + " ab"),
            ("Rig " + prepends(9) + "ab", "Rig " + prepends(7) + "ab"),
            ("Rig " + prepends(20) + "x yz", "Rig " + prepends(7) + "x yz"),
            ("Rig " + prepends(20), "Rig " + prepends(8)),
            (prepends(3) + "q" + acutes(9) + "z", "q" + acutes(7) + "z"),
            // The scalars nearest the base are kept: 7 of the 9 leading Prepend scalars fit.
            ("Rig " + prepends(4) + String(repeating: "\u{11A84}", count: 5) + "a",
             "Rig " + prepends(2) + String(repeating: "\u{11A84}", count: 5) + "a"),
            // Dropping the Prepend run lets the marks join "a"; the merged grapheme is capped again.
            ("a" + prepends(9) + acutes(9) + "z", "a" + acutes(7) + "z")
        ]
        for (raw, expected) in cases {
            #expect(UntrustedLabel(raw).text == expected)
            #expect(Self.meetsLabelPostcondition(raw))
        }
    }

    /// A rematch drops the ZWJ between the jamo runs, which then merge (L+V composes) into
    /// a nine-scalar grapheme; only the re-cap after the rematch brings it back to eight.
    @Test func aRematchThatMergesGraphemesIsCappedAgain() {
        let marks = "\u{0301}\u{0302}\u{0303}\u{0304}\u{0306}\u{0307}\u{0308}"
        let jamo = String(repeating: "\u{1100}", count: 5) + "\u{200D}" + String(repeating: "\u{1161}", count: 5)
        let raw = "R " + jamo + " q" + marks + "\u{030A}" + "XYZ12"
        let term = "q" + marks + "XYZ12"
        let label = UntrustedLabel(raw, withholding: [term])
        let merged = String(repeating: "\u{1100}", count: 4) + "\u{AC00}" + String(repeating: "\u{1161}", count: 3)
        #expect(label.text == "R " + merged + " " + UntrustedLabel.withheldMarker)
        #expect(Self.meetsLabelPostcondition(raw, withholding: [term]))
        // Withholding the whole label minus U+030A withholds all of it once capping completes the match.
        #expect(UntrustedLabel(raw, withholding: ["R " + jamo + " " + term]).text == UntrustedLabel.withheldMarker)
    }

    @Test(arguments: [0x0600, 0x0601, 0x0602, 0x0603, 0x0604, 0x0605, 0x06DD, 0x070F, 0x0D4E, 0x110BD])
    func prependRunsStayWithinTheGraphemeCap(value: UInt32) throws {
        let prepend = String(try #require(Unicode.Scalar(value)))
        let runs = [
            String(repeating: String(repeating: prepend, count: 9) + "a", count: 6) + "b",
            "Rig " + String(repeating: prepend, count: 12),
            "Rig " + String(repeating: prepend, count: 9) + "ab",
            String(repeating: prepend + "x\u{0301}\u{0323}", count: 20),
            String(repeating: String(repeating: prepend, count: 7) + "\u{1F1E8}\u{1F1E6}", count: 8),
            String(repeating: String(repeating: prepend, count: 8) + "👩\u{200D}👩\u{200D}👧", count: 6),
            String(repeating: String(repeating: prepend, count: 8) + "SN-1234", count: 4)
        ]
        for raw in runs {
            #expect(Self.meetsLabelPostcondition(raw, withholding: ["SN-1234"]), "\(raw.unicodeScalars.count)")
        }
    }

    @Test func aFirstGraphemeThatCannotFitIsWithheldNotEmptied() {
        let family = "👩\u{200D}👩\u{200D}👧\u{200D}👦"
        #expect(UntrustedLabel(family, maximumBytes: 12).text == UntrustedLabel.withheldMarker)
        // The marker is ten bytes: it fits a ten-byte cap exactly, and not a nine-byte one.
        #expect(UntrustedLabel(family, maximumBytes: 10).text == UntrustedLabel.withheldMarker)
        let nine = UntrustedLabel(family, maximumBytes: 9)
        #expect(nine.text.isEmpty && nine.isTruncated)
        let tiny = UntrustedLabel(family, maximumBytes: 5)
        #expect(tiny.text.isEmpty && tiny.isTruncated)
    }

    @Test func seededFuzzMeetsTheLabelPostcondition() {
        let alphabet = [
            "\u{0D4E}", "\u{0600}", "\u{110BD}", "a", "Z", "\u{0301}", "\u{0323}", "\u{1F1E8}", "\u{1F1E6}",
            "👩", "\u{200D}", "\u{FE0F}", "\u{1100}", "\u{1161}", "\u{11A8}", " ", "SN-1234", "[", "\u{0001}",
            "\u{200B}", "é", "9", "\u{0E33}", "\u{0903}", String(repeating: "\u{0D4E}", count: 8)
        ]
        var generator = SplitMix64(seed: 0x118_0010)
        for _ in 0..<2_000 {
            let count = Int.random(in: 0...80, using: &generator)
            let raw = (0..<count).map { _ in alphabet.randomElement(using: &generator) ?? "" }.joined()
            #expect(Self.meetsLabelPostcondition(raw, withholding: ["SN-1234"]), "\(Array(raw.unicodeScalars))")
        }
    }
}

/// A fixed-seed generator, so the fuzz cases are the same on every run.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
