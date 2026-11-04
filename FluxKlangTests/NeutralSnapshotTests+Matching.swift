import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension NeutralSnapshotTests {
    // MARK: - Joiner-free match form

    @Test(arguments: [
        ("Apple\u{200D}USBAudioEngine:WING:ABCD1234", "[withheld]"),
        ("Apple\u{200C}USBAudioEngine:WING:ABCD1234", "[withheld]"),
        ("👩\u{200D}💻 apple\u{200D}usbaudioengine:wing:abcd1234", "👩💻 [withheld]")
    ])
    func joinersInsideAWithheldStringDoNotHideIt(raw: String, expected: String) {
        let label = UntrustedLabel(raw, withholding: ["AppleUSBAudioEngine:WING:ABCD1234"])
        #expect(label.text == expected)
        #expect(label.text.unicodeScalars.allSatisfy { !UntrustedTextSanitizer.isJoiner($0) })
        #expect(label.wasSanitized && !label.isTruncated)
    }

    @Test(arguments: [
        "می\u{200C}خواهم", "👨\u{200D}👩\u{200D}👧\u{200D}👦 Mix", "❤\u{FE0F}\u{200D}🔥"
    ])
    func joinersAreKeptWhenNothingIsWithheld(raw: String) {
        let label = UntrustedLabel(raw, withholding: ["AppleUSBAudioEngine:WING:ABCD1234", "Mix-ABCD1234"])
        #expect(label.text.unicodeScalars.elementsEqual(raw.unicodeScalars))
        #expect(!label.wasSanitized && !label.isTruncated)
    }

    @Test func keptJoinersDoNotCountTowardTheScanLimit() {
        let raw = String(repeating: "a\u{200D}", count: 3) + "a"
        let scan = UntrustedTextSanitizer.filterScalars(raw.unicodeScalars, keeping: 4)
        #expect(scan.isComplete && scan.text == raw)
        #expect(!UntrustedTextSanitizer.filterScalars(raw.unicodeScalars, keeping: 3).isComplete)
    }

    @Test func aJoinedUIDCutByTheScanLimitLeavesNoPrefix() {
        let serial = Self.thousandByteSerial
        let joined = "SE\u{200D}RI\u{200C}AL" + serial.dropFirst(6)
        let raw = "Rig " + String(repeating: serial, count: 4) + joined
        let label = UntrustedLabel(raw, maximumBytes: 200, withholding: [serial])
        #expect(label.text == "Rig " + String(repeating: UntrustedLabel.withheldMarker, count: 4))
        #expect(label.isTruncated && label.wasSanitized)
    }

    // MARK: - Withheld-string normalization

    @Test func withheldStringsAreNormalizedLikeLabels() throws {
        var route = try Self.routeInput("rte.a", binding: .confirmed, presence: .present)
        route.route.evidence = "a\tb/longer"
        let nodes = try [
            Self.node("node.a", label: "Seen a b/longer"),
            Self.node("node.b", label: "Café-Rig 1"),
            Self.node("node.c", label: "Rig\u{200B}-Y\u{0301}-2 x")
        ]
        var inputs = try Snapshot.Inputs(graph: GraphDocument(id: GraphID(validated: "graph.n"), nodes: nodes))
        inputs.routes = [route]
        inputs.hardwareIdentifiers = ["Cafe\u{0301}-Rig", "Rig-\u{00DD}-2"]
        let snapshot = Snapshot.build(from: inputs)
        let marker = UntrustedLabel.withheldMarker
        #expect(snapshot.nodes.map(\.label.text) == ["Seen \(marker)", "\(marker) 1", "\(marker) x"])
        #expect(UntrustedTextSanitizer.withheldTerm(" Ca\u{200D}fe\u{0301}-Rig\n")?.text == "Café-Rig")
    }

    @Test func rawWithheldStringsPassedToALabelAreNormalized() {
        let label = UntrustedLabel("Seen a b/longer at Café-Rig", withholding: ["a\tb/longer", " Cafe\u{0301}-Rig "])
        let marker = UntrustedLabel.withheldMarker
        #expect(label.text == "Seen \(marker) at \(marker)")
        for raw in ["a\tb/longer", "Ca\u{200D}fe\u{0301}-Rig", Self.thousandByteSerial] {
            let term = UntrustedTextSanitizer.withheldTerm(raw)
            #expect(term != nil && UntrustedTextSanitizer.withheldTerm(term?.text ?? "") == term)
        }
    }

    // MARK: - Withheld caps

    @Test func overlongWithheldStringsRedactFromTheirPrefixToTheEnd() throws {
        let secret = String(repeating: "Q7", count: 1_500)
        let term = try #require(UntrustedTextSanitizer.withheldTerm(secret))
        #expect(term.isPrefix && term.text.utf8.count == UntrustedTextSanitizer.maximumWithheldBytes - 1)
        var inputs = try Snapshot.Inputs(graph: GraphDocument(
            id: GraphID(validated: "graph.c"), nodes: [Self.node("node.a", label: "Rig " + secret.lowercased() + " ok")]
        ))
        inputs.hardwareIdentifiers = [secret]
        let label = Snapshot.build(from: inputs).node(Self.nodeA)?.label
        #expect(label?.text == "Rig \(UntrustedLabel.withheldMarker)")
        let cut = try #require(UntrustedTextSanitizer.withheldTerm(String(repeating: "a", count: 1_023) + "e\u{0301}"))
        #expect(cut.isPrefix && cut.text == String(repeating: "a", count: 1_023))
        let wide = try #require(UntrustedTextSanitizer.withheldTerm(String(repeating: "Ж", count: 800)))
        #expect(wide.isPrefix && wide.text == String(repeating: "Ж", count: 511))
    }

    @Test func withheldStringsAreCollectedUpToTheCountCap() throws {
        let cap = NeutralSnapshotAssembly.maximumWithheldCount
        var inputs = Snapshot.Inputs(graph: Self.emptyGraph)
        inputs.hardwareIdentifiers = Self.serials(0...cap)
        var route = try Self.routeInput("rte.b", binding: .confirmed, presence: .present)
        route.route.evidence = "late evidence"
        var first = try Self.routeInput("rte.a", binding: .confirmed, presence: .present)
        first.route.evidence = "first evidence"
        inputs.routes = [route, first]
        let collected = NeutralSnapshotAssembly.collectWithheld(inputs)
        #expect(collected.strings == Self.serials(0..<cap) && collected.overflow == 3)
        let snapshot = Snapshot.build(from: inputs)
        #expect(snapshot.truncation.withheldOverflow == 3 && snapshot.truncation.isTruncated)
        inputs.hardwareIdentifiers = ["serial-0", "serial-0"]
        let few = NeutralSnapshotAssembly.collectWithheld(inputs)
        #expect(few.strings == ["serial-0", "first evidence", "late evidence"] && few.overflow == 0)
        #expect(Snapshot.build(from: inputs).truncation.withheldOverflow == 0)
        inputs.routes = [route]
        let long = String(repeating: "d", count: NeutralSnapshotAssembly.maximumRefusedBytes + 1)
        inputs.hardwareIdentifiers = [long, "dev.iface-z"]
        let assembly = NeutralSnapshotAssembly(inputs: inputs, limits: Snapshot.Limits())
        #expect(assembly.withheld == ["dev.iface-z", "late evidence"] && assembly.redacted.count == 3)
    }

    @Test func theWithheldCapIsIndependentOfHardwareInputOrder() {
        let cap = NeutralSnapshotAssembly.maximumWithheldCount
        let serials = Self.serials(0..<(cap + 6))
        var inputs = Snapshot.Inputs(graph: Self.emptyGraph)
        inputs.hardwareIdentifiers = serials.reversed()
        let reversed = NeutralSnapshotAssembly.collectWithheld(inputs)
        inputs.hardwareIdentifiers = serials.shuffled()
        let shuffled = NeutralSnapshotAssembly.collectWithheld(inputs)
        #expect(reversed.strings == Array(serials.prefix(cap)) && reversed.overflow == 6)
        #expect(shuffled.strings == reversed.strings && shuffled.overflow == 6)
        inputs.hardwareIdentifiers = ["Rig-Alpha\u{200B}", "\tRig-Bravo", "Rig-Alpha"]
        let prepared = NeutralSnapshotAssembly.collectWithheld(inputs).strings
        #expect(prepared == ["Rig-Alpha", "Rig-Alpha\u{200B}", "\tRig-Bravo"])
    }

    static func serials(_ range: some Sequence<Int>) -> [String] {
        range.map { "serial-" + String(repeating: "0", count: max(0, 4 - String($0).count)) + String($0) }
    }
}
