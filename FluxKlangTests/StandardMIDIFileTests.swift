import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

@Suite("Standard MIDI File writer")
struct StandardMIDIFileTests {
    typealias Clip = MIDIClipTimingTests
    static let quarter = MusicalTime.ticksPerQuarter

    /// A whole file: header, then `chunks` as given (each already a chunk, see `chunk`).
    static func file(format: UInt16 = 0, tracks: UInt16 = 1, division: UInt16 = 960,
                     headerExtra: [UInt8] = [], chunks: [[UInt8]]) -> [UInt8] {
        let header = [format >> 8, format & 0xFF, tracks >> 8, tracks & 0xFF, division >> 8, division & 0xFF]
            .map { UInt8($0) } + headerExtra
        return chunk("MThd", header) + chunks.flatMap { $0 }
    }

    static func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
        let length = UInt32(body.count)
        return Array(type.utf8) + [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: length >> $0) } + body
    }

    /// A track chunk of `events`, ended by End of Track after `endDelta` ticks.
    static func track(_ events: [UInt8], endDelta: [UInt8] = [0x00]) -> [UInt8] {
        chunk("MTrk", events + endDelta + [0xFF, 0x2F, 0x00])
    }

    static func refusal(_ bytes: [UInt8], limits: SMFReadLimits = .standard) -> SMFRefusal? {
        do {
            _ = try StandardMIDIFile.read(bytes, limits: limits)
            return nil
        } catch {
            return error
        }
    }

    static func roundTrip(_ clip: MIDIClip) throws -> MIDIClip {
        try StandardMIDIFile.read(StandardMIDIFile.write(clip).bytes).clip
    }

    static let golden = [
        Clip.note(0, quarter, velocity: 100),
        .event(ticks: quarter / 2, message: .controlChange(channel: 2, controller: 7, value: 100)),
        Clip.note(quarter, 2 * quarter, pitch: 62, velocity: 90, release: 0),
        .event(ticks: 2 * quarter, message: .pitchBend(channel: 16, value: 0x2000))
    ]

    @Test
    func aSmallClipWritesTheseExactBytes() throws {
        let clip = try MIDIClip.make(lengthTicks: 4 * Self.quarter, items: Self.golden)
        let result = StandardMIDIFile.write(clip)
        let header: [UInt8] = [0x4D, 0x54, 0x68, 0x64, 0, 0, 0, 6, 0, 0, 0, 1, 0x3C, 0x00]
        // Each event has its own status byte; at tick 30720 the Note Off precedes the pitch bend.
        let events: [UInt8] = [
            0x00, 0x90, 0x3C, 0x64,
            0xBC, 0x00, 0xB1, 0x07, 0x64,
            0xBC, 0x00, 0x80, 0x3C, 0x40,
            0x00, 0x90, 0x3E, 0x5A,
            0xF8, 0x00, 0x80, 0x3E, 0x00,
            0x00, 0xEF, 0x00, 0x40,
            0x81, 0xF0, 0x00, 0xFF, 0x2F, 0x00
        ]
        #expect(result.bytes == header + [0x4D, 0x54, 0x72, 0x6B, 0, 0, 0, 0x21] + events)
        #expect(result.losses.lossless)
        #expect(result.losses == SMFExportLossReport(losses: [:]))
        #expect(result.reorderedItems == 0)
        let read = try StandardMIDIFile.read(result.bytes)
        #expect(read.clip == clip)
        #expect(read.report == SMFReadReport(format: 0, division: 15_360, tracks: 1, ignoredMeta: [:],
                                             unknownChunks: 0, ignoredHeaderBytes: 0, ignoredSysEx: [:],
                                             ignoredControllers: [:], ignoredNoteOffs: 0, ignoredZeroLengthNotes: 0,
                                             ignoredEventsAtEnd: 0))
    }

    @Test
    func theDivisionIsTheClipResolutionWithTheSMPTEBitClear() {
        #expect(StandardMIDIFile.division == 15_360)
        #expect(StandardMIDIFile.division & 0x8000 == 0)
        #expect(SMFExportLoss.allCases.count == 11)
        #expect(!SMFExportLossReport(losses: [.passesOverlaid: 1]).lossless)
        #expect(SMFExportLoss.allCases.map(\.rawValue).first == "timingQuantized")
    }

    static let quantities: [(UInt32, [UInt8])] = [
        (0, [0x00]), (0x7F, [0x7F]), (0x80, [0x81, 0x00]), (0x3FFF, [0xFF, 0x7F]), (0x4000, [0x81, 0x80, 0x00]),
        (0x1F_FFFF, [0xFF, 0xFF, 0x7F]), (0x20_0000, [0x81, 0x80, 0x80, 0x00]), (0x0FFF_FFFF, [0xFF, 0xFF, 0xFF, 0x7F])
    ]

    @Test(arguments: quantities)
    func quantitiesEncodeAndDecodeAtEveryLengthBoundary(value: UInt32, bytes: [UInt8]) throws {
        #expect(StandardMIDIFile.quantity(value) == bytes)
        var offset = 0
        let padded = bytes + [0x55]
        #expect(try StandardMIDIFile.readQuantity(padded, at: &offset, end: padded.count) == value)
        #expect(offset == bytes.count)
    }

    @Test
    func overlongAndTruncatedQuantitiesAreRefused() {
        func refusal(_ bytes: [UInt8], from start: Int = 0) -> SMFRefusal? {
            var offset = start
            do {
                _ = try StandardMIDIFile.readQuantity(bytes, at: &offset, end: bytes.count)
                return nil
            } catch {
                return error
            }
        }
        #expect(StandardMIDIFile.maximumQuantity == 0x0FFF_FFFF)
        #expect(refusal([0x80, 0x80, 0x80, 0x80, 0x00]) == .overlongQuantity(offset: 0))
        #expect(refusal([0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F], from: 1) == .overlongQuantity(offset: 1))
        #expect(refusal([0x81]) == .truncated(offset: 0))
        #expect(refusal([0x00, 0xFF, 0xFF, 0xFF], from: 1) == .truncated(offset: 1))
        #expect(refusal([]) == .truncated(offset: 0))
        // An overlong delta inside a file is refused at its offset (14 header bytes + 8 chunk bytes).
        let file = Self.file(chunks: [Self.track([0x80, 0x80, 0x80, 0x80, 0x00, 0x90, 0x3C, 0x64])])
        #expect(Self.refusal(file) == .overlongQuantity(offset: 22))
    }

    @Test
    func writingThenReadingIsTheIdentityForOrderedClips() throws {
        var generator = MIDIClipSplitMix64(seed: 0x112C_2)
        for round in 0..<20 {
            let length = Int64(1 + generator.next() % UInt64(8 * Self.quarter))
            var items: [MIDIClipItem] = []
            var free: [UInt16: Int64] = [:]
            var tick: Int64 = 0
            for index in 0..<(10 + round * 7) {
                tick = min(length - 1, tick + Int64(generator.next() % 2000))
                let channel = UInt8(1 + generator.next() % 16)
                let value = UInt8(generator.next() % 128)
                switch index % 6 {
                case 0: items.append(.event(ticks: tick, message: .programChange(channel: channel, program: value)))
                case 1: items.append(.event(ticks: tick, message: .channelPressure(channel: channel, pressure: value)))
                case 2:
                    let pressure = MIDI1Semantic.polyphonicPressure(channel: channel, note: value,
                                                                    pressure: 127 - value)
                    items.append(.event(ticks: tick, message: pressure))
                case 3:
                    let bend = UInt16(generator.next() % 0x4000)
                    items.append(.event(ticks: tick, message: .pitchBend(channel: channel, value: bend)))
                default:
                    let key = UInt16(channel) << 8 | UInt16(value)
                    guard free[key, default: 0] <= tick else { continue }
                    let end = min(length, tick + 1 + Int64(generator.next() % 5000))
                    free[key] = end
                    items.append(Clip.note(tick, end, pitch: value, channel: channel,
                                           velocity: UInt8(1 + generator.next() % 127),
                                           release: UInt8(generator.next() % 128)))
                }
            }
            let clip = try MIDIClip.make(lengthTicks: length, items: items)
            let written = StandardMIDIFile.write(clip)
            #expect(written.reorderedItems == 0)
            #expect(written.losses.lossless)
            #expect(try StandardMIDIFile.read(written.bytes).clip == clip)
        }
    }

    @Test
    func aFullClipAtTheLengthAndItemBoundsRoundTrips() throws {
        let length = MIDIClip.maximumLengthTicks
        let items = (0..<MIDIClip.maximumItems).map { index in
            let start = Int64(index) * 3840
            return Clip.note(start, index == MIDIClip.maximumItems - 1 ? length : start + 1,
                             pitch: UInt8(index % 128), channel: UInt8(1 + index % 16))
        }
        let clip = try MIDIClip.make(lengthTicks: length, items: items)
        let written = StandardMIDIFile.write(clip)
        #expect(written.bytes.count < SMFReadLimits.standard.maximumFileBytes)
        #expect(try Self.roundTrip(clip) == clip)
        // The largest single delta: one event at tick 0 and End of Track at the maximum length.
        let sparse = try MIDIClip.make(lengthTicks: length, items: [Clip.controlChange(0)])
        let bytes = StandardMIDIFile.write(sparse).bytes
        #expect(Array(bytes.suffix(7)) == StandardMIDIFile.quantity(UInt32(length)) + [0xFF, 0x2F, 0x00])
        #expect(try Self.roundTrip(sparse) == sparse)
    }

    @Test
    func sameTickEventsKeepAuthoringOrderAndNoteOffsComeFirst() throws {
        let items = [
            Clip.note(0, Self.quarter), Clip.controlChange(Self.quarter, value: 9),
            Clip.note(Self.quarter, 2 * Self.quarter), Clip.controlChange(Self.quarter, value: 3)
        ]
        let clip = try MIDIClip.make(lengthTicks: 2 * Self.quarter, items: items)
        let bytes = StandardMIDIFile.write(clip).bytes
        // Tick 15360: Note Off of item 0, then CC 9, the Note On of item 2 and CC 3 in authoring order.
        let atQuarter: [UInt8] = [0xF8, 0x00, 0x80, 0x3C, 0x40, 0x00, 0xB0, 0x07, 0x09,
                                  0x00, 0x90, 0x3C, 0x64, 0x00, 0xB0, 0x07, 0x03]
        #expect(Array(bytes[26..<43]) == atQuarter)
        #expect(try Self.roundTrip(clip) == clip)
    }

    @Test
    func itemsOutOfOnsetOrderAreReorderedAndPlayTheSame() throws {
        let items = [
            Clip.note(2 * Self.quarter, 3 * Self.quarter, pitch: 64), Clip.controlChange(Self.quarter, value: 5),
            Clip.note(0, 3 * Self.quarter, pitch: 60), Clip.note(Self.quarter, 2 * Self.quarter, pitch: 62),
            Clip.controlChange(Self.quarter, value: 6)
        ]
        let clip = try MIDIClip.make(lengthTicks: 4 * Self.quarter, items: items)
        let written = StandardMIDIFile.write(clip)
        #expect(written.reorderedItems == 4)
        #expect(written.losses.lossless)
        let read = try StandardMIDIFile.read(written.bytes).clip
        #expect(read.items == [items[2], items[1], items[3], items[4], items[0]])
        #expect(StandardMIDIFile.write(read).reorderedItems == 0)
        #expect(StandardMIDIFile.write(read).bytes == written.bytes)
        let original = try MIDIClipPlacement.make(clip: clip, startTicks: 0, loop: nil)
        let reordered = try MIDIClipPlacement.make(clip: read, startTicks: 0, loop: nil)
        let messages = { (placement: MIDIClipPlacement) in
            try Clip.events(placement, 0, 200_000).map { [String(describing: $0.frame), "\($0.message)"] }
        }
        #expect(try messages(original) == messages(reordered))
    }
}

