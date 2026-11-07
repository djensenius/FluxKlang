/// What the rig wants done when sensing is lost. The observer never performs it; it only carries the choice.
enum ActiveSensingLossAction: Equatable, Sendable {
    /// Report the loss and nothing else. Held notes are never released because of it.
    case reportOnly
    /// Report the loss and flag that the caller should call `MIDINoteLedger.inputLost(_:)` for the input.
    case requestInputLost
}

/// A validated Active Sensing timeout and loss action. There is deliberately no default value of either: the
/// caller chooses both, and a held-note timeout is never implied (#82).
///
/// Build it only through `make(timeoutTicks:lossAction:)`; the initializer is private, so a value outside
/// `1...maximumTimeoutTicks` cannot exist. The observer still re-validates it on every call.
struct ActiveSensingPolicy: Equatable, Sendable {
    /// The largest accepted timeout, 2^48 host ticks.
    static let maximumTimeoutTicks: UInt64 = 1 << 48

    let timeoutTicks: UInt64
    let lossAction: ActiveSensingLossAction

    private init(timeoutTicks: UInt64, lossAction: ActiveSensingLossAction) {
        self.timeoutTicks = timeoutTicks
        self.lossAction = lossAction
    }

    /// Refuses a timeout of 0 or above `maximumTimeoutTicks`.
    static func make(
        timeoutTicks: UInt64,
        lossAction: ActiveSensingLossAction
    ) throws(ActiveSensingRefusal) -> ActiveSensingPolicy {
        let policy = ActiveSensingPolicy(timeoutTicks: timeoutTicks, lossAction: lossAction)
        try policy.validate()
        return policy
    }

    /// The point-of-use check shared by the factory and the observer.
    func validate() throws(ActiveSensingRefusal) {
        guard (1...Self.maximumTimeoutTicks).contains(timeoutTicks) else {
            throw .invalidTimeout(timeoutTicks)
        }
    }
}
