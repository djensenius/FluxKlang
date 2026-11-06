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
        let long = String(repeating: "d", count: RefusedIdentities.maximumIdentityFormBytes + 1)
        inputs.hardwareIdentifiers = [long, "dev.iface-z", "\u{2060} "]
        let assembly = NeutralSnapshotAssembly(inputs: inputs, limits: Snapshot.Limits())
        #expect(assembly.withheld == ["dev.iface-z", "late evidence"] && assembly.redacted.count == 3)
        #expect(assembly.withheldOverflow == 0)
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
        let form = UntrustedTextSanitizer.sourceForm(raw)
        #expect(form.unicodeScalars.elementsEqual("가나다".unicodeScalars))
        #expect(UntrustedTextSanitizer.sourceForm(form).unicodeScalars.elementsEqual(form.unicodeScalars))
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

    // MARK: - Round 6

    @Test func redactionRunsBeforeTheGraphemeCap() {
        let family = "👨\u{FE0F}\u{200D}👩\u{FE0F}\u{200D}👧\u{FE0F}\u{200D}👦\u{FE0F}"
        for withheld in ["👨👩👧👦ID-123456", family + "ID-123456"] {
            let label = UntrustedLabel(family + "ID-123456", withholding: [withheld])
            #expect(label.text == UntrustedLabel.withheldMarker && label.wasSanitized)
        }
        let flooded = "SN-x" + String(repeating: "\u{0301}", count: 8) + "-99"
        let completed = "SN-x" + String(repeating: "\u{0301}", count: 7) + "-99"
        #expect(UntrustedLabel(flooded, withholding: [completed]).text == UntrustedLabel.withheldMarker)
        // A term is never capped: a leading flood of nine distinct marks is matched whole
        // (and widened to the grapheme it sits in), not cut to eight scalars.
        let marks = String(String.UnicodeScalarView((0x0300...0x0309).compactMap(Unicode.Scalar.init)))
            .replacingOccurrences(of: "\u{0305}", with: "") + "-123456"
        let whole = UntrustedLabel("q" + marks, withholding: [marks])
        #expect(Array(whole.text.unicodeScalars) == Array(UntrustedLabel.withheldMarker.unicodeScalars))
    }

    @Test func aScanCutTailIsWithheldInTheSamePassAsCompleteMatches() {
        let short = "ABCABC"
        let long = short + "DEF-" + String(repeating: "7", count: 990)
        let label = UntrustedLabel("Rig " + String(repeating: short, count: 600) + long, withholding: [short, long])
        #expect(label.text == "Rig \(UntrustedLabel.withheldMarker)" && label.isTruncated)
        let exact = UntrustedLabel("Rig -----" + String(repeating: "ABCDEFGH", count: 600), withholding: ["ABCDEFGH"])
        #expect(exact.text == "Rig -----\(UntrustedLabel.withheldMarker)")
    }

    @Test func caseFoldingMatchesAcrossLengthChanges() {
        let label = UntrustedLabel("Rig " + String(repeating: "STRASSE-X", count: 800), withholding: ["Straße-X"])
        #expect(label.text == "Rig \(UntrustedLabel.withheldMarker)")
        let marker = UntrustedLabel.withheldMarker
        #expect(UntrustedLabel("Maß Straße-X ok", withholding: ["STRASSE-X"]).text == "Maß \(marker) ok")
        #expect(UntrustedLabel("Gro\u{00DF}-123456 ok", withholding: ["s-123456"]).text == "Gro\(marker) ok")
        #expect(UntrustedLabel("ΣΊΓΜΑ-12 ok", withholding: ["σίγμα-12"]).text == "\(marker) ok")
        // Accepted over-redaction: ß folds to "ss", so the whole ß is withheld.
        #expect(UntrustedLabel("Maß-123456", withholding: ["s-123456"]).text == "Ma\(marker)")
    }

    @Test func aTwoScalarTermWithholdsAOneScalarScanCutTail() {
        let cut = "Rig -" + String(repeating: "中文", count: 2045) + "中" + "文 tail"
        let label = UntrustedLabel(cut, withholding: ["中文"])
        #expect(label.text == "Rig -\(UntrustedLabel.withheldMarker)" && label.isTruncated)
    }

    // MARK: - Round 7

    @Test func anOversizedFirstGraphemeDoesNotEmptyTheTermPrefix() {
        let secret = String(repeating: "👩\u{200D}", count: 200) + "👩SERIAL-123456"
        let label = UntrustedLabel(secret, withholding: [secret])
        #expect(label.text == UntrustedLabel.withheldMarker && label.wasSanitized)
        let family = String(repeating: "👩\u{200D}", count: 300) + "👩"
        #expect(UntrustedLabel("Rig " + family, withholding: [family]).text == "Rig \(UntrustedLabel.withheldMarker)")
    }

    @Test func aTermWithNoSafePrefixWithholdsTheWholeLabel() {
        let giant = "q" + String(repeating: "\u{0301}", count: 600)
        #expect(UntrustedTextSanitizer.withheldTerm(giant) == .failClosed)
        let label = UntrustedLabel("Mic ok", withholding: [giant])
        #expect(label.text == UntrustedLabel.withheldMarker && label.wasSanitized)
        #expect(UntrustedLabel("", withholding: [giant]).text.isEmpty)
    }

    @Test(arguments: caseFoldingPairs)
    func fullCaseFoldingMatchesInEveryDirection(label: String, withheld: String) {
        let marker = UntrustedLabel.withheldMarker
        #expect(UntrustedLabel("Rig " + label + " ok", withholding: [withheld]).text == "Rig \(marker) ok")
    }

    // MARK: - Round 8

    @Test(arguments: canonicalCasePairs)
    func canonicallyEquivalentCaseVariantsMatch(label: String, withheld: String) {
        let marker = UntrustedLabel.withheldMarker
        #expect(UntrustedLabel("Rig " + label + " ok", withholding: [withheld]).text == "Rig \(marker) ok")
    }

    @Test func aMatchCoversTheWholeSourceGraphemes() {
        let marker = UntrustedLabel.withheldMarker
        #expect(UntrustedLabel("Rig ID-1234q\u{0323}\u{0307} ok", withholding: ["ID-1234q\u{0307}\u{0323}"]).text
            == "Rig \(marker) ok")
        // A term ending on a base letter withholds the marks on it too (over-redaction).
        #expect(UntrustedLabel("Rig SN-12345\u{00C5} ok", withholding: ["SN-12345A"]).text == "Rig \(marker) ok")
        #expect(UntrustedLabel("Rig ID-1234q\u{0323}\u{0307} ok", withholding: ["ID-1234q"]).text == "Rig \(marker) ok")
        // The grapheme can go on past the term with a starter (a spacing mark, ccc 0), not only marks.
        #expect(UntrustedLabel("Rig SN-1234\u{0915}\u{093E} ok", withholding: ["SN-1234\u{0915}"]).text
            == "Rig \(marker) ok")
    }

    @Test func aScanCutTailNeverEndsInsideANormalizationSegment() {
        let marker = UntrustedLabel.withheldMarker
        let jamo = "\u{1100}\u{1161}\u{1102}\u{1161}"
        let decomposed = UntrustedLabel("Rig -" + String(repeating: jamo, count: 1100), withholding: ["가나"])
        #expect(decomposed.text == "Rig -\(marker)" && decomposed.isTruncated)
        let precomposed = UntrustedLabel("Rig -" + String(repeating: "가나", count: 2100), withholding: [jamo])
        #expect(precomposed.text == "Rig -\(marker)" && precomposed.isTruncated)
        let midSyllable = UntrustedLabel(
            "Rig -" + String(repeating: "\u{1100}\u{1161}\u{11A8}", count: 1400), withholding: ["각각"]
        )
        #expect(midSyllable.text == "Rig -\(marker)" && midSyllable.isTruncated)
    }

    @Test func caselessMapMatchesTheWholeText() {
        let corpus = [
            "Rig \u{03AA}\u{0301}-123456 ok", "\u{1FB4}\u{0301}\u{0345}x", "q\u{0307}\u{0323}\u{0345}\u{0301}",
            "STRA\u{1E9E}E \u{01C5} \u{FB05} \u{0130}\u{0323}", "\u{1100}\u{1161}\u{11A8}\u{1102}", "👩👩👧 ΣΊΓΜΑ"
        ]
        for raw in corpus {
            let text = UntrustedTextSanitizer.sourceForm(raw)
            let map = UntrustedTextSanitizer.CaselessMap(text)
            #expect(map.scalars == UntrustedTextSanitizer.caselessForm(text.unicodeScalars))
            #expect(map.sourceCount == text.unicodeScalars.count)
        }
    }

    /// Label and withheld spellings that are equal under full case folding (round 7).
    static let caseFoldingPairs: [(String, String)] = [
        ("STRA\u{1E9E}E-X", "Straße-X"), ("Straße-X", "STRA\u{1E9E}E-X"), ("STRASSE-X", "Stra\u{1E9E}e-X"),
        ("Stra\u{1E9E}e-X", "STRASSE-X"), ("strasse-x", "STRA\u{1E9E}E-X"), ("Straße-X", "strasse-x"),
        ("\u{017F}erial-1234", "SERIAL-1234"), ("\u{212A}ELVIN-12", "kelvin-12"), ("\u{2126}MEGA-12", "ωmega-12"),
        ("ΟΔΟΣ-1234", "οδος-1234"), ("οδοσ-1234", "ΟΔΟΣ-1234"), ("\u{FB05}udio-123", "STUDIO-123"),
        ("STUDIO-123", "\u{FB05}udio-123")
    ]

    /// Label and withheld spellings that are canonically equivalent case variants (round 8).
    static let canonicalCasePairs: [(String, String)] = [
        ("\u{03AA}\u{0301}-123456", "\u{0390}-123456"), ("\u{0390}-123456", "\u{03AA}\u{0301}-123456"),
        ("\u{212B}12345", "\u{00C5}12345"), ("\u{00C5}12345", "A\u{030A}12345"),
        ("a\u{030A}12345", "\u{212B}12345"),
        ("\u{01C5}-123456", "\u{01C4}-123456"), ("\u{01C6}-123456", "\u{01C5}-123456"),
        ("\u{01C4}-1234", "\u{01C6}-1234"),
        ("q\u{0307}\u{0323}-123456", "q\u{0323}\u{0307}-123456"),
        ("q\u{0323}\u{0307}-123456", "Q\u{0307}\u{0323}-123456"),
        ("\u{1FB4}\u{0301}-12", "\u{0386}\u{0301}\u{0345}-12"), ("\u{0386}\u{0301}\u{0345}-12", "\u{1FB4}\u{0301}-12"),
        ("\u{D55C}\u{AD6D}-12", "\u{1112}\u{1161}\u{11AB}\u{1100}\u{116E}\u{11A8}-12"),
        ("\u{1112}\u{1161}\u{11AB}\u{1100}\u{116E}\u{11A8}-12", "\u{D55C}\u{AD6D}-12")
    ]

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

