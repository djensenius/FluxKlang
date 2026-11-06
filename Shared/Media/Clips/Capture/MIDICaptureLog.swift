//
//  MIDICaptureLog.swift
//  FluxKlang
//
//  A per-stream MIDI capture log (#112 CL4, media-contract.md §5.2, §9.1–§9.2). It
//  stores UMP words verbatim with the frame derived through the current anchor,
//  musical ticks exactly when a transport is anchored, and the protocol fields.
//  It keeps the first anchor of every sample clock generation, so a native UMP
//  export's origin never moves when the clock restarts later. Pure values only:
//  no CoreMIDI, threads or files.
//

/// The capture log of one sample clock. Records keep delivery order within and across streams.
///
/// Clock observations must arrive in host order, and the log refuses those that do not: a restart must start the next
/// generation and carry its nominal rate; a restart or locate may not precede the latest restart, locate or current
/// anchor; an anchor may not precede the latest restart or locate and, after its generation's first anchor, must agree
/// with it (§5.2). Discontinuities name their stream through `stream:`; `RuntimeDiscontinuity.stream` and
/// `.sample.clock` are runtime slots, which the log reads only to cross-check: a stream slot without a `stream:` always
/// disagrees, and with a `RuntimePreparation` both slots must be the ones it maps for `clock` and `stream:`.
struct MIDICaptureLog: Equatable, Sendable {
    static let maximumStreams = 64
    static let maximumCaptures = 65_536
    static let maximumUnsupported = 4_096
    static let maximumGenerations = 4_096
    /// The musical anchors of the current transport generation a musical map may be built from; the oldest is
    /// forgotten first, so a map from an older anchor of a long loop is refused (fail closed).
    static let maximumMusicalAnchors = 64

    /// Proof that the log admitted a capture: only this file can make one, so only the log builds records.
    struct Admission: Sendable {
        fileprivate init() {}
    }

    /// The protocols a stream's first capture pins until a `formatChange` on that stream.
    private struct ProtocolPin: Equatable, Sendable {
        let endpoint: MIDIEndpointProtocol
        let port: MIDIPortProtocol
    }

    /// The runtime slots of the log's clock and streams, from a `RuntimePreparation`.
    private struct RuntimeSlots: Equatable, Sendable {
        let clock: UInt32
        let streams: [StreamID: UInt32]
    }

    let streams: [StreamID]
    let clock: ClockID
    let timebase: HostTimebase
    /// The nominal rate of the current generation: the initializer's until a restart supplies the next one's.
    private(set) var nominalRate: Int
    /// The nominal rate of each generation in `firstAnchors`, kept when it is first anchored.
    private(set) var rates: [Generation: Int] = [:]
    private(set) var records: [MIDICaptureRecord] = []
    private(set) var unsupported: [MIDICaptureUnsupported] = []
    /// Streams no export may claim losslessly, with their first taint.
    private(set) var taints: [StreamID: MIDICaptureTaint] = [:]
    /// The first anchor recorded for each generation of `clock` (the checker's `first_anchor`).
    private(set) var firstAnchors: [Generation: ClockAnchor] = [:]
    /// The live sample clock generation: the latest anchor's, or the latest restart's.
    private(set) var currentGeneration: Generation?
    /// The latest anchor of `currentGeneration`; nil until the first anchor after a restart.
    private(set) var currentAnchor: ClockAnchor?
    /// The new-generation sample and host stamp of the latest restart, used as that generation's drift reference.
    private var restartAnchor: ClockAnchor?
    /// The latest musical stamp while a transport is anchored; a locate or restart clears it until the next one.
    private(set) var transport: MusicalStamp?
    /// The latest `maximumMusicalAnchors` distinct anchors carrying `transport`'s transport generation, oldest first.
    private(set) var musicalAnchors: [ClockAnchor] = []
    /// The genuine first musical anchor of the current transport, retained while rolling anchor history is bounded.
    private(set) var firstMusicalAnchor: ClockAnchor?
    /// Whether an anchor needed to resolve a capture frame may have fallen out of `musicalAnchors`.
    private var musicalAnchorHistoryWasEvicted = false
    private(set) var latestRestart: HostStamp?
    private(set) var latestLocate: HostStamp?
    private var pins: [StreamID: ProtocolPin] = [:]
    private let slots: RuntimeSlots?

