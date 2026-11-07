//
//  RemoteMirror.swift
//  FluxKlang
//
//  The remote controller's mirror of host truth (#96, RR2): the values and revisions a synced
//  `PeerSyncReceiver` holds, paired with the catalog the caller supplies (the sync stream carries no catalog).
//  A mirror has only `let` fields and a private initializer, so it comes only from `make` and is never changed
//  afterwards; after a resync the caller builds a new one.
//

struct RemoteMirror: Hashable, Sendable {
    /// The received values and the supplied catalog, ready to resolve bindings against.
    let truth: ControlHostTruth
    /// The revisions of the received state; a proposal's `basis`.
    let revisions: CommandRevisions
    let sequence: PeerSequence
    let session: PeerSyncSession

    private init(truth: ControlHostTruth, revisions: CommandRevisions, sequence: PeerSequence,
                 session: PeerSyncSession) {
        self.truth = truth
        self.revisions = revisions
        self.sequence = sequence
        self.session = session
    }

    /// Checks, first failure wins: the receiver is synced (`mirrorUnavailable`), at most
    /// `ControlHostTruth.maximumValues` values (`tooManyValues`), every received parameter is in the catalog
    /// (`unknownParameter`, the smallest id). Zero values and a catalog entry without a value are legal.
    static func make(receiver: PeerSyncReceiver,
                     catalog: ParameterCatalog) throws(RemoteDispatchRefusal) -> RemoteMirror {
        guard let state = receiver.state else { throw .mirrorUnavailable }
        let truth = try hostTruth(catalog: catalog, values: state.values)
        let known = Set(catalog.parameters.map(\.id))
        if let unknown = state.values.keys.filter({ !known.contains($0) }).min() {
            throw .unknownParameter(unknown)
        }
        return RemoteMirror(truth: truth, revisions: state.revisions, sequence: state.sequence,
                            session: receiver.session)
    }

    private static func hostTruth(
        catalog: ParameterCatalog, values: [ParameterID: ParameterValue]
    ) throws(RemoteDispatchRefusal) -> ControlHostTruth {
        do throws(ControlHostTruthRefusal) {
            return try ControlHostTruth(catalog: catalog, values: values)
        } catch {
            switch error {
            case .tooManyValues(let count): throw .tooManyValues(count)
            }
        }
    }
}
