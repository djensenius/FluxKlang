import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// MIDI 1 control feedback bytes (#88, slice FBM1): goldens, refusals, refusal order and batch bounds. The round trip
/// through the MIDI 1 state and the intake is in `ControlFeedbackMIDI1Tests+RoundTrip.swift`. Goldens are typed by
/// hand and positions are exact binary fractions, so the expected step is unambiguous.
@Suite("ControlFeedbackMIDI1Tests")
struct ControlFeedbackMIDI1Tests {
    typealias Outcome = Result<ControlFeedbackMIDI1Packet, ControlFeedbackMIDI1Refusal>
    typealias Refusal = ControlFeedbackMIDI1Refusal

    static let sevenBit = EncoderProfile.absolute(resolution: 128)
    static let fourteenBit = EncoderProfile.absolute(resolution: 16_384)
    static let maximumOrigin = "abcdefghijklmnopqrstuvwxyz012345"

    static func message(
        _ source: String, _ position: Double, binding: String = "binding-1"
    ) throws -> ControlFeedbackMessage {
        try ControlFeedbackMessage(
            binding: BindingID(binding), source: ControlSourceID(source), position: position, reason: .refresh)
    }

    static func run(
        _ source: String, _ profile: EncoderProfile, _ position: Double = 1,
        dialect: ControlIntakeDialect = .pairedFourteenBit
    ) throws -> Outcome {
        let feedback = try message(source, position)
        do throws(ControlFeedbackMIDI1Refusal) {
            return .success(try ControlFeedbackMIDI1Encoder.encode(feedback, profile: profile, dialect: dialect))
        } catch {
            return .failure(error)
        }
    }

    static func bytes(
        _ source: String, _ profile: EncoderProfile, _ position: Double = 1,
        dialect: ControlIntakeDialect = .pairedFourteenBit
    ) throws -> [UInt8] {
        let outcome = try run(source, profile, position, dialect: dialect)
        let packet = try outcome.get()
        return packet.bytes
    }

    static func refusal(
        _ source: String, _ profile: EncoderProfile, _ position: Double = 1,
        dialect: ControlIntakeDialect = .pairedFourteenBit
    ) throws -> Refusal? {
        let outcome = try run(source, profile, position, dialect: dialect)
        if case .failure(let reason) = outcome { return reason }
        return nil
    }

    // MARK: Goldens

    @Test
    func midi1FeedbackAPlainCCIsThreeBytesOnTheChannelNibble() throws {
        let source = "midi.lcxl-1.1.cc.65"
        let low = try Self.bytes(source, Self.sevenBit, 0)
        #expect(low == [0xB0, 0x41, 0x00])
        let high = try Self.bytes(source, Self.sevenBit, 1)
        #expect(high == [0xB0, 0x41, 0x7F])
        let half = try Self.bytes(source, Self.sevenBit, 0.5)
        #expect(half == [0xB0, 0x41, 0x40])
        let quarter = try Self.bytes(source, Self.sevenBit, 0.25)
        #expect(quarter == [0xB0, 0x41, 0x20])
        let channelSixteen = try Self.bytes("midi.lcxl-1.16.cc.65", Self.sevenBit, 1)
        #expect(channelSixteen == [0xBF, 0x41, 0x7F])
    }

    @Test
    func midi1FeedbackAFourteenBitPairIsSixBytesMostSignificantFirst() throws {
        let source = "midi.x.2.cc14.5"
        let high = try Self.bytes(source, Self.fourteenBit, 1)
        #expect(high == [0xB1, 0x05, 0x7F, 0xB1, 0x25, 0x7F])
        let low = try Self.bytes(source, Self.fourteenBit, 0)
        #expect(low == [0xB1, 0x05, 0x00, 0xB1, 0x25, 0x00])
        let half = try Self.bytes(source, Self.fourteenBit, 0.5)
        #expect(half == [0xB1, 0x05, 0x40, 0xB1, 0x25, 0x00])
    }

    @Test
    func midi1FeedbackPitchBendIsThreeBytesLeastSignificantFirst() throws {
        let source = "midi.x.3.bend.0"
        let high = try Self.bytes(source, Self.fourteenBit, 1)
        #expect(high == [0xE2, 0x7F, 0x7F])
        let low = try Self.bytes(source, Self.fourteenBit, 0)
        #expect(low == [0xE2, 0x00, 0x00])
        let half = try Self.bytes(source, Self.fourteenBit, 0.5)
        #expect(half == [0xE2, 0x00, 0x40])
        let packet = try Self.run(source, Self.fourteenBit, 1).get()
        #expect(packet.step == 16_383)
    }

