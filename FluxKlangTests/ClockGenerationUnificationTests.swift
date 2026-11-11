import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// One clock-generation snapshot behind the local mirrors (#108 GU1, slice a; the metronome takes the snapshot
/// itself since GU1b-1). This file holds the fixtures, the checks on the snapshot value and the scan of the new
/// sources; the ledger, staleness and adapter tests are in the extensions beside it.
struct ClockGenerationUnificationTests {
    static let primary = ClockID(validated: "smp.main")
    static let musical = ClockID(validated: "mus.main")
    static let primaryKey = GenerationKey(.sampleClock, primary)
    static let transportKey = GenerationKey(.transport, musical)
    static let mapKey = GenerationKey(.musicalMap, musical)
    static let axes: [ClockGenerationAxis] = [.sample, .transport, .musicalMap]

    /// 1, small values, a power of two, and the last two values the contract allows.
    static let rawTable = [1, 2, 3, 7, 1_000, 1 << 32, Generation.maximumValue - 1, Generation.maximumValue]

    static func table() throws -> [Generation] {
        try rawTable.map { try Generation($0) }
    }

    /// Eight snapshots whose three generations differ from each other; every table value sits on every axis once.
    static func triples() throws -> [ClockGenerationSnapshot] {
        let values = try table()
        return values.indices.map { index in
            ClockGenerationSnapshot(sample: values[index], transport: values[(index + 3) % values.count],
                                    musicalMap: values[(index + 5) % values.count])
        }
    }

    static func generation(_ axis: ClockGenerationAxis, of snapshot: ClockGenerationSnapshot) -> Generation {
        switch axis {
        case .sample: snapshot.sample
        case .transport: snapshot.transport
        case .musicalMap: snapshot.musicalMap
        }
    }

    static func replacing(_ axis: ClockGenerationAxis, of snapshot: ClockGenerationSnapshot,
                          with generation: Generation) -> ClockGenerationSnapshot {
        switch axis {
        case .sample:
            ClockGenerationSnapshot(sample: generation, transport: snapshot.transport, musicalMap: snapshot.musicalMap)
        case .transport:
            ClockGenerationSnapshot(sample: snapshot.sample, transport: generation, musicalMap: snapshot.musicalMap)
        case .musicalMap:
            ClockGenerationSnapshot(sample: snapshot.sample, transport: snapshot.transport, musicalMap: generation)
        }
    }

    /// The value after `generation` in `table`, wrapping at the end: always another value than `generation`.
    static func another(than generation: Generation, in table: [Generation]) -> Generation {
        let index = table.firstIndex(of: generation) ?? 0
        return table[(index + 1) % table.count]
    }

    /// `snapshot` with each of `changed` set to another table value than its own.
    static func changing(_ changed: [ClockGenerationAxis], of snapshot: ClockGenerationSnapshot,
                         in table: [Generation]) -> ClockGenerationSnapshot {
        changed.reduce(snapshot) { result, axis in
            replacing(axis, of: result, with: another(than: generation(axis, of: snapshot), in: table))
        }
    }

    /// Every pair of table values as (earlier, later): the table is in ascending order.
    static func orderedPairs(of table: [Generation]) -> [(Generation, Generation)] {
        table.indices.flatMap { low in table.indices.dropFirst(low + 1).map { (table[low], table[$0]) } }
    }

    /// A staleness report as plain flags. Its initializer is not visible to tests, so reports are compared through
    /// these flags, in the fixed order sample, transport, musical map.
    struct Flags: Equatable {
        let sample: Bool
        let transport: Bool
        let musicalMap: Bool
    }

    static func flags(of observed: ClockGenerationSnapshot, against live: ClockGenerationSnapshot) -> Flags? {
        ClockGenerationSnapshot.staleness(of: observed, against: live).map {
            Flags(sample: $0.sample, transport: $0.transport, musicalMap: $0.musicalMap)
        }
    }

    /// The flags of a report on which exactly `differing` axes are set; nil when none is.
    static func flags(differing: [ClockGenerationAxis]) -> Flags? {
        guard !differing.isEmpty else { return nil }
        return Flags(sample: differing.contains(.sample), transport: differing.contains(.transport),
                     musicalMap: differing.contains(.musicalMap))
    }

