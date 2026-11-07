//
//  OpenSoundControl+IntakePipeline.swift
//  FluxKlang
//
//  The bounded, opt-in intake stage between a transport and the O1 codec and
//  T1 immediate stage (#89, O2b). It is a pure value type: ticks are injected,
//  and it owns no socket, timer, clock or randomness. Total state is bounded by
//  the policy: at most `maximumPeers` ledgers, and for streams at most
//  `bufferedByteBound` bytes of incomplete frames.
//
//  Cost. Table lookups are O(1) and `expire` is O(peers log peers). Charging
//  and framing are linear in the bytes offered: a peer is taken out of the table
//  before its framer is appended to, so the framer's buffer is never shared and
//  never copied (while the caller holds no other copy of the pipeline). A short
//  chunk can complete a long buffered frame, so only the work over a whole
//  stream is linear in the bytes received. Each completed frame or datagram is
//  decoded in time linear in its size (at most `maximumPacketBytes`), and each
//  message in it costs one allow-list match: at most `AllowList.maximumEntries`
//  (256) entries, each bounded by `AddressPattern.matches` at tokens x address
//  bytes x pattern bytes, with the address and pattern each at most the codec's
//  1,024 string bytes.
//

extension OpenSoundControl {
    /// One input's outcome: its dispatchable batches in order, or the typed refusal.
    typealias IntakeResult = Result<[[Message]], IntakeRefusal>

    /// The outcome of one stream chunk.
    enum ChunkOutcome: Sendable, Hashable {
        /// A gate refusal. Nothing was consumed or charged; re-offer the same bytes later (or in smaller
        /// pieces for `chunkTooLarge`), or close the connection. Skipping them would desynchronise framing.
        case refused(IntakeRefusal)
        /// The bytes were consumed and charged. One result per framer event, in stream order; no results
        /// means a frame is still incomplete.
        case consumed([IntakeResult])
    }

    /// The opt-in intake stage. It starts disabled and holds no state until enabled with a validated
    /// policy; `disable()` returns it to exactly `IntakePipeline()`.
    ///
    /// Refusal order for a call is total, first match wins: disabled, wrong transport, tick regression,
    /// payload size (a chunk above `maximumChunkBytes`, a datagram above the byte allowance), peer table,
    /// quarantine, packet budget, byte budget. Gate refusals are uncharged and leave the pipeline equal to
    /// its value before the call. After the gates the input is charged, then decoded (`malformed`), then
    /// staged (`notAdmitted`). Peers are isolated: a peer's results depend on its own history, the shared
    /// tick, and (first contact only) table occupancy.
    ///
    /// Transport contract. The caller owns everything outside this value:
    /// - `PeerKey`: one key per datagram source and one fresh, never reused key per stream connection. There
    ///   is no forget call; a key's slot is freed only by `expire(now:)` or `disable()`.
    /// - `expire(now:)`: call it regularly with the same tick source, and close the stream connection of every
    ///   key it returns, because that peer's framer is gone.
    /// - `ChunkOutcome.refused` consumed and charged nothing: offer the same bytes again later (in smaller
    ///   pieces after `chunkTooLarge`), or close the connection.
    /// - `ChunkOutcome.consumed` took every byte offered, including frames dropped part way through the chunk
    ///   as uncharged refusals (the peer was quarantined or out of packets by then). Never offer those again.
    /// - A length-prefix framer that fails stays failed (`framerState(for:)` is `.failed`) and every later
    ///   chunk is one more malformed strike: close that connection.
    /// - An empty chunk is a real call: it takes a peer slot if the peer is new, and it advances the tick.
    ///
    /// Limits the caller must know:
    /// - Ticks have no ceiling. Every call that is not refused sets `latestTick`, so one far-future tick makes
    ///   every smaller tick `tickRegressed` until `disable()`. Feed one monotonic host clock, never a tick
    ///   taken from the wire.
    /// - A flood of new keys can fill the peer table, and nothing is ever evicted: `expire(now:)` frees only
    ///   peers that are idle and not quarantined, so a quarantined peer pins its slot until its cooldown is
    ///   over and it has been idle for `idleTicks`. Established peers are unaffected; a new key sees
    ///   `peerTableFull`. Cap the keys per source before they reach this stage.
    struct IntakePipeline: Sendable, Hashable {
        private(set) var endpoint: EndpointState = .disabled
        /// The latest tick of any call that was not a gate refusal; nil while disabled or untouched. A
        /// far-future tick wedges it until `disable()`: see the limits above.
        private(set) var latestTick: UInt64?
        private var peers: [PeerKey: IntakePeer] = [:]

        init() {}

