import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension PeerControlMessageTests {
    @Test func commandWithUnknownFieldsIsUnencodable() {
        let message = F.command(F.intent(unknownFields: ["x": .bool(true)]))
        #expect(F.encode(message) == .failure(.unencodable(.unknownFields)))
        #expect((try? F.encode(F.command(F.intent(unknownFields: [:]))).get().isEmpty) == false)
    }

    @Test func triggerResultIsUnencodableInEveryPosition() {
        let trigger = CommandResult.trigger(TriggerOutcome(trigger: F.ident("t"), result: .fired))
        #expect(F.encode(F.result(.replayed(.refused(trigger)))) == .failure(.unencodable(.trigger)))
        #expect(F.encode(F.result(.refused(.command(trigger)))) == .failure(.unencodable(.trigger)))
    }

    @Test func reservedTriggerResultCodeAndUnknownInnerCodesAreMalformed() {
        let head = F.goldenResult.prefix(13)
        let reserved = Array(head) + [4, 1, 4]
        #expect(Self.isMalformed(F.decode(reserved)))
        for outcome in [UInt8(0), 5, 0xFF] {
            #expect(Self.isMalformed(F.decode(Array(head) + [outcome])))
        }
        for section in [UInt8(0), 3, 9] {
            #expect(Self.isMalformed(F.decode(Array(head) + [4, section])))
        }
    }

    @Test func intentFactoryRefusalIsMalformedAtTheIntentStart() {
        let golden = F.goldenCommand
        let operationStart = golden.count - 6 - 12
        #expect(golden[operationStart] == 1)
        let bytes = Array(golden[..<operationStart]) + [8] + F.u64(UInt64.max) + Array(golden.suffix(6))
        #expect(F.decode(bytes) == .failure(.malformed(offset: 9)))
        let accepted = Array(golden[..<operationStart]) + [8] + F.u64(0) + Array(golden.suffix(6))
        #expect((try? F.decode(accepted).get().tag) == .command)
    }

    @Test func rampOverTheLimitOnTheWireIsMalformedAndAtTheLimitIsAccepted() {
        func payload(_ milliseconds: UInt64) -> [UInt8] {
            let intent = F.bytes(F.command(F.intent(operation: .ramp(F.pid("p"), F.value(0.5), milliseconds: 0))))
            let ramp = intent.count - 6 - 4
            guard ramp >= 0 else { return [] }
            var bytes = intent
            bytes.replaceSubrange(ramp..<(ramp + 4), with: F.u32(milliseconds))
            return bytes
        }
        #expect((try? F.decode(payload(60_000)).get().tag) == .command)
        #expect(F.decode(payload(60_001)) == .failure(.malformed(offset: 9)))
        #expect(F.decode(payload(UInt64(UInt32.max))) == .failure(.malformed(offset: 9)))
    }

    @Test func connectionFlagMustBeZeroOrOne() {
        let withConnection = F.goldenCommand
        let flag = 9 + 4 + 1 + 1 + 2 + 8
        var bytes = withConnection
        #expect(bytes[flag] == 1)
        bytes[flag] = 2
        #expect(F.decode(bytes) == .failure(.malformed(offset: flag)))
        bytes[flag] = 0
        #expect(Self.isMalformed(F.decode(bytes)))
    }

    @Test func commandWithoutAConnectionEpochRoundTripsWithOneFlagByte() {
        let with = F.bytes(F.command())
        let without = F.bytes(F.command(F.intent(connection: false)))
        #expect(with.count - without.count == 2 + 8)
        #expect(F.decode(without) == .success(F.command(F.intent(connection: false))))
    }

    @Test func fingerprintLengthBoundsAreEnforcedOnDecode() {
        let base = F.goldenCommand
        let prefix = Array(base.dropLast(6))
        func payload(_ length: Int, filler: UInt8 = 0x61) -> [UInt8] {
            prefix + [UInt8(length >> 8), UInt8(length & 0xFF)] + [UInt8](repeating: filler, count: length)
        }
        #expect((try? F.decode(payload(1)).get().tag) == .command)
        #expect((try? F.decode(payload(256)).get().tag) == .command)
        #expect(Self.isMalformed(F.decode(payload(0))))
        #expect(F.decode(payload(257)) == .failure(.malformed(offset: prefix.count)))
        #expect(F.decode(prefix + [0xFF, 0xFF, 0x61]) == .failure(.malformed(offset: prefix.count)))
        let invalid = prefix + [0, 2, 0xC3, 0x28]
        #expect(F.decode(invalid) == .failure(.malformed(offset: prefix.count + 2)))
        let overlong = prefix + [0, 2, 0xC0, 0x80]
        #expect(Self.isMalformed(F.decode(overlong)))
        let wide = String(repeating: "é", count: 128)
        let encoded = F.bytes(F.command(F.intent(permission: wide)))
        #expect(Array(encoded.suffix(2 + 256).prefix(2)) == [1, 0])
    }

    @Test func fingerprintWriterRefusesTextOutsideItsByteBounds() {
        let accepted = String(repeating: "é", count: 128)
        var writer = PeerWireWriter()
        do {
            try PeerControlMessage.writeText(accepted, bounds: 1...256, wide: true, into: &writer)
        } catch { Issue.record("256 bytes refused: \(error)") }
        #expect(Array(writer.bytes.prefix(2)) == [1, 0])
        for text in [accepted + "x", String(repeating: "é", count: 127) + "xxx", ""] {
            var scratch = PeerWireWriter()
            var failure: PeerControlMessageError?
            do { try PeerControlMessage.writeText(text, bounds: 1...256, wide: true, into: &scratch) } catch {
                failure = error
            }
            #expect(failure == .unencodable(.textLength(text.utf8.count)))
            #expect(scratch.bytes.isEmpty)
        }
    }
}
