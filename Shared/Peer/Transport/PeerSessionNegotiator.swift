//
//  PeerSessionNegotiator.swift
//  FluxKlang
//
//  Pure capability-hello state machine for one connection (#93). The initiator
//  sends a hello; the acceptor answers with an accept that assigns the
//  connection epoch, or a reject. Any unexpected, malformed or wrong-epoch frame
//  refuses the session permanently. Refusal yields nothing further.
//
//  A negotiated session admits opaque control *candidates* only when both
//  sides agreed the `control` capability. Close is one-way with no
//  acknowledgement; afterwards in-flight current-epoch control/close frames are
//  dropped and anything else refuses. Control candidates are not
//  authorized: identity, pairing and grants are #94, and command freshness and
//  authority are #95/#62.
//

import Foundation

enum PeerSessionRole: Hashable, Sendable { case initiator, acceptor }

/// Local eligibility for the acceptor, computed by the host (#57 platform
/// state, #94 trust/pairing policy) and never taken from peer bytes.
enum PeerAcceptorAvailability: Hashable, Sendable { case available, ineligible, denied }

struct PeerNegotiatedSession: Hashable, Sendable {
    let protocolVersion: UInt16
    let hostEpoch: Generation
    let connectionEpoch: Generation
    let capabilities: PeerCapabilitySet
}

/// An admitted, epoch-checked control payload. Not an authorization.
struct PeerControlCandidate: Hashable, Sendable {
    let connectionEpoch: Generation
    let sequence: UInt32
    let payload: [UInt8]
}

enum PeerRefusal: Hashable, Sendable {
    case wire(PeerWireError)
    case transportFailed
    case endOfStream
    case unexpectedFrame(PeerFrameKind)
    case incompatibleVersion
    case missingRequiredCapability
    case epochMismatch
    case rejectedByPeer(PeerRejectReason)
    case locallyUnavailable(PeerRejectReason)
}

enum PeerSessionEvent: Hashable, Sendable {
    case none
    case negotiated(PeerNegotiatedSession)
    case control(PeerControlCandidate)
    case closed
    case refused(PeerRefusal)
}

struct PeerSessionStep: Hashable, Sendable {
    var outbound: PeerOutboundMessage?
    var event: PeerSessionEvent
}

enum PeerSessionError: Error, Hashable, Sendable {
    case notNegotiated
    /// The negotiated capabilities do not include `PeerCapability.control`.
    case controlNotNegotiated
}

struct PeerSessionNegotiator: Sendable {
    enum State: Hashable, Sendable {
        case idle, awaitingHello, awaitingAccept
        case negotiated(PeerNegotiatedSession)
        /// One-way: no acknowledgement is sent or awaited.
        case closed(connectionEpoch: Generation)
        case refused(PeerRefusal)
    }

    /// Acceptor-only inputs, computed by the host before the hello arrives and
    /// never taken from peer bytes. `connectionEpoch` must be fresh for every
    /// connection, issued by the host with `Generation.next()` (the epoch
    /// ledger is owned by #95/#97). `availability` combines host platform state
    /// (#57, e.g. Local Network) and trust/pairing policy (#94).
    struct AcceptorContext: Hashable, Sendable {
        let hostEpoch: Generation
        let connectionEpoch: Generation
        let availability: PeerAcceptorAvailability
    }

    let role: PeerSessionRole
    let versions: ClosedRange<UInt16>
    let offered: PeerCapabilitySet
    let required: PeerCapabilitySet
    private let acceptor: AcceptorContext?
    private(set) var state: State

    /// `versions` must lie within `PeerWire.supportedProtocolVersions`.
    static func initiator(declaring hello: PeerHello) -> Self? {
        guard hello.versions.clamped(to: PeerWire.supportedProtocolVersions) == hello.versions else { return nil }
        return Self(role: .initiator, hello: hello, acceptor: nil, state: .idle)
    }

