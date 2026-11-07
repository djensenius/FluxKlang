//
//  OpenSoundControl+EndpointPolicy.swift
//  FluxKlang
//
//  The validated, immutable policy of one opt-in OSC intake endpoint (#89, O2b):
//  transport, allow-list, per-peer budget, peer-table size, idle expiry and the
//  codec bounds derived from them. Nothing enables itself: an endpoint is
//  `.disabled` until a caller passes a validated policy, and a disabled
//  endpoint holds no state. Every value validates once at construction and has
//  private storage afterwards, so an out-of-range policy cannot be represented.
//

extension OpenSoundControl {
    /// An opaque, host-assigned key for one remote peer: a datagram source or one
    /// stream connection. It is never parsed or compared as an address, and this
    /// stage keeps no address. A stream transport must give every connection its
    /// own key, because framing state is per key, and must never reuse a key for a
    /// later connection: there is no forget call, so a key's slot is freed only by
    /// `IntakePipeline.expire` or `disable()`.
    struct PeerKey: Sendable, Hashable, Comparable {
        let rawValue: UInt64

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// How an endpoint receives packets: one packet per datagram, or byte streams
    /// that are framed explicitly (never guessed).
    enum EndpointTransport: Sendable, Hashable {
        case datagram
        case stream(StreamFraming)

        /// The stream framing, or nil for datagrams.
        var framing: StreamFraming? {
            switch self {
            case .datagram: nil
            case .stream(let framing): framing
            }
        }
    }

    /// The policy knob a configuration refusal names.
    enum EndpointKnob: Sendable, Hashable {
        case peers, packets, bytes, malformed, packetBytes, bundleDepth
        case window, cooldown, idle
    }

    /// Every typed refusal of endpoint configuration. A refused call changes nothing.
    enum EndpointRefusal: Error, Sendable, Hashable {
        /// A count outside its documented range.
        case invalidCount(EndpointKnob, Int)
        /// A tick span below one.
        case invalidTicks(EndpointKnob, UInt64)
        /// The byte allowance is below the packet size: a full-size packet could never fit a window.
        case budgetCannotFitPacket(maximumBytes: Int, maximumPacketBytes: Int)
        /// A stream endpoint's byte allowance is below one whole chunk (a maximum-size frame and its length
        /// header). A full chunk could then never fit a window, yet a chunk refusal tells the caller to offer
        /// the same bytes again, so such a policy cannot be built. Datagram endpoints are not affected.
        case budgetCannotFitChunk(maximumBytes: Int, maximumChunkBytes: Int)
        /// Idle expiry is shorter than the window: expiry would grant budget a window roll would not.
        case idleBeforeWindowEnds(idleTicks: UInt64, windowTicks: UInt64)
        /// An endpoint is already enabled; disable it before enabling another policy.
        case alreadyEnabled
    }

    /// The validated policy of one endpoint. Limits are hard-ceilinged; tick-valued
    /// limits have no ceiling because ticks are only ever compared and subtracted
    /// after an ordering check, never added, so nothing can overflow.
    struct EndpointPolicy: Sendable, Hashable {
        /// Most peers one endpoint tracks.
        static let peerLimit = 256
        /// Largest packet (and frame) an endpoint may accept: the codec default.
        static let packetBytesLimit = Limits.standard.maximumPacketBytes
        /// Deepest bundle nesting an endpoint may accept: T1's ceiling.
        static let bundleDepthLimit = SchedulingPolicy.bundleDepthLimit
        /// The stream length header that may precede one maximum-size frame in a chunk.
        static let lengthHeaderBytes = 4

        private(set) var transport: EndpointTransport
        /// Passed to the immediate stage unchanged: inbound wildcards stay refused (Q-OSC-NS, provisional v1).
        private(set) var allowList: AllowList
        private(set) var budget: IntakeBudget
        private(set) var maximumPeers: Int
        /// A peer untouched for this many ticks (and not quarantined) may be expired; at least the window.
        private(set) var idleTicks: UInt64
        private(set) var maximumPacketBytes: Int
        /// A top-level bundle has depth 1; a bare message has depth 0.
        private(set) var maximumBundleDepth: Int

        /// Validation order: peers, idle, packet bytes, bundle depth, then the byte allowance against the
        /// packet size, then (stream endpoints only) against one whole chunk, then idle against the window.
        init(
            transport: EndpointTransport, allowList: AllowList, budget: IntakeBudget, maximumPeers: Int,
            idleTicks: UInt64, maximumPacketBytes: Int = EndpointPolicy.packetBytesLimit,
            maximumBundleDepth: Int = SchedulingPolicy.defaultMaximumBundleDepth
        ) throws(EndpointRefusal) {
            guard (1...Self.peerLimit).contains(maximumPeers) else { throw .invalidCount(.peers, maximumPeers) }
            guard idleTicks >= 1 else { throw .invalidTicks(.idle, idleTicks) }
            guard (1...Self.packetBytesLimit).contains(maximumPacketBytes) else {
                throw .invalidCount(.packetBytes, maximumPacketBytes)
            }
            guard (1...Self.bundleDepthLimit).contains(maximumBundleDepth) else {
                throw .invalidCount(.bundleDepth, maximumBundleDepth)
            }
            guard budget.maximumBytes >= maximumPacketBytes else {
                throw .budgetCannotFitPacket(maximumBytes: budget.maximumBytes, maximumPacketBytes: maximumPacketBytes)
            }
            let chunkBytes = maximumPacketBytes + Self.lengthHeaderBytes
            guard transport.framing == nil || budget.maximumBytes >= chunkBytes else {
                throw .budgetCannotFitChunk(maximumBytes: budget.maximumBytes, maximumChunkBytes: chunkBytes)
            }
            guard idleTicks >= budget.windowTicks else {
                throw .idleBeforeWindowEnds(idleTicks: idleTicks, windowTicks: budget.windowTicks)
            }
            self.transport = transport
            self.allowList = allowList
            self.budget = budget
            self.maximumPeers = maximumPeers
            self.idleTicks = idleTicks
            self.maximumPacketBytes = maximumPacketBytes
            self.maximumBundleDepth = maximumBundleDepth
        }

        /// The codec bounds for decoding and framing: the policy's packet size and depth, the rest standard.
        var limits: Limits {
            Limits(maximumPacketBytes: maximumPacketBytes, maximumBundleDepth: maximumBundleDepth)
        }

        /// Most bytes one stream chunk may carry: one maximum-size frame and its length header. On a stream
        /// endpoint the byte allowance always holds one whole chunk (checked at construction).
        var maximumChunkBytes: Int { maximumPacketBytes + Self.lengthHeaderBytes }

        /// Most bytes all framers together can hold for incomplete frames: the lane bound of one maximum-size
        /// frame plus its four-byte length header per peer. A framer actually holds at most one frame body
        /// (SLIP: up to `maximumPacketBytes`) or fewer than four header bytes, so the bound is never reached.
        var bufferedByteBound: Int { maximumPeers * (maximumPacketBytes + Self.lengthHeaderBytes) }
    }

    /// Whether an endpoint is taking packets. The initial state is `.disabled`.
    enum EndpointState: Sendable, Hashable {
        case disabled
        case enabled(EndpointPolicy)

        var policy: EndpointPolicy? {
            switch self {
            case .disabled: nil
            case .enabled(let policy): policy
            }
        }

        var isEnabled: Bool { policy != nil }
    }
}