        var peerCount: Int { peers.count }
        /// Tracked peers, ascending.
        var peerKeys: [PeerKey] { peers.keys.sorted() }
        /// Bytes all framers hold for incomplete frames; never above the policy's `bufferedByteBound`.
        var bufferedByteCount: Int { peers.values.reduce(0) { $0 + ($1.framer?.bufferedByteCount ?? 0) } }

        func ledger(for key: PeerKey) -> PeerLedger? { peers[key]?.ledger }
        func framerState(for key: PeerKey) -> FramerState? { peers[key]?.framer?.state }

        /// Turns the endpoint on. A second enable is refused; disable first to change the policy.
        mutating func enable(_ policy: EndpointPolicy) throws(EndpointRefusal) {
            guard !endpoint.isEnabled else { throw .alreadyEnabled }
            endpoint = .enabled(policy)
        }

        /// Turns the endpoint off and discards every peer, framer and tick. Idempotent.
        mutating func disable() { self = IntakePipeline() }

        /// Receives one datagram. Charges the peer one packet and `bytes.count` bytes before decoding. A
        /// datagram above the whole byte allowance can never fit any window and is refused as
        /// `datagramTooLarge`, with no retry hint; one within it but above the policy's packet size is charged
        /// and then refused as `malformed`.
        mutating func receive(datagram bytes: [UInt8], from key: PeerKey, now: UInt64) -> IntakeResult {
            do throws(IntakeRefusal) {
                let policy = try gate(streaming: false, now: now)
                guard bytes.count <= policy.budget.maximumBytes else {
                    throw .datagramTooLarge(byteCount: bytes.count, limit: policy.budget.maximumBytes)
                }
                var peer = try trackedPeer(for: key, policy: policy, now: now)
                peer.ledger = try peer.ledger.admittingDatagram(
                    byteCount: bytes.count, at: now, budget: policy.budget
                )
                let result = Self.process(bytes, policy: policy)
                peer.ledger = Self.charged(peer.ledger, for: result, at: now, budget: policy.budget)
                commit(peer, for: key, now: now)
                return result
            } catch {
                return .failure(error)
            }
        }

        /// Receives the next bytes of one stream. The chunk is charged once (bytes), then every completed
        /// frame charges one packet. A chunk that is not refused at the gates is consumed in full.
        mutating func receive(chunk bytes: [UInt8], from key: PeerKey, now: UInt64) -> ChunkOutcome {
            do throws(IntakeRefusal) {
                let policy = try gate(streaming: true, now: now)
                guard bytes.count <= policy.maximumChunkBytes else {
                    throw .chunkTooLarge(byteCount: bytes.count, limit: policy.maximumChunkBytes)
                }
                var peer = try trackedPeer(for: key, policy: policy, now: now)
                peer.ledger = try peer.ledger.admittingChunk(byteCount: bytes.count, at: now, budget: policy.budget)
                // The last step that can refuse, so a refusal above leaves the table untouched. Taking the entry
                // out now leaves `peer` the only holder of its framer's buffer: appending to a shared buffer
                // would copy it, up to one frame per chunk. Nothing below throws, and `commit` stores it back.
                peers[key] = nil
                var results: [IntakeResult] = []
                for event in peer.feed(bytes) {
                    results.append(Self.result(of: event, ledger: &peer.ledger, policy: policy, now: now))
                }
                commit(peer, for: key, now: now)
                return .consumed(results)
            } catch {
                return .refused(error)
            }
        }

        /// Frees every peer that is idle for `idleTicks` and not quarantined, and returns their keys
        /// ascending. This never grants budget a window roll would not, so it is transparent to datagram
        /// peers. A stream peer loses its framer: close the connection of every returned key. Refused
        /// (`endpointDisabled`, `tickRegressed`) without effect; success advances `latestTick`.
        mutating func expire(now: UInt64) throws(IntakeRefusal) -> [PeerKey] {
            let policy = try gate(streaming: nil, now: now)
            let expired = peers.filter {
                $0.value.ledger.isIdle(at: now, budget: policy.budget, idleTicks: policy.idleTicks)
            }.keys.sorted()
            for key in expired { peers[key] = nil }
            latestTick = now
            return expired
        }

        /// Gates 1 to 3. `streaming` is the transport the call needs, or nil when it needs none.
        private func gate(streaming: Bool?, now: UInt64) throws(IntakeRefusal) -> EndpointPolicy {
            guard let policy = endpoint.policy else { throw .endpointDisabled }
            if let streaming, (policy.transport.framing != nil) != streaming {
                throw .wrongTransport(expected: policy.transport)
            }
            if let latestTick, now < latestTick { throw .tickRegressed(previous: latestTick, now: now) }
            return policy
        }

