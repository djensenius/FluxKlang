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
    private var onMessages: (([MIDIControlChange]) -> Void)?
    private var onSourcesChanged: (([String]) -> Void)?

    func start(
        sourceNameContains: [String],
        onMessages: @escaping ([MIDIControlChange]) -> Void,
        onSourcesChanged: @escaping ([String]) -> Void
    ) {
        stop()
        self.sourceNameContains = sourceNameContains
        self.onMessages = onMessages
        self.onSourcesChanged = onSourcesChanged

        guard MIDIClientCreateWithBlock(
            "FluxKlang Launch Control XL" as CFString,
            &client,
            { [weak self] _ in
                Task { @MainActor [weak self] in self?.reconnectSources() }
            }
        ) == noErr else {
            return
        }
        guard MIDIInputPortCreateWithBlock(
            client,
            "FluxKlang Launch Control XL Input" as CFString,
            &inputPort,
            { [weak self] packetList, _ in
                let messages = Self.controlChanges(in: packetList)
                guard !messages.isEmpty else { return }
                Task { @MainActor [weak self] in self?.onMessages?(messages) }
            }
        ) == noErr else {
            MIDIClientDispose(client)
            client = MIDIClientRef()
            return
        }
        reconnectSources()
    }

    func stop() {
        for source in connectedSources.keys where inputPort != 0 {
            MIDIPortDisconnectSource(inputPort, source)
        }
        connectedSources = [:]
        if inputPort != 0 {
            MIDIPortDispose(inputPort)
            inputPort = MIDIPortRef()
        }
        if client != 0 {
            MIDIClientDispose(client)
            client = MIDIClientRef()
        }
        onSourcesChanged?([])
    }

    private func reconnectSources() {
        guard inputPort != 0 else { return }
        let available = (0..<MIDIGetNumberOfSources()).compactMap { index -> (MIDIEndpointRef, String)? in
            let source = MIDIGetSource(index)
            let name = Self.displayName(of: source)
            guard !name.localizedCaseInsensitiveContains("DAW"),
                  !name.localizedCaseInsensitiveContains("HUI"),
                  sourceNameContains.contains(where: {
                name.localizedCaseInsensitiveContains($0)
            }) else {
                return nil
            }
            return (source, name)
        }
        let availableIDs = Set(available.map(\.0))
        for source in connectedSources.keys where !availableIDs.contains(source) {
            MIDIPortDisconnectSource(inputPort, source)
            connectedSources[source] = nil
        }
        for (source, name) in available where connectedSources[source] == nil {
            guard MIDIPortConnectSource(inputPort, source, nil) == noErr else { continue }
            connectedSources[source] = name
        }
        onSourcesChanged?(connectedSources.values.sorted())
    }

    nonisolated private static func displayName(of object: MIDIObjectRef) -> String {
        var value: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(object, kMIDIPropertyDisplayName, &value) == noErr else {
            return "Unknown MIDI source"
        }
        return value?.takeRetainedValue() as String? ?? "Unknown MIDI source"
    }

    nonisolated private static func controlChanges(
        in packetList: UnsafePointer<MIDIPacketList>
    ) -> [MIDIControlChange] {
        var messages: [MIDIControlChange] = []
        var packet = packetList.pointee.packet
        for _ in 0..<packetList.pointee.numPackets {
            let bytes = withUnsafeBytes(of: packet.data) {
                Array($0.prefix(Int(packet.length)))
            }
            messages.append(contentsOf: MIDIControlChange.decode(bytes))
            packet = MIDIPacketNext(&packet).pointee
        }
        return messages
    }
}
