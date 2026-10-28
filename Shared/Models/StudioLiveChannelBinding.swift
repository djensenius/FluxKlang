import Foundation

/// An inert canvas shortcut to existing channel(s), not Equipment, an audio port or a routing endpoint.
/// Persisted session/label/source fields are display evidence only. A restored binding is always
/// unverified until explicitly reviewed against fresh observations; it never stores authorization.
struct StudioLiveChannelBinding: Identifiable, Codable, Hashable, Sendable {
    struct Member: Codable, Hashable, Sendable {
        let channel: Int
        let label: String
        let sourceGroup: String?
        let sourceIndex: Int?
        let equipmentID: Equipment.ID?
    }

    let id: UUID
    let observedSessionID: UUID
    /// Ordered mono or left/right members. Numeric membership alone cannot authorize a different session.
    let members: [Member]
    let pairStripID: UUID?
    let observedAt: Date

    init(id: UUID = UUID(), observedSessionID: UUID, members: [Member],
         pairStripID: UUID? = nil, observedAt: Date = Date()) {
        self.id = id
        self.observedSessionID = observedSessionID
        self.members = members
        self.pairStripID = pairStripID
        self.observedAt = observedAt
    }
}