        /// Gate 5: the established peer, or a fresh one while the table has room. Nothing is stored yet.
        private func trackedPeer(
            for key: PeerKey, policy: EndpointPolicy, now: UInt64
        ) throws(IntakeRefusal) -> IntakePeer {
            if let peer = peers[key] { return peer }
            guard peers.count < policy.maximumPeers else { throw .peerTableFull(limit: policy.maximumPeers) }
            // A fresh peer's first charge cannot refuse, so storing it before that charge (rather than at `commit`)
            // would change nothing a caller can see. Three separate facts make it so:
            // (a) the size gates ran first: `receive(datagram:)` refused `bytes.count > maximumBytes` as
            //     `datagramTooLarge`, and `receive(chunk:)` refused more than `maximumChunkBytes`, which a policy
            //     keeps within `maximumBytes`;
            // (b) `IntakeBudget` guarantees `maximumPackets >= 1`, `maximumBytes >= 1` and `windowTicks >= 1`;
            // (c) `PeerLedger.fresh(at:)` has no quarantine, no tick regression (`lastActivity == now`) and an
            //     empty window.
            return IntakePeer(
                ledger: .fresh(at: now),
                framer: policy.transport.framing.map { StreamFramer(framing: $0, limits: policy.limits) }
            )
        }

        private mutating func commit(_ peer: IntakePeer, for key: PeerKey, now: UInt64) {
            peers[key] = peer
            latestTick = now
        }

        /// Decodes with the policy's limits, then stages with its allow-list and depth.
        private static func process(_ bytes: [UInt8], policy: EndpointPolicy) -> IntakeResult {
            let packet: Packet
            do throws(CodecError) {
                packet = try Decoder(limits: policy.limits).decode(bytes)
            } catch {
                return .failure(.malformed(error))
            }
            do throws(SchedulingRefusal) {
                let batches = try ImmediateStage.admit(
                    packet, allowList: policy.allowList, maximumBundleDepth: policy.maximumBundleDepth
                )
                return .success(batches)
            } catch {
                return .failure(.notAdmitted(error))
            }
        }

        /// A decode failure is one malformed strike; a staged refusal is not.
        private static func charged(
            _ ledger: PeerLedger, for result: IntakeResult, at now: UInt64, budget: IntakeBudget
        ) -> PeerLedger {
            guard case .failure(.malformed) = result else { return ledger }
            return ledger.chargingMalformed(at: now, budget: budget)
        }

        /// One framer event: a frame is charged and processed (or refused individually, uncharged, when the
        /// peer was quarantined or ran out of packets earlier in the chunk); a framer refusal is malformed.
        private static func result(
            of event: FrameEvent, ledger: inout PeerLedger, policy: EndpointPolicy, now: UInt64
        ) -> IntakeResult {
            switch event {
            case .refused(let error):
                ledger = ledger.chargingMalformed(at: now, budget: policy.budget)
                return .failure(.malformed(error))
            case .frame(let bytes):
                do throws(IntakeRefusal) {
                    ledger = try ledger.admittingFrame(at: now, budget: policy.budget)
                } catch {
                    return .failure(error)
                }
                let result = process(bytes, policy: policy)
                ledger = charged(ledger, for: result, at: now, budget: policy.budget)
                return result
            }
        }
    }

    /// What `StreamFramer` exposes. It is not Equatable, so peer equality and hashing use this signature plus
    /// the peer's offered-byte count. It is a proxy, not an identity: it cannot see a pending SLIP escape, the
    /// length a length-prefix framer is waiting for, or buffered contents. The twin and replay tests, which
    /// give both sides the same bytes, vouch for those internals.
    fileprivate struct FramerSignature: Hashable {
        let framing: StreamFraming
        let state: FramerState
        let buffered: Int
        let limit: Int

        init(_ framer: StreamFramer) {
            framing = framer.framing
            state = framer.state
            buffered = framer.bufferedByteCount
            limit = framer.maximumFrameBytes
        }
    }

    /// One tracked peer: its ledger and, on stream endpoints, its framer.
    fileprivate struct IntakePeer: Sendable, Hashable {
        var ledger: PeerLedger
        var framer: StreamFramer?
        /// Every byte offered to the framer so far. Two peers fed different bytes differ even where the
        /// signature cannot tell their framers apart; refused chunks are never offered.
        var offeredBytes = 0

        private var signature: FramerSignature? { framer.map(FramerSignature.init) }

        /// Offers `bytes` to the framer, if the endpoint has one, and returns what it completed.
        mutating func feed(_ bytes: [UInt8]) -> [FrameEvent] {
            offeredBytes &+= bytes.count
            return framer?.append(bytes) ?? []
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.ledger == rhs.ledger && lhs.offeredBytes == rhs.offeredBytes && lhs.signature == rhs.signature
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(ledger)
            hasher.combine(offeredBytes)
            hasher.combine(signature)
        }
    }
}
