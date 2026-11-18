//
//  MIDICIPropertyHeaderTests.swift
//  FluxKlangTests
//
//  Typed values, bounds, refusal offsets, check order and hostile input for `MIDICIPropertyHeader.parse(_:)` (#83,
//  slice M83-PXH1, issue #820). Nothing calls the parser yet.
//
//  Provenance: every header is written by hand, and every expected offset was counted by hand from the JSON text. The
//  four goldens are `MIDICIMessageTests`' own. The other field names come from the slice brief, not from the Property
//  Exchange specification (M2-102-UM and M2-103-UM were not read).
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

@Suite("MIDI-CI Property Exchange header", .productionAccessAudit)
struct MIDICIPropertyHeaderTests {
    typealias Refusal = MIDICIPropertyHeaderRefusal
    typealias Case = (text: String, refusal: Refusal)

    /// A header with every known field, none at its default.
    static let everyField = #"{"resource":"ChannelList","resId":"r-1","status":202,"message":"Accepted","#
        + #""command":"partial","subscribeId":"s9","mediaType":"application/json","offset":0,"limit":1,"#
        + #""totalCount":2147483647,"setPartial":false,"cacheTime":30,"mutualEncoding":"Mcoded7"}"#

    static func bytes(_ text: String) -> [UInt8] {
        Array(text.utf8)
    }

    /// The parsed header or the refusal.
    static func outcome(_ bytes: [UInt8]) -> Result<MIDICIPropertyHeader, Refusal> {
        do {
            return .success(try MIDICIPropertyHeader.parse(bytes))
        } catch {
            return .failure(error)
        }
    }

    /// Asserts that each text is refused with its refusal.
    func expectRefusals(_ cases: [Case], sourceLocation: SourceLocation = #_sourceLocation) {
        for (text, refusal) in cases {
            #expect(Self.outcome(Self.bytes(text)) == .failure(refusal), "\(text)", sourceLocation: sourceLocation)
        }
    }

    // MARK: Typed values

    @Test func goldenHeadersParseToTheirTypedValues() throws {
        let goldens: [([UInt8], MIDICIPropertyHeader)] = [
            (MIDICIMessageTests.exchangeResourceHeader, MIDICIPropertyHeader(resource: "DeviceInfo")),
            (MIDICIMessageTests.exchangeStatus200Header, MIDICIPropertyHeader(status: 200)),
            (MIDICIMessageTests.exchangeStatus500Header, MIDICIPropertyHeader(status: 500)),
            (MIDICIMessageTests.exchangeSubscribeHeader, MIDICIPropertyHeader(command: "start"))
        ]
        for (bytes, expected) in goldens {
            let header = try MIDICIPropertyHeader.parse(bytes)
            #expect(header == expected)
            #expect(header.encoding == .ascii)
            #expect(header.unknownKeys.isEmpty)
        }
    }

