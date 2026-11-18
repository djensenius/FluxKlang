/// Which connection, token and endpoint key each matched CoreMIDI source has (#81, slice D2). Pure: it never calls
/// CoreMIDI. `CoreMIDIInput` applies an update by disconnecting every detach, then connecting every registration with
/// its token as refCon, and reports `sources` to the controller.
///
/// A source with a usable identity gets its own `MIDIEndpointKey(fingerprint:)`. One whose identity is unavailable,
/// one in an ambiguous group and one whose fingerprint is 0 is unresolved (`endpoint` nil): it shares the stream's
/// legacy source, keyed by fingerprint 0, until a later slice lets a person choose an ordinal. Nothing here assigns
/// an ordinal.
struct CoreMIDIEndpointBindings: Sendable, Equatable {
    /// One connected source and the endpoint ref it is connected through.
    struct Binding: Sendable, Equatable {
        let ref: UInt32
        let source: MIDIConnectedSource
        /// The mapped `kMIDIPropertyProtocolID` of the enumeration that registered or last kept this binding. Evidence
        /// only: not identity or eligibility, and not the protocol the input port receives (see `receiveFidelity`).
        let endpointProtocol: MIDIEndpointProtocol
    }

    /// One binding's derived receive fidelity, with the ref and token it belongs to.
    struct ReceiveFidelity: Sendable, Equatable {
        let ref: UInt32
        let token: MIDIConnectionToken
        let fidelity: CoreMIDIReceiveFidelity
    }

    /// A kept binding whose mapped endpoint protocol changed. Reported only: its token and key stay, because the input
    /// port's protocol is fixed for the start, and nothing records a `formatChange` for it yet.
    struct ProtocolChange: Sendable, Equatable {
        let ref: UInt32
        let token: MIDIConnectionToken
        let from: MIDIEndpointProtocol
        let to: MIDIEndpointProtocol
    }

    /// One enumeration's changes. Detaches come first, so a unit replugged under a new ref, or rekeyed on the same
    /// ref, is gone before its new binding registers and never meets itself as an ambiguous endpoint.
    struct Update: Sendable, Equatable {
        /// To disconnect: refs that stopped matching (ascending by ref), then refs whose endpoint key changed (in
        /// enumeration order).
        let detaches: [Binding]
        /// To connect, each with a fresh token, in enumeration order.
        let registrations: [Binding]
        /// The bindings once every detach and registration is applied.
        let bindings: CoreMIDIEndpointBindings
        /// Kept bindings, in enumeration order, whose mapped endpoint protocol changed. Never a registration or a
        /// rekey; raw values that map alike, such as 0 and an unreadable property, are no change.
        let protocolChanges: [ProtocolChange]
    }

    /// In the enumeration order of the last update.
    private(set) var bindings: [Binding] = []
    /// The last token minted in this start; 0 before the first.
    private var lastToken: UInt

    /// `lastToken` is a test seam for exhausting the counter; every start begins at 0, so its first token is 1.
    init(lastToken: UInt = 0) {
        self.lastToken = lastToken
    }

    var connectedRefs: Set<UInt32> { Set(bindings.map(\.ref)) }

    var sources: [MIDIConnectedSource] { bindings.map(\.source) }

    /// Each binding's receive fidelity through an input backend delivering `format`, in enumeration order. Derived
    /// from the last mapped endpoint protocol; nothing consumes it yet.
    func receiveFidelity(format: MIDIPacketBatch.Format) -> [ReceiveFidelity] {
        bindings.map { binding in
            ReceiveFidelity(
                ref: binding.ref, token: binding.source.token,
                fidelity: CoreMIDIReceiveFidelity(endpoint: binding.endpointProtocol, format: format)
            )
        }
    }

    /// The key a matched source is registered under, or nil when it is unresolved. `fingerprint` is nil when the
    /// source has no uniqueID. Fingerprint 0 is the legacy source's key, so a real fingerprint of 0 shares it.
    static func endpointKey(fingerprint: UInt64?, isAmbiguous: Bool) -> MIDIEndpointKey? {
        guard let fingerprint, fingerprint != 0, !isAmbiguous else { return nil }
        return MIDIEndpointKey(fingerprint: fingerprint)
    }

    /// Compares fingerprints itself, because the reconciler compares refs only: a changed key on a connected ref is a
    /// detach and a registration, never carried state. A renamed source keeps its token. When the counter cannot
    /// mint another token, the source is left unconnected rather than wrapping, and the next enumeration tries again.
    /// A changed endpoint protocol on a kept binding is reported and keeps its token.
    func update(with reconciliation: CoreMIDIEndpointReconciliation) -> Update {
        let matchedRefs = Set(reconciliation.matched.map(\.ref))
        let ambiguousRefs = Set(reconciliation.ambiguous.flatMap(\.refs))
        let current = Dictionary(bindings.map { ($0.ref, $0) }, uniquingKeysWith: { first, _ in first })
        var detaches = bindings.filter { !matchedRefs.contains($0.ref) }.sorted { $0.ref < $1.ref }
        var registrations: [Binding] = []
        var protocolChanges: [ProtocolChange] = []
        var next = CoreMIDIEndpointBindings(lastToken: lastToken)
        for record in reconciliation.matched {
            let key = Self.endpointKey(
                fingerprint: record.uniqueID == nil ? nil : record.fingerprint,
                isAmbiguous: ambiguousRefs.contains(record.ref)
            )
            let endpointProtocol = record.endpointProtocol
            if let bound = current[record.ref] {
                if bound.source.endpoint == key {
                    let source = MIDIConnectedSource(token: bound.source.token, endpoint: key, name: record.displayName)
                    next.bindings.append(Binding(ref: record.ref, source: source, endpointProtocol: endpointProtocol))
                    if bound.endpointProtocol != endpointProtocol {
                        protocolChanges.append(ProtocolChange(
                            ref: record.ref, token: source.token, from: bound.endpointProtocol, to: endpointProtocol
                        ))
                    }
                    continue
                }
                detaches.append(bound)
            }
            guard let token = next.mintToken() else { continue }
            let binding = Binding(
                ref: record.ref, source: MIDIConnectedSource(token: token, endpoint: key, name: record.displayName),
                endpointProtocol: endpointProtocol
            )
            registrations.append(binding)
            next.bindings.append(binding)
        }
        return Update(
            detaches: detaches, registrations: registrations, bindings: next, protocolChanges: protocolChanges
        )
    }

    /// Forgets `ref` after CoreMIDI refused to connect it, so the next enumeration tries again with a fresh token.
    mutating func remove(_ ref: UInt32) {
        bindings.removeAll { $0.ref == ref }
    }

    /// Nil once `UInt.max` has been minted: tokens are refused, never wrapped or reused.
    private mutating func mintToken() -> MIDIConnectionToken? {
        guard lastToken < UInt.max, let token = MIDIConnectionToken(rawValue: lastToken + 1) else { return nil }
        lastToken = token.rawValue
        return token
    }
}
