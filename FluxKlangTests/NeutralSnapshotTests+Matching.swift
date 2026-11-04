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
        let selected = "😀\u{FE0F}😀"
        #expect(UntrustedTextSanitizer.filterScalars(selected.unicodeScalars, keeping: 2).isComplete)
    }

    @Test func aJoinedUIDCutByTheScanLimitLeavesNoPrefix() {
        let serial = Self.thousandByteSerial
        let joined = "SE\u{200D}RI\u{200C}AL" + serial.dropFirst(6)
        let raw = "Rig " + String(repeating: serial, count: 4) + joined
        let label = UntrustedLabel(raw, maximumBytes: 200, withholding: [serial])
        #expect(label.text == "Rig " + UntrustedLabel.withheldMarker)
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

    // MARK: - Round 5

    @Test func deviceIDsRefusedByTheAliasFormAreRedactedFromLabels() throws {
        let uuid = "6F1D2C8A-3B4E-4F50-9A61-7C8D9E0F1A2B"
        var route = try Self.routeInput("rte.uuid", binding: .proposed, presence: nil)
        route.route.device = try DeviceID(uuid)
        let alias = try Self.routeInput("rte.alias", binding: .proposed, presence: nil)
        let node = try Self.node("node.a", label: "Rig \(uuid.lowercased()) on dev.interface-b")
        var inputs = Snapshot.Inputs(graph: GraphDocument(id: GraphID(validated: "graph.d"), nodes: [node]))
        inputs.routes = [route, alias]
        inputs.diagnostics = try [Self.diagnostic("dgn.a", .warning, summary: "Lost \(uuid)")]
        let snapshot = Snapshot.build(from: inputs)
        let marker = UntrustedLabel.withheldMarker
        #expect(snapshot.node(Self.nodeA)?.label.text == "Rig \(marker) on dev.interface-b")
        #expect(snapshot.diagnostics.map(\.summary.text) == ["Lost \(marker)"])
        #expect(snapshot.route(RouteID(validated: "rte.uuid"))?.isDeviceWithheld == true)
        let json = try #require(String(data: Self.encode(snapshot), encoding: .utf8))
        #expect(!json.localizedCaseInsensitiveContains(uuid) && json.contains("dev.interface-b"))
    }

    @Test(arguments: [
        ("SN-12\u{FE0F}3456", "SN-123456"),
        ("SN-12\u{FE0E}3456", "SN-123456"),
        ("SN-123456", "SN-12\u{FE0F}3456"),
        ("SN-123456", "SN-12\u{E0100}34\u{FE00}56\u{180B}")
    ])
    func variationSelectorsDoNotHideAWithheldString(raw: String, withheld: String) {
        let label = UntrustedLabel(raw, withholding: [withheld])
        #expect(label.text == UntrustedLabel.withheldMarker && label.wasSanitized)
        let kept = UntrustedLabel("SN-12\u{FE0F}34", withholding: [withheld])
        #expect(kept.text.unicodeScalars.elementsEqual("SN-12\u{FE0F}34".unicodeScalars) && !kept.wasSanitized)
    }

    @Test func theMatchFormIsNFCAfterJoinersAreRemoved() throws {
        let label = UntrustedLabel("\u{1100}\u{200D}\u{1161}나다", withholding: ["가나다"])
        #expect(label.text == UntrustedLabel.withheldMarker)
        let raw = "\u{1100}\u{200D}\u{1161}\u{FE0F}나다"
        let form = UntrustedTextSanitizer.matchForm(raw)
        #expect(form.unicodeScalars.elementsEqual("가나다".unicodeScalars))
        #expect(UntrustedTextSanitizer.matchForm(form).unicodeScalars.elementsEqual(form.unicodeScalars))
        let term = try #require(UntrustedTextSanitizer.withheldTerm(raw))
        #expect(term.text.unicodeScalars.elementsEqual("가나다".unicodeScalars))
        #expect(UntrustedTextSanitizer.withheldTerm(term.text) == term)
        let unmatched = UntrustedLabel("Cafe\u{0301} \u{1100}\u{1161}", withholding: ["가나다"]).text
        #expect(unmatched.unicodeScalars.elementsEqual("Café 가".unicodeScalars))
    }

    @Test func overlappingWithheldStringsLeaveNoTail() {
        let run = String(repeating: "A", count: 1_024)
        for withheld in [[run, run + "SECRET-TAIL"], [run + "SECRET-TAIL", run]] {
            let label = UntrustedLabel("Rig " + run + "SECRET-TAIL", withholding: withheld)
            #expect(label.text == "Rig \(UntrustedLabel.withheldMarker)")
        }
    }

    @Test func overlappingCopiesOfOneTermAreAllRedacted() {
        let label = UntrustedLabel("abcabcabcab", withholding: ["abcabcab"])
        #expect(label.text == UntrustedLabel.withheldMarker && label.wasSanitized)
    }

    @Test func noWholeWithheldTermSurvivesInAnyOrder() {
        let terms = ["AAAAAA-1", "a-1-secret", "SECRET-TAIL", "TAIL-END-9"]
        let raw = "x AAAAAA-1-SECRET-TAIL-END-9 y SECRET-TAIL-END-9AAAAAA-1 z"
        let marker = UntrustedLabel.withheldMarker
        for order in Self.permutations(terms) {
            let text = UntrustedLabel(raw, withholding: order).text
            #expect(text == "x \(marker) y \(marker) z")
            #expect(!order.contains { text.localizedCaseInsensitiveContains($0) })
            let prefix = UntrustedTextSanitizer.WithheldTerm(text: "SECRET-T", isPrefix: true)
            let terms = UntrustedTextSanitizer.withheldTerms(order) + [prefix]
            let redacted = UntrustedTextSanitizer.redact(raw, withheld: terms.reversed(), marker: marker)
            #expect(redacted.text == "x \(marker)" && redacted.changed)
        }
    }

    @Test func routesSharingAnIDContributeWithheldStringsInAFixedOrder() throws {
        let cap = NeutralSnapshotAssembly.maximumWithheldCount
        var serial = try Self.routeInput("rte.a", binding: .proposed, presence: nil)
        serial.route.device = try DeviceID("SN-0001-A")
        var evidence = try Self.routeInput("rte.a", binding: .confirmed, presence: .present)
        evidence.route.evidence = "evidence-two"
        var inputs = try Snapshot.Inputs(graph: GraphDocument(
            id: GraphID(validated: "graph.t"), nodes: [Self.node("node.a", label: "SN-0001-A evidence-two")]
        ))
        inputs.hardwareIdentifiers = Self.serials(0..<(cap - 1))
        inputs.routes = [evidence, serial]
        let forward = NeutralSnapshotAssembly.collectWithheld(inputs)
        let snapshot = Snapshot.build(from: inputs)
        inputs.routes.reverse()
        #expect(NeutralSnapshotAssembly.collectWithheld(inputs) == forward)
        #expect(Snapshot.build(from: inputs) == snapshot)
        #expect(forward.strings.last == "SN-0001-A" && forward.overflow == 1)
        #expect(snapshot.node(Self.nodeA)?.label.text == "\(UntrustedLabel.withheldMarker) evidence-two")
    }

    static func permutations(_ items: [String]) -> [[String]] {
        guard items.count > 1 else { return [items] }
        return items.indices.flatMap { index in
            var rest = items
            let first = rest.remove(at: index)
            return permutations(rest).map { [first] + $0 }
        }
    }

    static func serials(_ range: some Sequence<Int>) -> [String] {
        range.map { "serial-" + String(repeating: "0", count: max(0, 4 - String($0).count)) + String($0) }
    }
}
