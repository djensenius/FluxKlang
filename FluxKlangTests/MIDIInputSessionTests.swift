import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Tests of the control-side MIDI input session: a source registry, Active Sensing observers and a note ledger as one
/// value. This file holds the fixtures, the lifecycle tests and the source scan; `+Loss` holds the loss, poll, pedal,
/// feed-order and limit tests.
@Suite("MIDIInputSession")
struct MIDIInputSessionTests {
    static let keys = MIDIInputID(1)
    static let pads = MIDIInputID(2)
    static let drone = MIDIInputID(3)
    static let piano = MIDIRouteID(10)
    static let strings = MIDIRouteID(20)
    static let bass = MIDIRouteID(30)
    static let empty = MIDIInputSessionResult(outputs: [], notices: [], rejections: [])
    static let activeSensing: [UInt8] = [0xFE]
    static let systemReset: [UInt8] = [0xFF]
    static let sustain: [UInt8] = [0xB0, 64, 127]

    /// Everything a refused call must leave alone. The ledger is compared whole: its next press number counts too.
    struct Snapshot: Equatable, Sendable {
        let registry: MIDISourceRegistrySnapshot
        let observers: [ActiveSensingObserver]
        let ledger: MIDINoteLedger

        init(_ session: MIDIInputSession) {
            registry = session.registry.snapshot
            observers = session.observers
            ledger = session.ledger
        }
    }

    static func key(_ input: MIDIInputID) -> MIDIEndpointKey {
        MIDIEndpointKey(fingerprint: UInt64(input.rawValue), ordinal: 0)
    }

    static func stamp(_ ticks: UInt64) -> HostStamp { HostStamp(ticks: ticks) }

    static func noteOn(_ note: UInt8, _ velocity: UInt8 = 100) -> [UInt8] { [0x90, note, velocity] }

    static func noteOff(_ note: UInt8) -> [UInt8] { [0x80, note, 64] }

    static func sentOn(_ route: MIDIRouteID, _ note: UInt8, _ velocity: UInt8) -> MIDIRoutedOutput {
        MIDIRoutedOutput(route: route, message: .noteOn(channel: 1, note: note, velocity: velocity))
    }

    /// The release velocity of a forced release is 64, the same as a Note Off sent with 64.
    static func sentOff(_ route: MIDIRouteID, _ note: UInt8) -> MIDIRoutedOutput {
        MIDIRoutedOutput(route: route, message: .noteOff(channel: 1, note: note, velocity: 64))
    }

    static func result(
        _ outputs: [MIDIRoutedOutput] = [], notices: [MIDIInputSessionNotice] = [],
        rejections: [MIDIInputSessionRejection] = []
    ) -> MIDIInputSessionResult {
        MIDIInputSessionResult(outputs: outputs, notices: notices, rejections: rejections)
    }

    static func rule(_ route: MIDIRouteID, from input: MIDIInputID) throws -> MIDIRoutingRule {
        try #require(MIDIRoutingRule(input: input, route: route, channels: 1...16, notes: 0...127, transpose: 0))
    }

    /// Keys to piano, pads to strings and drone to bass, on every channel and note.
    static func routing() throws -> MIDIRouting {
        let rules = [try rule(piano, from: keys), try rule(strings, from: pads), try rule(bass, from: drone)]
        return try #require(MIDIRouting(rules: rules))
    }

    static func routing(keysTo route: MIDIRouteID) throws -> MIDIRouting {
        let only = try rule(route, from: keys)
        return try #require(MIDIRouting(rules: [only]))
    }

    static func policy(
        _ action: ActiveSensingLossAction = .requestInputLost, timeout: UInt64 = 100
    ) throws -> ActiveSensingPolicy {
        try ActiveSensingPolicy.make(timeoutTicks: timeout, lossAction: action)
    }

    static func profile(reset: MIDISystemResetPolicy = .ignore, heldNotes: Int = 128) throws -> MIDISourceProfile {
        let limits = try #require(MIDI1StatePolicy(maximumHeldNotes: heldNotes))
        return try MIDISourceProfile.make(statePolicy: limits, systemReset: reset)
    }

