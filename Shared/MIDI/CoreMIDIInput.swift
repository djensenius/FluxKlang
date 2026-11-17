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
    private var connectedSources: [MIDIEndpointRef: String] = [:]
    private var sourceNameContains: [String] = []
    /// The current start's ordered path to the main actor; cancelled by `stop()`.
    private var delivery: MIDIPacketDelivery?
    private var onSourcesChanged: (([String]) -> Void)?
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
        onSourcesChanged: @escaping ([String]) -> Void
    ) {
        ProductionAccessAudit.shared.record(.attempted, for: .midiInput, mirroring: auditMirror)
        guard !AppPersistence.isTesting else {
            ProductionAccessAudit.shared.record(.denied, for: .midiInput, mirroring: auditMirror)
            return
        }
        stop()
        self.sourceNameContains = sourceNameContains
        self.onSourcesChanged = onSourcesChanged

        ProductionAccessAudit.shared.record(.apiEntered, for: .midiInput, mirroring: auditMirror)
        guard MIDIClientCreateWithBlock(
            "FluxKlang Launch Control XL" as CFString,
            &client,
            { [weak self] _ in
                Task { @MainActor [weak self] in self?.reconnectSources() }
            }
        ) == noErr else {
            return
        }
        ProductionAccessAudit.shared.record(.apiEntered, for: .midiInput, mirroring: auditMirror)
        let delivery = MIDIPacketDelivery(handler: onPackets)
        guard MIDIInputPortCreateWithBlock(
            client,
            "FluxKlang Launch Control XL Input" as CFString,
            &inputPort,
            // Runs on CoreMIDI's read thread: copies the bytes out of the packet list, then only yields.
            { @Sendable packetList, _ in
                let packets = Self.packetBytes(in: packetList)
                guard !packets.isEmpty else { return }
                delivery.yield(packets)
            }
        ) == noErr else {
            delivery.cancel()
            ProductionAccessAudit.shared.record(.apiEntered, for: .midiInput, mirroring: auditMirror)
            MIDIClientDispose(client)
            client = MIDIClientRef()
            return
        }
        self.delivery = delivery
        reconnectSources()
    }

    func stop() {
        delivery?.cancel()
        delivery = nil
        if inputPort != 0 || client != 0 {
            ProductionAccessAudit.shared.record(.attempted, for: .midiInput, mirroring: auditMirror)
            guard !AppPersistence.isTesting else {
                ProductionAccessAudit.shared.record(.denied, for: .midiInput, mirroring: auditMirror)
                return
            }
        }
        for source in connectedSources.keys where inputPort != 0 {
            ProductionAccessAudit.shared.record(.apiEntered, for: .midiInput, mirroring: auditMirror)
            MIDIPortDisconnectSource(inputPort, source)
        }
        connectedSources = [:]
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
        onSourcesChanged?([])
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
            .reconcile(records, connected: Set(connectedSources.keys))
        lastReconciliation = reconciliation
        for source in reconciliation.toDisconnect {
            ProductionAccessAudit.shared.record(.apiEntered, for: .midiInput, mirroring: auditMirror)
            MIDIPortDisconnectSource(inputPort, source)
            connectedSources[source] = nil
        }
        for record in reconciliation.toConnect where connectedSources[record.ref] == nil {
            ProductionAccessAudit.shared.record(.apiEntered, for: .midiInput, mirroring: auditMirror)
            guard MIDIPortConnectSource(inputPort, record.ref, nil) == noErr else { continue }
            connectedSources[record.ref] = record.displayName
        }
        onSourcesChanged?(connectedSources.values.sorted())
    }

    /// The bytes of each non-empty packet, unchanged and in order. Each packet is read in place through CoreMIDI's
    /// sequence API, so its full `length` is kept and the list is walked from the real packets, not a copy.
    nonisolated private static func packetBytes(in packetList: UnsafePointer<MIDIPacketList>) -> [[UInt8]] {
        packetList.unsafeSequence().compactMap { packet in
            let bytes = Array(packet.bytes())
            return bytes.isEmpty ? nil : bytes
        }
    }
}
