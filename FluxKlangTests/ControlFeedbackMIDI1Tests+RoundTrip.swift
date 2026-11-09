import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Round trip of the encoded bytes through `MIDI1Parser`, `MIDI1PerformanceState(policy: .standard)` and
/// `MIDIControlIntake.resolve`, plus batch bounds, determinism and the source scan of the encoder files.
extension ControlFeedbackMIDI1Tests {
    static func replay(_ bytes: [UInt8]) throws -> [MIDI1StateUpdate] {
        var parser = try #require(MIDI1Parser(maximumSysExPayloadBytes: 16))
        var state = MIDI1PerformanceState(policy: .standard)
        var updates: [MIDI1StateUpdate] = []
        for byte in bytes {
            if let event = parser.consume(byte) { updates.append(try state.apply(event)) }
        }
        return updates
    }

    static func events(_ bytes: [UInt8]) throws -> [MIDI1Event] {
        var parser = try #require(MIDI1Parser(maximumSysExPayloadBytes: 16))
        return bytes.compactMap { parser.consume($0) }
    }

    /// Encodes the position of `step` on the profile's grid and requires the intake to read the same step back.
    static func requireRoundTrip(
        _ source: String, _ profile: EncoderProfile, step: Int,
        dialect: ControlIntakeDialect = .pairedFourteenBit
    ) throws {
        let grid = profile.feedbackGrid
        let position = Double(step) / Double(grid - 1)
        let packet = try Self.run(source, profile, position, dialect: dialect).get()
        #expect(packet.step == step)
        let updates = try Self.replay(packet.bytes)
        let last = try #require(updates.last)
        let sample = try MIDIControlIntake.resolve(
            last, origin: packet.key.origin, profile: profile, dialect: dialect)
        #expect(sample.raw == step)
        #expect(sample.key == packet.key)
        guard case .absolute(let normalized) = sample.input else {
            Issue.record("the sample is not absolute")
            return
        }
        let echoStep = ControlFeedbackEcho.step(of: normalized, grid: grid)
        #expect(echoStep == step)
    }

    static func edgeSteps(of profile: EncoderProfile) -> [Int] {
        let grid = profile.feedbackGrid
        return [0, 1, grid - 2, grid - 1]
    }

    // MARK: Round trip

    @Test
    func midi1FeedbackSevenBitKindsReadBackTheirStepAtTheEdgesOfThreeResolutions() throws {
        let profiles: [EncoderProfile] = [
            .absolute(resolution: 2), .absolute(resolution: 100), .absolute(resolution: 128)
        ]
        for source in ["midi.x.1.cc.65", "midi.x.16.cc.119", "midi.x.4.press.0"] {
            for profile in profiles {
                for step in Self.edgeSteps(of: profile) {
                    try Self.requireRoundTrip(source, profile, step: step)
                }
            }
        }
    }

    @Test
    func midi1FeedbackFourteenBitKindsReadBackTheirStepAtTheEdgesOfThreeResolutions() throws {
        let profiles: [EncoderProfile] = [
            .absolute(resolution: 129), .absolute(resolution: 1_000), .absolute(resolution: 16_384)
        ]
        for source in ["midi.x.2.cc14.5", "midi.x.16.cc14.31", "midi.x.3.bend.0"] {
            for profile in profiles {
                for step in Self.edgeSteps(of: profile) {
                    try Self.requireRoundTrip(source, profile, step: step)
                }
            }
        }
    }

    @Test
    func midi1FeedbackAllHundredAndTwentyEightStepsOfACCReadBackAsTheStepSent() throws {
        for step in 0..<128 {
            try Self.requireRoundTrip("midi.x.1.cc.65", Self.sevenBit, step: step)
        }
    }

    @Test
    func midi1FeedbackAllSixteenThousandThreeHundredEightyFourStepsOfAPitchBendReadBackAsTheStepSent() throws {
        for step in 0..<16_384 {
            try Self.requireRoundTrip("midi.x.1.bend.0", Self.fourteenBit, step: step)
        }
    }