    /// The axes set in the low three bits of `mask`, in the fixed order.
    static func axes(inMask mask: Int) -> [ClockGenerationAxis] {
        axes.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element)
    }

    static func ledger(musicalClock: ClockID? = ClockGenerationUnificationTests.musical,
                       declaring counters: [GenerationKey] = []) throws -> GenerationLedger {
        try GenerationLedger(primaryClock: primary, musicalClock: musicalClock, nominalRate: 48_000,
                             declaring: counters)
    }

    /// A live read as a value: the snapshot, or the refusal.
    enum Live: Equatable {
        case read(ClockGenerationSnapshot)
        case refused(ClockGenerationRefusal)

        var snapshot: ClockGenerationSnapshot? {
            if case let .read(snapshot) = self { snapshot } else { nil }
        }
    }

    static func liveRead(of ledger: GenerationLedger) -> Live {
        do throws(ClockGenerationRefusal) {
            return .read(try ClockGenerationSnapshot.live(from: ledger))
        } catch {
            return .refused(error)
        }
    }

    static func liveRead(primaryClock: GenerationKey, musicalClock: ClockID?,
                         counters: [GenerationKey: Generation]) -> Live {
        do throws(ClockGenerationRefusal) {
            return .read(try ClockGenerationSnapshot.live(primaryClock: primaryClock, musicalClock: musicalClock,
                                                         counters: counters))
        } catch {
            return .refused(error)
        }
    }

    @Test func aSnapshotEqualsItsTwinAndDiffersWhenAnyOneGenerationDiffers() throws {
        let values = try Self.table()
        for snapshot in try Self.triples() {
            let twin = ClockGenerationSnapshot(sample: snapshot.sample, transport: snapshot.transport,
                                               musicalMap: snapshot.musicalMap)
            #expect(snapshot == twin)
            for axis in Self.axes {
                let other = Self.another(than: Self.generation(axis, of: snapshot), in: values)
                #expect(snapshot != Self.replacing(axis, of: snapshot, with: other), "\(axis)")
            }
        }
    }

    @Test func neitherASnapshotNorAGenerationConformsToComparable() {
        let snapshot: Any = ClockGenerationSnapshot(sample: .initial, transport: .initial, musicalMap: .initial)
        let generation: Any = Generation.initial
        let positiveControl: Any = 1
        #expect(!(snapshot is any Comparable))
        #expect(!(generation is any Comparable))
        #expect(positiveControl is any Comparable)
    }

    @Test func generationAcceptsBothEndsOfItsContractRangeAndRefusesIntegersOutsideIt() throws {
        #expect(try Generation(1) == .initial)
        #expect(try Generation(Generation.maximumValue).value == Generation.maximumValue)
        for outside in [0, -1, Generation.maximumValue + 1, Int.max, Int.min] {
            #expect(throws: RevisionError.outOfRange(outside)) { try Generation(outside) }
        }
    }
}

/// Reads the three new production files from disk, next to this test file, and scans their code (line comments
/// removed) for what the equality-only and no-state rules forbid: the word `Comparable`, any `.value` access, a spaced
/// `<`, `>`, `<=` or `>=`, a `Generation(` construction, a line that starts an import, `static var`, `mutating`,
/// `inout`, `bump`, `declare`, `class`, `actor`, `async`, `await`, `Task`, `Date`, `UUID`, `ContinuousClock`,
/// `SuspendingClock`, `DispatchTime`, `SystemRandomNumberGenerator`, words that start with `random` or `shuffle`, and
/// the names of the four generation types of other domains. Nothing outside that list is proven absent. A `//` inside
/// a string literal would be taken for a comment, and block comments are not removed; the sources hold neither. The
/// scan runs where the checkout sits next to the tests (macOS, and the simulator on the build machine). It is skipped,
/// not failed, where the sources are not reachable, and a skipped scan proves nothing. The scanner self-tests below
/// run everywhere.
extension ClockGenerationUnificationTests {
    private static let sources: [(name: String, declaration: String)] = [
        ("ClockGenerationSnapshot.swift", "struct ClockGenerationSnapshot"),
        ("ClockGenerationStaleness.swift", "struct ClockGenerationStaleness"),
        ("ClockGenerationAdapters.swift", "extension ClockGenerationSnapshot")
    ]

    private static let differentDomainTypes = [
        "CalibrationGenerations", "GenerationSlot", "GenerationAnchor", "RuntimeGenerationKey"
    ]

