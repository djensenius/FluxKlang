import Foundation
import Observation

extension AppModel {
    func configureAssistantMixer() {
        assistantChat.mixerExecutor = AssistantMixerExecutor(
            controller: { [weak self] in self?.wing },
            layout: { [weak self] in
                guard let self else { return FaderLayout() }
                return self.faderLayout.layout.includingStudioAllocations(self.studioResourcePlan().allocations)
            }
        )
    }
}

/// The only conversational hardware boundary. Model output, retry and history
/// never enter this executor. One SET maximum; failed confirmation never retries.
@MainActor
final class AssistantMixerExecutor: AssistantMixerExecuting {
    private let controller: @MainActor () -> WingController?
    private let layout: @MainActor () -> FaderLayout
    private let timeout: Duration
    private var busy = false

    init(
        controller: @escaping @MainActor () -> WingController?,
        layout: @escaping @MainActor () -> FaderLayout,
        timeout: Duration = .milliseconds(750)
    ) {
        self.controller = controller
        self.layout = layout
        self.timeout = timeout
    }

    func execute(_ command: AssistantMixerCommand) async -> String {
        await execute(command, sessionID: controller()?.sessionID)
    }

    // Keep the per-suspension session checks visible in one linear audit trail.
    // swiftlint:disable:next cyclomatic_complexity
    func execute(_ command: AssistantMixerCommand, sessionID expectedSession: UUID?) async -> String {
        guard !busy else { return "No changes: another mixer command is being checked." }
        busy = true
        defer { busy = false }
        guard !Task.isCancelled, let wing = controller(), !wing.isDemo,
            wing.connection.isConnected, let session = wing.sessionID, session == expectedSession
        else {
            return "No changes: connect to a real WING with a current confirmed session first (not Demo Mode)."
        }
        let originalLayout = layout().strips
        func current() -> Bool {
            !Task.isCancelled && controller() === wing && wing.sessionID == session
                && wing.connection.isConnected && layout().strips == originalLayout
        }
        let evidenceDeadline = ContinuousClock.now.advanced(by: timeout)
        var names: [Int: String] = [:]
        if case .liveName = command.target {
            let addresses = (1...40).map { WingAddress.name(.channel, $0) }
            guard let fresh = await wing.readFreshConfirmed(addresses, session: session, timeout: timeout), current()
            else {
                return "No changes: could not freshly confirm all channel names in the same WING session."
            }
            names = Dictionary(
                uniqueKeysWithValues: (1...40).compactMap { index in
                    fresh[WingAddress.name(.channel, index)]?.stringValue.map { (index, $0) }
                })
            guard names.count == 40 else { return "No changes: channel name replies were incomplete." }
        }
        let node: WingNodeRef
        switch AssistantMixerTargetResolver.resolve(
            command.target, names: names, layout: FaderLayout(strips: originalLayout)) {
        case .clarification(let text): return text
        case .node(let resolved): node = resolved
        }
        let nameAddress = WingAddress.name(node.kind, node.index)
        let isMute: Bool
        if case .mute = command.operation { isMute = true } else { isMute = false }
        let valueAddress = isMute ? WingAddress.mute(node.kind, node.index) : WingAddress.fader(node.kind, node.index)
        guard
            let baseline = await wing.readFreshConfirmed(
                [nameAddress, valueAddress], session: session, timeout: timeout),
            current(), let targetName = baseline[nameAddress]?.stringValue
        else {
            return "No changes: no fresh target identity and baseline reply in the current WING session."
        }
        if case .liveName(let requested) = command.target {
            // Recheck the whole uniqueness set after suspension, not only the selected strip.
            let snapshot = wing.confirmedSnapshot()
            let latest = Dictionary(
                uniqueKeysWithValues: (1...40).compactMap { index in
                    snapshot.freshValue(WingAddress.name(.channel, index))?.stringValue.map { (index, $0) }
                })
            guard AssistantLiveWingContext.normalize(targetName) == AssistantLiveWingContext.normalize(requested),
                AssistantMixerTargetResolver.resolve(
                    command.target, names: latest,
                    layout: FaderLayout(strips: originalLayout)) == .node(node), latest.count == 40
            else {
                return "No changes: the target name or uniqueness changed during the fresh read."
            }
        }
        if case .adjustDB = command.operation, let position = baseline[valueAddress]?.floatValue,
           FaderMath.isOff(position: position) {
            return "No changes: this fader is off (−∞), not a finite dB baseline. Set an explicit absolute level first."
        }
        guard let expected = Self.expectedValue(for: command.operation, baseline: baseline[valueAddress]) else {
            return "No changes: invalid fresh baseline or resulting level outside -90...+10 dB. "
                + "Relative changes are rejected, not clamped."
        }
        guard current() else {
            return "No changes: the controller, session or layout changed, or the request was cancelled."
        }
        let authorization = WingMixerWriteAuthorization(deadline: evidenceDeadline)
        defer { authorization.invalidate() }
        let authorized = withObservationTracking {
            _ = wing.confirmedNameRevision
            return current()
        } onChange: { authorization.invalidate() }
        guard authorized else { return "No changes: the target changed before authorization." }
        let sent = await withTaskCancellationHandler {
            await wing.setConfirmedMixerValue(node, value: expected, muted: isMute,
                                             session: session, authorization: authorization)
        } onCancel: { authorization.invalidate() }
        // UDP send failure does not prove that the console did not act.
        guard sent else {
            return "Mixer send failed or was cancelled; the hardware outcome is unconfirmed. No retry was attempted."
        }
        guard current(),
            let confirmed = await wing.readFreshConfirmed(
                [nameAddress, valueAddress], session: session, timeout: timeout),
            current(), confirmed[nameAddress]?.stringValue == targetName
        else {
            return
                "Mixer command was sent once, but its outcome could not be confirmed "
                + "(session, target, cancellation or timeout). Check the console; no retry or rollback was attempted."
        }
        return Self.confirmedOutcome(node: node, expected: expected,
                                     actual: confirmed[valueAddress], isMute: isMute)
    }

