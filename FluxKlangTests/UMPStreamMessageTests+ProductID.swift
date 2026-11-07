import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// The Product Instance Id is printable ASCII (0x20...0x7E) on encode and on decode; the other names keep UTF-8.
extension UMPStreamMessageTests {
    private static func product(_ value: String) -> UMPStreamMessage {
        .productInstanceID(UMPStreamString(value))
    }

    private static func scalar(_ byte: UInt8) -> String {
        String(Character(UnicodeScalar(byte)))
    }

    private static func assemble(_ packets: [[UInt32]]) throws -> UMPStreamTextEvent? {
        var assembler = UMPStreamTextAssembler(limits: try limits())
        var last: UMPStreamTextEvent?
        for words in packets { last = try assembler.feed(UMPPacket(words: words)) }
        return last
    }

    @Test func productInstanceIDEncodeAcceptsTheEdgesAndRefusesTheBytesJustOutsideThem() throws {
        for byte in [UInt8(0x20), 0x7E] {
            let message = Self.product("A" + Self.scalar(byte))
            #expect(try Self.encodeRefusal(message) == nil, "byte \(byte)")
            #expect(try Self.assemble(Self.encode(message)) == .complete(message), "byte \(byte)")
        }
        for byte in [UInt8(0x1F), 0x7F, 0x80, 0x09, 0x0A] {
            let refusal = try Self.encodeRefusal(Self.product("A" + Self.scalar(byte)))
            #expect(refusal == .productInstanceIDNotPrintableASCII(offset: 1), "byte \(byte)")
        }
        let accented = try Self.encodeRefusal(Self.product("\u{E9}"))
        #expect(accented == .productInstanceIDNotPrintableASCII(offset: 0))
        #expect(try Self.encodeRefusal(Self.product("ab\u{E9}")) == .productInstanceIDNotPrintableASCII(offset: 2))
    }

    @Test func productInstanceIDOfExactlyTheMaximumLengthInPrintableASCIIRoundTrips() throws {
        let value = String((0..<42).map { Character(UnicodeScalar(UInt8(0x20 + $0 * 2 % 95))) })
        #expect(value.utf8.count == 42)
        let message = Self.product(value)
        let packets = try Self.encode(message)
        #expect(packets.count == 3)
        #expect(try Self.assemble(packets) == .complete(message))
    }

    @Test func endpointAndFunctionBlockNamesKeepFullUTF8AndRoundTripAnAccentedName() throws {
        let messages: [UMPStreamMessage] = [
            .endpointName(UMPStreamString("caf\u{E9} \u{1F3B9}")),
            .functionBlockName(index: 3, name: UMPStreamString("caf\u{E9} \u{1F3B9}"))
        ]
        for message in messages {
            #expect(try Self.encodeRefusal(message) == nil)
            #expect(try Self.assemble(Self.encode(message)) == .complete(message))
        }
    }

    @Test func productInstanceIDReportsTooLongThenTrailingZeroBeforeTheCharacterCheck() throws {
        let long = Self.product(Self.text(42) + "\u{E9}")
        #expect(try Self.encodeRefusal(long) == .textTooLong(44))
        let zero = Self.product("\u{E9}A\u{0}")
        #expect(try Self.encodeRefusal(zero) == .trailingZeroByte)
    }

    @Test func productInstanceIDDecodeAcceptsTheEdgesAndRefusesEveryOtherByteWithItsOffset() throws {
        let edges = Self.textWords(status: 0x004, format: 0, bytes: [0x20, 0x7E])
        #expect(try Self.decode(edges) == Self.product(" ~"))
        for byte in [UInt8(0x1F), 0x7F, 0x80, 0xFF, 0x09, 0x0A, 0xC3] {
            let words = Self.textWords(status: 0x004, format: 0, bytes: [0x41, byte, 0x42])
            #expect(try Self.decodeRefusal(words) == .productInstanceIDNotPrintableASCII(offset: 1), "byte \(byte)")
        }
        let zeroInside = Self.textWords(status: 0x004, format: 0, bytes: [0x41, 0x00, 0x42])
        #expect(try Self.decodeRefusal(zeroInside) == .productInstanceIDNotPrintableASCII(offset: 1))
        let accented = Self.textWords(status: 0x004, format: 0, bytes: [0xC3, 0xA9])
        #expect(try Self.decodeRefusal(accented) == .productInstanceIDNotPrintableASCII(offset: 0))
        let endpoint = Self.textWords(status: 0x003, format: 0, bytes: [0xC3, 0xA9])
        #expect(try Self.decode(endpoint) == .endpointName(UMPStreamString("\u{E9}")))
    }

    @Test func aMultiPacketProductInstanceIDWithABadByteInTheLastPacketIsRefusedAndKeepsTheStart() throws {
        var assembler = UMPStreamTextAssembler(limits: try Self.limits())
        let head = Self.textWords(status: 0x004, format: 1, bytes: Array("ABCDEFGHIJKLMN".utf8))
        #expect(try assembler.feed(UMPPacket(words: head)) == .partial)
        let held = assembler
        let tail = try UMPPacket(words: Self.textWords(status: 0x004, format: 3, bytes: [0x41, 0x7F]))
        do {
            _ = try assembler.feed(tail)
            Issue.record("a bad byte in the last packet was accepted")
        } catch {
            #expect(error == .productInstanceIDNotPrintableASCII(offset: 15))
        }
        #expect(assembler == held)
    }
}
