@preconcurrency import CoreMIDI
import Foundation

/// Lists the MIDI sources the system reports, in enumeration order (#81).
protocol CoreMIDIEndpointDirectory: Sendable {
    func sources() -> [CoreMIDIEndpointRecord]
}

/// Reads each source and its properties from CoreMIDI. Construct and call it only after the caller's testing
/// guard; every CoreMIDI call is recorded as `.apiEntered` for `.midiInput` first.
struct LiveCoreMIDIEndpointDirectory: CoreMIDIEndpointDirectory {
    let auditMirror: ProductionAccessAudit?

    func sources() -> [CoreMIDIEndpointRecord] {
        enter()
        return (0..<MIDIGetNumberOfSources()).map { index in
            enter()
            let source = MIDIGetSource(index)
            let displayName = string(kMIDIPropertyDisplayName, of: source) ?? "Unknown MIDI source"
            return CoreMIDIEndpointRecord(
                ref: source,
                uniqueID: integer(kMIDIPropertyUniqueID, of: source),
                displayName: displayName,
                manufacturer: string(kMIDIPropertyManufacturer, of: source),
                model: string(kMIDIPropertyModel, of: source),
                driverOwner: string(kMIDIPropertyDriverOwner, of: source),
                isOffline: integer(kMIDIPropertyOffline, of: source).map { $0 != 0 },
                protocolID: integer(kMIDIPropertyProtocolID, of: source)
            )
        }
    }

    private func enter() {
        ProductionAccessAudit.shared.record(.apiEntered, for: .midiInput, mirroring: auditMirror)
    }

    private func string(_ property: CFString, of object: MIDIObjectRef) -> String? {
        var value: Unmanaged<CFString>?
        enter()
        guard MIDIObjectGetStringProperty(object, property, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private func integer(_ property: CFString, of object: MIDIObjectRef) -> Int32? {
        var value: Int32 = 0
        enter()
        guard MIDIObjectGetIntegerProperty(object, property, &value) == noErr else { return nil }
        return value
    }
}
