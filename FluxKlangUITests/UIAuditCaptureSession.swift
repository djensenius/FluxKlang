import XCTest

/// Retain within ONE executing test method, across its intentional launches.
/// Supplied environments are not read from or written to the process/application.
@MainActor
final class UIAuditCaptureRun {
    enum Opening {
        case session(UIAuditCaptureSession)
        case refused(UIAuditCaptureState.Refusal)
    }

    private let testCase: XCTestCase
    fileprivate let state = UIAuditCaptureState()
    /// Use the latest aggregate for assertions, not a cached individual session outcome.
    var outcome: UIAuditCaptureState.Outcome { state.outcome }

    init(testCase: XCTestCase) {
        self.testCase = testCase
    }

    func open(
        app: XCUIApplication,
        runnerEnvironment: [String: String],
        appEnvironment: [String: String],
        appArguments: [String]
    ) -> Opening {
        switch state.open(runner: runnerEnvironment, app: appEnvironment, arguments: appArguments) {
        case .refused(let reason, let token):
            emitRejection(token)
            return .refused(reason)
        case .admitted(let launch, let token):
            guard emit(token, phase: .creationIntent), emit(token, phase: .creationOutcome),
                  state.settle(token) else {
                _ = state.settle(token)
                return .refused(.invalidated)
            }
            return .session(UIAuditCaptureSession(run: self, app: app, launch: launch))
        }
    }

    /// Direct XCTest evidence; every SDK boundary has both a before and after guard.
    fileprivate func emit(_ token: UIAuditCaptureState.Token, phase: UIAuditCaptureState.Phase) -> Bool {
        guard let evidence = state.evidence(token, phase: phase),
              state.start(token, phase: phase, boundary: .construct) else { return false }
        let attachment = XCTAttachment(string: evidence.text)
        guard state.returned(token, phase: phase, boundary: .construct),
              state.start(token, phase: phase, boundary: .name) else { return false }
        attachment.name = evidence.name
        guard state.returned(token, phase: phase, boundary: .name),
              state.start(token, phase: phase, boundary: .lifetime) else { return false }
        attachment.lifetime = .keepAlways
        guard state.returned(token, phase: phase, boundary: .lifetime),
              state.start(token, phase: phase, boundary: .add) else { return false }
        testCase.add(attachment)
        return state.returned(token, phase: phase, boundary: .add)
    }

    fileprivate func emitRejection(_ token: UIAuditCaptureState.Token?) {
        guard let token else { return }
        _ = emit(token, phase: .refusal)
        _ = state.settle(token)
    }
}

/// UNUSED SDK consumer. Does not launch, activate, configure, focus or terminate the app.
/// Returning a sampled result acknowledges neither command delivery nor completed coverage.
@MainActor
final class UIAuditCaptureSession {
    enum Sample {
        case sampled
        case refused(UIAuditCaptureState.Refusal)
    }
    enum Finish {
        case outcome(UIAuditCaptureState.Outcome)
        case refused(UIAuditCaptureState.Refusal)
    }

    private let run: UIAuditCaptureRun
    private let app: XCUIApplication
    private let launch: UIAuditCaptureState.Launch
    var configuration: UIAuditRunPreflight.ValidatedLaunchConfiguration { launch.configuration }

    fileprivate init(run: UIAuditCaptureRun, app: XCUIApplication, launch: UIAuditCaptureState.Launch) {
        self.run = run
        self.app = app
        self.launch = launch
    }

    func entry() -> Sample { sample(.entry) }
    func exit() -> Sample { sample(.exit) }

    private func sample(_ slot: UIAuditCaptureState.Slot) -> Sample {
        let state = run.state
        switch state.begin(launch, slot: slot) {
        case .refused(let reason, let token):
            run.emitRejection(token)
            return .refused(reason)
        case .closed:
            return .refused(.closed)
        case .admitted(let token):
            defer { _ = state.settle(token) }
            let pre: UIAuditCaptureState.Position = slot == .entry ? .entryPre : .exitPre
            let post: UIAuditCaptureState.Position = slot == .entry ? .entryPost : .exitPost
            guard observe(pre, token: token) else { return .refused(.invalidated) }
            if let refusal = token.refusal {
                _ = run.emit(token, phase: .refusal)
                return .refused(refusal)
            }
            guard run.emit(token, phase: .commandIntent(slot)),
                  state.start(token, phase: .command(slot), boundary: .command) else {
                return .refused(.invalidated)
            }
            app.typeKey("u", modifierFlags: [.control, .option, .shift, .command])
            guard state.returned(token, phase: .command(slot), boundary: .command),
                  observe(post, token: token) else { return .refused(.invalidated) }
            if let refusal = token.refusal {
                _ = run.emit(token, phase: .refusal)
                return .refused(refusal)
            }
            guard state.permits(token, phase: .done), state.settle(token) else {
                return .refused(.invalidated)
            }
            return .sampled
        }
    }

    private func observe(_ position: UIAuditCaptureState.Position, token: UIAuditCaptureState.Token) -> Bool {
        let state = run.state
        guard run.emit(token, phase: .queryIntent(position)),
              state.start(token, phase: .read(position), boundary: .read) else { return false }
        let observation = UIAuditSnapshotReader().read(in: app)
        guard state.returnedObservation(observation, token: token, position: position),
              run.emit(token, phase: .observation(position, raw: false)) else { return false }
        if case .receipt = observation {
            return run.emit(token, phase: .observation(position, raw: true))
        }
        return true
    }

    func finish() -> Finish {
        let state = run.state
        switch state.finish(launch) {
        case .closed(let outcome):
            return .outcome(outcome)
        case .refused(let reason, let token):
            run.emitRejection(token)
            return .refused(reason)
        case .admitted(let token):
            // Bounded fixed positions only; no reacquisition and no attempted-record retries.
            for position in UIAuditCaptureState.Position.allCases {
                for raw in [false, true] {
                    let phase = UIAuditCaptureState.Phase.observation(position, raw: raw)
                    if state.permits(token, phase: phase), !run.emit(token, phase: phase) {
                        _ = state.settle(token)
                        return .outcome(launch.terminal ?? .failed)
                    }
                }
            }
            _ = run.emit(token, phase: .finish)
            _ = state.settle(token)
            return .outcome(launch.terminal ?? .failed)
        }
    }
}
