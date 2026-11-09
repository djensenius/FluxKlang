/// A pure, control-side MIDI input session. It composes `MIDISourceRegistry`, one `ActiveSensingObserver` per input
/// that has a sensing policy and one `MIDINoteLedger`, so the notes an input holds are released on the routes they
/// started on when the input is detached or reset, sends System Reset under the opt-in `.resetSource` profile, or
/// loses Active Sensing under the opt-in `.requestInputLost` policy.
///
/// - The ledger is the authority: `inputLost` runs for each trigger whatever the registry held, and the registry's
///   own release lists are discarded. Nothing expires by itself and the session has no timeout.
/// - `feed` and `poll` take the host's "now" as a `HostStamp` and hand it to observers only. An input registered
///   without `sensing:` ignores it and cannot report a loss. A stamp is not read, reordered or clamped here.
/// - A call that is refused as a whole changes nothing. A per-event refusal (the registry's or the ledger's) is
///   reported in `rejections` and the feed continues.
/// - A loss leaves the registry source alone: its held notes stay there, so a later Note Off for a released key is
///   refused by the ledger as `.unownedNote`. `resetSource` clears them.
/// - The session owns its ledger, separate from the one `MIDIClipHost` owns.
///
/// A release costs O(n^2) in the held notes (`MIDINoteLedger`): call the session from the control side, not from a
/// realtime thread.
struct MIDIInputSession: Sendable {
    /// Readable outside the type, not mutable: no caller can detach or reset half of the pair.
    private(set) var registry: MIDISourceRegistry
    /// Readable outside the type, not mutable: only the session's own triggers release notes.
    private(set) var ledger: MIDINoteLedger
    private var slots: [Slot] = []

    /// One input, ascending by input and in lock-step with the registry. The observer exists when the input was
    /// registered with a sensing policy.
    private struct Slot: Sendable {
        let input: MIDIInputID
        var observer: ActiveSensingObserver?
    }

    /// What the observer pass of one feed leaves: the observer after the bytes, committed only once the registry has
    /// taken them, and the first loss the bytes reported.
    private struct SensingPass: Sendable {
        let observer: ActiveSensingObserver?
        let loss: ActiveSensingOutcome?
    }

    /// The three result lists while a call builds them.
    private struct Draft: Sendable {
        var outputs: [MIDIRoutedOutput] = []
        var notices: [MIDIInputSessionNotice] = []
        var rejections: [MIDIInputSessionRejection] = []

        var result: MIDIInputSessionResult {
            MIDIInputSessionResult(outputs: outputs, notices: notices, rejections: rejections)
        }
    }

    /// Ascending by input; only inputs registered with a sensing policy. A copy: it cannot be polled from outside.
    var observers: [ActiveSensingObserver] { slots.compactMap(\.observer) }

    /// Nil for an unknown input and for one registered without a sensing policy.
    func observer(of input: MIDIInputID) -> ActiveSensingObserver? {
        slots.first { $0.input == input }?.observer
    }

    /// Refuses limits outside the registry's bounds as `.source(.invalidConfiguration)`, the source limit first. The
    /// ledger policy is valid by construction, so `make` adds no refusal of its own.
    static func make(
        maximumSources: Int = MIDISourceRegistry.defaultMaximumSources,
        maximumFeedBytes: Int = MIDISourceRegistry.defaultMaximumFeedBytes,
        ledgerPolicy: MIDINoteLedgerPolicy = .standard
    ) throws(MIDIInputSessionRefusal) -> MIDIInputSession {
        do throws(MIDISourceRefusal) {
            let registry = try MIDISourceRegistry.make(
                maximumSources: maximumSources, maximumFeedBytes: maximumFeedBytes
            )
            return MIDIInputSession(registry: registry, ledger: MIDINoteLedger(policy: ledgerPolicy))
        } catch {
            throw .source(error)
        }
    }

    /// The registry decides first, so a refusal (`.duplicateInput`, `.ambiguousEndpoint`, `.registryFull`) leaves no
    /// slot and no observer. A sensing policy gives the input a fresh, unarmed observer.
    mutating func register(
        _ input: MIDIInputID, key: MIDIEndpointKey, profile: MIDISourceProfile = .standard,
        sensing: ActiveSensingPolicy? = nil
    ) throws(MIDIInputSessionRefusal) {
        do throws(MIDISourceRefusal) {
            try registry.register(input, key: key, profile: profile)
        } catch {
            throw .source(error)
        }
        let observer = sensing.map { ActiveSensingObserver(input: input, policy: $0) }
        let position = slots.firstIndex { $0.input > input } ?? slots.endIndex
        slots.insert(Slot(input: input, observer: observer), at: position)
    }

    /// Releases the input's notes on the routes they started on (key-ups in arrival order, then its pedal), drops its
    /// source and its observer, and returns the release. It takes no routing: a release goes where each note began.
    mutating func detach(_ input: MIDIInputID) throws(MIDIInputSessionRefusal) -> [MIDIRoutedOutput] {
        let index = try requireSlot(input)
        do throws(MIDISourceRefusal) {
            _ = try registry.detach(input)
        } catch {
            throw .source(error)
        }
        slots.remove(at: index)
        return ledger.inputLost(input)
    }