extension NeutralSnapshotTests {
    // MARK: - Round 11: marks reordered into a term's edges

    /// Each label holds its withheld string verbatim, raw or in its NFC display form, but
    /// NFD sorts the label's own marks in among the term's leading or trailing marks
    /// (`é` U+0316 is `e` U+0316 U+0301; `α` U+0345 U+0301 folds to `α` U+0301 `ι`), so until
    /// round 11 the caseless forms were not contiguous and every label was shown as is.
    @Test(arguments: [
        ("Rig SN-12345\u{00E9}\u{0316} ok", "SN-12345\u{00E9}"),
        ("Rig SN-12345e\u{0301}\u{0316} ok", "SN-12345\u{00E9}"),
        ("Rig \u{00E1}\u{0316}SN-123456 ok", "\u{0316}SN-123456"),
        ("Rig q\u{0300}\u{0316}SN-123456 ok", "\u{0316}SN-123456"),
        ("Rig ID-1234\u{03B1}\u{0345}\u{0301} ok", "ID-1234\u{1FB3}"),
        ("Rig SN-12345e" + String(repeating: "\u{0316}", count: 8) + "\u{0301} ok", "SN-12345\u{00E9}"),
        ("Rig a\u{0300}\u{0316}\u{0301}\u{0302} ok", "\u{0316}\u{0301}\u{0302}")
    ])
    func marksReorderedIntoATermsEdgesDoNotHideIt(raw: String, withheld: String) {
        let label = UntrustedLabel(raw, withholding: [withheld])
        #expect(label.text == "Rig \(UntrustedLabel.withheldMarker) ok", "\(Array(label.text.unicodeScalars))")
        #expect(label.wasSanitized && !label.isTruncated)
    }