    @Test func everyKnownFieldHasItsTypeAndAnAbsentOneIsNil() throws {
        let header = try MIDICIPropertyHeader.parse(Self.bytes(Self.everyField))
        #expect(header == MIDICIPropertyHeader(
            resource: "ChannelList", resID: "r-1", status: 202, message: "Accepted", command: "partial",
            subscribeID: "s9", mediaType: "application/json", offset: 0, limit: 1, totalCount: 2_147_483_647,
            setPartial: false, cacheTime: 30, encoding: .mcoded7))
        #expect(try MIDICIPropertyHeader.parse(Self.bytes(#"{"setPartial":true}"#)).setPartial == true)

        let empty = try MIDICIPropertyHeader.parse(Self.bytes("{}"))
        #expect(empty == MIDICIPropertyHeader())
        #expect(empty.resource == nil && empty.resID == nil && empty.status == nil && empty.message == nil)
        #expect(empty.command == nil && empty.subscribeID == nil && empty.mediaType == nil && empty.offset == nil)
        #expect(empty.limit == nil && empty.totalCount == nil && empty.setPartial == nil && empty.cacheTime == nil)
        #expect(empty.encoding == .ascii)
        #expect(empty.unknownKeys.isEmpty)
    }

    @Test func whitespaceAndMemberOrderDoNotChangeTheValue() throws {
        let compact = try MIDICIPropertyHeader.parse(Self.bytes(#"{"status":200,"resource":"A","setPartial":true}"#))
        let spaced = " \t\r\n{ \"setPartial\" :\ttrue ,\r\n\"resource\": \"A\" , \"status\" : 200 }\n "
        #expect(try MIDICIPropertyHeader.parse(Self.bytes(spaced)) == compact)
        #expect(compact == MIDICIPropertyHeader(resource: "A", status: 200, setPartial: true))
        #expect(try MIDICIPropertyHeader.parse(Self.bytes(" {\n}\t")) == MIDICIPropertyHeader())
    }

    @Test func unknownMembersAreCheckedSkippedAndTheirNamesKeptInByteOrder() throws {
        let text = #"{"zeta":[1,{"x":null},[]],"resource":"A","Alpha":{"b":[true,false,-1.5e+3,"s"]},"#
            + #""_":{},"\u00e9":0,"status":7}"#
        let header = try MIDICIPropertyHeader.parse(Self.bytes(text))
        #expect(header == MIDICIPropertyHeader(resource: "A", status: 7, unknownKeys: ["Alpha", "_", "zeta", "é"]))
    }

    @Test func stringEscapesAreDecoded() throws {
        let text = #"{"message":"\"\\\/\b\f\n\r\t\u0041\u00e9\uD83D\uDE00\udbff\udfff ok","command":"\u0000"}"#
        let header = try MIDICIPropertyHeader.parse(Self.bytes(text))
        let expected = "\"\\/\u{8}\u{C}\n\r\tA\u{E9}\u{1F600}\u{10FFFF} ok"
        #expect(header.message.map { Array($0.unicodeScalars) } == Array(expected.unicodeScalars))
        #expect(header.command.map { Array($0.unicodeScalars) } == ["\u{0}"])
        // RFC 8259 refuses only bytes below 0x20 in a string; DEL (0x7F) is kept as written.
        let delete = try MIDICIPropertyHeader.parse(Self.bytes(#"{"message":""# + "\u{7F}" + #""}"#))
        #expect(delete.message.map { Array($0.unicodeScalars) } == ["\u{7F}"])
    }

    @Test func theEncodingNameIsMatchedExactly() throws {
        #expect(try MIDICIPropertyHeader.parse(Self.bytes(#"{"status":200}"#)).encoding == .ascii)
        let names: [(name: String, encoding: MIDICIPropertyEncoding)] = [
            ("ASCII", .ascii), ("Mcoded7", .mcoded7), ("zlib+Mcoded7", .zlibMcoded7), ("ascii", .other("ascii")),
            ("mcoded7", .other("mcoded7")), ("MCODED7", .other("MCODED7")), ("Zlib+Mcoded7", .other("Zlib+Mcoded7")),
            ("zlib+mcoded7", .other("zlib+mcoded7")), (" Mcoded7", .other(" Mcoded7")),
            ("Mcoded7 ", .other("Mcoded7 ")), ("zlib", .other("zlib")), ("", .other(""))
        ]
        for (name, encoding) in names {
            let header = try MIDICIPropertyHeader.parse(Self.bytes(#"{"mutualEncoding":""# + name + #""}"#))
            #expect(header.encoding == encoding, "\(name)")
            #expect(MIDICIPropertyEncoding(name: name) == encoding)
        }
        #expect(try MIDICIPropertyHeader.parse(Self.bytes(#"{"mutualEncoding":"\u0041SCII"}"#)).encoding == .ascii)
        expectRefusals([
            (#"{"mutualEncoding":7}"#, .wrongType(key: "mutualEncoding", offset: 18)),
            (#"{"mutualEncoding":null}"#, .wrongType(key: "mutualEncoding", offset: 18))
        ])
    }

    @Test func namesAreComparedByTheirBytesNotByCanonicalEquivalence() throws {
        // String == folds canonical equivalents; key and encoding names must not.
        #expect("\u{212A}" == "K")
        #expect(!MIDICIPropertyHeader.isSpelled("\u{212A}", as: "K"))
        #expect("e\u{301}" == "\u{E9}")
        #expect(!MIDICIPropertyHeader.isSpelled("e\u{301}", as: "\u{E9}"))
        #expect(MIDICIPropertyHeader.isSpelled("resource", as: "resource"))
        // Only U+037E, U+1FEF and U+212A decompose to plain ASCII, and no known name holds ";", "`" or "K",
        // so no known name has a canonical respelling; the near misses below stay unknown.
        let header = try MIDICIPropertyHeader.parse(Self.bytes(#"{"\u212A":1,"resourc\u0065\u0301":"x"}"#))
        #expect(header.unknownKeys.map { Array($0.utf8) } == [Array("resource\u{301}".utf8), [0xE2, 0x84, 0xAA]])
        #expect(header.resource == nil)
        let encoding = try MIDICIPropertyHeader.parse(Self.bytes(#"{"mutualEncoding":"ASCI\u0049\u0301"}"#))
        #expect(encoding.encoding == .other("ASCII\u{301}"))
    }

    // MARK: Bounds

    @Test func theByteLimitIsInclusive() throws {
        let maximum = MIDICIPropertyChunk.maximumHeaderBytes
        #expect(maximum == 2_048)
        let fill = maximum - 14  // `{"message":""}` is 14 bytes.
        let atLimit = Self.bytes(#"{"message":""# + String(repeating: "a", count: fill) + #""}"#)
        #expect(atLimit.count == 2_048)
        #expect(try MIDICIPropertyHeader.parse(atLimit).message?.utf8.count == fill)
        let padded = Self.bytes("{}" + String(repeating: " ", count: maximum - 2))
        #expect(try MIDICIPropertyHeader.parse(padded) == MIDICIPropertyHeader())

        let over = Self.bytes(#"{"message":""# + String(repeating: "a", count: fill + 1) + #""}"#)
        #expect(Self.outcome(over) == .failure(.tooLong(count: 2_049, limit: 2_048)))
        #expect(Self.outcome(padded + [0x20]) == .failure(.tooLong(count: 2_049, limit: 2_048)))
        let huge = [UInt8](repeating: 0x80, count: 65_536)
        #expect(Self.outcome(huge) == .failure(.tooLong(count: 65_536, limit: 2_048)))
    }

    @Test func nestingIsBoundedAtTheDepthLimitInclusive() throws {
        #expect(MIDICIPropertyHeaderScanner.maximumDepth == 8)
        // `levels` objects, each the value of `"a"` in the one around it.
        func objects(_ levels: Int) -> [UInt8] {
            let inner = levels - 1
            return Self.bytes(String(repeating: #"{"a":"#, count: inner) + "{}" + String(repeating: "}", count: inner))
        }
        // The top-level object holding `levels - 1` nested arrays.
        func arrays(_ levels: Int) -> [UInt8] {
            let inner = levels - 1
            let brackets = String(repeating: "[", count: inner) + String(repeating: "]", count: inner)
            return Self.bytes(#"{"a":"# + brackets + "}")
        }
        #expect(try MIDICIPropertyHeader.parse(objects(8)) == MIDICIPropertyHeader(unknownKeys: ["a"]))
        #expect(try MIDICIPropertyHeader.parse(arrays(8)) == MIDICIPropertyHeader(unknownKeys: ["a"]))
        let mixed = #"{"a":[{"b":[{"c":[{"d":[]}]}]}],"status":1}"#
        #expect(try MIDICIPropertyHeader.parse(Self.bytes(mixed))
            == MIDICIPropertyHeader(status: 1, unknownKeys: ["a"]))

        #expect(Self.outcome(objects(9)) == .failure(.tooDeep(offset: 40)))
        #expect(Self.outcome(arrays(9)) == .failure(.tooDeep(offset: 12)))
        let deep = Self.bytes(#"{"a":"# + String(repeating: "[", count: 2_000))
        #expect(Self.outcome(deep) == .failure(.tooDeep(offset: 12)))
        expectRefusals([
            (#"{"a":[{"b":[{"c":[{"d":[{}]}]}]}]}"#, .tooDeep(offset: 24)),
            (#"{"status":1,"a":[[[[[[[[1]]]]]]]]}"#, .tooDeep(offset: 23))
        ])
    }

    // MARK: Refusals

    @Test func aByteOfEightBitsIsRefusedAtItsFirstOffset() {
        let cases: [([UInt8], Int)] = [
            ([0xFF] + Self.bytes("{}"), 0),
            (Self.bytes(#"{"message":""#) + [0xC3, 0xA9] + Self.bytes(#""}"#), 12),
            (Self.bytes("{}") + [0x80], 2),
            (Self.bytes(#"{"a":1,"#) + [0x80] + Self.bytes(#""b":"#) + [0xFF] + Self.bytes("2}"), 7)
        ]
        for (bytes, offset) in cases {
            #expect(Self.outcome(bytes) == .failure(.byteHigh(offset: offset)))
        }
        // The scanner's own guard, which `parse` cannot reach because it refuses the byte first.
        let inString = Self.bytes(#"{"a":""#) + [0x80] + Self.bytes(#""}"#)
        #expect(throws: Refusal.invalidString(offset: 6)) { try MIDICIPropertyHeaderScanner.members(of: inString) }
    }

    @Test func everySyntaxRefusalNamesItsOffset() {
        expectRefusals([
            ("", .unexpectedEnd(offset: 0)), ("   ", .unexpectedEnd(offset: 3)), ("{", .unexpectedEnd(offset: 1)),
            (#"{"a":"x"#, .unexpectedEnd(offset: 7)), (#"{"a":tru"#, .unexpectedEnd(offset: 8)),
            (#"{"a":1"#, .unexpectedEnd(offset: 6)), (#"{"a":"\u00"#, .unexpectedEnd(offset: 10)),
            ("[]", .unexpectedByte(offset: 0)), (#""a""#, .unexpectedByte(offset: 0)),
            ("1", .unexpectedByte(offset: 0)),
            (#"{"a"}"#, .unexpectedByte(offset: 4)), (#"{"a":}"#, .unexpectedByte(offset: 5)),
            (#"{"a":1,}"#, .unexpectedByte(offset: 7)), (#"{"a":1 "b":2}"#, .unexpectedByte(offset: 7)),
            ("{a:1}", .unexpectedByte(offset: 1)), (#"{"a":[1,]}"#, .unexpectedByte(offset: 8)),
            (#"{"a":[1}"#, .unexpectedByte(offset: 7)), (#"{"a":tru}"#, .unexpectedByte(offset: 8)),
            (#"{"a":nul}"#, .unexpectedByte(offset: 8)), (#"{"a":True}"#, .unexpectedByte(offset: 5)),
            (#"{"a":+1}"#, .unexpectedByte(offset: 5)), (#"{"a":.5}"#, .unexpectedByte(offset: 5)),
            (#"{"a":0x1}"#, .unexpectedByte(offset: 6)), (#"{"a":truex}"#, .unexpectedByte(offset: 9)),
            (#"{"a":01}"#, .invalidNumber(offset: 6)), (#"{"a":-}"#, .invalidNumber(offset: 6)),
            (#"{"a":-01}"#, .invalidNumber(offset: 7)), (#"{"a":1.}"#, .invalidNumber(offset: 7)),
            (#"{"a":1e}"#, .invalidNumber(offset: 7)), (#"{"a":1e+}"#, .invalidNumber(offset: 8)),
            (#"{"a":1.5.2}"#, .invalidNumber(offset: 8)), (#"{"a":1-2}"#, .invalidNumber(offset: 6)),
            ("{\"a\":\"\t\"}", .invalidString(offset: 6)), ("{\"\u{1F}\":1}", .invalidString(offset: 2)),
            (#"{"a":"\q"}"#, .invalidString(offset: 6)), (#"{"a":"\U0041"}"#, .invalidString(offset: 6)),
            (#"{"a":"\u12G4"}"#, .invalidString(offset: 6)), (#"{"a":"\uD800"}"#, .invalidString(offset: 6)),
            (#"{"a":"\uDC00"}"#, .invalidString(offset: 6)), (#"{"a":"\uD800\u0041"}"#, .invalidString(offset: 6)),
            (#"{"a":"\uD800\n"}"#, .invalidString(offset: 6)), (#"{"a":"\uDBFF\uE000"}"#, .invalidString(offset: 6)),
            (#"{"a":"\uD800\uZ"}"#, .invalidString(offset: 12)),
            ("{}x", .trailingBytes(offset: 2)), ("{} {}", .trailingBytes(offset: 3)),
            ("{}}", .trailingBytes(offset: 2)), ("{}\u{0}", .trailingBytes(offset: 2)),
            // Form feed and vertical tab are not JSON whitespace.
            ("{\u{0C}}", .unexpectedByte(offset: 1)), ("{}\u{0B}", .trailingBytes(offset: 2))
        ])
    }

    @Test func aDuplicateKeyIsRefusedAtTheSecondOccurrence() throws {
        expectRefusals([
            (#"{"a":1,"a":2}"#, .duplicateKey(name: "a", offset: 7)),
            (#"{"status":200,"status":200}"#, .duplicateKey(name: "status", offset: 14)),
            (#"{"a":1,"\u0061":2}"#, .duplicateKey(name: "a", offset: 7)),
            (#"{"x":{"b":1,"b":2}}"#, .duplicateKey(name: "b", offset: 12)),
            (#"{"x":[{"c":{},"c":[]}]}"#, .duplicateKey(name: "c", offset: 14)),
            (#"{"a":1,"a":01}"#, .duplicateKey(name: "a", offset: 7))
        ])
        let apart = #"{"a":{"a":{"a":1}},"b":[{"a":1},{"a":2}]}"#
        #expect(try MIDICIPropertyHeader.parse(Self.bytes(apart)) == MIDICIPropertyHeader(unknownKeys: ["a", "b"]))
        // U+212A KELVIN SIGN is canonically equivalent to "K" but a different name; both stay, in UTF-8 byte order.
        let kelvin = try MIDICIPropertyHeader.parse(Self.bytes(#"{"\u212A":1,"K":2}"#))
        #expect(kelvin.unknownKeys.map { Array($0.utf8) } == [[0x4B], [0xE2, 0x84, 0xAA]])
    }

    @Test func aKnownKeyWithTheWrongTypeOrRangeIsRefused() throws {
        expectRefusals([
            (#"{"status":"200"}"#, .wrongType(key: "status", offset: 10)),
            (#"{"status":200.0}"#, .wrongType(key: "status", offset: 10)),
            (#"{"status":2e2}"#, .wrongType(key: "status", offset: 10)),
            (#"{"status":2E+2}"#, .wrongType(key: "status", offset: 10)),
            (#"{"status":-1.5}"#, .wrongType(key: "status", offset: 10)),
            (#"{"status":-1}"#, .outOfRange(key: "status", offset: 10)),
            (#"{"status":-0}"#, .outOfRange(key: "status", offset: 10)),
            (#"{"status" : -1}"#, .outOfRange(key: "status", offset: 12)),
            (#"{"offset":2147483648}"#, .outOfRange(key: "offset", offset: 10)),
            (#"{"limit":99999999999999999999999}"#, .outOfRange(key: "limit", offset: 9)),
            (#"{"totalCount":null}"#, .wrongType(key: "totalCount", offset: 14)),
            (#"{"cacheTime":true}"#, .wrongType(key: "cacheTime", offset: 13)),
            (#"{"setPartial":1}"#, .wrongType(key: "setPartial", offset: 14)),
            (#"{"setPartial":"true"}"#, .wrongType(key: "setPartial", offset: 14)),
            (#"{"resource":5}"#, .wrongType(key: "resource", offset: 12)),
            (#"{"resId":[]}"#, .wrongType(key: "resId", offset: 9)),
            (#"{"message":{}}"#, .wrongType(key: "message", offset: 11)),
            (#"{"command":false}"#, .wrongType(key: "command", offset: 11)),
            (#"{"subscribeId":1}"#, .wrongType(key: "subscribeId", offset: 15)),
            (#"{"mediaType":null}"#, .wrongType(key: "mediaType", offset: 13)),
            (#"{"status":"x","resource":5}"#, .wrongType(key: "status", offset: 10)),
            (#"{"resource":5,"status":"x"}"#, .wrongType(key: "resource", offset: 12)),
            (#"{"zz":1,"limit":-5,"offset":"x"}"#, .outOfRange(key: "limit", offset: 16))
        ])
        let edges = try MIDICIPropertyHeader.parse(Self.bytes(#"{"offset":2147483647,"limit":0,"cacheTime":0}"#))
        #expect(edges == MIDICIPropertyHeader(offset: 2_147_483_647, limit: 0, cacheTime: 0))
    }

    @Test func theCheckOrderIsLengthThenHighByteThenSyntaxThenTypes() {
        // Length before the bytes: 2,049 bytes of 0x80.
        #expect(Self.outcome([UInt8](repeating: 0x80, count: 2_049)) == .failure(.tooLong(count: 2_049, limit: 2_048)))
        // A high byte before the syntax: the top level at 0 is wrong, but the high byte at 3 is refused.
        #expect(Self.outcome(Self.bytes("[1,") + [0x80]) == .failure(.byteHigh(offset: 3)))
        expectRefusals([
            // The syntax before the types: each has a wrong type at 10 and a syntax failure later.
            (#"{"status":"x","a":01}"#, .invalidNumber(offset: 19)),
            (#"{"status":"x","status":1}"#, .duplicateKey(name: "status", offset: 14)),
            (#"{"status":"x","a":[[[[[[[[]]]]]]]]}"#, .tooDeep(offset: 25)),
            (#"{"status":"x"} x"#, .trailingBytes(offset: 15)),
            (#"{"status":"x","#, .unexpectedEnd(offset: 14)),
            // Within the syntax pass, the lowest offset wins.
            (#"{"a":01,"a":1}"#, .invalidNumber(offset: 6))
        ])
    }

    // MARK: Hostile input

    @Test func seededHeadersNeverTrap() throws {
        var random = PropertyHeaderSplitMix64(state: 0x5058_4831_0000_0820)
        let alphabet = Self.bytes(#"{}[]":,\ uDdC809aeE.-+tfnrls"#) + [0x00, 0x09, 0x0C, 0x1F, 0x7F, 0x80, 0xFF]
        let seeds = [
            MIDICIMessageTests.exchangeResourceHeader, MIDICIMessageTests.exchangeStatus200Header,
            MIDICIMessageTests.exchangeSubscribeHeader, Self.bytes(Self.everyField),
            Self.bytes(#"{"a":[{"b":"\uD83D\uDE00"},-1.5e+3,null],"setPartial":true}"#)
        ]
        var tally = PropertyHeaderTally()
        for round in 0..<4_000 {
            // Half start inside an object, so they get past the first byte.
            var input = round.isMultiple(of: 2) ? [] : Self.bytes(#"{"k":"#)
            for _ in 0..<Int.random(in: 0...48, using: &random) {
                input.append(try #require(alphabet.randomElement(using: &random)))
            }
            tally.check(input)
        }
        for _ in 0..<2_000 {
            let seed = try #require(seeds.randomElement(using: &random))
            tally.check(PropertyHeaderWriter.corrupt(seed, from: alphabet, using: &random))
        }
        var writer = PropertyHeaderWriter(random: random)
        for _ in 0..<800 {
            let target = Int.random(in: 1...12, using: &writer.random)
            let written = writer.document(depth: target)
            tally.checkWritten(written.bytes, depth: written.depth)
            tally.check(PropertyHeaderWriter.corrupt(written.bytes, from: alphabet, using: &writer.random))
        }
        for seed in seeds {
            #expect(Self.outcome(seed).map { _ in true } == .success(true))
            for length in 0..<seed.count {
                #expect(Self.outcome(Array(seed.prefix(length))) == .failure(.unexpectedEnd(offset: length)))
            }
        }
        #expect(tally.parsed > 0)
        #expect(tally.deepest == MIDICIPropertyHeaderScanner.maximumDepth)
        #expect(tally.longest > 1_900)
        let kinds: Set = ["tooLong", "byteHigh", "unexpectedEnd", "unexpectedByte", "invalidString", "invalidNumber",
                          "tooDeep", "trailingBytes", "wrongType", "outOfRange"]
        #expect(tally.seen.isSuperset(of: kinds), "\(tally.seen.sorted())")
    }
}

/// SplitMix64, private to this file so its name cannot collide in the shared test module.
private struct PropertyHeaderSplitMix64: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}

/// Parses hostile input twice and checks what every outcome must satisfy.
private struct PropertyHeaderTally {
    static let limit = MIDICIPropertyChunk.maximumHeaderBytes
    var parsed = 0
    var longest = 0
    var deepest = 0
    /// The refusals seen, by case name.
    var seen: Set<String> = []

    /// The offset a refusal names, or nil for `tooLong`.
    static func offset(of refusal: MIDICIPropertyHeaderRefusal) -> Int? {
        switch refusal {
        case .tooLong: nil
        case .byteHigh(let offset), .unexpectedEnd(let offset), .unexpectedByte(let offset),
             .invalidString(let offset), .invalidNumber(let offset), .tooDeep(let offset), .trailingBytes(let offset),
             .duplicateKey(_, let offset), .wrongType(_, let offset), .outOfRange(_, let offset): offset
        }
    }

    @discardableResult
    mutating func check(_ input: [UInt8]) -> Result<MIDICIPropertyHeader, MIDICIPropertyHeaderRefusal> {
        let first = MIDICIPropertyHeaderTests.outcome(input)
        #expect(MIDICIPropertyHeaderTests.outcome(input) == first)
        let high = input.firstIndex { $0 >= 0x80 }
        switch first {
        case .success:
            parsed += 1
            longest = max(longest, input.count)
            #expect(high == nil && input.count <= Self.limit)
        case .failure(let refusal):
            seen.insert(String(String(describing: refusal).prefix { $0 != "(" }))
            if input.count > Self.limit {
                #expect(refusal == .tooLong(count: input.count, limit: Self.limit))
            } else if let high {
                #expect(refusal == .byteHigh(offset: high))
            } else {
                #expect((0...input.count).contains(Self.offset(of: refusal) ?? -1))
            }
            if case .unexpectedEnd(let offset) = refusal { #expect(offset == input.count) }
        }
        return first
    }

    /// Checks a document the writer wrote. It is valid JSON, so only a limit or a known member's type refuses it.
    mutating func checkWritten(_ document: [UInt8], depth: Int) {
        let maximumDepth = MIDICIPropertyHeaderScanner.maximumDepth
        let withinLimits = document.count <= Self.limit && depth <= maximumDepth
        switch check(document) {
        case .success:
            deepest = max(deepest, depth)
            #expect(withinLimits)
        case .failure(.tooLong): break  // `check` matched its count.
        case .failure(.tooDeep): #expect(depth > maximumDepth)
        case .failure(.wrongType), .failure(.outOfRange): #expect(withinLimits)
        case .failure(let refusal): Issue.record("A written document was refused: \(refusal)")
        }
    }
}

/// Writes random header documents of valid JSON whose nesting and length reach past the parser's limits.
private struct PropertyHeaderWriter {
    /// Member names; `resId` and `limit` are known, so a value of the wrong type or range is refused at the top level.
    static let names = [#""a""#, #""b""#, #""c""#, #""\u00e9""#, #""resId""#, #""limit""#]
    static let scalars = [
        #""""#, #""ok""#, #""\"\\\/\b\f\n\r\t""#, #""\u00e9""#, #""\uD83D\uDE00""#, #""\udbff\udfff""#, "0", "7", "-1",
        "200", "2147483647", "2147483648", "1.5", "-0", "1e3", "-2.5E-3", "true", "false", "null"
    ]
    var random: PropertyHeaderSplitMix64
    var text = ""
    /// The length past which no more containers open.
    var budget = 0
    /// The deepest level opened so far; the top-level object is level 1.
    var reached = 0

    /// The input kept, cut short, with one byte replaced, or with one byte inserted.
    static func corrupt(
        _ input: [UInt8], from alphabet: [UInt8], using random: inout PropertyHeaderSplitMix64
    ) -> [UInt8] {
        var output = input
        let position = Int.random(in: 0...input.count, using: &random)
        let byte = alphabet.randomElement(using: &random) ?? 0
        switch Int.random(in: 0..<4, using: &random) {
        case 0: break
        case 1: output.removeSubrange(position...)
        case 2 where position < input.count: output[position] = byte
        default: output.insert(byte, at: position)
        }
        return output
    }

    /// A document whose first members open containers down to `depth` levels unless the budget runs out first, half
    /// of them led by a message long enough to straddle the byte limit; and the depth it reached.
    mutating func document(depth: Int) -> (bytes: [UInt8], depth: Int) {
        text = "{"
        reached = 1
        if Bool.random(using: &random) {
            let pad = String(repeating: "m", count: Int.random(in: 1_850...2_100, using: &random))
            text += #""message":""# + pad + #"","#
        }
        budget = text.utf8.count + Int.random(in: 0...400, using: &random)
        members(level: 1, depth: depth)
        text += "}"
        return (Array(text.utf8), reached)
    }

    /// One to three members with distinct names.
    mutating func members(level: Int, depth: Int) {
        let count = Int.random(in: 1...3, using: &random)
        for (index, name) in Self.names.shuffled(using: &random).prefix(count).enumerated() {
            text += (index == 0 ? "" : ",") + name + ":"
            value(level: level, depth: depth, first: index == 0)
        }
    }

    mutating func elements(level: Int, depth: Int) {
        for index in 0..<Int.random(in: 1...3, using: &random) {
            text += index == 0 ? "" : ","
            value(level: level, depth: depth, first: index == 0)
        }
    }

    /// A value in a container at `level`: below `depth` and within the budget, a container if it is the first and
    /// one time in four otherwise; else a scalar.
    mutating func value(level: Int, depth: Int, first: Bool) {
        let opens = first || Int.random(in: 0..<4, using: &random) == 0
        guard level < depth, text.utf8.count < budget, opens else {
            text += Self.scalars.randomElement(using: &random) ?? "null"
            return
        }
        reached = max(reached, level + 1)
        let object = Bool.random(using: &random)
        text += object ? "{" : "["
        if object { members(level: level + 1, depth: depth) } else { elements(level: level + 1, depth: depth) }
        text += object ? "}" : "]"
    }
}
