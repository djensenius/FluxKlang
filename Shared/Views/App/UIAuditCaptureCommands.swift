#if DEBUG && os(iOS)
import SwiftUI

/// The only app entry: no injectable context/audit and no AppModel access.
@MainActor
final class UIAuditCaptureService {
    static let shared = UIAuditCaptureService()

    private let state: UIAuditCaptureState
    private let windows: UIAuditCaptureWindows

    private init?() {
        guard let state = UIAuditCaptureState(
            context: Self.currentContext(), audit: ProductionAccessAudit.shared
        ) else { return nil }
        self.state = state
        self.windows = UIAuditCaptureWindows()
    }

    private static func currentContext() -> UIAuditCaptureState.Context {
        let process = ProcessInfo.processInfo
        return UIAuditCaptureState.Context(
            isDebug: true, isIOS: true, arguments: process.arguments,
            environment: process.environment, selectedTesting: AppPersistence.isTesting,
            pid: process.processIdentifier
        )
    }

    var isEligible: Bool {
        guard state.validate(Self.currentContext()) else {
            windows.publish(nil)
            windows.removeAll()
            return false
        }
        return true
    }

    func capture() {
        state.capture(Self.currentContext())
        windows.publish(state.publication)
        // Terminal exhaustion also removes output ownership; this never captures.
        _ = isEligible
    }

    func reconcile(_ host: UIAuditCaptureHostView) {
        guard isEligible else { return }
        windows.publish(state.publication)
        windows.reconcile(host)
    }

    func detach(bridgeID: UUID, lease: UIAuditCaptureLease?) {
        windows.detach(bridgeID: bridgeID, lease: lease)
    }
}

@MainActor
struct UIAuditCaptureCommands: Commands {
    var body: some Commands {
        if let service = UIAuditCaptureService.shared, service.isEligible {
            CommandMenu("Isolation audit") {
                Button("Capture audit") {
                    service.capture()
                }
                .keyboardShortcut("u", modifiers: [.control, .option, .shift, .command])
            }
        }
    }
}
#endif
