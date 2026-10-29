import Foundation

/// Incoming-only evidence. A socket being open, cached UI values and local SETs
/// are deliberately not evidence that a console replied in this session.
struct WingConfirmedSnapshot: Sendable {
    enum Status: String, Sendable { case disconnected, refreshing, observed, stale, demo }
    static let maximumAge: TimeInterval = 30
    var status: Status
    var sessionID: UUID?
    var capturedAt: Date
    var values: [String: WingValue]
    var receivedAt: [String: Date]

    func freshValue(_ address: String) -> WingValue? {
        guard status == .observed, let date = receivedAt[address],
            capturedAt.timeIntervalSince(date) >= 0,
            capturedAt.timeIntervalSince(date) <= Self.maximumAge
        else { return nil }
        return values[address]
    }
}