    static func acceptor(declaring hello: PeerHello, context: AcceptorContext) -> Self? {
        guard hello.versions.clamped(to: PeerWire.supportedProtocolVersions) == hello.versions else { return nil }
        return Self(role: .acceptor, hello: hello, acceptor: context, state: .awaitingHello)
    }

    private init(role: PeerSessionRole, hello: PeerHello, acceptor: AcceptorContext?, state: State) {
        self.role = role
        versions = hello.versions
        offered = hello.offered
        required = hello.required
        self.acceptor = acceptor
        self.state = state
    }

    var negotiated: PeerNegotiatedSession? {
        if case .negotiated(let session) = state { session } else { nil }
    }

    /// The initiator's opening hello; nil for an acceptor or after start.
    mutating func start() -> PeerOutboundMessage? {
        guard role == .initiator, state == .idle, let hello = PeerHello(
            versions: versions, offered: offered, required: required
        ) else { return nil }
        state = .awaitingAccept
        return PeerOutboundMessage(kind: .hello, connectionEpoch: nil, payload: hello.encoded())
    }

    mutating func receive(_ frame: PeerFrame) -> PeerSessionStep {
        switch state {
        case .refused(let refusal):
            return PeerSessionStep(outbound: nil, event: .refused(refusal))
        case .awaitingHello where frame.kind == .hello:
            return answerHello(frame)
        case .awaitingAccept where frame.kind == .helloAccept:
            return completeAccept(frame)
        case .awaitingAccept where frame.kind == .helloReject:
            return completeReject(frame)
        case .negotiated(let session) where frame.kind == .control || frame.kind == .close:
            return admit(frame, in: session)
        case .closed(let epoch) where frame.kind == .control || frame.kind == .close:
            guard frame.connectionEpoch == epoch else { return refuse(.epochMismatch) }
            return PeerSessionStep(outbound: nil, event: .closed)
        default:
            return refuse(.unexpectedFrame(frame.kind))
        }
    }

    /// Records a decoder or transport failure; terminal. A closed session
    /// stays closed, since the transport is expected to end after a close.
    mutating func fail(_ refusal: PeerRefusal) -> PeerSessionStep {
        switch state {
        case .refused(let existing): return PeerSessionStep(outbound: nil, event: .refused(existing))
        case .closed: return PeerSessionStep(outbound: nil, event: .closed)
        default: return refuse(refusal)
        }
    }

    /// Only when `control` was negotiated.
    func control(_ payload: [UInt8]) throws(PeerSessionError) -> PeerOutboundMessage {
        guard let session = negotiated else { throw .notNegotiated }
        guard session.capabilities.contains(.control) else { throw .controlNotNegotiated }
        return PeerOutboundMessage(kind: .control, connectionEpoch: session.connectionEpoch, payload: payload)
    }

    /// Close is one-way with no acknowledgement. Afterwards, current-epoch
    /// control and close frames already in flight are dropped silently and
    /// anything else refuses.
    mutating func close() throws(PeerSessionError) -> PeerOutboundMessage {
        guard let session = negotiated else { throw .notNegotiated }
        state = .closed(connectionEpoch: session.connectionEpoch)
        return PeerOutboundMessage(kind: .close, connectionEpoch: session.connectionEpoch, payload: [])
    }