    /// Refuses more than `maximumStreams` streams, a repeated stream, an invalid nominal rate, a zero timebase, and a
    /// `preparation` that maps no sample clock slot for `clock` or no capture stream slot for a stream. `nominalRate`
    /// is the rate of the first generation the log anchors unless a restart before it supplies another.
    init(streams: [StreamID], clock: ClockID, timebase: HostTimebase, nominalRate: Int,
         preparation: RuntimePreparation? = nil) throws(MIDICaptureRefusal) {
        guard streams.count <= Self.maximumStreams else {
            throw .tooManyStreams(count: streams.count, limit: Self.maximumStreams)
        }
        var seen = Set<StreamID>()
        for stream in streams where !seen.insert(stream).inserted {
            throw .duplicateStream(stream)
        }
        guard MediaNominalRate.isValid(nominalRate) else { throw .invalidRate(nominalRate) }
        guard timebase.numer > 0, timebase.denom > 0 else { throw .invalidTimebase }
        self.streams = streams
        self.clock = clock
        self.timebase = timebase
        self.nominalRate = nominalRate
        slots = try preparation.map { preparation throws(MIDICaptureRefusal) in
            do throws(RuntimePreparationError) {
                var streamSlots: [StreamID: UInt32] = [:]
                for stream in streams {
                    streamSlots[stream] = try preparation.slot(for: .stream(stream, direction: .capture))
                }
                return RuntimeSlots(clock: try preparation.slot(for: .sampleClock(clock)), streams: streamSlots)
            } catch {
                throw .runtimeSlotsUnmapped
            }
        }
    }

    /// Records an advancing anchor of the current generation (any generation for the log's first anchor, or the
    /// generation a restart started), at or after the latest restart. Later anchors must advance in host and frame
    /// and agree with the generation's first anchor, or its restart stamp when restarted (§5.2–§5.3).
    mutating func observe(anchor: ClockAnchor) throws(MIDICaptureRefusal) {
        guard anchor.sample.clock == clock else { throw .foreignClock(anchor.sample.clock) }
        let generation = anchor.sample.generation
        if let currentGeneration, generation != currentGeneration { throw .staleGeneration }
        if let restart = latestRestart, anchor.host.ticks < restart.ticks {
            throw .anchorPredatesRestart(restart: restart)
        }
        if let locate = latestLocate, anchor.host.ticks < locate.ticks {
            throw .anchorPredatesLocate(locate: locate)
        }
        if let currentAnchor,
           anchor.host.ticks <= currentAnchor.host.ticks || anchor.sample.frame <= currentAnchor.sample.frame {
            throw .anchorDisagrees
        }
        let first = firstAnchors[generation]
        if let reference = restartAnchor ?? first {
            guard let map = try? SampleClockMap(anchor: reference, nominalRate: nominalRate, timebase: timebase),
                  map.agrees(anchor) else { throw .anchorDisagrees }
        }
        if first == nil {
            guard firstAnchors.count < Self.maximumGenerations else {
                throw .capacity(limit: Self.maximumGenerations)
            }
            firstAnchors[generation] = anchor
            rates[generation] = nominalRate
        }
        currentGeneration = generation
        currentAnchor = anchor
        if let musical = anchor.musical { remember(anchor, musical) }
    }

    /// Makes `musical` the anchored transport and remembers its anchor for musical maps.
    private mutating func remember(_ anchor: ClockAnchor, _ musical: MusicalStamp) {
        if transport?.transport != musical.transport {
            musicalAnchors = []
            firstMusicalAnchor = anchor
            musicalAnchorHistoryWasEvicted = false
        }
        if !musicalAnchors.contains(anchor) {
            if musicalAnchors.count == Self.maximumMusicalAnchors {
                musicalAnchors.removeFirst()
                musicalAnchorHistoryWasEvicted = true
            }
            musicalAnchors.append(anchor)
        }
        transport = musical
    }