    @Test
    func midi1FeedbackChannelPressureIsTwoBytes() throws {
        let source = "midi.x.4.press.0"
        let high = try Self.bytes(source, Self.sevenBit, 1)
        #expect(high == [0xD3, 0x7F])
        let low = try Self.bytes(source, Self.sevenBit, 0)
        #expect(low == [0xD3, 0x00])
    }

    @Test
    func midi1FeedbackAResolutionOfOneHundredAndOfTwoStepsOnItsOwnGrid() throws {
        let hundred = try Self.bytes("midi.lcxl-1.1.cc.65", .absolute(resolution: 100), 1)
        #expect(hundred == [0xB0, 0x41, 0x63])
        let two = try Self.bytes("midi.lcxl-1.1.cc.65", .absolute(resolution: 2), 0.5)
        #expect(two == [0xB0, 0x41, 0x01])
    }

    @Test
    func midi1FeedbackTheSevenBitDialectSendsAPairNumberAsAPlainCCAndTheDefaultRefusesIt() throws {
        let seven = try Self.bytes(
            "midi.x.1.cc.7", Self.sevenBit, 1, dialect: .msbOnlySevenBit)
        #expect(seven == [0xB0, 0x07, 0x7F])
        let byDefault = try Self.refusal("midi.x.1.cc.7", Self.sevenBit, 1)
        #expect(byDefault == .controllerNotReadable(number: 7))
        let omitted = try ControlFeedbackMIDI1Encoder.encode(
            Self.message("midi.x.1.cc14.5", 1), profile: Self.fourteenBit)
        #expect(omitted.bytes == [0xB0, 0x05, 0x7F, 0xB0, 0x25, 0x7F])
        let dataEntry = try Self.refusal("midi.x.1.cc.6", Self.sevenBit, 1, dialect: .msbOnlySevenBit)
        #expect(dataEntry == .controllerNotReadable(number: 6))
        let pairDataEntry = try Self.refusal("midi.x.1.cc14.6", Self.fourteenBit, 1)
        #expect(pairDataEntry == .controllerNotReadable(number: 6))
        let pairUnderSeven = try Self.refusal(
            "midi.x.1.cc14.5", Self.fourteenBit, 1, dialect: .msbOnlySevenBit)
        #expect(pairUnderSeven == .unsupportedKind(.controller14))
    }

    @Test
    func midi1FeedbackTheLargestEncodableKeyAndTheRangeEdgesEncode() throws {
        let source = "midi.\(Self.maximumOrigin).16.cc14.31"
        #expect(source.utf8.count == 48)
        let edge = try Self.bytes(source, Self.fourteenBit, 1)
        #expect(edge == [0xBF, 0x1F, 0x7F, 0xBF, 0x3F, 0x7F])
        let lowest = try Self.bytes("midi.x.1.cc14.1", Self.fourteenBit, 1)
        #expect(lowest == [0xB0, 0x01, 0x7F, 0xB0, 0x21, 0x7F])
        let firstReachable = try Self.bytes("midi.x.1.cc.65", Self.sevenBit, 1)
        #expect(firstReachable == [0xB0, 0x41, 0x7F])
        let lastReachable = try Self.bytes("midi.x.1.cc.119", Self.sevenBit, 1)
        #expect(lastReachable == [0xB0, 0x77, 0x7F])
    }

    // MARK: Source parsing

    @Test
    func midi1FeedbackTheParserReadsACanonicalSourceBackIntoItsKey() throws {
        let key = try ControlFeedbackMIDI1SourceParser.parse(ControlSourceID("midi.lcxl-1.16.cc14.5"))
        #expect(key.origin.token == "lcxl-1")
        #expect(key.channel == 16)
        #expect(key.kind == .controller14)
        #expect(key.number == 5)
        let bend = try ControlFeedbackMIDI1SourceParser.parse(ControlSourceID("midi.a.1.bend.0"))
        #expect(bend.kind == .pitchBend)
        let nrpn = try ControlFeedbackMIDI1SourceParser.parse(ControlSourceID("midi.a.1.nrpn.16383"))
        #expect(nrpn.number == 16_383)
    }

