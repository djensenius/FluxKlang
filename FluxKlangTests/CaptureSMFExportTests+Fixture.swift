import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension CaptureSMFExportTests {
    /// Fixtures of the CL5 suites. One host tick is `1 / 500` of a clip tick: the timebase is 125/3 ns per host tick,
    /// the rate 48 kHz and the tempo 320,000 µs per quarter, so a quarter is 15,360 frames and one frame is one tick.
    enum Fixture {
        static let clock = ClockID(validated: "smp.main")
        static let musicalClock = ClockID(validated: "mus.main")
        static let timebase = HostTimebase(numer: 125, denom: 3)
        static let baseHost: UInt64 = 2_400_000_000
        static let hostPerTick: UInt64 = 500
        static let streamA = StreamID(validated: "str.a")
        static let streamB = StreamID(validated: "str.b")
        static let streamC = StreamID(validated: "str.c")
        static let idle = StreamID(validated: "str.idle")
        static let other = StreamID(validated: "str.other")
        static let undeclared = StreamID(validated: "str.undeclared")
        // swiftlint:disable:next nesting
        typealias Feed = CaptureSMFExportTests.Feed

        static func noteOn(_ channel: UInt8, _ note: UInt8, _ velocity: UInt8) -> [UInt32] {
            voice(0x90 | (channel - 1), note, velocity)
        }

        static func noteOff(_ channel: UInt8, _ note: UInt8, _ velocity: UInt8) -> [UInt32] {
            voice(0x80 | (channel - 1), note, velocity)
        }

        static func controlChange(_ channel: UInt8, _ controller: UInt8, _ value: UInt8) -> [UInt32] {
            voice(0xB0 | (channel - 1), controller, value)
        }

        /// One MT 0x2 word of group 0.
        static func voice(_ status: UInt8, _ data1: UInt8, _ data2: UInt8?) -> [UInt32] {
            [0x2000_0000 | UInt32(status) << 16 | UInt32(data1) << 8 | UInt32(data2 ?? 0)]
        }

        /// A MIDI 2 channel-voice Note On (MT 0x4), which this slice does not translate.
        static let midi2NoteOn: [UInt32] = [0x4090_3C00, 0xC924_0000]
        /// A JR Timestamp (MT 0x0), a SysEx 7 packet (MT 0x3) and a system real-time clock (MT 0x1).
        static let utility: [UInt32] = [0x0020_1F40]
        static let sysEx: [UInt32] = [0x3004_0102, 0x0300_0000]
        static let realTime: [UInt32] = [0x10F8_0000]

        static func anchor(transport: Int?, frame: Int64 = 0, ticks: Int64 = 0) throws -> ClockAnchor {
            let musical = try transport.map {
                MusicalStamp(transport: try Generation($0), musicalMap: .initial, ticks: ticks, loopIteration: 0)
            }
            return ClockAnchor(sample: SampleStamp(clock: clock, generation: .initial, frame: frame),
                               host: HostStamp(ticks: baseHost + UInt64(frame) * hostPerTick), musical: musical)
        }

        /// A musical map through `anchor`, which must carry a musical stamp.
        static func map(_ anchor: ClockAnchor) throws -> MusicalClockMap {
            let map = try MusicalMap(clock: musicalClock, revision: .initial,
                                     segments: [TempoSegment(atTicks: 0, microsPerQuarter: 320_000)])
            let musical = try #require(anchor.musical)
            return try MusicalClockMap(anchor: anchor, map: map, nominalRate: 48_000,
                                       currentSample: anchor.sample.generation, currentTransport: musical.transport)
        }

        static func export(_ log: MIDICaptureLog, _ streams: [StreamID],
                           length: Int64? = nil) throws -> CaptureClipExport {
            try CaptureClipExport.make(from: log, streams: streams, lengthTicks: length)
        }

        /// The refusal of an export, or nil when it succeeds.
        static func refusal(_ log: MIDICaptureLog, _ streams: [StreamID],
                            length: Int64? = nil) -> CaptureClipExportRefusal? {
            do {
                _ = try CaptureClipExport.make(from: log, streams: streams, lengthTicks: length)
                return nil
            } catch {
                return error
            }
        }

        static func timed(_ ticks: Int64, _ message: MIDI1Semantic) -> CaptureTimedMessage {
            CaptureTimedMessage(ticks: ticks, message: message)
        }

        static func pairingRefusal(_ events: [CaptureTimedMessage], length: Int64) -> CaptureClipExportRefusal? {
            do {
                _ = try CaptureNotePairing.pair(events, lengthTicks: length)
                return nil
            } catch {
                return error
            }
        }
    }

    /// A log under construction: every capture at clip tick `tick` is stamped `tick` musical ticks after the
    /// transport anchor, or with no musical ticks when no transport is anchored.
    struct Feed {
        private(set) var log: MIDICaptureLog
        private var musicalMap: MusicalClockMap?
        private var anchorFrame: Int64 = 0

        init(_ streams: [StreamID], transport: Bool = true) throws {
            log = try MIDICaptureLog(streams: streams, clock: Fixture.clock, timebase: Fixture.timebase,
                                     nominalRate: 48_000)
            let anchor = try Fixture.anchor(transport: transport ? 1 : nil)
            try log.observe(anchor: anchor)
            musicalMap = transport ? try Fixture.map(anchor) : nil
        }

        /// Anchors the transport at `frame`, so captures from there on carry musical ticks from `ticks`.
        mutating func anchorTransport(atFrame frame: Int64, ticks: Int64 = 0) throws {
            let anchor = try Fixture.anchor(transport: 1, frame: frame, ticks: ticks)
            try log.observe(anchor: anchor)
            musicalMap = try Fixture.map(anchor)
            anchorFrame = frame
        }

        /// A locate at clip tick `tick`: captures stamped before it are unsupported and taint their stream.
        mutating func locate(atTick tick: Int64) throws {
            let stamp = RuntimeSampleStamp(clock: 0, generation: 1, frame: 0)
            let host = HostStamp(ticks: Fixture.baseHost + UInt64(tick) * Fixture.hostPerTick)
            let locate = RuntimeDiscontinuity(kind: .locate, sample: stamp, frames: nil, stream: nil, host: host)
            try log.observe(locate, stream: nil)
        }

        /// The log's refusal of a capture, or nil when it was accepted.
        mutating func captureRefusal(_ stream: StreamID, _ words: [UInt32], tick: Int64) -> MIDICaptureRefusal? {
            do {
                try add(stream, words, tick: tick)
                return nil
            } catch {
                return error as? MIDICaptureRefusal
            }
        }

        @discardableResult
        mutating func add(_ stream: StreamID, _ words: [UInt32], tick: Int64,
                          endpoint: MIDIEndpointProtocol = .midi1,
                          port: MIDIPortProtocol = .midi1) throws -> MIDICaptureOutcome {
            let host = Fixture.baseHost + UInt64(tick + anchorFrame) * Fixture.hostPerTick
            return try log.capture(words, stream: stream, host: HostStamp(ticks: host), endpoint: endpoint,
                                   port: port, musicalMap: musicalMap, current: .initial)
        }
    }
}
