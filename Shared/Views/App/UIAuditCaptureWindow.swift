#if DEBUG && os(iOS)
import SwiftUI
import UIKit

/// No capture here: this bridge only identifies its actual hosting scene.
struct UIAuditCaptureRootBridge: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if let service = UIAuditCaptureService.shared, service.isEligible {
            content.background {
                UIAuditCaptureBridge(service: service)
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        } else {
            content
        }
    }
}

private struct UIAuditCaptureBridge: UIViewRepresentable {
    let service: UIAuditCaptureService

    func makeUIView(context: Context) -> UIAuditCaptureHostView {
        UIAuditCaptureHostView(service: service)
    }

    func updateUIView(_ view: UIAuditCaptureHostView, context: Context) {
        view.reconcile()
    }

    static func dismantleUIView(_ view: UIAuditCaptureHostView, coordinator: ()) {
        view.detach()
    }
}

struct UIAuditCaptureLease: Equatable {
    let bridgeID: UUID
    let generation: UUID
    let sceneID: ObjectIdentifier
}

@MainActor
final class UIAuditCaptureHostView: UIView {
    let bridgeID = UUID()
    var lease: UIAuditCaptureLease?
    private weak var service: UIAuditCaptureService?

    init(service: UIAuditCaptureService) {
        self.service = service
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { nil }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        reconcile()
    }

    func reconcile() {
        service?.reconcile(self)
    }

    func detach() {
        service?.detach(bridgeID: bridgeID, lease: lease)
        lease = nil
        service = nil
    }

    isolated deinit {
        service?.detach(bridgeID: bridgeID, lease: lease)
    }
}

/// Process-owned registry. Bridge references are weak; every attachment has its own generation.
@MainActor
final class UIAuditCaptureWindows: NSObject {
    /// Releasing this owner removes observers without retaining the registry or its bridges.
    @MainActor
    private final class Observation: NSObject {
        weak var owner: UIAuditCaptureWindows?

        init(owner: UIAuditCaptureWindows) {
            self.owner = owner
            super.init()
            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(disconnected(_:)),
                               name: UIScene.didDisconnectNotification, object: nil)
            center.addObserver(self, selector: #selector(activated(_:)),
                               name: UIScene.didActivateNotification, object: nil)
        }

        @objc private func disconnected(_ notification: Notification) {
            owner?.disconnected(notification)
        }

        @objc private func activated(_ notification: Notification) {
            owner?.activated(notification)
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }

    @MainActor
    private final class Bridge {
        weak var host: UIAuditCaptureHostView?
        var lease: UIAuditCaptureLease?

        init(_ host: UIAuditCaptureHostView) {
            self.host = host
        }
    }

    @MainActor
    private final class Output {
        let window: UIAuditCaptureOutputWindow
        var leases: [UUID: UIAuditCaptureLease] = [:]

        init(scene: UIWindowScene, value: String?) {
            window = UIAuditCaptureOutputWindow(windowScene: scene)
            window.frame = scene.coordinateSpace.bounds
            window.windowLevel = .init(rawValue: UIWindow.Level.alert.rawValue + 1)
            window.backgroundColor = .clear
            window.isOpaque = false
            let controller = UIViewController()
            let output = UIView(frame: window.bounds)
            output.backgroundColor = .clear
            output.isOpaque = false
            output.isAccessibilityElement = true
            output.accessibilityIdentifier = "fluxklang.audit.capture"
            output.accessibilityLabel = "Isolation audit capture"
            output.accessibilityTraits = .staticText
            output.accessibilityValue = value
            output.accessibilityViewIsModal = false
            controller.view = output
            window.rootViewController = controller
            window.isHidden = false
        }

        func publish(_ value: String?) {
            window.rootViewController?.view.accessibilityValue = value
        }

        func releaseWindow() {
            publish(nil)
            window.isHidden = true
            window.rootViewController = nil
            window.windowScene = nil
        }
    }

    private var bridges: [UUID: Bridge] = [:]
    private var outputs: [ObjectIdentifier: Output] = [:]
    private var publication: String?
    private var observation: Observation?

    func publish(_ value: String?) {
        publication = value
        for output in outputs.values { output.publish(value) }
    }

    func reconcile(_ host: UIAuditCaptureHostView) {
        let bridge: Bridge
        if let existing = bridges[host.bridgeID] {
            bridge = existing
        } else {
            bridge = Bridge(host)
            bridges[host.bridgeID] = bridge
            startObserving()
        }
        let scene = host.window?.windowScene
        if let scene, scene.activationState != .unattached,
           let lease = bridge.lease, lease.sceneID == ObjectIdentifier(scene),
           outputs[lease.sceneID]?.leases[host.bridgeID] == lease {
            return
        }
        release(bridge.lease)
        bridge.lease = nil
        host.lease = nil
        guard let scene, scene.activationState != .unattached else { return }
        let sceneID = ObjectIdentifier(scene)
        let output = outputs[sceneID] ?? Output(scene: scene, value: publication)
        outputs[sceneID] = output
        let lease = UIAuditCaptureLease(bridgeID: host.bridgeID, generation: UUID(), sceneID: sceneID)
        output.leases[host.bridgeID] = lease
        bridge.lease = lease
        host.lease = lease
    }

    /// Obsolete detach cannot release a newer attachment or unregister its bridge.
    func detach(bridgeID: UUID, lease: UIAuditCaptureLease?) {
        guard let bridge = bridges[bridgeID], bridge.lease == lease else { return }
        release(lease)
        bridge.host?.lease = nil
        bridges.removeValue(forKey: bridgeID)
        if bridges.isEmpty { stopObserving() }
    }

    private func release(_ lease: UIAuditCaptureLease?) {
        guard let lease, let output = outputs[lease.sceneID],
              output.leases[lease.bridgeID] == lease else { return }
        output.leases.removeValue(forKey: lease.bridgeID)
        if output.leases.isEmpty {
            output.releaseWindow()
            outputs.removeValue(forKey: lease.sceneID)
        }
    }

    func removeAll() {
        for bridge in bridges.values { bridge.host?.lease = nil }
        for output in outputs.values { output.releaseWindow() }
        outputs.removeAll()
        bridges.removeAll()
        publication = nil
        stopObserving()
    }

    private func startObserving() {
        guard observation == nil else { return }
        observation = Observation(owner: self)
    }

    private func stopObserving() {
        observation = nil
    }

    private func disconnected(_ notification: Notification) {
        guard let scene = notification.object as? UIWindowScene else { return }
        let sceneID = ObjectIdentifier(scene)
        guard let output = outputs.removeValue(forKey: sceneID) else { return }
        for lease in output.leases.values {
            guard let bridge = bridges[lease.bridgeID], bridge.lease == lease else { continue }
            bridge.lease = nil
            bridge.host?.lease = nil
        }
        output.releaseWindow()
    }

    private func activated(_ notification: Notification) {
        guard let scene = notification.object as? UIWindowScene else { return }
        // Snapshot the records because reconciliation can invalidate the entire registry.
        for bridge in Array(bridges.values) {
            if let host = bridge.host, host.window?.windowScene === scene {
                host.reconcile()
            }
        }
    }

    isolated deinit {
        removeAll()
    }
}

/// App-owned ordering only. Keyboard, touch and AX noninterference remain unqualified.
private final class UIAuditCaptureOutputWindow: UIWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeFirstResponder: Bool { false }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
}
#endif