    @Test
    func midi1FeedbackTheParserRefusesTheListedNonCanonicalAndOutOfRangeSpellings() throws {
        let malformed = [
            "midi.x.01.cc.65", "midi.x.1.cc.065", "midi.x.1.cc.65-", "midi.x.1.cc", "midi.x.1.cc.65.9",
            "midi.x.17.cc.65", "midi.x.0.cc.65", "midi.X.1.cc.65", "midi.x.1.cc.128", "midi.x.1.foo.1",
            "midi.x.1.cc.", "midi..1.cc.65", "midi.x.256.cc.65", "midi.x.1.cc.65536", "midi.x", "midi.",
            "midi.x.1.cc14.32", "midi.x.1.cc14.0", "midi.x.1.bend.1", "midi.x.1.CC.65"
        ]
        for text in malformed {
            let id = try ControlSourceID(text)
            #expect(throws: Refusal.malformedSource) { try ControlFeedbackMIDI1SourceParser.parse(id) }
        }
    }

    @Test
    func midi1FeedbackASourceWithoutTheMidiPrefixIsNotMIDIEvenWhenItIsAlmostOne() throws {
        for text in ["par.mains.gain", "midi", "midix.1.1.cc.65", "Midi.x.1.cc.65", "mid", "x"] {
            let id = try ControlSourceID(text)
            #expect(throws: Refusal.notMIDISource) { try ControlFeedbackMIDI1SourceParser.parse(id) }
        }
    }

    @Test
    func midi1FeedbackAMidiSourceOfFiftyTwoOrOfOneHundredAndTwentyEightBytesIsMalformed() throws {
        let fiftyTwo = "midi.\(Self.maximumOrigin).16.cc14.000031"
        #expect(fiftyTwo.utf8.count == 52)
        let first = try Self.refusal(fiftyTwo, Self.fourteenBit)
        #expect(first == .malformedSource)
        let padding = String(repeating: "7", count: 128 - 46)
        let longest = "midi.\(Self.maximumOrigin).16.cc14.\(padding)"
        #expect(longest.utf8.count == 128)
        let second = try Self.refusal(longest, Self.fourteenBit)
        #expect(second == .malformedSource)
    }

    // MARK: Refusals, each alone

    @Test
    func midi1FeedbackANonMIDISourceIsRefusedAsNotMIDI() throws {
        let reason = try Self.refusal("par.mains.gain", Self.sevenBit)
        #expect(reason == .notMIDISource)
    }

    @Test
    func midi1FeedbackAMalformedMidiSourceIsRefusedAsMalformed() throws {
        let reason = try Self.refusal("midi.x.01.cc.65", Self.sevenBit)
        #expect(reason == .malformedSource)
    }

    @Test
    func midi1FeedbackRPNAndNRPNAreRefusedAsUnsupportedWithTheirOwnKind() throws {
        let registered = try Self.refusal("midi.x.1.rpn.5", Self.fourteenBit)
        #expect(registered == .unsupportedKind(.registeredParameter))
        let nonRegistered = try Self.refusal("midi.x.1.nrpn.16383", Self.fourteenBit)
        #expect(nonRegistered == .unsupportedKind(.nonRegisteredParameter))
    }

    @Test
    func midi1FeedbackEachRelativeProfileIsRefusedAsRelative() throws {
        let profiles: [EncoderProfile] = [
            .binaryOffset(width: .seven), .twosComplement(width: .seven), .signMagnitude(width: .seven),
            .binaryOffset(width: .fourteen)
        ]
        for profile in profiles {
            let reason = try Self.refusal("midi.x.1.cc.65", profile)
            #expect(reason == .relativeProfile)
        }
    }

    @Test
    func midi1FeedbackAResolutionOutsideTwoToSixteenThousandThreeHundredEightyFourIsInvalid() throws {
        for resolution in [-1, 0, 1, 16_385] {
            let reason = try Self.refusal("midi.x.1.cc.65", .absolute(resolution: resolution))
            #expect(reason == .invalidProfile(resolution: resolution))
        }
        let smallest = try Self.refusal("midi.x.1.cc.65", .absolute(resolution: 2))
        #expect(smallest == nil)
        let largest = try Self.refusal("midi.x.1.bend.0", .absolute(resolution: 16_384))
        #expect(largest == nil)
    }