    /// Registers the inputs in the order given, each with the same profile and sensing policy.
    static func session(
        _ inputs: [MIDIInputID] = [keys, pads, drone], sensing: ActiveSensingPolicy? = nil,
        profile: MIDISourceProfile = .standard, maximumFeedBytes: Int = 4_096,
        ledgerPolicy: MIDINoteLedgerPolicy = .standard
    ) throws -> MIDIInputSession {
        var built = try MIDIInputSession.make(maximumFeedBytes: maximumFeedBytes, ledgerPolicy: ledgerPolicy)
        for input in inputs { try built.register(input, key: key(input), profile: profile, sensing: sensing) }
        return built
    }

    /// Feeds one packet at `ticks` through the three-rule routing.
    static func play(
        _ session: inout MIDIInputSession, _ bytes: [UInt8], from input: MIDIInputID = keys, at ticks: UInt64 = 0
    ) throws -> MIDIInputSessionResult {
        try session.feed(bytes, from: input, at: stamp(ticks), routing: routing())
    }

    /// The refusal `body` throws, or nil when it succeeds.
    static func refusal<Value>(_ body: () throws(MIDIInputSessionRefusal) -> Value) -> MIDIInputSessionRefusal? {
        do throws(MIDIInputSessionRefusal) {
            _ = try body()
            return nil
        } catch {
            return error
        }
    }

    /// The refusal of feeding `bytes` at `ticks` through the three-rule routing, or nil when the feed is accepted.
    static func refusedFeed(
        _ session: inout MIDIInputSession, _ bytes: [UInt8], from input: MIDIInputID = keys, at ticks: UInt64 = 0
    ) throws -> MIDIInputSessionRefusal? {
        let table = try routing()
        do throws(MIDIInputSessionRefusal) {
            _ = try session.feed(bytes, from: input, at: stamp(ticks), routing: table)
            return nil
        } catch {
            return error
        }
    }

    static func phase(_ session: MIDIInputSession, _ input: MIDIInputID = keys) -> ActiveSensingPhase? {
        session.observer(of: input)?.phase
    }

    /// The notes the registry holds for the input on channel 1.
    static func held(_ session: MIDIInputSession, _ input: MIDIInputID = keys) -> [UInt8] {
        let state = session.registry.snapshot.sources.first { $0.input == input }?.state
        return state?.channels.first?.heldNotes.map(\.note) ?? []
    }

    @Test
    func midiInputSessionDetachReleasesHeldKeysToTheirRecordedRoutes() throws {
        var session = try Self.session([Self.keys, Self.pads], sensing: Self.policy())
        _ = try Self.play(&session, Self.noteOn(60) + Self.noteOn(64))
        _ = try Self.play(&session, Self.noteOn(62), from: Self.pads)
        let released = try session.detach(Self.keys)
        let expected = [Self.sentOff(Self.piano, 60), Self.sentOff(Self.piano, 64)]
        #expect(released == expected)
        let heldInputs = session.ledger.notes.map(\.input)
        #expect(heldInputs == [Self.pads])
        let observer = session.observer(of: Self.keys)
        #expect(observer == nil)
        let listed = session.registry.sources.map(\.input)
        #expect(listed == [Self.pads])
    }

    @Test
    func midiInputSessionDetachReleasesToRoutesRecordedBeforeARoutingChange() throws {
        var session = try Self.session([Self.keys])
        let toPiano = try Self.routing(keysTo: Self.piano)
        let toBass = try Self.routing(keysTo: Self.bass)
        let first = try session.feed(Self.noteOn(60), from: Self.keys, at: Self.stamp(0), routing: toPiano)
        let second = try session.feed(Self.noteOn(64), from: Self.keys, at: Self.stamp(0), routing: toBass)
        let expectedFirst = Self.result([Self.sentOn(Self.piano, 60, 100)])
        let expectedSecond = Self.result([Self.sentOn(Self.bass, 64, 100)])
        #expect(first == expectedFirst)
        #expect(second == expectedSecond)
        let released = try session.detach(Self.keys)
        let expected = [Self.sentOff(Self.piano, 60), Self.sentOff(Self.bass, 64)]
        #expect(released == expected)
    }

