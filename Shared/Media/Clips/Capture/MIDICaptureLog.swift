//
//  MIDICaptureLog.swift
//  FluxKlang
//
//  A per-stream MIDI capture log (#112 CL4, media-contract.md §9.1–§9.2). It
//  stores UMP words verbatim with the frame derived through the current anchor,
//  musical ticks exactly when a transport is anchored, and the protocol fields.
//  It keeps the first anchor of every sample clock generation, so a native UMP
//  export's origin never moves when the clock restarts later. Pure values only:
//  no CoreMIDI, threads or files.
//

/// The capture log of one sample clock. Records keep delivery order within and across streams.
struct MIDICaptureLog: Equatable, Sendable {
    static let maximumStreams = 64
    static let maximumCaptures = 65_536
    static let maximumUnsupported = 4_096
    static let maximumGenerations = 4_096

    /// Proof that the log admitted a capture: only this file can make one, so only the log builds records.
    struct Admission: Sendable {
        fileprivate init() {}
    }

    /// The protocols a stream's first capture pins until a `formatChange` on that stream.
    private struct ProtocolPin: Equatable, Sendable {
        let endpoint: MIDIEndpointProtocol
        let port: MIDIPortProtocol
    }

    let streams: [StreamID]
    let clock: ClockID
    let timebase: HostTimebase
    let nominalRate: Int
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
    /// The latest musical stamp while a transport is anchored; a locate or restart clears it until the next one.
    private(set) var transport: MusicalStamp?
    private(set) var latestRestart: HostStamp?
    private(set) var latestLocate: HostStamp?
    private var pins: [StreamID: ProtocolPin] = [:]

    /// Refuses more than `maximumStreams` streams, a repeated stream, an invalid nominal rate or a zero timebase.
    init(streams: [StreamID], clock: ClockID, timebase: HostTimebase, nominalRate: Int) throws(MIDICaptureRefusal) {
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
    }

    /// Records an anchor of the current generation (any generation for the log's first anchor, or the generation a
    /// restart started). The first anchor of each generation is kept; the latest becomes the current anchor.
    mutating func observe(anchor: ClockAnchor) throws(MIDICaptureRefusal) {
        guard anchor.sample.clock == clock else { throw .foreignClock(anchor.sample.clock) }
        let generation = anchor.sample.generation
        if let currentGeneration, generation != currentGeneration { throw .staleGeneration }
        if firstAnchors[generation] == nil {
            guard firstAnchors.count < Self.maximumGenerations else {
                throw .capacity(limit: Self.maximumGenerations)
            }
            firstAnchors[generation] = anchor
        }
        currentGeneration = generation
        currentAnchor = anchor
        if let musical = anchor.musical { transport = musical }
    }

    /// Applies a discontinuity of this clock. `clockRestart` starts a new generation and `locate` ends the transport
    /// anchor; both need host ticks, which later captures are checked against. `formatChange` names its stream and
    /// re-pins that stream's protocols on its next capture. Other kinds do not affect MIDI capture.
    mutating func observe(_ discontinuity: RuntimeDiscontinuity, stream: StreamID?) throws(MIDICaptureRefusal) {
        if let stream, !streams.contains(stream) { throw .undeclaredStream(stream) }
        if case .clockRestart = discontinuity.kind {
            guard let host = discontinuity.host else { throw .discontinuityNeedsHost }
            guard let raw = Int(exactly: discontinuity.sample.generation), let generation = try? Generation(raw),
                  generation != currentGeneration, firstAnchors[generation] == nil else { throw .staleGeneration }
            currentGeneration = generation
            currentAnchor = nil
            transport = nil
            latestRestart = host
            return
        }
        if let currentGeneration, Int(exactly: discontinuity.sample.generation) != currentGeneration.value {
            throw .staleGeneration
        }
        switch discontinuity.kind {
        case .locate:
            guard let host = discontinuity.host else { throw .discontinuityNeedsHost }
            transport = nil
            latestLocate = host
        case .formatChange:
            guard let stream else { throw .formatChangeNeedsStream }
            pins[stream] = nil
        default:
            break
        }
    }

    // The parameters are the §9.2 capture inputs (words, stream, host, protocols, clocks), kept flat.
    // swiftlint:disable function_parameter_count
    /// Captures one packet. A capture stamped before the latest restart or locate is recorded in `unsupported`, taints
    /// its stream and returns `.unsupported`; otherwise its frame derives through the current anchor of `current`,
    /// and its musical ticks through `musicalMap`, which must be given exactly when a transport is anchored.
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
        if let reason = unsupportedReason(host) {
            guard unsupported.count < Self.maximumUnsupported else {
                taint(stream, .refusedAtCapacity)
                throw .capacity(limit: Self.maximumUnsupported)
            }
            unsupported.append(MIDICaptureUnsupported(Admission(), stream: stream, packet: packet, host: host,
                                                      protocolStamp: stamp, reason: reason))
            taint(stream, .unsupportedCapture)
            return .unsupported(reason)
        }
        let pin = ProtocolPin(endpoint: endpoint, port: port)
        if let pinned = pins[stream], pinned != pin { throw .protocolChangedWithoutFormatChange(stream: stream) }
        guard let anchor = currentAnchor else { throw .noCurrentAnchor }
        let frame = try frame(atHost: host, anchor: anchor, current: current)
        let ticks = try musicalTicks(atFrame: frame, map: musicalMap, current: current)
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

    private func musicalTicks(atFrame frame: Int64, map: MusicalClockMap?,
                              current: Generation) throws(MIDICaptureRefusal) -> Int64? {
        guard let transport else {
            guard map == nil else { throw .musicalMapMismatch }
            return nil
        }
        guard let map, map.anchor.sample.clock == clock, map.anchor.sample.generation == current,
              map.musical.transport == transport.transport else { throw .musicalMapMismatch }
        do throws(ClockMapError) {
            return try map.ticks(atFrame: frame)
        } catch {
            throw .overflow
        }
    }
}
