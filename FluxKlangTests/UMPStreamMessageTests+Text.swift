import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension UMPStreamMessageTests {
    private static func packet(_ words: [UInt32]) throws -> UMPPacket {
        try UMPPacket(words: words)
    }

    private static func name(_ kind: UMPStreamTextKind, _ value: String, index: Int = 4) -> UMPStreamMessage {
        switch kind {
        case .endpointName: return .endpointName(UMPStreamString(value))
        case .productInstanceID: return .productInstanceID(UMPStreamString(value))
        case .functionBlockName: return .functionBlockName(index: index, name: UMPStreamString(value))
        }
    }

    private static func fresh(_ limit: Int = 255) throws -> UMPStreamTextAssembler {
        UMPStreamTextAssembler(limits: try limits(limit))
    }

    private static func feed(
        _ assembler: inout UMPStreamTextAssembler,
        _ words: [UInt32]
    ) throws -> UMPStreamTextEvent {
        try assembler.feed(UMPPacket(words: words))
    }

    private static func feedRefusal(
        _ assembler: inout UMPStreamTextAssembler,
        _ words: [UInt32]
    ) throws -> UMPStreamRefusal? {
        let packet = try UMPPacket(words: words)
        let before = assembler
        do {
            _ = try assembler.feed(packet)
            return nil
        } catch {
            #expect(assembler == before, "a refused packet changed the assembler")
            return error
        }
    }

    /// Text packet words by role: `.start` etc. use the kind's status; the optional index is the block index.
    private static func piece(
        _ kind: UMPStreamTextKind,
        _ format: UMPStreamFormat,
        _ bytes: [UInt8],
        index: UInt8 = 4
    ) -> [UInt32] {
        textWords(
            status: UInt32(kind.status), format: UInt32(format.rawValue),
            index: kind == .functionBlockName ? index : nil, bytes: bytes
        )
    }

    @Test func endpointNameLengthsRoundTripAtEveryPacketBoundaryWithTheLowestPacketCount() throws {
        let expectedPackets = [(0, 1), (1, 1), (13, 1), (14, 1), (15, 2), (27, 2), (28, 2), (29, 3), (97, 7), (98, 7)]
        for (length, count) in expectedPackets {
            let message = Self.name(.endpointName, Self.text(length))
            let packets = try Self.encode(message)
            #expect(packets.count == count, "length \(length)")
            var assembler = try Self.fresh()
            var last: UMPStreamTextEvent?
            for words in packets { last = try Self.feed(&assembler, words) }
            #expect(last == .complete(message), "length \(length)")
            #expect(!assembler.isAssembling)
        }
    }

    @Test func endpointNameFormatsAreCompleteOrStartContinueEnd() throws {
        func formats(_ length: Int) throws -> [UInt32] {
            try Self.encode(Self.name(.endpointName, Self.text(length))).map { ($0[0] >> 26) & 3 }
        }
        #expect(try formats(14) == [0])
        #expect(try formats(15) == [1, 3])
        #expect(try formats(29) == [1, 2, 3])
        #expect(try formats(98) == [1, 2, 2, 2, 2, 2, 3])
        var assembler = try Self.fresh()
        let packets = try Self.encode(Self.name(.endpointName, Self.text(29)))
        #expect(try Self.feed(&assembler, packets[0]) == .partial)
        #expect(try Self.feed(&assembler, packets[1]) == .partial)
        #expect(try Self.feed(&assembler, packets[2]) == .complete(Self.name(.endpointName, Self.text(29))))
    }

    @Test func endpointNameMaximumIsNinetyEightBytesAndNinetyNineIsRefused() throws {
        #expect(try Self.encodeRefusal(Self.name(.endpointName, Self.text(98))) == nil)
        #expect(try Self.encodeRefusal(Self.name(.endpointName, Self.text(99))) == .textTooLong(99))
    }

    @Test func productInstanceIDMaximumIsFortyTwoBytesInThreePacketsAndFortyThreeIsRefused() throws {
        #expect(try Self.encode(Self.name(.productInstanceID, Self.text(42))).count == 3)
        #expect(try Self.encodeRefusal(Self.name(.productInstanceID, Self.text(43))) == .textTooLong(43))
        #expect(try Self.encode(Self.name(.productInstanceID, Self.text(15))).count == 2)
    }

    @Test func functionBlockNameCarriesThirteenBytesPerPacketUpToNinetyOne() throws {
        let expected = [(0, 1), (1, 1), (13, 1), (14, 2), (26, 2), (27, 3), (90, 7), (91, 7)]
        for (length, count) in expected {
            let message = Self.name(.functionBlockName, Self.text(length), index: 7)
            let packets = try Self.encode(message)
            #expect(packets.count == count, "length \(length)")
            for words in packets { #expect((words[0] >> 8) & 0xFF == 7) }
            var assembler = try Self.fresh()
            var last: UMPStreamTextEvent?
            for words in packets { last = try Self.feed(&assembler, words) }
            #expect(last == .complete(message), "length \(length)")
        }
        #expect(try Self.encodeRefusal(Self.name(.functionBlockName, Self.text(92))) == .textTooLong(92))
    }

    @Test func textGoldenWordsForAFunctionBlockNameThatNeedsTwoPackets() throws {
        let message = Self.name(.functionBlockName, "ABCDEFGHIJKLMN", index: 6)
        let expected: [[UInt32]] = [
            [0xF412_0641, 0x4243_4445, 0x4647_4849, 0x4A4B_4C4D],
            [0xFC12_064E, 0, 0, 0]
        ]
        #expect(try Self.encode(message) == expected)
    }

    @Test func encodeAcceptsExactlyTheLimitAndRefusesOneByteMoreForEveryKind() throws {
        for kind in [UMPStreamTextKind.endpointName, .productInstanceID, .functionBlockName] {
            for limit in [1, 5, 13, 14, 15, 27, 28, 40, 42] {
                #expect(
                    try Self.encodeRefusal(Self.name(kind, Self.text(limit)), limit: limit) == nil,
                    "\(kind) \(limit)"
                )
                #expect(
                    try Self.encodeRefusal(Self.name(kind, Self.text(limit + 1)), limit: limit)
                        == .textTooLong(limit + 1),
                    "\(kind) \(limit)"
                )
            }
        }
        #expect(try Self.encodeRefusal(Self.name(.endpointName, ""), limit: 1) == nil)
    }

    @Test func aCallerLimitAboveTheMessageMaximumNeverRaisesTheMessageMaximum() throws {
        #expect(try Self.encodeRefusal(Self.name(.endpointName, Self.text(99)), limit: 255) == .textTooLong(99))
        #expect(try Self.encodeRefusal(Self.name(.productInstanceID, Self.text(43)), limit: 255) == .textTooLong(43))
        #expect(try Self.encodeRefusal(Self.name(.functionBlockName, Self.text(92)), limit: 255) == .textTooLong(92))
        #expect(try Self.encodeRefusal(Self.name(.endpointName, Self.text(98)), limit: 255) == nil)
    }

    @Test func emptyTextsAreOneCompletePacketPerKindAndDecodeToTheEmptyString() throws {
        #expect(try Self.encode(Self.name(.endpointName, "")) == [[0xF003_0000, 0, 0, 0]])
        #expect(try Self.encode(Self.name(.productInstanceID, "")) == [[0xF004_0000, 0, 0, 0]])
        #expect(try Self.encode(Self.name(.functionBlockName, "", index: 3)) == [[0xF012_0300, 0, 0, 0]])
        #expect(try Self.decode([0xF003_0000, 0, 0, 0]) == Self.name(.endpointName, ""))
        #expect(try Self.decode([0xF012_0300, 0, 0, 0]) == Self.name(.functionBlockName, "", index: 3))
        var assembler = try Self.fresh(1)
        #expect(try Self.feed(&assembler, [0xF004_0000, 0, 0, 0]) == .complete(Self.name(.productInstanceID, "")))
    }

    @Test func characterCountDoesNotDecideTheByteLimit() throws {
        let decomposed = String(repeating: "e\u{301}", count: 10)
        #expect(decomposed.count == 10)
        #expect(decomposed.utf8.count == 30)
        #expect(try Self.encodeRefusal(Self.name(.endpointName, decomposed), limit: 29) == .textTooLong(30))
        #expect(try Self.encodeRefusal(Self.name(.endpointName, decomposed), limit: 30) == nil)
        let family = String(repeating: "\u{1F468}\u{200D}\u{1F469}", count: 3)
        #expect(family.utf8.count == 33)
        #expect(try Self.encodeRefusal(Self.name(.endpointName, family), limit: 32) == .textTooLong(33))
    }

    @Test func multiByteScalarsStraddlingAPacketBoundaryRoundTripAtEveryOffset() throws {
        for padding in 10...14 {
            let value = String(repeating: "x", count: padding) + "\u{E9}\u{1F3B9}\u{20AC}tail"
            for kind in [UMPStreamTextKind.endpointName, .functionBlockName] {
                let message = Self.name(kind, value)
                var assembler = try Self.fresh()
                var last: UMPStreamTextEvent?
                for words in try Self.encode(message) { last = try Self.feed(&assembler, words) }
                #expect(last == .complete(message), "\(kind) padding \(padding)")
            }
        }
    }

    @Test func namesWithTheSameCharactersButDifferentBytesAreDifferentValues() {
        #expect(UMPStreamString("\u{E9}") != UMPStreamString("e\u{301}"))
        #expect(UMPStreamString("e\u{301}") == UMPStreamString("e\u{301}"))
        #expect(Self.name(.endpointName, "\u{E9}") != Self.name(.endpointName, "e\u{301}"))
    }

    @Test func invalidUTF8IsRefusedOnlyWhenTheTextIsFinishedAndKeepsThePartialText() throws {
        let bad: [[UInt8]] = [[0xFF], [0xC0, 0x80], [0xED, 0xA0, 0x80], [0xC3], [0xF8, 0x88, 0x80, 0x80, 0x80], [0x80]]
        for bytes in bad {
            var assembler = try Self.fresh()
            let head = Array(repeating: UInt8(0x41), count: 13) + [bytes[0]]
            #expect(try Self.feed(&assembler, Self.piece(.endpointName, .start, head)) == .partial)
            let end = Self.piece(.endpointName, .end, Array(bytes.dropFirst()))
            let held = assembler
            #expect(try Self.feedRefusal(&assembler, end) == .invalidUTF8, "\(bytes)")
            #expect(assembler == held)
            #expect(assembler.pendingPacketCount == 1)
        }
        var assembler = try Self.fresh()
        #expect(try Self.feedRefusal(&assembler, Self.piece(.endpointName, .complete, [0xFF])) == .invalidUTF8)
        #expect(!assembler.isAssembling)
    }

    @Test func aMultiByteScalarSplitAcrossTwoPacketsIsValidWhenCompleted() throws {
        var assembler = try Self.fresh()
        let head = Array(repeating: UInt8(0x41), count: 13) + [0xC3]
        #expect(try Self.feed(&assembler, Self.piece(.endpointName, .start, head)) == .partial)
        let finished = try Self.feed(&assembler, Self.piece(.endpointName, .end, [0xA9]))
        #expect(finished == .complete(Self.name(.endpointName, String(repeating: "A", count: 13) + "\u{E9}")))
    }

    @Test func embeddedZeroBytesAreKeptAndOnlyTheFinalPaddingIsStripped() throws {
        let embedded = Self.name(.endpointName, "a\u{0}b")
        #expect(try Self.encode(embedded) == [[0xF003_6100, 0x6200_0000, 0, 0]])
        #expect(try Self.decode([0xF003_6100, 0x6200_0000, 0, 0]) == embedded)
        var assembler = try Self.fresh()
        let zeros = [UInt8(0x41), 0x42] + Array(repeating: UInt8(0), count: 12)
        #expect(try Self.feed(&assembler, Self.piece(.endpointName, .start, zeros)) == .partial)
        let finished = try Self.feed(&assembler, Self.piece(.endpointName, .end, [0x43]))
        #expect(finished == .complete(Self.name(.endpointName, "AB" + String(repeating: "\u{0}", count: 12) + "C")))
        let leading = Self.name(.endpointName, "\u{0}z")
        #expect(try Self.decode(Self.encode(leading)[0]) == leading)
    }

    @Test func aTextEndingInAZeroByteIsRefusedByEncodeAndAZeroOnlyTextToo() throws {
        #expect(try Self.encodeRefusal(Self.name(.endpointName, "ab\u{0}")) == .trailingZeroByte)
        #expect(try Self.encodeRefusal(Self.name(.productInstanceID, "\u{0}")) == .trailingZeroByte)
        #expect(try Self.encodeRefusal(Self.name(.functionBlockName, "x\u{0}\u{0}")) == .trailingZeroByte)
        #expect(try Self.decode([0xF003_6100, 0, 0, 0]) == Self.name(.endpointName, "a"))
    }

    @Test func assemblerJoinsStartContinueEndAndReportsItsProgress() throws {
        var assembler = try Self.fresh()
        #expect(!assembler.isAssembling && assembler.pendingByteCount == 0 && assembler.pendingPacketCount == 0)
        let first = Array("ABCDEFGHIJKLMN".utf8)
        let second = Array("OPQRSTUVWXYZab".utf8)
        let third = Array("cd".utf8)
        #expect(try Self.feed(&assembler, Self.piece(.productInstanceID, .start, first)) == .partial)
        #expect(assembler.isAssembling && assembler.pendingByteCount == 14 && assembler.pendingPacketCount == 1)
        #expect(try Self.feed(&assembler, Self.piece(.productInstanceID, .continuation, second)) == .partial)
        #expect(assembler.pendingByteCount == 28 && assembler.pendingPacketCount == 2)
        let done = try Self.feed(&assembler, Self.piece(.productInstanceID, .end, third))
        #expect(done == .complete(Self.name(.productInstanceID, "ABCDEFGHIJKLMNOPQRSTUVWXYZabcd")))
        #expect(!assembler.isAssembling && assembler.pendingByteCount == 0 && assembler.pendingPacketCount == 0)
        #expect(assembler == (try Self.fresh()))
    }

    @Test func aCompletePacketLeavesTheAssemblerIdleAndReusable() throws {
        var assembler = try Self.fresh()
        for value in ["one", "two"] {
            let event = try Self.feed(&assembler, Self.piece(.endpointName, .complete, Array(value.utf8)))
            #expect(event == .complete(Self.name(.endpointName, value)))
            #expect(assembler == (try Self.fresh()))
        }
        let head = Self.piece(.endpointName, .start, Array("ABCDEFGHIJKLMN".utf8))
        let tail = Self.piece(.endpointName, .end, Array("cd".utf8))
        #expect(try Self.feed(&assembler, head) == .partial)
        #expect(try Self.feed(&assembler, tail) == .complete(Self.name(.endpointName, "ABCDEFGHIJKLMNcd")))
        #expect(assembler == (try Self.fresh()))
        #expect(try Self.feedRefusal(&assembler, tail) == .orphanContinue(status: 3))
    }

    @Test func continueAndEndWithNothingPendingAreOrphansReportingTheirStatus() throws {
        for format in [UMPStreamFormat.continuation, .end] {
            for kind in [UMPStreamTextKind.endpointName, .productInstanceID, .functionBlockName] {
                var assembler = try Self.fresh()
                #expect(
                    try Self.feedRefusal(&assembler, Self.piece(kind, format, [0x41]))
                        == .orphanContinue(status: kind.status)
                )
                #expect(assembler == (try Self.fresh()))
            }
        }
    }

    @Test func startOrCompleteWhileAssemblingIsRefusedAndTheOldTextSurvives() throws {
        for format in [UMPStreamFormat.start, .complete] {
            var assembler = try Self.fresh()
            let head = Array("ABCDEFGHIJKLMN".utf8)
            #expect(try Self.feed(&assembler, Self.piece(.productInstanceID, .start, head)) == .partial)
            let held = assembler
            let intruder = Self.piece(.endpointName, format, [0x5A])
            #expect(try Self.feedRefusal(&assembler, intruder) == .unexpectedStart(pendingStatus: 0x004))
            #expect(assembler == held)
            let done = try Self.feed(&assembler, Self.piece(.productInstanceID, .end, [0x4F]))
            #expect(done == .complete(Self.name(.productInstanceID, "ABCDEFGHIJKLMNO")))
        }
    }

    @Test func aContinuationOfAnotherMessageOrBlockIsRefusedAndTheTextSurvives() throws {
        var assembler = try Self.fresh()
        let thirteen = Array("ABCDEFGHIJKLM".utf8)
        #expect(try Self.feed(&assembler, Self.piece(.functionBlockName, .start, thirteen, index: 9)) == .partial)
        let held = assembler
        #expect(
            try Self.feedRefusal(&assembler, Self.piece(.endpointName, .end, [0x5A]))
                == .mismatchedStatus(expected: 0x012, actual: 0x003)
        )
        #expect(
            try Self.feedRefusal(&assembler, Self.piece(.functionBlockName, .continuation, [0x5A], index: 10))
                == .mismatchedFunctionBlock(expected: 9, actual: 10)
        )
        #expect(assembler == held)
        let done = try Self.feed(&assembler, Self.piece(.functionBlockName, .end, Array("N".utf8), index: 9))
        #expect(done == .complete(Self.name(.functionBlockName, "ABCDEFGHIJKLMN", index: 9)))
    }

    @Test func nonStreamAndNonTextPacketsAreRefusedMidTextWithoutChangingIt() throws {
        var assembler = try Self.fresh()
        #expect(try Self.feed(&assembler, Self.piece(.endpointName, .start, Array("ABCDEFGHIJKLMN".utf8))) == .partial)
        let held = assembler
        for status in [UInt16(0x000), 0x001, 0x002, 0x005, 0x006, 0x010, 0x011, 0x020, 0x021] {
            let words: [UInt32] = [0xF000_0000 | UInt32(status) << 16, 0, 0, 0]
            #expect(try Self.feedRefusal(&assembler, words) == .notTextStatus(status))
        }
        for (first, status) in [(UInt32(0xF420_0000), UInt16(0x020)), (0xFC20_0000, 0x020), (0xF421_0000, 0x021),
                                (0xFC21_0000, 0x021)] {
            #expect(try Self.feedRefusal(&assembler, [first, 0, 0, 0]) == .notTextStatus(status))
        }
        #expect(try Self.feedRefusal(&assembler, [0xF007_0000, 0, 0, 0]) == .unknownStatus(7))
        let flex = try UMPPacket(words: [0xD000_0000, 0, 0, 0])
        do {
            _ = try assembler.feed(flex)
            Issue.record("flex data was fed")
        } catch {
            #expect(error == .notStream(actual: .flexData))
        }
        #expect(assembler == held)
    }

    @Test func functionBlockNameIndexIsCheckedInEveryPacketThirtyOneAcceptedThirtyTwoRefused() throws {
        var assembler = try Self.fresh()
        let start = Self.piece(.functionBlockName, .start, Array("ABCDEFGHIJKLM".utf8), index: 31)
        #expect(try Self.feed(&assembler, start) == .partial)
        let held = assembler
        for wire: UInt8 in [32, 127, 128, 255] {
            let words = Self.piece(.functionBlockName, .end, [0x4E], index: wire)
            #expect(try Self.feedRefusal(&assembler, words) == .functionBlockOutOfRange(Int(wire)))
        }
        #expect(assembler == held)
        var other = try Self.fresh()
        #expect(
            try Self.feedRefusal(&other, Self.piece(.functionBlockName, .complete, [0x41], index: 32))
                == .functionBlockOutOfRange(32)
        )
    }

    @Test func resetDropsTheCurrentTextAndAllowsANewStart() throws {
        var assembler = try Self.fresh()
        #expect(try Self.feed(&assembler, Self.piece(.endpointName, .start, Array("ABCDEFGHIJKLMN".utf8))) == .partial)
        assembler.reset()
        #expect(assembler == (try Self.fresh()))
        let done = try Self.feed(&assembler, Self.piece(.productInstanceID, .complete, Array("ok".utf8)))
        #expect(done == .complete(Self.name(.productInstanceID, "ok")))
    }

    @Test func aPacketCountOfSevenThreeSevenIsAcceptedAndOneMoreIsRefusedEvenWhenAllZero() throws {
        for (kind, count) in [(UMPStreamTextKind.endpointName, 7), (.productInstanceID, 3), (.functionBlockName, 7)] {
            var assembler = try Self.fresh()
            let filler = Array(repeating: UInt8(0x41), count: kind.bytesPerPacket)
            for position in 0..<count {
                let format: UMPStreamFormat = position == 0 ? .start : .continuation
                #expect(try Self.feed(&assembler, Self.piece(kind, format, filler)) == .partial)
            }
            let held = assembler
            #expect(
                try Self.feedRefusal(&assembler, Self.piece(kind, .continuation, [])) == .tooManyPackets(limit: count)
            )
            #expect(try Self.feedRefusal(&assembler, Self.piece(kind, .end, [])) == .tooManyPackets(limit: count))
            #expect(assembler == held)
        }
        var assembler = try Self.fresh()
        let zero = Self.piece(.endpointName, .start, [0x41])
        #expect(try Self.feed(&assembler, zero) == .partial)
        for _ in 1..<6 { #expect(try Self.feed(&assembler, Self.piece(.endpointName, .continuation, [])) == .partial) }
        let finished = try Self.feed(&assembler, Self.piece(.endpointName, .end, []))
        #expect(finished == .complete(Self.name(.endpointName, "A")))
    }

    @Test func assemblerTextBoundAcceptsTheLimitAndRefusesOneMoreWithoutAppending() throws {
        var assembler = try Self.fresh(20)
        let head = Array("ABCDEFGHIJKLMN".utf8)
        #expect(try Self.feed(&assembler, Self.piece(.endpointName, .start, head)) == .partial)
        let held = assembler
        let over = Self.piece(.endpointName, .end, Array("OPQRSTU".utf8))
        #expect(try Self.feedRefusal(&assembler, over) == .textTooLong(21))
        #expect(assembler == held)
        #expect(assembler.pendingByteCount == 14)
        let exact = try Self.feed(&assembler, Self.piece(.endpointName, .end, Array("OPQRST".utf8)))
        #expect(exact == .complete(Self.name(.endpointName, "ABCDEFGHIJKLMNOPQRST")))
    }

    @Test func assemblerLimitCountsBytesWithoutTrailingPaddingAndNeverCharacters() throws {
        var assembler = try Self.fresh(1)
        let single = try Self.feed(&assembler, Self.piece(.endpointName, .complete, [0x41]))
        #expect(single == .complete(Self.name(.endpointName, "A")))
        #expect(try Self.feedRefusal(&assembler, Self.piece(.endpointName, .complete, [0x41, 0x42])) == .textTooLong(2))
        var wide = try Self.fresh(2)
        let tooWide = Self.piece(.endpointName, .complete, [0xC3, 0xA9, 0x41])
        #expect(try Self.feedRefusal(&wide, tooWide) == .textTooLong(3))
        let accent = try Self.feed(&wide, Self.piece(.endpointName, .complete, [0xC3, 0xA9]))
        #expect(accent == .complete(Self.name(.endpointName, "\u{E9}")))
    }

    @Test func decodeOfATextPacketAppliesTheLimitAndOnlyAcceptsFormatZero() throws {
        let six = Self.textWords(status: 0x003, format: 0, bytes: Array("ABCDEF".utf8))
        #expect(try Self.decode(six, limit: 6) == Self.name(.endpointName, "ABCDEF"))
        #expect(try Self.decodeRefusal(six, limit: 5) == .textTooLong(6))
        let startPacket = Self.textWords(status: 0x003, format: 1, bytes: [0x41])
        #expect(try Self.decodeRefusal(startPacket) == .wrongFormat(status: 3, format: 1))
        let badIndex = Self.textWords(status: 0x012, format: 0, index: 32, bytes: [0x41])
        #expect(try Self.decodeRefusal(badIndex) == .functionBlockOutOfRange(32))
        let invalid = Self.textWords(status: 0x004, format: 0, bytes: [0xFF])
        #expect(try Self.decodeRefusal(invalid) == .productInstanceIDNotPrintableASCII(offset: 0))
        #expect(try Self.decodeRefusal(Self.textWords(status: 0x003, format: 0, bytes: [0xFF])) == .invalidUTF8)
    }

    @Test func encodeChecksTheBlockIndexThenTheLengthThenTheTrailingZero() throws {
        let long = Self.name(.functionBlockName, Self.text(20) + "\u{0}", index: 40)
        #expect(try Self.encodeRefusal(long, limit: 10) == .functionBlockOutOfRange(40))
        let tooLongAndZero = Self.name(.endpointName, Self.text(20) + "\u{0}")
        #expect(try Self.encodeRefusal(tooLongAndZero, limit: 10) == .textTooLong(21))
        let trailing = Self.name(.endpointName, Self.text(5) + "\u{0}")
        #expect(try Self.encodeRefusal(trailing, limit: 10) == .trailingZeroByte)
    }

    @Test func assemblerReportsAnUnknownStatusBeforeAnySequenceError() throws {
        var assembler = try Self.fresh()
        #expect(try Self.feed(&assembler, Self.piece(.endpointName, .start, [0x41])) == .partial)
        let held = assembler
        #expect(try Self.feedRefusal(&assembler, [0xF407_0000, 0, 0, 0]) == .unknownStatus(7))
        var idle = try Self.fresh()
        #expect(try Self.feedRefusal(&idle, [0xF807_0000, 0, 0, 0]) == .unknownStatus(7))
        #expect(assembler == held)
    }

    @Test func assemblerChecksTheBlockIndexBeforeTheSequence() throws {
        var idle = try Self.fresh()
        let idleBad = Self.piece(.functionBlockName, .end, [0x41], index: 32)
        #expect(try Self.feedRefusal(&idle, idleBad) == .functionBlockOutOfRange(32))
        var busy = try Self.fresh()
        #expect(try Self.feed(&busy, Self.piece(.functionBlockName, .start, [0x41], index: 1)) == .partial)
        let busyBad = Self.piece(.functionBlockName, .start, [0x41], index: 99)
        #expect(try Self.feedRefusal(&busy, busyBad) == .functionBlockOutOfRange(99))
    }

    @Test func assemblerReportsSequenceErrorsBeforeLengthAndPacketCountErrors() throws {
        var assembler = try Self.fresh(5)
        #expect(try Self.feed(&assembler, Self.piece(.endpointName, .start, Array("ABC".utf8))) == .partial)
        let long = Array("XXXXXXXXXXXXXX".utf8)
        #expect(
            try Self.feedRefusal(&assembler, Self.piece(.productInstanceID, .end, long))
                == .mismatchedStatus(expected: 3, actual: 4)
        )
        let restart = Self.piece(.endpointName, .start, long)
        #expect(try Self.feedRefusal(&assembler, restart) == .unexpectedStart(pendingStatus: 3))
        var idle = try Self.fresh(5)
        #expect(try Self.feedRefusal(&idle, Self.piece(.endpointName, .end, long)) == .orphanContinue(status: 3))
        var block = try Self.fresh(5)
        let named = Self.piece(.functionBlockName, .start, Array("ABC".utf8), index: 9)
        #expect(try Self.feed(&block, named) == .partial)
        let both = Self.piece(.endpointName, .end, Array("Z".utf8))
        let status = UInt16(UMPStreamTextKind.functionBlockName.status)
        #expect(try Self.feedRefusal(&block, both) == .mismatchedStatus(expected: status, actual: 3))
    }

    @Test func assemblerReportsTooManyPacketsBeforeATooLongText() throws {
        var assembler = try Self.fresh()
        let filler = Array(repeating: UInt8(0x41), count: 14)
        #expect(try Self.feed(&assembler, Self.piece(.productInstanceID, .start, filler)) == .partial)
        let middle = Self.piece(.productInstanceID, .continuation, filler)
        for _ in 1..<3 { #expect(try Self.feed(&assembler, middle) == .partial) }
        #expect(assembler.pendingPacketCount == 3)
        let last = Self.piece(.productInstanceID, .end, filler)
        #expect(try Self.feedRefusal(&assembler, last) == .tooManyPackets(limit: 3))
    }

    @Test func assemblerReportsATooLongTextBeforeInvalidUTF8() throws {
        var assembler = try Self.fresh(14)
        let filler = Array(repeating: UInt8(0x41), count: 14)
        #expect(try Self.feed(&assembler, Self.piece(.endpointName, .start, filler)) == .partial)
        #expect(try Self.feedRefusal(&assembler, Self.piece(.endpointName, .end, [0xFF])) == .textTooLong(15))
        var other = try Self.fresh(3)
        let invalid = Self.piece(.endpointName, .complete, [0xFF, 0xFF, 0xFF, 0xFF])
        #expect(try Self.feedRefusal(&other, invalid) == .textTooLong(4))
    }
}