    @Test
    func midiInputSessionResetSourceReleasesTheNamedInputAndKeepsItsObserver() throws {
        var session = try Self.session([Self.keys, Self.pads], sensing: Self.policy())
        _ = try Self.play(&session, Self.activeSensing, at: 0)
        _ = try Self.play(&session, Self.noteOn(60), at: 10)
        _ = try Self.play(&session, Self.noteOn(62), from: Self.pads, at: 10)
        let released = try session.resetSource(Self.keys)
        let expected = [Self.sentOff(Self.piano, 60)]
        #expect(released == expected)
        let listed = session.registry.sources.map(\.input)
        #expect(listed == [Self.keys, Self.pads])
        let observer = try #require(session.observer(of: Self.keys))
        let armed = ActiveSensingPhase.armed(deadline: 110)
        #expect(observer.phase == armed)
        #expect(observer.lastTick == 10)
        let heldInputs = session.ledger.notes.map(\.input)
        #expect(heldInputs == [Self.pads])
        let registryHeld = Self.held(session)
        #expect(registryHeld.isEmpty)
    }

    @Test
    func midiInputSessionSystemResetReleasesUnderTheResetProfileAndNotUnderIgnore() throws {
        let resetting = try Self.profile(reset: .resetSource)
        var session = try Self.session([Self.keys], profile: resetting)
        let first = try Self.play(&session, Self.noteOn(60) + Self.systemReset)
        let expectedFirst = Self.result(
            [Self.sentOn(Self.piano, 60, 100), Self.sentOff(Self.piano, 60)], notices: [.systemReset(Self.keys)]
        )
        #expect(first == expectedFirst)
        var midPacket = try Self.session([Self.keys], profile: resetting)
        let second = try Self.play(&midPacket, Self.noteOn(60) + Self.systemReset + Self.noteOn(62))
        let expectedSecond = Self.result(
            [Self.sentOn(Self.piano, 60, 100), Self.sentOff(Self.piano, 60), Self.sentOn(Self.piano, 62, 100)],
            notices: [.systemReset(Self.keys)]
        )
        #expect(second == expectedSecond)
        let stillHeld = midPacket.ledger.notes.map(\.note)
        #expect(stillHeld == [62])
        var ignoring = try Self.session([Self.keys])
        let third = try Self.play(&ignoring, Self.noteOn(60) + Self.systemReset)
        let expectedThird = Self.result([Self.sentOn(Self.piano, 60, 100)])
        #expect(third == expectedThird)
        let ignoredHeld = ignoring.ledger.notes.map(\.note)
        #expect(ignoredHeld == [60])
    }

