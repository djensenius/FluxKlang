//
//  NativeUMPExport.swift
//  FluxKlang
//
//  Lossless `nativeUmp` export of a MIDI capture log (#112 CL4, media-contract.md
//  §9.2): the UMP words verbatim, in capture order, with `offsetsNs` from an
//  origin bound to its generation's first recorded anchor. It never carries
//  absolute host ticks (M13).
//

/// A native UMP export: one packet and one offset per capture record of the named streams, in capture order.
struct NativeUMPExport: Equatable, Sendable {
    let id: ExportID
    let streams: [StreamID]
    /// The take start as clock, generation and frame.
    let origin: SampleStamp
    let packets: [UMPPacket]
    /// Nanoseconds from the origin to each capture, rounded half-up.
    let offsetsNs: [Int64]

    private init(id: ExportID, streams: [StreamID], origin: SampleStamp, packets: [UMPPacket], offsetsNs: [Int64]) {
        self.id = id
        self.streams = streams
        self.origin = origin
        self.packets = packets
        self.offsetsNs = offsetsNs
    }

    /// Always true: an export that cannot be lossless is refused instead.
    var lossless: Bool { true }

    /// Exports the captures of `streams` from `log`. Refuses an empty, repeated or undeclared stream list, a stream
    /// tainted by an unsupported capture or a capacity refusal, an origin without a recorded anchor, no captures, and
    /// an offset outside `Int64`.
    static func make(from log: MIDICaptureLog, id: ExportID, streams: [StreamID],
                     origin: SampleStamp) throws(MIDICaptureRefusal) -> NativeUMPExport {
        let selected = try validate(streams, in: log)
        guard origin.clock == log.clock, let anchor = log.firstAnchors[origin.generation] else {
            throw .originAnchorUnknown(clock: origin.clock, generation: origin.generation)
        }
        let records = log.records.filter { selected.contains($0.stream) }
        guard !records.isEmpty else { throw .exportHasNoCaptures }
        var offsets: [Int64] = []
        offsets.reserveCapacity(records.count)
        for record in records {
            offsets.append(try offset(of: record.host, anchor: anchor, originFrame: origin.frame,
                                      timebase: log.timebase, rate: log.nominalRate))
        }
        return NativeUMPExport(id: id, streams: streams, origin: origin, packets: records.map(\.packet),
                               offsetsNs: offsets)
    }

    /// The distinct declared streams of an export, none of them tainted.
    private static func validate(_ streams: [StreamID],
                                 in log: MIDICaptureLog) throws(MIDICaptureRefusal) -> Set<StreamID> {
        guard !streams.isEmpty else { throw .exportStreamsEmpty }
        var selected = Set<StreamID>()
        for stream in streams {
            guard log.streams.contains(stream) else { throw .undeclaredStream(stream) }
            guard selected.insert(stream).inserted else { throw .exportStreamsDuplicate(stream) }
        }
        for stream in streams {
            switch log.taints[stream] {
            case .unsupportedCapture: throw .containsUnsupportedCapture(stream: stream)
            case .refusedAtCapacity: throw .captureRefusedAtCapacity(stream: stream)
            case nil: break
            }
        }
        return selected
    }

    /// `roundHalfUp(((host − anchorHost)·numer·rate − (originFrame − anchorFrame)·10⁹·denom) / (denom·rate))`: the
    /// checker's `rnd((host − host_at(anchor, originFrame))·nsPerTick)`, in exact `Int128` arithmetic.
    private static func offset(of host: HostStamp, anchor: ClockAnchor, originFrame: Int64,
                               timebase: HostTimebase, rate: Int) throws(MIDICaptureRefusal) -> Int64 {
        let rate = Int128(rate)
        let elapsed = (Int128(host.ticks) - Int128(anchor.host.ticks)) * Int128(timebase.numer) * rate
        let shift = (Int128(originFrame) - Int128(anchor.sample.frame)) * ExactMath.nanosPerSecond
            * Int128(timebase.denom)
        // |elapsed| < 2¹¹⁵ and |shift| < 2¹²⁶ − 2¹¹⁵, so `roundHalfUp`'s doubling stays inside Int128.
        guard let result = Int64(exactly: ExactMath.roundHalfUp(elapsed - shift, Int128(timebase.denom) * rate)) else {
            throw .overflow
        }
        return result
    }
}