    @Test
    func midi1FeedbackTheSevenBitDialectReadsBackCC1AndCC31AtTheEdges() throws {
        for source in ["midi.x.1.cc.1", "midi.x.5.cc.31"] {
            for step in Self.edgeSteps(of: Self.sevenBit) {
                try Self.requireRoundTrip(source, Self.sevenBit, step: step, dialect: .msbOnlySevenBit)
            }
        }
    }

    @Test
    func midi1FeedbackAFourteenBitPairReportsTheHighSevenBitsFirstAndThenTheFullValue() throws {
        let step = 12_345
        let packet = try Self.run("midi.x.1.cc14.5", Self.fourteenBit, Double(step) / 16_383).get()
        #expect(packet.step == step)
        let updates = try Self.replay(packet.bytes)
        #expect(updates.count == 2)
        let first = try #require(updates.first)
        let intermediate = try MIDIControlIntake.resolve(
            first, origin: packet.key.origin, profile: Self.fourteenBit)
        let expected: Int = (step >> 7) << 7
        #expect(intermediate.raw == expected)
        let last = try #require(updates.last)
        let final = try MIDIControlIntake.resolve(last, origin: packet.key.origin, profile: Self.fourteenBit)
        #expect(final.raw == step)
    }

    @Test
    func midi1FeedbackTheBytesFrameAsCompleteMessagesWithoutRunningStatus() throws {
        let pair = try Self.run("midi.x.2.cc14.5", Self.fourteenBit, 1).get()
        let pairEvents = try Self.events(pair.bytes)
        #expect(pairEvents == [
            .channel(status: 0xB1, data1: 0x05, data2: 0x7F), .channel(status: 0xB1, data1: 0x25, data2: 0x7F)
        ])
        let pressure = try Self.run("midi.x.4.press.0", Self.sevenBit, 1).get()
        let pressureEvents = try Self.events(pressure.bytes)
        #expect(pressureEvents == [.channel(status: 0xD3, data1: 0x7F, data2: nil)])
        let bend = try Self.run("midi.x.3.bend.0", Self.fourteenBit, 1).get()
        let bendEvents = try Self.events(bend.bytes)
        #expect(bendEvents == [.channel(status: 0xE2, data1: 0x7F, data2: 0x7F)])
    }

    @Test
    func midi1FeedbackTheDataBytesAtTheLargestStepAreBelow0x80AndTheStatusBytesAreNot() throws {
        let cases: [(EncoderProfile, Set<Int>)] = [
            (Self.sevenBit, [0]), (Self.fourteenBit, [0, 3]), (Self.fourteenBit, [0]), (Self.sevenBit, [0])
        ]
        let sources = ["midi.x.16.cc.119", "midi.x.16.cc14.31", "midi.x.16.bend.0", "midi.x.16.press.0"]
        for (source, entry) in zip(sources, cases) {
            let bytes = try Self.bytes(source, entry.0, 1)
            for (index, byte) in bytes.enumerated() {
                let isStatus = entry.1.contains(index)
                let isHigh = byte >= 0x80
                #expect(isStatus == isHigh)
            }
        }
    }

    // MARK: Batch

    static func profiles(_ identifiers: [String], _ profile: EncoderProfile) throws -> [BindingID: EncoderProfile] {
        var result: [BindingID: EncoderProfile] = [:]
        for identifier in identifiers { result[try BindingID(identifier)] = profile }
        return result
    }

    @Test
    func midi1FeedbackAnEmptyBatchIsValidAndGivesNoItems() throws {
        let items = try ControlFeedbackMIDI1Encoder.encode(all: [], profiles: [:])
        #expect(items.isEmpty)
    }

    @Test
    func midi1FeedbackABatchOfFourThousandAndNinetySixIsEncodedAndFourThousandAndNinetySevenIsRefused() throws {
        let feedback = try Self.message("midi.x.1.cc.65", 1)
        let profiles = try Self.profiles(["binding-1"], Self.sevenBit)
        let limit = ControlFeedbackMIDI1Encoder.maximumMessages
        #expect(limit == 4_096)
        let belowLimit: Int = limit - 1
        let below = try ControlFeedbackMIDI1Encoder.encode(
            all: Array(repeating: feedback, count: belowLimit), profiles: profiles)
        #expect(below.count == belowLimit)
        let full = try ControlFeedbackMIDI1Encoder.encode(
            all: Array(repeating: feedback, count: limit), profiles: profiles)
        #expect(full.count == limit)
        let last = try #require(full.last)
        let packet = try last.outcome.get()
        #expect(packet.bytes == [0xB0, 0x41, 0x7F])
        let over = limit + 1
        #expect(throws: Refusal.tooManyMessages(over)) {
            try ControlFeedbackMIDI1Encoder.encode(
                all: Array(repeating: feedback, count: over), profiles: profiles)
        }
    }

    @Test
    func midi1FeedbackTheBatchSizeIsRefusedBeforeAnyMissingProfileIsReported() throws {
        let feedback = try Self.message("midi.x.1.cc.65", 1)
        let over = ControlFeedbackMIDI1Encoder.maximumMessages + 1
        #expect(throws: Refusal.tooManyMessages(over)) {
            try ControlFeedbackMIDI1Encoder.encode(all: Array(repeating: feedback, count: over), profiles: [:])
        }
    }

    @Test
    func midi1FeedbackAMissingProfileOrABadMessageRefusesItsOwnItemAndKeepsInputOrder() throws {
        let first = try Self.message("midi.x.1.cc.65", 1, binding: "binding-a")
        let missing = try Self.message("midi.x.1.cc.65", 1, binding: "binding-missing")
        let bad = try Self.message("midi.x.01.cc.65", 1, binding: "binding-bad")
        let last = try Self.message("midi.x.2.press.0", 0, binding: "binding-z")
        let profiles = try Self.profiles(["binding-a", "binding-bad", "binding-z"], Self.sevenBit)
        let items = try ControlFeedbackMIDI1Encoder.encode(all: [first, missing, bad, last], profiles: profiles)
        let identifiers = items.map(\.binding)
        let expected = try ["binding-a", "binding-missing", "binding-bad", "binding-z"].map { try BindingID($0) }
        #expect(identifiers == expected)
        let expectedFirst = try Self.run("midi.x.1.cc.65", Self.sevenBit, 1)
        let expectedMissing = Outcome.failure(.profileMissing(try BindingID("binding-missing")))
        let pressure = try Self.bytes("midi.x.2.press.0", Self.sevenBit, 0)
        guard items.count == 4 else {
            Issue.record("expected four items, got \(items.count)")
            return
        }
        #expect(items[0].outcome == expectedFirst)
        #expect(items[1].outcome == expectedMissing)
        #expect(items[2].outcome == .failure(.malformedSource))
        let lastPacket = try items[3].outcome.get()
        #expect(lastPacket.bytes == pressure)
    }

    @Test
    func midi1FeedbackAMissingProfileIsReportedBeforeAMalformedSourceOfTheSameMessage() throws {
        let feedback = try Self.message("midi.x.01.cc.65", 1, binding: "binding-missing")
        let items = try ControlFeedbackMIDI1Encoder.encode(all: [feedback], profiles: [:])
        let item = try #require(items.first)
        #expect(item.outcome == .failure(.profileMissing(try BindingID("binding-missing"))))
    }

    @Test
    func midi1FeedbackTwoMessagesForOneBindingAreEncodedSeparately() throws {
        let low = try Self.message("midi.x.1.cc.65", 0)
        let high = try Self.message("midi.x.1.cc.65", 1)
        let profiles = try Self.profiles(["binding-1"], Self.sevenBit)
        let items = try ControlFeedbackMIDI1Encoder.encode(all: [low, high, low], profiles: profiles)
        let bytes = try items.map { try $0.outcome.get().bytes }
        #expect(bytes == [[0xB0, 0x41, 0x00], [0xB0, 0x41, 0x7F], [0xB0, 0x41, 0x00]])
    }

    @Test
    func midi1FeedbackTheSevenBitDialectReachesTheBatchAndRefusesAPairItemByItem() throws {
        let pair = try Self.message("midi.x.1.cc14.5", 1)
        let plain = try Self.message("midi.x.1.cc.7", 1, binding: "binding-2")
        let profiles = try Self.profiles(["binding-1"], Self.fourteenBit).merging(
            try Self.profiles(["binding-2"], Self.sevenBit)) { first, _ in first }
        let items = try ControlFeedbackMIDI1Encoder.encode(
            all: [pair, plain], profiles: profiles, dialect: .msbOnlySevenBit)
        guard items.count == 2 else {
            Issue.record("expected two items, got \(items.count)")
            return
        }
        #expect(items[0].outcome == .failure(.unsupportedKind(.controller14)))
        let plainPacket = try items[1].outcome.get()
        #expect(plainPacket.bytes == [0xB0, 0x07, 0x7F])
    }

    @Test
    func midi1FeedbackTheBatchWithoutADialectArgumentEncodesAPairMostSignificantFirst() throws {
        let pair = try Self.message("midi.x.1.cc14.5", 1)
        let profiles = try Self.profiles(["binding-1"], Self.fourteenBit)
        let items = try ControlFeedbackMIDI1Encoder.encode(all: [pair], profiles: profiles)
        let item = try #require(items.first)
        let packet = try item.outcome.get()
        #expect(packet.bytes == [0xB0, 0x05, 0x7F, 0xB0, 0x25, 0x7F])
    }

    // MARK: Determinism

    @Test
    func midi1FeedbackEncodingTheSameMessageTwiceGivesEqualPacketsAndEqualBatches() throws {
        let first = try Self.run("midi.x.2.cc14.5", Self.fourteenBit, 0.3)
        let second = try Self.run("midi.x.2.cc14.5", Self.fourteenBit, 0.3)
        #expect(first == second)
        let feedback = try Self.message("midi.x.1.bend.0", 0.7)
        let profiles = try Self.profiles(["binding-1"], Self.fourteenBit)
        let batchOne = try ControlFeedbackMIDI1Encoder.encode(all: [feedback, feedback], profiles: profiles)
        let batchTwo = try ControlFeedbackMIDI1Encoder.encode(all: [feedback, feedback], profiles: profiles)
        #expect(batchOne == batchTwo)
    }

    // MARK: Source scan

    private static func sourceDirectory(from path: String = #filePath) -> URL? {
        let here = URL(fileURLWithPath: path).deletingLastPathComponent()
        let candidates = [
            "../Shared/Control/Feedback/Encode",
            "../../Sources/FluxKlang/Shared/Control/Feedback/Encode"
        ]
        let marker = "ControlFeedbackMIDI1Encoder.swift"
        return candidates
            .map { here.appendingPathComponent($0).standardizedFileURL }
            .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent(marker).path) }
    }

    private static let sourcesAreReachable = sourceDirectory() != nil

    private static let forbiddenWords: [String] = [
        ["Ta", "sk"].joined(), ["Clo", "ck"].joined(), ["def", "ault:"].joined(), ["Da", "te"].joined(),
        "DispatchQueue", "import ", ["mut", "ating"].joined(), "static var", ["try", "!"].joined(),
        "fatalError", ["Dou", "ble"].joined(), "SwiftUI"
    ]

    private static func scan(_ text: String) -> [String] {
        forbiddenWords.filter { text.contains($0) }
    }

    @Test
    func midi1FeedbackTheSourceScanFindsAPlantedWordAndIgnoresPlainText() {
        let planted = "let value = " + (Self.forbiddenWords.first ?? "")
        let found = Self.scan(planted)
        #expect(found.count == 1)
        let clean = Self.scan("let value = 1")
        #expect(clean.isEmpty)
    }

    @Test(.enabled(if: sourcesAreReachable))
    func midi1FeedbackTheFourEncoderFilesContainNoForbiddenWord() throws {
        let directory = try #require(Self.sourceDirectory())
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        #expect(names.count == 4)
        for name in names {
            let text = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
            let found = Self.scan(text)
            #expect(found.isEmpty, "\(name) names \(found)")
        }
    }
}
