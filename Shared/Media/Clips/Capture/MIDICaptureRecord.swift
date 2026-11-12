//
//  MIDICaptureRecord.swift
//  FluxKlang
//
//  The values a MIDI capture log stores (#112 CL4, media-contract.md §9.2): an
//  accepted capture with its derived stamps, an unsupported capture with its
//  reason, and why a stream can no longer be exported losslessly. Records and
//  unsupported entries need a `MIDICaptureLog.Admission`, which only the log makes.
//

/// One accepted capture: the UMP words verbatim, host ticks, the frame derived through the current anchor, musical
/// ticks exactly when a transport was anchored, the frame those ticks map back to, the pass the ticks belong to, and
/// the §9.1 protocol fields. Host ticks are transient (M13).
struct MIDICaptureRecord: Equatable, Sendable {
    let stream: StreamID
    let packet: UMPPacket
    let host: HostStamp
    let sample: SampleStamp
    let musicalTicks: Int64?
    /// The frame `musicalTicks` maps back to through the capture-time musical map; nil when there are no ticks or
    /// the map-back overflowed Int64. A frame other than `sample.frame` means the ticks quantized the timing.
    let musicalRoundTripFrame: Int64?
    /// The pass `musicalTicks` belong to; nil exactly when there are no ticks.
    let pass: MIDICapturePass?
    let protocolStamp: MIDIProtocolStamp

    init(_ admission: MIDICaptureLog.Admission, stream: StreamID, packet: UMPPacket, host: HostStamp,
         sample: SampleStamp, musicalTicks: Int64?, musicalRoundTripFrame: Int64?, pass: MIDICapturePass?,
         protocolStamp: MIDIProtocolStamp) {
        self.stream = stream
        self.packet = packet
        self.host = host
        self.sample = sample
        self.musicalTicks = musicalTicks
        self.musicalRoundTripFrame = musicalRoundTripFrame
        self.pass = pass
        self.protocolStamp = protocolStamp
    }
}

/// Where a capture lies among the passes of its musical timeline (media-contract.md §9.3). `span` counts the locates
/// and transport restarts before it and `iteration` the loop iterations within its span, carried over a clock restart,
/// which continues its pass. Passes order by span, then iteration; two captures overlay when their passes differ.
struct MIDICapturePass: Comparable, Sendable {
    static let initial = MIDICapturePass(span: 0, iteration: 0)

    let span: Int
    let iteration: Int

    /// The pass a locate or transport restart begins: the next span, at its first loop iteration.
    var nextSpan: MIDICapturePass { MIDICapturePass(span: span + 1, iteration: 0) }

    /// This pass `loops` loop iterations further on.
    func advanced(byLoops loops: UInt32) -> MIDICapturePass {
        MIDICapturePass(span: span, iteration: iteration + Int(loops))
    }

    static func < (lhs: MIDICapturePass, rhs: MIDICapturePass) -> Bool {
        (lhs.span, lhs.iteration) < (rhs.span, rhs.iteration)
    }
}

/// Why a capture is unsupported in v1: it was stamped before the latest restart or locate but delivered after it.
enum MIDICaptureUnsupportedReason: Equatable, Sendable {
    /// Host ticks strictly before the latest `clockRestart`'s host ticks.
    case predatesClockRestart(restart: HostStamp)
    /// Host ticks strictly before the latest `locate`'s host ticks.
    case predatesLocate(locate: HostStamp)
}

/// A capture reported as unsupported: never remapped through the new anchor, never silently dropped.
struct MIDICaptureUnsupported: Equatable, Sendable {
    let stream: StreamID
    let packet: UMPPacket
    let host: HostStamp
    let protocolStamp: MIDIProtocolStamp
    let reason: MIDICaptureUnsupportedReason

    init(_ admission: MIDICaptureLog.Admission, stream: StreamID, packet: UMPPacket, host: HostStamp,
         protocolStamp: MIDIProtocolStamp, reason: MIDICaptureUnsupportedReason) {
        self.stream = stream
        self.packet = packet
        self.host = host
        self.protocolStamp = protocolStamp
        self.reason = reason
    }
}

/// Why no export naming a stream may claim to be lossless. The first taint of a stream is kept.
enum MIDICaptureTaint: Equatable, Sendable {
    /// The stream holds an unsupported capture.
    case unsupportedCapture
    /// A capture on the stream was refused at capacity.
    case refusedAtCapacity
}

/// The result of an accepted capture call.
enum MIDICaptureOutcome: Equatable, Sendable {
    /// Appended to `records`.
    case recorded(MIDICaptureRecord)
    /// Appended to `unsupported`; the stream is tainted.
    case unsupported(MIDICaptureUnsupportedReason)
}
