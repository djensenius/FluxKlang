import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Reads the three new production files from disk, next to this test file, and scans their words for a fixed list of
/// names: the writer, intent and queue types of the other lanes, CoreMIDI and WING names, the clock and random types
/// `Date`, `UUID`, `ContinuousClock`, `SuspendingClock`, `DispatchTime` and `SystemRandomNumberGenerator`, words that
/// start with `random` or `shuffle`, and a line that starts an import. Nothing outside that list is proven absent.
/// The scan runs where the checkout sits next to the tests (macOS, and the simulator on the build machine). It is
/// skipped, not failed, where the sources are not reachable (a device, or a machine that only runs the built tests),
/// and a skipped scan proves nothing. The scanner self-tests below run everywhere.
/// The scan is by name only: words are ASCII identifier runs (no canonical equivalence), and an import is
/// recognised only at the start of a line, optionally behind one attribute such as `@testable`.
extension RemoteDispatchTests {
    private static let sourceFiles: [(name: String, declaration: String)] = [
        ("RemoteMirror.swift", "struct RemoteMirror"),
        ("RemoteControlDispatch.swift", "enum RemoteControlDispatch"),
        ("RemoteDispatchRefusal.swift", "enum RemoteDispatchRefusal")
    ]

    private static let forbiddenNames = [
        "EngineWriting", "ConsoleWriting", "MIDIWriting", "CommandIntent", "PeerOutboundQueue", "CoreMIDI",
        "Date", "UUID", "ContinuousClock", "SuspendingClock", "DispatchTime", "SystemRandomNumberGenerator"
    ]

    /// Lowercase: a word is forbidden when its lowercased form starts with one of these.
    private static let forbiddenPrefixes = [
        "midiclient", "midiport", "midiendpoint", "midipacket", "midisend", "midiobject", "midieventlist",
        "mididevice", "midientity", "wing", "random", "shuffle"
    ]

    private static func sourceDirectory(from path: String = #filePath) -> URL? {
        let here = URL(fileURLWithPath: path).deletingLastPathComponent()
        let candidates = ["../Shared/Peer/RemoteRole", "../../Sources/FluxKlang/Shared/Peer/RemoteRole"]
        return candidates
            .map { here.appendingPathComponent($0).standardizedFileURL }
            .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("RemoteMirror.swift").path) }
    }

    /// Whether `sourceDirectory()` finds the RemoteRole sources from the path this file was compiled at.
    private static let sourcesAreReachable = sourceDirectory() != nil

    private static func sourceText(_ name: String) throws -> String {
        let directory = try #require(sourceDirectory(), "the RemoteRole sources are not next to the tests")
        return try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
    }

    private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar) || scalar == "_"
    }

    private static func words(in text: String) -> [String] {
        text.unicodeScalars.split(whereSeparator: { !isWordScalar($0) }).map { String($0) }
    }

    private static func isForbidden(_ word: String) -> Bool {
        let lowered = word.lowercased().unicodeScalars
        return forbiddenNames.contains { word.unicodeScalars.elementsEqual($0.unicodeScalars) }
            || forbiddenPrefixes.contains { lowered.starts(with: $0.unicodeScalars) }
    }

    private static func hasImportLine(_ text: String) -> Bool {
        text.unicodeScalars.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).contains { line in
            let lineWords = words(in: String(line))
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            return (trimmed.first == "i" && lineWords.first == "import")
                || (trimmed.first == "@" && lineWords.dropFirst().first == "import")
        }
    }

    /// The distinct forbidden words of `text` in first-seen order, then `import` when a line starts an import.
    private static func findings(in text: String) -> [String] {
        var found: [String] = []
        for word in words(in: text) where isForbidden(word) && !found.contains(word) {
            found.append(word)
        }
        if hasImportLine(text) {
            found.append("import")
        }
        return found
    }

    @Test(.enabled(if: Self.sourcesAreReachable, "the RemoteRole sources are not next to the tests"))
    func theRemoteDispatchSourcesNameNoLocalWritePathAndImportNothing() throws {
        for source in Self.sourceFiles {
            let text = try Self.sourceText(source.name)
            #expect(text.contains(source.declaration), "\(source.name)")
            #expect(Self.findings(in: text) == [], "\(source.name)")
        }
    }

    @Test func theSourceScannerFlagsEveryForbiddenNameAndNothingBesides() {
        let flagged = [
            "EngineWriting", "ConsoleWriting", "MIDIWriting", "CommandIntent", "PeerOutboundQueue", "CoreMIDI",
            "MIDIClientRef", "MIDIPortRef", "MIDIEndpointRef", "MIDIPacketList", "MIDISend", "MIDIObjectRef",
            "MIDIEventList", "MIDIDeviceRef", "MIDIEntityRef", "WINGClient", "wingMixer", "Wing",
            "Date", "UUID", "ContinuousClock", "SuspendingClock", "DispatchTime", "SystemRandomNumberGenerator",
            "random", "randomElement", "Random", "shuffled", "shuffle"
        ]
        for name in flagged {
            #expect(Self.findings(in: "let value: \(name) = 1") == [name], "\(name)")
        }
        let clean = """
        MIDI1Semantic MIDIControlIntake MIDI1StateUpdate following owing RemoteRoleGuard PeerSyncReceiver \
        update candidate dated Updates SchedulerClock
        """
        #expect(Self.findings(in: clean).isEmpty)
        let repeated = Self.findings(in: "// EngineWriting\nCommandIntent EngineWriting")
        #expect(repeated == ["EngineWriting", "CommandIntent"])
    }

    @Test func theSourceScannerFlagsLineLeadingImportsAndNothingElse() {
        let imports = [
            "import Foundation", "  import CoreMIDI", "\timport X", "@testable import Foo",
            "@_exported import Foo", "let x = 1\r\nimport Foo\r\n", "let x = 1\rimport Foo"
        ]
        for line in imports {
            #expect(Self.findings(in: line).contains("import"), "\(line)")
        }
        let clean = ["/// import this", "// import", "let important = 1", "#if canImport(X)", "let word = \"import\""]
        for line in clean {
            #expect(Self.findings(in: line).isEmpty, "\(line)")
        }
    }
}