    private static func confirmedOutcome(node: WingNodeRef, expected: WingValue,
                                         actual: WingValue?, isMute: Bool) -> String {
        let matches: Bool
        if isMute {
            matches = actual?.intValue == expected.intValue
        } else if let actual = actual?.floatValue, let desired = expected.floatValue {
            matches = actual.isFinite && (0...1).contains(actual)
                && FaderMath.isOff(position: actual) == FaderMath.isOff(position: desired)
                && abs(actual - desired) <= 0.001
        } else {
            matches = false
        }
        guard matches else {
            return
                "Mixer command was sent once, but the console readback differs. "
                + "Check the console; no retry was attempted."
        }
        let action: String
        if isMute {
            action = expected.intValue == 1 ? "muted" : "unmuted"
        } else {
            let position = expected.floatValue!
            action = FaderMath.isOff(position: position) ? "off (−∞ dB; minimum fader position)"
                : String(format: "%.1f dB", FaderMath.decibels(fromPosition: position))
        }
        return
            "Confirmed WING \(node.defaultLabel): \(action) from a fresh readback. "
            + "This is not a hardware lock; another operator can change it."
    }

    static func expectedValue(for operation: AssistantMixerCommand.Operation, baseline: WingValue?) -> WingValue? {
        switch operation {
        case .mute(let muted):
            guard let previous = baseline?.intValue, previous == 0 || previous == 1 else { return nil }
            return .int(muted ? 1 : 0)
        case .setDB(let amount), .adjustDB(let amount):
            guard let position = baseline?.floatValue, position.isFinite, (0...1).contains(position), amount.isFinite
            else { return nil }
            let decibels: Float
            if case .adjustDB = operation {
                guard !FaderMath.isOff(position: position) else { return nil }
                decibels = FaderMath.decibels(fromPosition: position) + amount
            } else { decibels = amount }
            guard decibels.isFinite, (-90...10).contains(decibels) else { return nil }
            return .float(FaderMath.position(fromDecibels: decibels))
        }
    }

}