    /// The edge rule is canonical equivalence, not a looser match. A label mark of the
    /// same class in front of the term's edge mark makes a different text (`è` U+0301 is
    /// not `é` U+0300; `q` U+0316 U+0323 does not hold U+0323 `S`), a leading mark must be
    /// there, and a term made of marks must be consecutive marks of each class.
    @Test(arguments: [
        ("Rig SN-12345e\u{0300}\u{0301} ok", "SN-12345\u{00E9}"),
        ("Rig q\u{0316}\u{0323}SN-123456 ok", "\u{0316}SN-123456"),
        ("Rig SN-123456 ok", "\u{0316}SN-123456"),
        ("Rig a\u{0301}\u{0300}\u{0302}\u{0303} ok", "\u{0301}\u{0302}\u{0303}")
    ])
    func marksThatCannotBeReorderedIntoATermKeepItFromMatching(raw: String, withheld: String) {
        let label = UntrustedLabel(raw, withholding: [withheld])
        #expect(label.text.unicodeScalars.elementsEqual(raw.precomposedStringWithCanonicalMapping.unicodeScalars))
        #expect(!label.text.contains(UntrustedLabel.withheldMarker))
    }

    /// `matchClass` counts a real `ι` as a mark (240), so an overlong run of `ι` becomes a
    /// prefix term made only of "marks". It is matched as a run (`markRuns`, first match
    /// only) and withholds the label from there to the end (round 11b).
    @Test func anOverlongIotaRunIsAMarksOnlyPrefixTerm() throws {
        let iotas = String(repeating: "\u{03B9}", count: 600)
        let term = try #require(UntrustedTextSanitizer.withheldTerm(iotas))
        #expect(term.isPrefix && term.core.isEmpty && term.folded.count == 511)
        let label = UntrustedLabel("Rig " + iotas + " ok " + iotas, withholding: [iotas])
        #expect(label.text == "Rig \(UntrustedLabel.withheldMarker)")
    }

    /// A run of marks before a term's core may cross a real `ι` (ccc 0, counted as 240).
    /// The match then starts at the run's start, so `à` is withheld too: an over-match,
    /// never a miss (round 11b).
    @Test func aLeadingRunThatCrossesAnIotaIsWithheldFromItsStart() {
        let label = UntrustedLabel("Rig a\u{0300}\u{03B9}\u{0316}SN-123456 ok", withholding: ["\u{0316}SN-123456"])
        #expect(label.text == "Rig \(UntrustedLabel.withheldMarker) ok", "\(Array(label.text.unicodeScalars))")
    }
}