    /// Releases the input's notes as `detach` does and starts its source fresh. The source stays registered and its
    /// observer is untouched: clearing state is not a connection event, so an armed deadline keeps running.
    mutating func resetSource(_ input: MIDIInputID) throws(MIDIInputSessionRefusal) -> [MIDIRoutedOutput] {
        do throws(MIDISourceRefusal) {
            _ = try registry.resetSource(input)
        } catch {
            throw .source(error)
        }
        return ledger.inputLost(input)
    }

    /// Feeds one packet from `input`. Three refusals are decided before anything changes, in this order: an unknown
    /// input, a packet above the registry's feed limit, and an observer refusal of `stamp`. Then the registry takes
    /// the bytes, the observer is committed, a loss releases the input's notes (before the packet's own notes), and
    /// the registry's events are routed in order; a System Reset under the opt-in profile releases at its own place.
    ///
    /// Each byte goes through the input's observer at `stamp`, because framing hides a System Exclusive message until
    /// its end. An empty packet observes nothing, so a stamp cannot refuse it.
    mutating func feed(
        _ bytes: [UInt8], from input: MIDIInputID, at stamp: HostStamp, routing: MIDIRouting
    ) throws(MIDIInputSessionRefusal) -> MIDIInputSessionResult {
        let index = try requireSlot(input)
        guard bytes.count <= registry.maximumFeedBytes else {
            throw .source(.feedTooLarge(count: bytes.count, limit: registry.maximumFeedBytes))
        }
        let pass = try observe(bytes, at: stamp, through: slots[index])
        let events: [MIDISourceOutput]
        do throws(MIDISourceRefusal) {
            events = try registry.feed(bytes, from: input)
        } catch {
            throw .source(error)
        }
        slots[index].observer = pass.observer
        var draft = Draft()
        if case let .lost(lostInput, request)? = pass.loss {
            settleLoss(of: lostInput, release: request, into: &draft)
        }
        apply(events, routing: routing, into: &draft)
        return draft.result
    }

    /// Gives each observer the host's "now", ascending by input. The lowest input's refusal wins and nothing is
    /// committed; otherwise the observers advance and each loss, ascending, is settled as `feed` settles it. A pulled
    /// cable sends nothing more, so only this call notices it.
    mutating func poll(at stamp: HostStamp) throws(MIDIInputSessionRefusal) -> MIDIInputSessionResult {
        var polled = slots
        var outcomes: [ActiveSensingOutcome] = []
        for index in polled.indices {
            let input = polled[index].input
            do throws(ActiveSensingRefusal) {
                if let outcome = try polled[index].observer?.poll(at: stamp) { outcomes.append(outcome) }
            } catch {
                throw .sensing(input: input, reason: error)
            }
        }
        slots = polled
        var draft = Draft()
        for case let .lost(input, request) in outcomes {
            settleLoss(of: input, release: request, into: &draft)
        }
        return draft.result
    }

    private func requireSlot(_ input: MIDIInputID) throws(MIDIInputSessionRefusal) -> Int {
        guard let index = slots.firstIndex(where: { $0.input == input }) else {
            throw .source(.unknownInput(input))
        }
        return index
    }

    /// Runs the bytes through a copy of the slot's observer, so a refusal leaves the real one as it was; the first
    /// refusal wins. All bytes of a packet share its stamp, so a loss can fire at the first byte only.
    private func observe(
        _ bytes: [UInt8], at stamp: HostStamp, through slot: Slot
    ) throws(MIDIInputSessionRefusal) -> SensingPass {
        guard var observer = slot.observer else { return SensingPass(observer: nil, loss: nil) }
        var loss: ActiveSensingOutcome?
        do throws(ActiveSensingRefusal) {
            for byte in bytes {
                let outcome = try observer.observe(byte: byte, at: stamp)
                if loss == nil, case .lost = outcome { loss = outcome }
            }
        } catch {
            throw .sensing(input: slot.input, reason: error)
        }
        return SensingPass(observer: observer, loss: loss)
    }

    /// A loss under `.requestInputLost` releases the input's notes; under `.reportOnly` it only says so. The registry
    /// source stays as it is.
    private mutating func settleLoss(of input: MIDIInputID, release: Bool, into draft: inout Draft) {
        guard release else {
            draft.notices.append(.sensingLostReported(input))
            return
        }
        draft.outputs.append(contentsOf: ledger.inputLost(input))
        draft.notices.append(.sensingLostReleased(input))
    }

    /// Routes the registry's events in order. Refusals are logged and the loop goes on: the registry has taken the
    /// bytes already, so a live stream cannot be undone event by event.
    private mutating func apply(_ events: [MIDISourceOutput], routing: MIDIRouting, into draft: inout Draft) {
        for event in events {
            switch event.outcome {
            case .systemReset:
                draft.outputs.append(contentsOf: ledger.inputLost(event.input))
                draft.notices.append(.systemReset(event.input))
            case let .refused(refusal):
                draft.rejections.append(.state(refusal))
            case .applied:
                routeEvent(event, routing: routing, into: &draft)
            }
        }
    }

    /// Real-time, system and System Exclusive events carry no performance event and are skipped.
    private mutating func routeEvent(_ event: MIDISourceOutput, routing: MIDIRouting, into draft: inout Draft) {
        guard let performance = event.performanceEvent else { return }
        do throws(MIDIPerformanceRefusal) {
            try ledger.route(performance, routing: routing, into: &draft.outputs)
        } catch {
            draft.rejections.append(.ledger(error))
        }
    }
}