    @Test
    func midi1FeedbackTheWidthOfTheKindMustEqualTheWidthTheProfileReadsAtOneHundredTwentyEightAndTwentyNine() throws {
        let sevenKindWide = try Self.refusal("midi.x.1.cc.65", .absolute(resolution: 129))
        #expect(sevenKindWide == .widthMismatch(messageBits: 7, profileBits: 14))
        let pressureWide = try Self.refusal("midi.x.1.press.0", .absolute(resolution: 16_384))
        #expect(pressureWide == .widthMismatch(messageBits: 7, profileBits: 14))
        let wideKindSeven = try Self.refusal("midi.x.1.cc14.5", .absolute(resolution: 128))
        #expect(wideKindSeven == .widthMismatch(messageBits: 14, profileBits: 7))
        let bendSeven = try Self.refusal("midi.x.1.bend.0", .absolute(resolution: 2))
        #expect(bendSeven == .widthMismatch(messageBits: 14, profileBits: 7))
        let sevenAt128 = try Self.refusal("midi.x.1.cc.65", .absolute(resolution: 128))
        #expect(sevenAt128 == nil)
        let wideAt129 = try Self.refusal("midi.x.1.cc14.5", .absolute(resolution: 129))
        #expect(wideAt129 == nil)
    }

    @Test
    func midi1FeedbackACCNumberTheIntakeCannotReadBackIsRefusedWithItsNumber() throws {
        for number in [0, 7, 31, 64, 96, 98, 101, 120, 127] {
            let reason = try Self.refusal("midi.x.1.cc.\(number)", Self.sevenBit)
            #expect(reason == .controllerNotReadable(number: number))
        }
        for number in [65, 95, 102, 119] {
            let reason = try Self.refusal("midi.x.1.cc.\(number)", Self.sevenBit)
            #expect(reason == nil)
        }
        let seven = try Self.refusal("midi.x.1.cc.1", Self.sevenBit, 1, dialect: .msbOnlySevenBit)
        #expect(seven == nil)
        let thirtyOne = try Self.refusal("midi.x.1.cc.31", Self.sevenBit, 1, dialect: .msbOnlySevenBit)
        #expect(thirtyOne == nil)
        let thirtyTwo = try Self.refusal("midi.x.1.cc.32", Self.sevenBit, 1, dialect: .msbOnlySevenBit)
        #expect(thirtyTwo == .controllerNotReadable(number: 32))
    }