    /// Applies a discontinuity of this clock. `clockRestart` starts the next generation at `nominalRate`, which only
    /// a restart carries and a restart needs; `locate` ends the transport anchor. Both need host ticks at or after
    /// the latest restart, locate and current anchor, which later captures are checked against. `formatChange` names
    /// its stream and re-pins that stream's protocols on its next capture. Other kinds do not affect MIDI capture.
    mutating func observe(_ discontinuity: RuntimeDiscontinuity, stream: StreamID?,
                          nominalRate rate: Int? = nil) throws(MIDICaptureRefusal) {
        if let stream, !streams.contains(stream) { throw .undeclaredStream(stream) }
        try crossCheck(discontinuity, stream: stream)
        if case .clockRestart = discontinuity.kind {
            try restart(discontinuity, rate: rate)
            return
        }
        guard rate == nil else { throw .nominalRateWithoutRestart }
        if let currentGeneration, Int(exactly: discontinuity.sample.generation) != currentGeneration.value {
            throw .staleGeneration
        }
        switch discontinuity.kind {
        case .locate:
            guard let host = discontinuity.host else { throw .discontinuityNeedsHost }
            try requireNotBackwards(host)
            transport = nil
            musicalAnchors = []
            firstMusicalAnchor = nil
            musicalAnchorHistoryWasEvicted = false
            latestLocate = host
        case .formatChange:
            guard let stream else { throw .formatChangeNeedsStream }
            pins[stream] = nil
        default:
            break
        }
    }

    /// A restart starts the next generation (generations step by one and are never ordered, M2) at its own rate.
    private mutating func restart(_ discontinuity: RuntimeDiscontinuity, rate: Int?) throws(MIDICaptureRefusal) {
        guard let host = discontinuity.host else { throw .discontinuityNeedsHost }
        guard let raw = Int(exactly: discontinuity.sample.generation), let generation = try? Generation(raw),
              currentGeneration.map({ (try? $0.next()) == generation }) ?? true else { throw .staleGeneration }
        try requireNotBackwards(host)
        guard let rate else { throw .restartNeedsRate }
        guard MediaNominalRate.isValid(rate) else { throw .invalidRate(rate) }
        currentGeneration = generation
        currentAnchor = nil
        transport = nil
        musicalAnchors = []
        firstMusicalAnchor = nil
        musicalAnchorHistoryWasEvicted = false
        latestRestart = host
        restartAnchor = ClockAnchor(
            sample: SampleStamp(clock: clock, generation: generation, frame: discontinuity.sample.frame),
            host: host,
            musical: nil)
        nominalRate = rate
    }

    /// Refuses a restart or locate before the latest restart, locate or current anchor, which would reopen the past.
    private func requireNotBackwards(_ host: HostStamp) throws(MIDICaptureRefusal) {
        let cutoff = [latestRestart, latestLocate, currentAnchor?.host].compactMap { $0 }.max { $0.ticks < $1.ticks }
        if let cutoff, host.ticks < cutoff.ticks { throw .discontinuityPredatesCutoff(host: host, cutoff: cutoff) }
    }

    /// A stream slot needs a `stream:`; with runtime slots, the clock and stream slots must be the mapped ones.
    private func crossCheck(_ discontinuity: RuntimeDiscontinuity,
                            stream: StreamID?) throws(MIDICaptureRefusal) {
        if let slot = discontinuity.stream {
            guard let stream else { throw .discontinuitySlotMismatch }
            if let slots, slots.streams[stream] != slot { throw .discontinuitySlotMismatch }
        }
        if let slots, discontinuity.sample.clock != slots.clock { throw .discontinuitySlotMismatch }
    }