    private static let forbiddenWords = [
        "Comparable", "mutating", "inout", "bump", "declare", "class", "actor", "async", "await", "Task",
        "Date", "UUID", "ContinuousClock", "SuspendingClock", "DispatchTime", "SystemRandomNumberGenerator"
    ] + differentDomainTypes

    /// Lowercase: a word is forbidden when its lowercased form starts with one of these.
    private static let forbiddenPrefixes = ["random", "shuffle"]

    private static let orderingOperators = ["<", ">", "<=", ">="]

    private static func sourceDirectory(from path: String = #filePath) -> URL? {
        let here = URL(fileURLWithPath: path).deletingLastPathComponent()
        let candidates = [
            "../Shared/Contracts/Transport/Snapshot",
            "../../Sources/FluxKlang/Shared/Contracts/Transport/Snapshot"
        ]
        let marker = "ClockGenerationSnapshot.swift"
        return candidates
            .map { here.appendingPathComponent($0).standardizedFileURL }
            .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent(marker).path) }
    }

    /// Whether `sourceDirectory()` finds the snapshot sources from the path this file was compiled at.
    private static let sourcesAreReachable = sourceDirectory() != nil

    private static func sourceText(_ name: String) throws -> String {
        let directory = try #require(sourceDirectory(), "the snapshot sources are not next to the tests")
        return try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
    }

    private static func lines(of text: String) -> [Substring] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
    }

    /// `text` without its line comments, which run from `//` to the end of the line.
    private static func code(in text: String) -> String {
        lines(of: text)
            .map { line in line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? String(line) }
            .joined(separator: "\n")
    }

    /// Only the line comments of `text`, one per line.
    private static func comments(in text: String) -> String {
        lines(of: text)
            .compactMap { line in line.range(of: "//").map { String(line[$0.lowerBound...]) } }
            .joined(separator: "\n")
    }

    private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar) || scalar == "_"
    }

    private static func words(in text: String) -> [String] {
        text.unicodeScalars.split(whereSeparator: { !isWordScalar($0) }).map { String($0) }
    }

    private static func isForbidden(_ word: String) -> Bool {
        let lowered = word.lowercased().unicodeScalars
        return forbiddenWords.contains { word.unicodeScalars.elementsEqual($0.unicodeScalars) }
            || forbiddenPrefixes.contains { lowered.starts(with: $0.unicodeScalars) }
    }

    private static func hasImportLine(_ text: String) -> Bool {
        lines(of: text).contains { line in
            let lineWords = words(in: String(line))
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            return (trimmed.first == "i" && lineWords.first == "import")
                || (trimmed.first == "@" && lineWords.dropFirst().first == "import")
        }
    }

    /// Whether `text` reads a `value` member: `.value` not followed by another identifier character.
    private static func hasValueAccess(_ text: String) -> Bool {
        text.components(separatedBy: ".value").dropFirst().contains { rest in
            rest.unicodeScalars.first.map { !isWordScalar($0) } ?? true
        }
    }

    /// Whether the word `static` is directly followed by the word `var`: a stored property shared by every value.
    private static func hasStaticVariable(_ words: [String]) -> Bool {
        zip(words, words.dropFirst()).contains { $0 == "static" && $1 == "var" }
    }

    /// The distinct forbidden words of the code of `text` in first-seen order, then `import` when a line starts an
    /// import, `.value` when a value member is read, `Generation(` when a generation is built, `static var` when a
    /// shared variable is declared and each spaced ordering operator it uses.
    private static func findings(in text: String) -> [String] {
        let stripped = code(in: text)
        let tokens = words(in: stripped)
        var found: [String] = []
        for word in tokens where isForbidden(word) && !found.contains(word) {
            found.append(word)
        }
        if hasImportLine(stripped) { found.append("import") }
        if hasValueAccess(stripped) { found.append(".value") }
        if stripped.contains("Generation(") { found.append("Generation(") }
        if hasStaticVariable(tokens) { found.append("static var") }
        return found + orderingOperators.filter { stripped.contains(" \($0) ") }
    }

    @Test(.enabled(if: Self.sourcesAreReachable, "the snapshot sources are not next to the tests"))
    func theNewSourcesContainNoGenerationValueAccessConstructionOrderingStateClockOrOtherDomainTypeName() throws {
        for source in Self.sources {
            let text = try Self.sourceText(source.name)
            #expect(text.contains(source.declaration), "\(source.name)")
            #expect(Self.findings(in: text) == [], "\(source.name)")
        }
    }

    @Test(.enabled(if: Self.sourcesAreReachable, "the snapshot sources are not next to the tests"))
    func theAdaptersFileNamesEachOtherDomainGenerationTypeInALineComment() throws {
        let comments = Self.comments(in: try Self.sourceText("ClockGenerationAdapters.swift"))
        for name in Self.differentDomainTypes {
            #expect(comments.contains(name), "\(name)")
        }
    }

    @Test func theSourceScannerFlagsEveryForbiddenWordAndNothingBesides() {
        for name in Self.forbiddenWords + ["random", "randomElement", "Random", "shuffled", "shuffle"] {
            #expect(Self.findings(in: "let item: \(name) = 1") == [name], "\(name)")
        }
        let clean = """
        ComparableValue valueOf subclass reclassify Updates candidate mutated inoutput actors Datestamp Tasks \
        awaiting GenerationSlots CalibrationGeneration
        """
        #expect(Self.findings(in: clean).isEmpty)
        #expect(Self.findings(in: "let item = Task // Date, random, import\n// class") == ["Task"])
        #expect(Self.findings(in: "Date UUID Date") == ["Date", "UUID"])
    }

    @Test func theSourceScannerFlagsValueMembersAndSpacedOrderingOperatorsAndNothingBesides() {
        for text in ["x.value", "a.value < b.value", "snapshot.sample.value)", "(x.value,", "x.value\ny"] {
            #expect(Self.findings(in: text).contains(".value"), "\(text)")
        }
        for text in ["x.valueOf", "x.values", "let value = 1", "// x.value", "let note = x // .value", "valueOf"] {
            #expect(!Self.findings(in: text).contains(".value"), "\(text)")
        }
        for symbol in ["<", ">", "<=", ">="] {
            #expect(Self.findings(in: "let flag = lhs \(symbol) rhs") == [symbol], "\(symbol)")
        }
        for text in ["a -> b", "Set<Int>", "a == b", "a != b", "a << b", "// a < b"] {
            #expect(Self.findings(in: text).isEmpty, "\(text)")
        }
    }

    @Test func theSourceScannerFlagsGenerationConstructionAndNothingBesides() {
        let built = ["try Generation(1)", "let next = Generation(maximum)", "(Generation(value))", "x = Generation(\n"]
        for text in built {
            #expect(Self.findings(in: text) == ["Generation("], "\(text)")
        }
        let clean = [
            "ClockGenerationSnapshot(sample: a)", "LaneGenerations(snapshot)", "GenerationKey(.transport, id)",
            "Generation.initial", "let sample: Generation", "// Generation(1)", "let note = x // Generation(1)"
        ]
        for text in clean {
            #expect(Self.findings(in: text).isEmpty, "\(text)")
        }
    }

    @Test func theSourceScannerFlagsStaticVariablesAndNothingBesides() {
        let shared = [
            "static var cache = 0", "nonisolated(unsafe) static var cache = 0", "static\nvar total: Int",
            "@MainActor private static  var current = 1"
        ]
        for text in shared {
            #expect(Self.findings(in: text) == ["static var"], "\(text)")
        }
        let clean = [
            "static let limit = 1", "var firstStale: Int { 1 }", "static func variable() {}", "static varied",
            "var static_ = 1", "// static var cache", "let note = x // static var cache"
        ]
        for text in clean {
            #expect(Self.findings(in: text).isEmpty, "\(text)")
        }
    }

    @Test func theSourceScannerFlagsLineLeadingImportsAndNothingElse() {
        let imports = [
            "import Foundation", "  import CoreMIDI", "\timport X", "@testable import Foo",
            "@_exported import Foo", "let x = 1\nimport Foo\n"
        ]
        for line in imports {
            #expect(Self.findings(in: line).contains("import"), "\(line)")
        }
        let clean = ["/// import this", "// import", "let important = 1", "#if canImport(X)", "let word = \"import\""]
        for line in clean {
            #expect(Self.findings(in: line).isEmpty, "\(line)")
        }
    }

    @Test func theSourceScannerSeparatesCodeFromLineComments() {
        #expect(Self.code(in: "let a = 1 // note\n// all\nlet b = 2") == "let a = 1 \n\nlet b = 2")
        #expect(Self.comments(in: "let a = 1 // note\n// all\nlet b = 2") == "// note\n// all")
    }
}