    private mutating func answerHello(_ frame: PeerFrame) -> PeerSessionStep {
        guard let acceptor else { return refuse(.unexpectedFrame(.hello)) }
        guard frame.connectionEpoch == nil else { return refuse(.epochMismatch) }
        switch acceptor.availability {
        case .available: break
        case .ineligible: return refuse(.locallyUnavailable(.ineligible), reply: .ineligible)
        case .denied: return refuse(.locallyUnavailable(.denied), reply: .denied)
        }
        let hello: PeerHello
        do {
            hello = try PeerHello.decode(frame.payload)
        } catch {
            return refuse(.wire(error), reply: .malformedHello)
        }
        guard let version = Self.highestCommon(versions, hello.versions) else {
            return refuse(.incompatibleVersion, reply: .incompatibleVersion)
        }
        let shared = offered.intersection(hello.offered)
        guard hello.required.isSubset(of: shared), required.isSubset(of: shared) else {
            return refuse(.missingRequiredCapability, reply: .missingRequiredCapability)
        }
        let session = PeerNegotiatedSession(
            protocolVersion: version, hostEpoch: acceptor.hostEpoch,
            connectionEpoch: acceptor.connectionEpoch, capabilities: shared
        )
        state = .negotiated(session)
        let accept = PeerHelloAccept(
            version: version, hostEpoch: session.hostEpoch,
            connectionEpoch: session.connectionEpoch, capabilities: shared
        )
        let reply = PeerOutboundMessage(
            kind: .helloAccept, connectionEpoch: session.connectionEpoch, payload: accept.encoded()
        )
        return PeerSessionStep(outbound: reply, event: .negotiated(session))
    }

    private mutating func completeReject(_ frame: PeerFrame) -> PeerSessionStep {
        guard frame.connectionEpoch == nil else { return refuse(.epochMismatch) }
        do {
            return refuse(.rejectedByPeer(try PeerRejectReason.decode(frame.payload)))
        } catch {
            return refuse(.wire(error))
        }
    }

    /// Admits a close, or a control frame when `control` was negotiated, only
    /// on the negotiated connection epoch.
    private mutating func admit(_ frame: PeerFrame, in session: PeerNegotiatedSession) -> PeerSessionStep {
        guard frame.connectionEpoch == session.connectionEpoch else { return refuse(.epochMismatch) }
        guard frame.kind == .control else {
            guard frame.payload.isEmpty else { return refuse(.wire(.malformedPayload(.close))) }
            state = .closed(connectionEpoch: session.connectionEpoch)
            return PeerSessionStep(outbound: nil, event: .closed)
        }
        guard session.capabilities.contains(.control) else { return refuse(.missingRequiredCapability) }
        let candidate = PeerControlCandidate(
            connectionEpoch: session.connectionEpoch, sequence: frame.sequence, payload: frame.payload
        )
        return PeerSessionStep(outbound: nil, event: .control(candidate))
    }

    private mutating func completeAccept(_ frame: PeerFrame) -> PeerSessionStep {
        let accept: PeerHelloAccept
        do {
            accept = try PeerHelloAccept.decode(frame.payload)
        } catch {
            return refuse(.wire(error))
        }
        guard frame.connectionEpoch == accept.connectionEpoch else { return refuse(.epochMismatch) }
        guard versions.contains(accept.version) else { return refuse(.incompatibleVersion) }
        guard accept.capabilities.isSubset(of: offered), required.isSubset(of: accept.capabilities) else {
            return refuse(.missingRequiredCapability)
        }
        let session = PeerNegotiatedSession(
            protocolVersion: accept.version, hostEpoch: accept.hostEpoch,
            connectionEpoch: accept.connectionEpoch, capabilities: accept.capabilities
        )
        state = .negotiated(session)
        return PeerSessionStep(outbound: nil, event: .negotiated(session))
    }

    private mutating func refuse(_ refusal: PeerRefusal, reply: PeerRejectReason? = nil) -> PeerSessionStep {
        state = .refused(refusal)
        let outbound = reply.map {
            PeerOutboundMessage(kind: .helloReject, connectionEpoch: nil, payload: $0.encoded)
        }
        return PeerSessionStep(outbound: outbound, event: .refused(refusal))
    }

    private static func highestCommon(_ lhs: ClosedRange<UInt16>, _ rhs: ClosedRange<UInt16>) -> UInt16? {
        let lower = max(lhs.lowerBound, rhs.lowerBound)
        let upper = min(lhs.upperBound, rhs.upperBound)
        return lower <= upper ? upper : nil
    }
}