    @Test
    func midiInputSessionRegistrationRefusalsAddNoObserver() throws {
        let sensing = try Self.policy()
        var session = try MIDIInputSession.make(maximumSources: 1)
        try session.register(Self.keys, key: Self.key(Self.keys), sensing: sensing)
        let before = Self.Snapshot(session)
        let duplicate = Self.refusal { () throws(MIDIInputSessionRefusal) in
            try session.register(Self.keys, key: Self.key(Self.pads), sensing: sensing)
        }
        let expectedDuplicate: MIDIInputSessionRefusal? = .source(.duplicateInput(Self.keys))
        #expect(duplicate == expectedDuplicate)
        let ambiguous = Self.refusal { () throws(MIDIInputSessionRefusal) in
            try session.register(Self.pads, key: Self.key(Self.keys), sensing: sensing)
        }
        let expectedAmbiguous: MIDIInputSessionRefusal? = .source(.ambiguousEndpoint(existing: Self.keys))
        #expect(ambiguous == expectedAmbiguous)
        let full = Self.refusal { () throws(MIDIInputSessionRefusal) in
            try session.register(Self.pads, key: Self.key(Self.pads), sensing: sensing)
        }
        let expectedFull: MIDIInputSessionRefusal? = .source(.registryFull(limit: 1))
        #expect(full == expectedFull)
        let unknown: MIDIInputSessionRefusal? = .source(.unknownInput(Self.drone))
        let detached = Self.refusal { () throws(MIDIInputSessionRefusal) in try session.detach(Self.drone) }
        let reset = Self.refusal { () throws(MIDIInputSessionRefusal) in try session.resetSource(Self.drone) }
        #expect(detached == unknown)
        #expect(reset == unknown)
        let after = Self.Snapshot(session)
        #expect(after == before)
        let sources: MIDIInputSessionRefusal? = .source(.invalidConfiguration(.maximumSources))
        let feedBytes: MIDIInputSessionRefusal? = .source(.invalidConfiguration(.maximumFeedBytes))
        let badSources = Self.refusal { () throws(MIDIInputSessionRefusal) in
            try MIDIInputSession.make(maximumSources: 0)
        }
        let badFeed = Self.refusal { () throws(MIDIInputSessionRefusal) in
            try MIDIInputSession.make(maximumFeedBytes: 0)
        }
        let both = Self.refusal { () throws(MIDIInputSessionRefusal) in
            try MIDIInputSession.make(maximumSources: 129, maximumFeedBytes: 65_537)
        }
        #expect(badSources == sources)
        #expect(badFeed == feedBytes)
        #expect(both == sources)
        _ = try Self.play(&session, Self.noteOn(60), at: 20)
        _ = try session.detach(Self.keys)
        let dropped = session.observer(of: Self.keys)
        #expect(dropped == nil)
        try session.register(Self.keys, key: Self.key(Self.keys), sensing: sensing)
        let fresh = try #require(session.observer(of: Self.keys))
        let unarmed = ActiveSensingPhase.unarmed
        #expect(fresh.phase == unarmed)
        #expect(fresh.lastTick == nil)
        var crowded = try MIDIInputSession.make(maximumSources: 128)
        for raw in stride(from: 128, through: 1, by: -1) {
            let input = MIDIInputID(UInt32(raw))
            try crowded.register(input, key: Self.key(input), sensing: sensing)
        }
        let listed = crowded.observers.map(\.input.rawValue)
        let ascending = Array(UInt32(1)...UInt32(128))
        #expect(listed == ascending)
        let extra = MIDIInputID(129)
        let overflow = Self.refusal { () throws(MIDIInputSessionRefusal) in
            try crowded.register(extra, key: Self.key(extra), sensing: sensing)
        }
        let expectedOverflow: MIDIInputSessionRefusal? = .source(.registryFull(limit: 128))
        #expect(overflow == expectedOverflow)
    }

    @Test
    func midiInputSessionLedgerRefusalIsReportedAndTheFeedContinues() throws {
        let tiny = try #require(MIDINoteLedgerPolicy(noteCapacity: 1))
        var session = try Self.session([Self.keys], ledgerPolicy: tiny)
        let packet = Self.noteOn(60) + Self.noteOn(62) + Self.noteOff(60)
        let fed = try Self.play(&session, packet)
        let expected = Self.result(
            [Self.sentOn(Self.piano, 60, 100), Self.sentOff(Self.piano, 60)],
            rejections: [.ledger(.noteLedgerFull(input: Self.keys, channel: 1, note: 62))]
        )
        #expect(fed == expected)
        let registryHeld = Self.held(session)
        #expect(registryHeld == [62])
    }

    @Test
    func midiInputSessionStateRefusalIsReportedAndTheFeedContinues() throws {
        let limited = try Self.profile(heldNotes: 1)
        var session = try Self.session([Self.keys], profile: limited)
        let packet = Self.noteOn(60) + Self.noteOn(62) + Self.noteOff(60)
        let fed = try Self.play(&session, packet)
        let expected = Self.result(
            [Self.sentOn(Self.piano, 60, 100), Self.sentOff(Self.piano, 60)],
            rejections: [.state(.heldNoteLimit(channel: 1, note: 62))]
        )
        #expect(fed == expected)
    }

    // MARK: - Source scan

    private static func startsAt(_ wanted: [UInt8], in bytes: [UInt8], at start: Int) -> Bool {
        guard start + wanted.count <= bytes.count else { return false }
        for offset in 0..<wanted.count where bytes[start + offset] != wanted[offset] {
            return false
        }
        return true
    }