    @Test
    func midi1FeedbackTheByteBuilderRefusesAStepOutsideTheWidthAndAKindWithoutAnEncoding() throws {
        let paired = ControlIntakeDialect.pairedFourteenBit
        let plain = try ControlFeedbackMIDI1SourceParser.parse(ControlSourceID("midi.x.1.cc.65"))
        #expect(throws: Refusal.stepOutOfRange(step: 128, maximum: 127)) {
            try ControlFeedbackMIDI1Packet.make(key: plain, step: 128, dialect: paired)
        }
        #expect(throws: Refusal.stepOutOfRange(step: -1, maximum: 127)) {
            try ControlFeedbackMIDI1Packet.make(key: plain, step: -1, dialect: paired)
        }
        let bend = try ControlFeedbackMIDI1SourceParser.parse(ControlSourceID("midi.x.1.bend.0"))
        #expect(throws: Refusal.stepOutOfRange(step: 16_384, maximum: 16_383)) {
            try ControlFeedbackMIDI1Packet.make(key: bend, step: 16_384, dialect: paired)
        }
        let last = try ControlFeedbackMIDI1Packet.make(key: bend, step: 16_383, dialect: paired)
        #expect(last.bytes == [0xE0, 0x7F, 0x7F])
        let rpn = try ControlFeedbackMIDI1SourceParser.parse(ControlSourceID("midi.x.1.rpn.5"))
        #expect(throws: Refusal.unsupportedKind(.registeredParameter)) {
            try ControlFeedbackMIDI1Packet.make(key: rpn, step: 0, dialect: paired)
        }
        #expect(throws: Refusal.stepOutOfRange(step: 16_384, maximum: 16_383)) {
            try ControlFeedbackMIDI1Packet.make(key: rpn, step: 16_384, dialect: paired)
        }
        let nrpn = try ControlFeedbackMIDI1SourceParser.parse(ControlSourceID("midi.x.1.nrpn.5"))
        #expect(throws: Refusal.unsupportedKind(.nonRegisteredParameter)) {
            try ControlFeedbackMIDI1Packet.make(key: nrpn, step: 0, dialect: paired)
        }
        #expect(throws: Refusal.stepOutOfRange(step: 16_384, maximum: 16_383)) {
            try ControlFeedbackMIDI1Packet.make(key: nrpn, step: 16_384, dialect: paired)
        }
    }

    @Test
    func midi1FeedbackTheByteBuilderRefusesAnUnreadableKeyBeforeAStepOutsideTheWidth() throws {
        let paired = ControlIntakeDialect.pairedFourteenBit
        let unreadable = try ControlFeedbackMIDI1SourceParser.parse(ControlSourceID("midi.x.1.cc.64"))
        #expect(throws: Refusal.controllerNotReadable(number: 64)) {
            try ControlFeedbackMIDI1Packet.make(key: unreadable, step: 0, dialect: paired)
        }
        #expect(throws: Refusal.controllerNotReadable(number: 64)) {
            try ControlFeedbackMIDI1Packet.make(key: unreadable, step: 128, dialect: paired)
        }
        let dataEntry = try ControlFeedbackMIDI1SourceParser.parse(ControlSourceID("midi.x.1.cc14.6"))
        #expect(throws: Refusal.controllerNotReadable(number: 6)) {
            try ControlFeedbackMIDI1Packet.make(key: dataEntry, step: 16_384, dialect: paired)
        }
        let pair = try ControlFeedbackMIDI1SourceParser.parse(ControlSourceID("midi.x.1.cc14.5"))
        #expect(throws: Refusal.unsupportedKind(.controller14)) {
            try ControlFeedbackMIDI1Packet.make(key: pair, step: 16_384, dialect: .msbOnlySevenBit)
        }
        let packet = try ControlFeedbackMIDI1Packet.make(key: pair, step: 16_383, dialect: paired)
        #expect(packet.step == 16_383)
    }

    // MARK: Refusal order: every fixture holds both defects

    @Test
    func midi1FeedbackANonMIDISourceWithARelativeProfileIsReportedAsNotMIDI() throws {
        let reason = try Self.refusal("par.mains.gain", .binaryOffset(width: .seven))
        #expect(reason == .notMIDISource)
    }

    @Test
    func midi1FeedbackAMalformedSourceWithARelativeProfileIsReportedAsMalformed() throws {
        let reason = try Self.refusal("midi.x.01.cc.65", .binaryOffset(width: .seven))
        #expect(reason == .malformedSource)
    }

    @Test
    func midi1FeedbackRPNWithARelativeProfileIsReportedAsUnsupported() throws {
        let reason = try Self.refusal("midi.x.1.rpn.5", .binaryOffset(width: .fourteen))
        #expect(reason == .unsupportedKind(.registeredParameter))
    }

    @Test
    func midi1FeedbackRPNWithAResolutionOfOneIsReportedAsUnsupported() throws {
        let reason = try Self.refusal("midi.x.1.rpn.5", .absolute(resolution: 1))
        #expect(reason == .unsupportedKind(.registeredParameter))
    }

    @Test
    func midi1FeedbackARelativeProfileOfTheWrongWidthIsReportedAsRelativeBeforeTheWidthMismatch() throws {
        let reason = try Self.refusal("midi.x.1.cc14.5", .binaryOffset(width: .seven))
        #expect(reason == .relativeProfile)
    }

    @Test
    func midi1FeedbackAResolutionOfOneOnAFourteenBitKindIsReportedAsInvalidBeforeTheWidthMismatch() throws {
        let reason = try Self.refusal("midi.x.1.cc14.5", .absolute(resolution: 1))
        #expect(reason == .invalidProfile(resolution: 1))
    }

    @Test
    func midi1FeedbackAWidthMismatchIsReportedBeforeAnUnreadableNumberForPlainAndForPairedCCs() throws {
        let plain = try Self.refusal("midi.x.1.cc.6", Self.fourteenBit)
        #expect(plain == .widthMismatch(messageBits: 7, profileBits: 14))
        let paired = try Self.refusal("midi.x.1.cc14.6", Self.sevenBit)
        #expect(paired == .widthMismatch(messageBits: 14, profileBits: 7))
    }

    @Test
    func midi1FeedbackAPairUnderTheSevenBitDialectIsUnsupportedBeforeItsNumberIsJudged() throws {
        let reason = try Self.refusal("midi.x.1.cc14.6", Self.fourteenBit, 1, dialect: .msbOnlySevenBit)
        #expect(reason == .unsupportedKind(.controller14))
        let relative = try Self.refusal("midi.x.1.cc14.6", .binaryOffset(width: .seven), 1, dialect: .msbOnlySevenBit)
        #expect(relative == .unsupportedKind(.controller14))
    }
}
