//
//  OpenSoundControl+StreamFramer.swift
//  FluxKlang
//
//  Incremental framing of OSC packets on byte streams (TCP). The framing is
//  chosen explicitly per stream:
//  - `.slip`: OSC 1.1 / RFC 1055 double-END SLIP. Empty frames between ENDs are
//    ignored. An oversize frame or invalid escape is refused and the framer
//    discards bytes until the next END, then resumes (resync at END).
//  - `.lengthPrefixed`: OSC 1.0 big-endian UInt32 size before each packet. A
//    zero or oversize size is refused and the framer enters a permanent failed
//    state; there is no resync guessing. Create a new framer for a new stream.
//  Buffered bytes never exceed `maximumPacketBytes` (+4 header bytes).
//

extension OpenSoundControl {
    enum StreamFraming: Sendable, Hashable {
        case slip
        case lengthPrefixed
    }

    /// One ordered result of feeding bytes to a framer.
    enum FrameEvent: Sendable, Hashable {
        case frame([UInt8])
        case refused(CodecError)
    }

    enum FramerState: Sendable, Hashable {
        case ready
        /// SLIP only: dropping bytes until the next END.
        case discarding
        /// Length-prefix only: permanent.
        case failed
    }

    struct StreamFramer: Sendable {
        static let slipEnd: UInt8 = 0xC0
        static let slipEscape: UInt8 = 0xDB
        static let slipEscapedEnd: UInt8 = 0xDC
        static let slipEscapedEscape: UInt8 = 0xDD

        let framing: StreamFraming
        let maximumFrameBytes: Int
        private(set) var state: FramerState = .ready
        private var buffer: [UInt8] = []
        private var header: [UInt8] = []
        private var expectedLength: Int?
        private var escaping = false

        init(framing: StreamFraming, limits: Limits = .standard) {
            self.framing = framing
            maximumFrameBytes = limits.maximumPacketBytes
        }

        /// Bytes currently held for an incomplete frame.
        var bufferedByteCount: Int { buffer.count + header.count }

        mutating func append(_ chunk: [UInt8]) -> [FrameEvent] {
            switch framing {
            case .slip: appendSlip(chunk)
            case .lengthPrefixed: appendLengthPrefixed(chunk)
            }
        }

        /// Frames one encoded packet for the given stream framing.
        static func frame(
            _ packet: [UInt8], framing: StreamFraming, limits: Limits = .standard
        ) throws(CodecError) -> [UInt8] {
            guard !packet.isEmpty else { throw .emptyFrame }
            guard packet.count <= limits.maximumPacketBytes, packet.count <= Int(UInt32.max) else {
                throw .frameTooLarge(byteCount: packet.count, limit: limits.maximumPacketBytes)
            }
            switch framing {
            case .lengthPrefixed:
                var writer = ByteWriter()
                writer.append(UInt32(truncatingIfNeeded: packet.count))
                writer.append(bytes: packet)
                return writer.bytes
            case .slip:
                var framed: [UInt8] = [slipEnd]
                for byte in packet {
                    switch byte {
                    case slipEnd: framed += [slipEscape, slipEscapedEnd]
                    case slipEscape: framed += [slipEscape, slipEscapedEscape]
                    default: framed.append(byte)
                    }
                }
                framed.append(slipEnd)
                return framed
            }
        }

        private mutating func appendSlip(_ chunk: [UInt8]) -> [FrameEvent] {
            var events: [FrameEvent] = []
            for byte in chunk {
                if state == .discarding {
                    if byte == Self.slipEnd { resetSlip() }
                    continue
                }
                if escaping {
                    escaping = false
                    appendEscaped(byte, events: &events)
                    continue
                }
                switch byte {
                case Self.slipEnd:
                    if !buffer.isEmpty { events.append(.frame(buffer)) }
                    buffer = []
                case Self.slipEscape:
                    escaping = true
                default:
                    appendSlipByte(byte, events: &events)
                }
            }
            return events
        }

        private mutating func appendEscaped(_ byte: UInt8, events: inout [FrameEvent]) {
            switch byte {
            case Self.slipEscapedEnd: appendSlipByte(Self.slipEnd, events: &events)
            case Self.slipEscapedEscape: appendSlipByte(Self.slipEscape, events: &events)
            default:
                events.append(.refused(.invalidSlipEscape(byte)))
                buffer = []
                // An escaped END still terminates the frame, so the stream is already resynchronised.
                if byte != Self.slipEnd { state = .discarding }
            }
        }

        private mutating func appendSlipByte(_ byte: UInt8, events: inout [FrameEvent]) {
            guard buffer.count < maximumFrameBytes else {
                events.append(.refused(.frameTooLarge(byteCount: buffer.count + 1, limit: maximumFrameBytes)))
                buffer = []
                state = .discarding
                return
            }
            buffer.append(byte)
        }

        private mutating func resetSlip() {
            buffer = []
            escaping = false
            state = .ready
        }

        private mutating func appendLengthPrefixed(_ chunk: [UInt8]) -> [FrameEvent] {
            guard state != .failed else { return [.refused(.framerFailed)] }
            var events: [FrameEvent] = []
            var index = 0
            while index < chunk.count {
                guard let expected = expectedLength else {
                    header.append(chunk[index])
                    index += 1
                    guard header.count == 4 else { continue }
                    let length = header.reduce(0) { $0 << 8 | Int($1) }
                    header = []
                    guard length > 0 else { return fail(.emptyFrame, events) }
                    guard length <= maximumFrameBytes else {
                        return fail(.frameTooLarge(byteCount: length, limit: maximumFrameBytes), events)
                    }
                    expectedLength = length
                    continue
                }
                let take = min(expected - buffer.count, chunk.count - index)
                buffer.append(contentsOf: chunk[index..<(index + take)])
                index += take
                if buffer.count == expected {
                    events.append(.frame(buffer))
                    buffer = []
                    expectedLength = nil
                }
            }
            return events
        }

        private mutating func fail(_ error: CodecError, _ events: [FrameEvent]) -> [FrameEvent] {
            state = .failed
            buffer = []
            header = []
            expectedLength = nil
            return events + [.refused(error)]
        }
    }
}