/// #112 MLC1: per-capture SMF export losses, pinned to check_media_contract.py `midi2_losses` and `on_export`.
extension StandardMIDIFileTests {
    static func captureLosses(_ words: [UInt32], endpoint: MIDIEndpointProtocol = .midi2,
                              port: MIDIPortProtocol = .midi2) throws -> [SMFExportLoss: Int] {
        let packet = try UMPPacket(words: words)
        let stamp = try MIDIProtocolStamp.classify(packet, endpoint: endpoint, port: port)
        return SMFCaptureLossClassifier.losses(of: packet, stamp: stamp)
    }

    @Test
    func genuineMIDI2NoteLossesFollowTheChecker() throws {
        #expect(try Self.captureLosses([0x4090_3C00, 0xC924_0000]).isEmpty)
        #expect(try Self.captureLosses([0x4090_3C00, 0x0100_0000])
            == [.noteOnVelocityRemapped: 1, .velocityDownscaled: 1])
        #expect(try Self.captureLosses([0x4090_3C00, 0x0000_0000]) == [.noteOnVelocityRemapped: 1])
        #expect(try Self.captureLosses([0x4080_3C00, 0x0100_0000]) == [.velocityDownscaled: 1])
        #expect(try Self.captureLosses([0x4080_3C00, 0x0000_0000]).isEmpty)
        #expect(try Self.captureLosses([0x4090_3C03, 0xC924_1E00]) == [.attributeDropped: 1])
        #expect(try Self.captureLosses([0x4080_3C01, 0xC925_0000]) == [.velocityDownscaled: 1, .attributeDropped: 1])
    }

    @Test
    func genuineMIDI2ValueLossesFollowTheChecker() throws {
        for opcode: UInt32 in [0xA, 0xB, 0xD, 0x2, 0x3, 0xE] {
            let first = 0x4000_0000 | opcode << 20
            #expect(try Self.captureLosses([first, 0x8000_0000]).isEmpty)
            #expect(try Self.captureLosses([first, 0xFFFF_FFFF]).isEmpty)
            #expect(try Self.captureLosses([first, 0x8000_0001]) == [.valueDownscaled: 1])
        }
        // Above the centre, below the maximum: scaleUp(100, 7→32) and scaleUp(10000, 14→32) repeat the low bits.
        #expect(try Self.captureLosses([0x40B0_0700, 0xC924_9249]).isEmpty)
        #expect(try Self.captureLosses([0x40E0_0000, 0x9C40_E207]).isEmpty)
        #expect(try Self.captureLosses([0x40B0_0700, 0xFE00_0000]) == [.valueDownscaled: 1])
        #expect(try Self.captureLosses([0x40E0_0000, 0xFFFC_0000]) == [.valueDownscaled: 1])
        #expect(try Self.captureLosses([0x40E0_0000, 0xFFFF_FFFE]) == [.valueDownscaled: 1])
    }

    @Test
    func genuineMIDI2OtherOpcodesFollowTheChecker() throws {
        for opcode: UInt32 in [0x0, 0x1, 0x6, 0xF] {
            #expect(try Self.captureLosses([0x4000_0000 | opcode << 20, 0x1234_5678]) == [.perNoteDropped: 1])
        }
        for opcode: UInt32 in [0x4, 0x5, 0x7] {
            #expect(try Self.captureLosses([0x4000_0000 | opcode << 20, 0x8000_0000]) == [.umpOnlyDropped: 1])
        }
        #expect(try Self.captureLosses([0x40C0_0001, 0x1234_5678]).isEmpty)
    }

    @Test
    func onlyGenuineMIDI2IsCheckedAndUnknownEndpointsAreUnverified() throws {
        let lossy: [UInt32] = [0x4090_3C03, 0x0100_0000]
        #expect(try Self.captureLosses(lossy, endpoint: .unknown) == [.fidelityUnverified: 1])
        #expect(try Self.captureLosses([0x4090_3C00, 0xC924_0000], endpoint: .unknown) == [.fidelityUnverified: 1])
        #expect(try Self.captureLosses(lossy, endpoint: .midi1).isEmpty)
        for endpoint in MIDIEndpointProtocol.allCases {
            #expect(try Self.captureLosses([0x2090_3C64], endpoint: endpoint, port: .midi1).isEmpty)
            #expect(try Self.captureLosses([0x2090_3C00], endpoint: endpoint, port: .midi1).isEmpty)
        }
    }

    @Test
    func messageTypesOtherThanChannelVoiceAndData64AreUMPOnly() throws {
        let data64: [UInt32] = [0x3001_0203, 0x0405_0600]
        let others: [[UInt32]] = [[0x0020_1F40], [0x10F8_0000], [0x5000_0000, 0, 0, 0], [0xD000_0000, 0, 0, 0],
                                  [0xF000_0000, 0, 0, 0], [0x6000_0000], [0x8000_0000, 0], [0xE000_0000, 0, 0, 0]]
        for endpoint in MIDIEndpointProtocol.allCases {
            for port in MIDIPortProtocol.allCases {
                #expect(try Self.captureLosses(data64, endpoint: endpoint, port: port).isEmpty)
                for words in others {
                    #expect(try Self.captureLosses(words, endpoint: endpoint, port: port) == [.umpOnlyDropped: 1])
                }
            }
        }
    }

    /// Example 10's nine captures (seq 2...10) sum to its SMF export's losses (seq 12) without `timingQuantized: 1`,
    /// which depends on the export's division, not on one capture.
    @Test
    func example10CapturesSumToTheSMFExportLossesBesidesTiming() throws {
        let log = try MIDICaptureFixture.example10()
        try #require(log.records.count == 9)
        let perCapture = log.records.map { SMFCaptureLossClassifier.losses(of: $0.packet, stamp: $0.protocolStamp) }
        #expect(perCapture == [
            [.velocityDownscaled: 1, .attributeDropped: 1], [.perNoteDropped: 1], [.valueDownscaled: 1],
            [.noteOnVelocityRemapped: 1, .velocityDownscaled: 1], [:], [:], [:], [.fidelityUnverified: 1],
            [.umpOnlyDropped: 1]
        ])
        let total = perCapture.reduce(into: [SMFExportLoss: Int]()) { $0.merge($1, uniquingKeysWith: +) }
        #expect(total == [.velocityDownscaled: 2, .attributeDropped: 1, .perNoteDropped: 1, .valueDownscaled: 1,
                          .noteOnVelocityRemapped: 1, .fidelityUnverified: 1, .umpOnlyDropped: 1])
    }
}
