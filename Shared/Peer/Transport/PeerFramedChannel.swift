//
//  PeerFramedChannel.swift
//  FluxKlang
//
//  The byte-stream seam between peer framing and a concrete transport. This
//  lane provides no network, TLS or Bonjour implementation; a production
//  transport (Network.framework over TLS) conforms later. Tests use in-memory
//  doubles.
//

import Foundation

enum PeerTransportError: Error, Hashable, Sendable { case disconnected, failed }

/// An ordered, reliable byte stream (for example TCP+TLS).
protocol PeerByteTransport: Sendable {
    func send(_ bytes: [UInt8]) async throws(PeerTransportError)
    /// Up to `maximumLength` bytes; nil at a clean end of stream.
    func receive(maximumLength: Int) async throws(PeerTransportError) -> [UInt8]?
}

enum PeerChannelError: Error, Hashable, Sendable {
    case wire(PeerWireError)
    case transport(PeerTransportError)
    case receiveExceededLimit
}

/// Encodes outbound messages and decodes inbound frames over one transport.
/// Inbound reads are at most one maximum frame, so pending frames stay bounded
/// by the current delivery; they drain FIFO through a head index (linear total
/// work) and the queue is released once drained.
/// Frames decoded before a wire defect are returned first; the defect is then
/// thrown and latched, whatever the transport's chunking.
struct PeerFramedChannel<Transport: PeerByteTransport>: Sendable {
    let transport: Transport
    private var encoder: PeerFrameEncoder
    private var decoder: PeerFrameDecoder
    private var pending: [PeerFrame] = []
    private var pendingHead = 0
    private var failed: PeerChannelError?

    init(transport: Transport, limits: PeerFrameLimits = .standard) {
        self.transport = transport
        encoder = PeerFrameEncoder(limits: limits)
        decoder = PeerFrameDecoder(limits: limits)
    }

    /// Refuses with the latched error once inbound decoding or the transport has
    /// failed. A transport send failure latches too: the frame's sequence is
    /// spent and the stream may hold a partial frame, so the channel is dead.
    /// An encode refusal (oversized payload) spends no sequence and does not latch.
    mutating func send(_ message: PeerOutboundMessage) async throws(PeerChannelError) {
        if let failed { throw failed }
        let bytes: [UInt8]
        do {
            bytes = try encoder.encode(message)
        } catch {
            throw .wire(error)
        }
        do {
            try await transport.send(bytes)
        } catch {
            throw latch(.transport(error))
        }
    }

    /// The next whole frame, or nil at a clean end of stream between frames.
    mutating func receive() async throws(PeerChannelError) -> PeerFrame? {
        while pendingHead == pending.count {
            if let failed { throw failed }
            let maximum = decoder.limits.maximumFrameBytes
            let chunk: [UInt8]?
            do {
                chunk = try await transport.receive(maximumLength: maximum)
            } catch {
                throw latch(.transport(error))
            }
            guard let chunk else {
                do {
                    try decoder.finish()
                } catch {
                    throw latch(.wire(error))
                }
                return nil
            }
            guard chunk.count <= maximum else { throw latch(.receiveExceededLimit) }
            let delivery = decoder.feed(chunk)
            pending = delivery.frames
            pendingHead = 0
            if let failure = delivery.failure { failed = .wire(failure) }
        }
        // Returned frames stay referenced by `pending` until the whole current
        // delivery drains. That is bounded by one delivery (at most one maximum
        // frame of bytes, ~1 MiB at the ceiling). The queue is released when it
        // empties or when a failure latches.
        let frame = pending[pendingHead]
        pendingHead += 1
        if pendingHead == pending.count {
            pending = []
            pendingHead = 0
        }
        return frame
    }

    private mutating func latch(_ error: PeerChannelError) -> PeerChannelError {
        failed = error
        pending = []
        pendingHead = 0
        return error
    }
}

extension PeerFramedChannel {
    /// Runs one hello exchange: the session negotiates or refuses. Every
    /// channel failure becomes a terminal refusal; nothing is retried. A
    /// negotiated, closed or refused session returns its state without reading.
    /// A wire defect latched in the same delivery as the hello or accept refuses
    /// the session rather than reporting it negotiated. Once the channel has
    /// latched any failure, a session that is not refused or closed is failed
    /// with it, including an already negotiated one.
    mutating func negotiate(_ session: inout PeerSessionNegotiator) async -> PeerSessionEvent {
        switch session.state {
        case .refused(let refusal): return .refused(refusal)
        case .closed: return .closed
        case .negotiated, .idle, .awaitingHello, .awaitingAccept: break
        }
        if let failed { return session.fail(Self.refusal(for: failed)).event }
        if let existing = session.negotiated { return .negotiated(existing) }
        if let hello = session.start(), let refusal = await deliver(hello) { return session.fail(refusal).event }
        let frame: PeerFrame?
        do {
            frame = try await receive()
        } catch {
            return session.fail(Self.refusal(for: error)).event
        }
        guard let frame else { return session.fail(.endOfStream).event }
        let step = session.receive(frame)
        // A defect latched behind the hello or accept refuses before any reply is sent.
        if let failed, case .negotiated = step.event { return session.fail(Self.refusal(for: failed)).event }
        if let outbound = step.outbound, let refusal = await deliver(outbound), case .negotiated = step.event {
            return session.fail(refusal).event
        }
        return step.event
    }

    private mutating func deliver(_ message: PeerOutboundMessage) async -> PeerRefusal? {
        do {
            try await send(message)
            return nil
        } catch {
            return Self.refusal(for: error)
        }
    }

    private static func refusal(for error: PeerChannelError) -> PeerRefusal {
        switch error {
        case .wire(let wire): .wire(wire)
        case .transport, .receiveExceededLimit: .transportFailed
        }
    }
}