    private static func containsBytes(_ needle: String, in haystack: String) -> Bool {
        let wanted = Array(needle.utf8)
        let bytes = Array(haystack.utf8)
        guard !wanted.isEmpty, wanted.count <= bytes.count else { return false }
        for start in 0...(bytes.count - wanted.count) where startsAt(wanted, in: bytes, at: start) {
            return true
        }
        return false
    }

    /// True when the text holds `static func ` followed by a symbol byte. Other operator forms are not looked for.
    private static func declaresAStaticOperatorFunction(_ text: String) -> Bool {
        let wanted = Array(["static", " func", " "].joined().utf8)
        let bytes = Array(text.utf8)
        let symbols = Array("=<>+-*/!&|%^~".utf8)
        guard wanted.count < bytes.count else { return false }
        for start in 0...(bytes.count - wanted.count - 1) where startsAt(wanted, in: bytes, at: start) {
            let following = bytes[start + wanted.count]
            if symbols.contains(following) { return true }
        }
        return false
    }

    /// Texts the production files must not contain, even in a comment. Each is joined from pieces, so that no single
    /// literal in this list spells it.
    private static func forbiddenSourceWords() -> [String] {
        [
            ["im", "port "].joined(), ["Da", "te"].joined(), ["Dispatch", "Queue"].joined(),
            ["Swift", "UI"].joined(), ["Ta", "sk"].joined(), ["Cl", "ock"].joined(), ["Dou", "ble"].joined(),
            ["Flo", "at"].joined(), ["defa", "ult:"].joined(), ["static", " var"].joined(),
            ["nonisolated", "(unsafe)"].joined(), ["try", "!"].joined(), ["Core", "MIDI"].joined(),
            ["Ti", "mer"].joined(), ["Thr", "ead"].joined(), ["Ran", "dom"].joined(), ["fatal", "Error"].joined(),
            ["Cod", "able"].joined()
        ]
    }

    private static func sourceDirectory(from path: String = #filePath) -> URL? {
        let here = URL(fileURLWithPath: path).deletingLastPathComponent()
        let candidates = ["../Shared/MIDI/Session", "../../Sources/FluxKlang/Shared/MIDI/Session"]
        let marker = "MIDIInputSession.swift"
        return candidates
            .map { here.appendingPathComponent($0).standardizedFileURL }
            .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent(marker).path) }
    }

    private static let sourcesAreReachable = sourceDirectory() != nil

    /// Looks for each text of `forbiddenSourceWords()` and for a static operator function in the two production
    /// files. The search is over the raw bytes, so a text in a comment is found too, and an API that the list does not
    /// name is not. It is skipped when the sources are not next to the tests.
    @Test(.enabled(if: Self.sourcesAreReachable, "the session sources are not next to the tests"))
    func midiInputSessionSourceFilesStayPure() throws {
        let directory = try #require(Self.sourceDirectory(), "the session sources are not next to the tests")
        var hits: [String] = []
        var scanned = 0
        for name in ["MIDIInputSession.swift", "MIDIInputSessionResult.swift"] {
            let text = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
            scanned += 1
            for word in Self.forbiddenSourceWords() where Self.containsBytes(word, in: text) {
                hits.append("\(name): \(word)")
            }
            if Self.declaresAStaticOperatorFunction(text) { hits.append("\(name): static operator function") }
        }
        #expect(scanned == 2)
        #expect(hits.isEmpty)
    }

    @Test
    func midiInputSessionSourceScanCatchesAPlantedWord() {
        for word in Self.forbiddenSourceWords() {
            let found = Self.containsBytes(word, in: "a " + word + " b")
            #expect(found)
        }
        let missing = Self.containsBytes("nothing", in: "to see here")
        #expect(!missing)
        let plantedOperator = ["static", " func", " == (left: Int) -> Bool"].joined()
        let foundOperator = Self.declaresAStaticOperatorFunction(plantedOperator)
        #expect(foundOperator)
        let plainFunction = ["static", " func", " begin() -> Self"].joined()
        let foundPlain = Self.declaresAStaticOperatorFunction(plainFunction)
        #expect(!foundPlain)
    }
}