    // The parameters are the §9.2 capture inputs (words, stream, host, protocols, clocks), kept flat.
    // swiftlint:disable function_parameter_count
    /// Captures one packet on the current generation `current`, in its stream's pinned protocols. A capture stamped
    /// before the latest restart or locate is recorded in `unsupported`, taints its stream and returns
    /// `.unsupported`; otherwise its frame derives through the current anchor at the generation's rate, and its
    /// nonnegative musical ticks through a same-rate `musicalMap`, which must be given exactly when a transport is
    /// anchored.
    mutating func capture(_ words: [UInt32], stream: StreamID, host: HostStamp, endpoint: MIDIEndpointProtocol,
                          port: MIDIPortProtocol, musicalMap: MusicalClockMap?,
                          current: Generation) throws(MIDICaptureRefusal) -> MIDICaptureOutcome {
        guard streams.contains(stream) else { throw .undeclaredStream(stream) }
        let packet: UMPPacket
        do throws(UMPRefusal) {
            packet = try UMPPacket(words: words)
        } catch {
            throw .invalidPacket(error)
        }
        let stamp = try MIDIProtocolStamp.classify(packet, endpoint: endpoint, port: port)
        guard let currentGeneration else { throw .noCurrentAnchor }
        guard current == currentGeneration else { throw .staleGeneration }
        let pin = ProtocolPin(endpoint: endpoint, port: port)
        if let pinned = pins[stream], pinned != pin { throw .protocolChangedWithoutFormatChange(stream: stream) }
        if let reason = unsupportedReason(host) {
            guard unsupported.count < Self.maximumUnsupported else {
                taint(stream, .refusedAtCapacity)
                throw .capacity(limit: Self.maximumUnsupported)
            }
            unsupported.append(MIDICaptureUnsupported(Admission(), stream: stream, packet: packet, host: host,
                                                      protocolStamp: stamp, reason: reason))
            taint(stream, .unsupportedCapture)
            pins[stream] = pin
            return .unsupported(reason)
        }
        guard let anchor = currentAnchor else { throw .noCurrentAnchor }
        let frame = try frame(atHost: host, anchor: anchor, current: current)
        let ticks = try musicalTicks(atFrame: frame, map: musicalMap)
        guard records.count < Self.maximumCaptures else {
            taint(stream, .refusedAtCapacity)
            throw .capacity(limit: Self.maximumCaptures)
        }
        let record = MIDICaptureRecord(Admission(), stream: stream, packet: packet, host: host,
                                       sample: SampleStamp(clock: clock, generation: current, frame: frame),
                                       musicalTicks: ticks, protocolStamp: stamp)
        records.append(record)
        pins[stream] = pin
        return .recorded(record)
    }
    // swiftlint:enable function_parameter_count

    /// Strictly before the latest restart (as the checker compares), else strictly before the latest locate.
    private func unsupportedReason(_ host: HostStamp) -> MIDICaptureUnsupportedReason? {
        if let restart = latestRestart, host.ticks < restart.ticks { return .predatesClockRestart(restart: restart) }
        if let locate = latestLocate, host.ticks < locate.ticks { return .predatesLocate(locate: locate) }
        return nil
    }

    private mutating func taint(_ stream: StreamID, _ taint: MIDICaptureTaint) {
        if taints[stream] == nil { taints[stream] = taint }
    }

    private func frame(atHost host: HostStamp, anchor: ClockAnchor, current: Generation) throws(MIDICaptureRefusal)
        -> Int64 {
        do throws(ClockMapError) {
            let map = try SampleClockMap(anchor: anchor, nominalRate: nominalRate, timebase: timebase)
            return try map.frame(atHost: host, current: current)
        } catch {
            throw error == .overflow ? .overflow : .staleGeneration
        }
    }

    private func musicalTicks(atFrame frame: Int64, map: MusicalClockMap?) throws(MIDICaptureRefusal) -> Int64? {
        guard let transport else {
            guard map == nil else { throw .musicalMapMismatch }
            return nil
        }
        guard let map else { throw .musicalMapMismatch }
        guard map.nominalRate == nominalRate else { throw .musicalMapMismatch }
        let expectedAnchor = try musicalAnchor(atOrBefore: frame)
        guard map.anchor == expectedAnchor, map.map.revision == transport.musicalMap else {
            throw .musicalMapMismatch
        }
        let ticks: Int64
        do throws(ClockMapError) {
            ticks = try map.ticks(atFrame: frame)
        } catch {
            throw .overflow
        }
        guard ticks >= 0 else { throw .negativeMusicalTicks }
        return ticks
    }

    /// Resolves the map basis for a frame, retaining the genuine first anchor as a pre-anchor fallback.
    private func musicalAnchor(atOrBefore frame: Int64) throws(MIDICaptureRefusal) -> ClockAnchor {
        if let latest = musicalAnchors.last(where: { $0.sample.frame <= frame }) { return latest }
        if let firstMusicalAnchor, frame < firstMusicalAnchor.sample.frame { return firstMusicalAnchor }
        guard !musicalAnchorHistoryWasEvicted, let firstMusicalAnchor else {
            throw .musicalMapMismatch
        }
        return firstMusicalAnchor
    }
}
