/// What one enumeration means for the connected sources (#81): which to disconnect, which to connect, and which
/// matched sources cannot be told apart. Ambiguous and identity-unavailable sources are reported and still connected;
/// refusing them needs a way for a person to resolve them, which does not exist yet.
struct CoreMIDIEndpointReconciliation: Sendable, Equatable {
    /// Matched sources whose identity evidence is equal, so their fingerprint cannot tell them apart.
    struct AmbiguousGroup: Sendable, Hashable {
        let fingerprint: UInt64
        /// Two or more, in enumeration order.
        let refs: [UInt32]
    }

    /// The sources that pass the name filter and are not explicitly offline, in enumeration order.
    let matched: [CoreMIDIEndpointRecord]
    /// Connected refs that are no longer matched, ascending.
    let toDisconnect: [UInt32]
    /// Matched sources that are not connected, in enumeration order.
    let toConnect: [CoreMIDIEndpointRecord]
    /// Ordered by the enumeration position of each group's first source.
    let ambiguous: [AmbiguousGroup]
    /// Matched refs without a uniqueID, in enumeration order. Never grouped: without it nothing tells such units apart.
    let identityUnavailable: [UInt32]
}

/// Decides, without calling CoreMIDI, which sources the Launch Control XL input connects.
struct CoreMIDIEndpointReconciler: Sendable {
    /// A source matches when its display name contains any of these, ignoring case.
    let sourceNameContains: [String]

    /// The surface's DAW and HUI ports never match, even when they contain a wanted name.
    func matches(_ displayName: String) -> Bool {
        !displayName.localizedCaseInsensitiveContains("DAW")
            && !displayName.localizedCaseInsensitiveContains("HUI")
            && sourceNameContains.contains(where: { displayName.localizedCaseInsensitiveContains($0) })
    }

    func reconcile(_ records: [CoreMIDIEndpointRecord], connected: Set<UInt32>) -> CoreMIDIEndpointReconciliation {
        let matched = records.filter { $0.isOffline != true && matches($0.displayName) }
        let matchedRefs = Set(matched.map(\.ref))
        var groups: [(fingerprint: UInt64, refs: [UInt32])] = []
        var groupIndex: [UInt64: Int] = [:]
        var identityUnavailable: [UInt32] = []
        for record in matched {
            guard record.uniqueID != nil else {
                identityUnavailable.append(record.ref)
                continue
            }
            let fingerprint = record.fingerprint
            if let index = groupIndex[fingerprint] {
                groups[index].refs.append(record.ref)
            } else {
                groupIndex[fingerprint] = groups.count
                groups.append((fingerprint, [record.ref]))
            }
        }
        return CoreMIDIEndpointReconciliation(
            matched: matched,
            toDisconnect: connected.filter { !matchedRefs.contains($0) }.sorted(),
            toConnect: matched.filter { !connected.contains($0.ref) },
            ambiguous: groups.filter { $0.refs.count > 1 }.map {
                CoreMIDIEndpointReconciliation.AmbiguousGroup(fingerprint: $0.fingerprint, refs: $0.refs)
            },
            identityUnavailable: identityUnavailable
        )
    }
}
