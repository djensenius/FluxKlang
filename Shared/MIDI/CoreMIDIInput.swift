//
//  CoreMIDIInput.swift
//  FluxKlang
//

@preconcurrency import CoreMIDI
import Foundation

@MainActor
final class CoreMIDIInput: LaunchControlXLInput {
    private var client = MIDIClientRef()
    private var inputPort = MIDIPortRef()
    /// The connected sources and their tokens; a fresh value, whose first token is 1, for every start.
    private var bindings = CoreMIDIEndpointBindings()
    private var sourceNameContains: [String] = []
    /// One reusable consumer task, created before any connection; suspends while inactive.
    private let delivery = MIDICallbackDelivery()
    private var onSourcesChanged: (([MIDIConnectedSource]) -> Void)?
    private let auditMirror: ProductionAccessAudit?
    /// What the last enumeration decided, before CoreMIDI accepted or refused each connection; nil until the first
    /// one and after `stop()` (#81).
    private(set) var lastReconciliation: CoreMIDIEndpointReconciliation?

    init(mirroring audit: ProductionAccessAudit? = nil) {
        auditMirror = audit
        ProductionAccessAudit.shared.record(.passiveConstruction, for: .midiInput, mirroring: audit)
    }

    func start(
        sourceNameContains: [String],
        onPackets: @escaping @MainActor (MIDIPacketBatch) -> Void,
        onSourcesChanged: @escaping ([MIDIConnectedSource]) -> Void
    ) {
        start(
            backend: .legacyBytes, sourceNameContains: sourceNameContains,
            onPackets: onPackets, onSourcesChanged: onSourcesChanged
        )
    }

    func start(
        backend: LaunchControlXLInputBackend,
        sourceNameContains: [String],
        onPackets: @escaping @MainActor (MIDIPacketBatch) -> Void,
        onSourcesChanged: @escaping ([MIDIConnectedSource]) -> Void
    ) {
        ProductionAccessAudit.shared.record(.attempted, for: .midiInput, mirroring: auditMirror)
        guard !AppPersistence.isTesting else {
            ProductionAccessAudit.shared.record(.denied, for: .midiInput, mirroring: auditMirror)
            return
        }
        stop()
        guard let ingress = try? MIDICallbackIngress(format: backend.format) else { return }
        self.sourceNameContains = sourceNameContains
        self.onSourcesChanged = onSourcesChanged

        ProductionAccessAudit.shared.record(.apiEntered, for: .midiInput, mirroring: auditMirror)
        guard MIDIClientCreateWithBlock(
            "FluxKlang Launch Control XL" as CFString,
            &client,
            { @Sendable _ in ingress.sourcesChanged() }
        ) == noErr else {
            return
        }
        ProductionAccessAudit.shared.record(.apiEntered, for: .midiInput, mirroring: auditMirror)
        guard createPort(backend: backend, ingress: ingress) == noErr else {
            ingress.close()
            ProductionAccessAudit.shared.record(.apiEntered, for: .midiInput, mirroring: auditMirror)
            MIDIClientDispose(client)
            client = MIDIClientRef()
            return
        }
        delivery.start(ingress, reconcile: { [weak self] in self?.reconnectSources() }, handler: onPackets)
        reconnectSources()
    }

    /// Called only after start's isolation gate and API-entry audit.
    private func createPort(backend: LaunchControlXLInputBackend, ingress: MIDICallbackIngress) -> OSStatus {
        if backend == .experimentalMIDI1UMP {
            return MIDIInputPortCreateWithProtocol(
                client, "FluxKlang Launch Control XL Input" as CFString, ._1_0, &inputPort,
                { @Sendable eventList, refCon in
                    var cursor = CoreMIDIEventPacketCursor(UnsafeRawPointer(eventList))
                    ingress.receive(&cursor, rawToken: UInt(bitPattern: refCon))
                }
            )
        }
        return MIDIInputPortCreateWithBlock(
            client,
            "FluxKlang Launch Control XL Input" as CFString,
            &inputPort,
            // Strong session ownership survives stop/dispose. No borrowed pointers escape this call.
            { @Sendable packetList, refCon in
                var cursor = CoreMIDIPacketCursor(packetList)
                ingress.receive(&cursor, rawToken: UInt(bitPattern: refCon))
            }
        )
    }

    func stop() {
        delivery.stop()
        if inputPort != 0 || client != 0 {
            ProductionAccessAudit.shared.record(.attempted, for: .midiInput, mirroring: auditMirror)
            guard !AppPersistence.isTesting else {
                ProductionAccessAudit.shared.record(.denied, for: .midiInput, mirroring: auditMirror)
                return
            }
        }
        for binding in bindings.bindings where inputPort != 0 {
            ProductionAccessAudit.shared.record(.apiEntered, for: .midiInput, mirroring: auditMirror)
            MIDIPortDisconnectSource(inputPort, binding.ref)
        }
        bindings = CoreMIDIEndpointBindings()
        lastReconciliation = nil
        if inputPort != 0 {
            ProductionAccessAudit.shared.record(.apiEntered, for: .midiInput, mirroring: auditMirror)
            MIDIPortDispose(inputPort)
            inputPort = MIDIPortRef()
        }
        if client != 0 {
            ProductionAccessAudit.shared.record(.apiEntered, for: .midiInput, mirroring: auditMirror)
            MIDIClientDispose(client)
            client = MIDIClientRef()
        }
        let report = onSourcesChanged
        onSourcesChanged = nil
        report?([])
    }

    private func reconnectSources() {
        guard inputPort != 0 else { return }
        ProductionAccessAudit.shared.record(.attempted, for: .midiInput, mirroring: auditMirror)
        guard !AppPersistence.isTesting else {
            ProductionAccessAudit.shared.record(.denied, for: .midiInput, mirroring: auditMirror)
            return
        }
        let records = LiveCoreMIDIEndpointDirectory(auditMirror: auditMirror).sources()
        let reconciliation = CoreMIDIEndpointReconciler(sourceNameContains: sourceNameContains)
            .reconcile(records, connected: bindings.connectedRefs)
        lastReconciliation = reconciliation
        let update = bindings.update(with: reconciliation)
        // Every detach before any connect: a rekeyed ref is disconnected and connected again with its new token.
        for binding in update.detaches {
            ProductionAccessAudit.shared.record(.apiEntered, for: .midiInput, mirroring: auditMirror)
            MIDIPortDisconnectSource(inputPort, binding.ref)
        }
        bindings = update.bindings
        for binding in update.registrations {
            ProductionAccessAudit.shared.record(.apiEntered, for: .midiInput, mirroring: auditMirror)
            if MIDIPortConnectSource(inputPort, binding.ref, binding.source.token.refCon) != noErr {
                bindings.remove(binding.ref)
            }
        }
        // Sorted by name, as the status always listed them.
        onSourcesChanged?(bindings.sources.sorted { $0.name < $1.name })
    }

}
