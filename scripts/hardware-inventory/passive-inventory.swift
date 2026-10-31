//
//  passive-inventory.swift
//  FluxKlang passive hardware inventory (roadmap #48, issue #67)
//
//  Read-only listing of CoreAudio HAL devices and CoreMIDI devices. The code
//  only issues HAL property has/size/get queries and CoreMIDI enumeration and
//  property getters. It creates no MIDI client or port, starts no device I/O,
//  sets no property, installs no listener and itself sends nothing anywhere.
//
//  Side effects outside this file's control: the first HAL query connects to
//  coreaudiod, which may load HAL driver plug-ins; property reads may make a
//  driver issue USB control (GET) requests to the device; the first CoreMIDI
//  call may launch the CoreMIDI server, which loads its own MIDI drivers
//  (including the network and Bluetooth MIDI drivers).
//
//  Run standalone (not part of any app target):
//      swift scripts/hardware-inventory/passive-inventory.swift
//  JSON is written to standard output. Defence-in-depth tripwire (not a proof)
//  for this file's identifiers and linked symbols:
//      scripts/hardware-inventory/passive-inventory.sh --self-check
//

import CoreAudio
import CoreMIDI
import Foundation

// MARK: - Output model

struct ValueRange: Codable {
    let minimum: Double
    let maximum: Double
}

struct StreamInfo: Codable {
    let startingChannel: UInt32?
    let terminalType: String?
    let isActive: Bool?
    let physicalSampleRate: Double?
    let physicalChannels: UInt32?
    let physicalBitsPerChannel: UInt32?
    let physicalFormatID: String?
}

struct ScopeInfo: Codable {
    let channels: Int?
    let channelNames: [String]
    let streams: [StreamInfo]
}

struct ClockInfo: Codable {
    let scope: String
    let currentSourceID: UInt32?
    let currentSourceName: String?
    let availableSources: [String]
}

struct DeviceInfo: Codable {
    let objectID: UInt32
    let name: String?
    let manufacturer: String?
    let modelName: String?
    let firmwareVersion: String?
    let uid: String?
    let modelUID: String?
    let transportType: String?
    let clockDomain: UInt32?
    let isAlive: Bool?
    let isRunningSomewhere: Bool?
    let isHogModeOwned: Bool?
    let nominalSampleRate: Double?
    let availableNominalSampleRates: [ValueRange]
    let bufferFrameSize: UInt32?
    let bufferFrameSizeRange: ValueRange?
    let clocks: [ClockInfo]
    let input: ScopeInfo
    let output: ScopeInfo
    let isDefaultInput: Bool
    let isDefaultOutput: Bool
    let isDefaultSystemOutput: Bool
}

struct MidiEndpointInfo: Codable {
    let name: String?
    let isOffline: Bool?
    let protocolID: Int32?
}

struct MidiEntityInfo: Codable {
    let name: String?
    let sources: [MidiEndpointInfo]
    let destinations: [MidiEndpointInfo]
}

struct MidiDeviceInfo: Codable {
    let name: String?
    let manufacturer: String?
    let model: String?
    let driverOwner: String?
    let isOffline: Bool?
    let entities: [MidiEntityInfo]
}

struct MidiInventory: Codable {
    let deviceCount: Int
    let systemSourceCount: Int
    let systemDestinationCount: Int
    let devices: [MidiDeviceInfo]
}

struct Inventory: Codable {
    let schema: String
    let generatedAt: String
    let audioDevices: [DeviceInfo]
    let midi: MidiInventory
}

// MARK: - HAL getters (read-only)

func propertyAddress(
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
}

func halHas(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
    var query = address
    return AudioObjectHasProperty(object, &query)
}

func halValue<Value>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, empty: Value) -> Value? {
    guard halHas(object, address) else { return nil }
    var query = address
    var value = empty
    var size = UInt32(MemoryLayout<Value>.size)
    let status = withUnsafeMutablePointer(to: &value) { pointer in
        AudioObjectGetPropertyData(object, &query, 0, nil, &size, pointer)
    }
    return status == noErr ? value : nil
}

func halArray<Element>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, empty: Element) -> [Element] {
    guard halHas(object, address) else { return [] }
    var query = address
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(object, &query, 0, nil, &size) == noErr else { return [] }
    let capacity = Int(size) / MemoryLayout<Element>.stride
    guard capacity > 0 else { return [] }
    var values = [Element](repeating: empty, count: capacity)
    let status = values.withUnsafeMutableBytes { buffer -> OSStatus in
        guard let base = buffer.baseAddress else { return OSStatus(-1) }
        return AudioObjectGetPropertyData(object, &query, 0, nil, &size, base)
    }
    guard status == noErr else { return [] }
    return Array(values.prefix(Int(size) / MemoryLayout<Element>.stride))
}

func halString(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> String? {
    guard let wrapped = halValue(object, address, empty: Unmanaged<CFString>?.none),
          let unmanaged = wrapped else { return nil }
    let text = unmanaged.takeRetainedValue() as String
    return text.isEmpty ? nil : text
}

func halFlag(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool? {
    halValue(object, propertyAddress(selector), empty: UInt32(0)).map { $0 != 0 }
}

func halRange(_ range: AudioValueRange) -> ValueRange {
    ValueRange(minimum: range.mMinimum, maximum: range.mMaximum)
}

func fourCC(_ code: UInt32) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
    if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }), let text = String(bytes: bytes, encoding: .ascii) {
        return text
    }
    return String(format: "0x%08X", code)
}

// MARK: - HAL device description

func channelCount(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> Int? {
    var query = propertyAddress(kAudioDevicePropertyStreamConfiguration, scope: scope)
    guard AudioObjectHasProperty(device, &query) else { return nil }
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(device, &query, 0, nil, &size) == noErr, size > 0 else { return nil }
    let raw = UnsafeMutableRawPointer.allocate(
        byteCount: Int(size),
        alignment: MemoryLayout<AudioBufferList>.alignment
    )
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(device, &query, 0, nil, &size, raw) == noErr else { return nil }
    let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    return list.reduce(0) { $0 + Int($1.mNumberChannels) }
}

func channelNames(_ device: AudioObjectID, scope: AudioObjectPropertyScope, count: Int) -> [String] {
    guard count > 0 else { return [] }
    return (1...count).map { channel in
        let address = propertyAddress(kAudioObjectPropertyElementName, scope: scope, element: UInt32(channel))
        return halString(device, address) ?? ""
    }
}

func streams(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> [StreamInfo] {
    let ids = halArray(device, propertyAddress(kAudioDevicePropertyStreams, scope: scope), empty: AudioStreamID(0))
    return ids.map { stream in
        let format = halValue(
            stream,
            propertyAddress(kAudioStreamPropertyPhysicalFormat),
            empty: AudioStreamBasicDescription()
        )
        return StreamInfo(
            startingChannel: halValue(stream, propertyAddress(kAudioStreamPropertyStartingChannel), empty: UInt32(0)),
            terminalType: halValue(stream, propertyAddress(kAudioStreamPropertyTerminalType), empty: UInt32(0))
                .map(fourCC),
            isActive: halFlag(stream, kAudioStreamPropertyIsActive),
            physicalSampleRate: format?.mSampleRate,
            physicalChannels: format?.mChannelsPerFrame,
            physicalBitsPerChannel: format?.mBitsPerChannel,
            physicalFormatID: format.map { fourCC($0.mFormatID) }
        )
    }
}

func scopeInfo(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> ScopeInfo {
    let channels = channelCount(device, scope: scope)
    return ScopeInfo(
        channels: channels,
        channelNames: channelNames(device, scope: scope, count: channels ?? 0),
        streams: streams(device, scope: scope)
    )
}

func clockName(_ device: AudioObjectID, scope: AudioObjectPropertyScope, sourceID: UInt32) -> String? {
    var query = propertyAddress(kAudioDevicePropertyClockSourceNameForIDCFString, scope: scope)
    guard AudioObjectHasProperty(device, &query) else { return nil }
    var input = sourceID
    var output: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<AudioValueTranslation>.size)
    let status = withUnsafeMutablePointer(to: &input) { inputPointer in
        withUnsafeMutablePointer(to: &output) { outputPointer in
            var translation = AudioValueTranslation(
                mInputData: inputPointer,
                mInputDataSize: UInt32(MemoryLayout<UInt32>.size),
                mOutputData: outputPointer,
                mOutputDataSize: UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            )
            return AudioObjectGetPropertyData(device, &query, 0, nil, &size, &translation)
        }
    }
    guard status == noErr, let name = output?.takeRetainedValue() else { return nil }
    return name as String
}

func clocks(_ device: AudioObjectID) -> [ClockInfo] {
    let scopes: [(String, AudioObjectPropertyScope)] = [
        ("global", kAudioObjectPropertyScopeGlobal),
        ("input", kAudioObjectPropertyScopeInput),
        ("output", kAudioObjectPropertyScopeOutput)
    ]
    return scopes.compactMap { label, scope in
        let currentAddress = propertyAddress(kAudioDevicePropertyClockSource, scope: scope)
        let current = halValue(device, currentAddress, empty: UInt32(0))
        let sourcesAddress = propertyAddress(kAudioDevicePropertyClockSources, scope: scope)
        let sources = halArray(device, sourcesAddress, empty: UInt32(0))
        guard current != nil || !sources.isEmpty else { return nil }
        return ClockInfo(
            scope: label,
            currentSourceID: current,
            currentSourceName: current.flatMap { clockName(device, scope: scope, sourceID: $0) },
            availableSources: sources.map { clockName(device, scope: scope, sourceID: $0) ?? fourCC($0) }
        )
    }
}

struct DefaultDevices {
    let input: AudioObjectID?
    let output: AudioObjectID?
    let systemOutput: AudioObjectID?
}

func describe(_ device: AudioObjectID, defaults: DefaultDevices) -> DeviceInfo {
    let rangeAddress = propertyAddress(kAudioDevicePropertyBufferFrameSizeRange)
    return DeviceInfo(
        objectID: device,
        name: halString(device, propertyAddress(kAudioObjectPropertyName)),
        manufacturer: halString(device, propertyAddress(kAudioObjectPropertyManufacturer)),
        modelName: halString(device, propertyAddress(kAudioObjectPropertyModelName)),
        firmwareVersion: halString(device, propertyAddress(kAudioObjectPropertyFirmwareVersion)),
        uid: halString(device, propertyAddress(kAudioDevicePropertyDeviceUID)),
        modelUID: halString(device, propertyAddress(kAudioDevicePropertyModelUID)),
        transportType: halValue(device, propertyAddress(kAudioDevicePropertyTransportType), empty: UInt32(0))
            .map(fourCC),
        clockDomain: halValue(device, propertyAddress(kAudioDevicePropertyClockDomain), empty: UInt32(0)),
        isAlive: halFlag(device, kAudioDevicePropertyDeviceIsAlive),
        isRunningSomewhere: halFlag(device, kAudioDevicePropertyDeviceIsRunningSomewhere),
        isHogModeOwned: halValue(device, propertyAddress(kAudioDevicePropertyHogMode), empty: pid_t(-1))
            .map { $0 != -1 },
        nominalSampleRate: halValue(device, propertyAddress(kAudioDevicePropertyNominalSampleRate), empty: 0.0),
        availableNominalSampleRates: halArray(
            device,
            propertyAddress(kAudioDevicePropertyAvailableNominalSampleRates),
            empty: AudioValueRange()
        ).map(halRange),
        bufferFrameSize: halValue(device, propertyAddress(kAudioDevicePropertyBufferFrameSize), empty: UInt32(0)),
        bufferFrameSizeRange: halValue(device, rangeAddress, empty: AudioValueRange()).map(halRange),
        clocks: clocks(device),
        input: scopeInfo(device, scope: kAudioObjectPropertyScopeInput),
        output: scopeInfo(device, scope: kAudioObjectPropertyScopeOutput),
        isDefaultInput: device == defaults.input,
        isDefaultOutput: device == defaults.output,
        isDefaultSystemOutput: device == defaults.systemOutput
    )
}

func audioDevices() -> [DeviceInfo] {
    let systemObject = AudioObjectID(kAudioObjectSystemObject)
    let defaults = DefaultDevices(
        input: halValue(
            systemObject,
            propertyAddress(kAudioHardwarePropertyDefaultInputDevice),
            empty: AudioObjectID(0)
        ),
        output: halValue(
            systemObject,
            propertyAddress(kAudioHardwarePropertyDefaultOutputDevice),
            empty: AudioObjectID(0)
        ),
        systemOutput: halValue(
            systemObject,
            propertyAddress(kAudioHardwarePropertyDefaultSystemOutputDevice),
            empty: AudioObjectID(0)
        )
    )
    let devices = halArray(systemObject, propertyAddress(kAudioHardwarePropertyDevices), empty: AudioObjectID(0))
    return devices.map { describe($0, defaults: defaults) }
}

// MARK: - CoreMIDI getters (read-only, no client)

func midiString(_ object: MIDIObjectRef, _ property: CFString) -> String? {
    var value: Unmanaged<CFString>?
    guard MIDIObjectGetStringProperty(object, property, &value) == noErr,
          let text = value?.takeRetainedValue() else { return nil }
    let string = text as String
    return string.isEmpty ? nil : string
}

func midiInteger(_ object: MIDIObjectRef, _ property: CFString) -> Int32? {
    var value: Int32 = 0
    return MIDIObjectGetIntegerProperty(object, property, &value) == noErr ? value : nil
}

func midiEndpoint(_ endpoint: MIDIEndpointRef) -> MidiEndpointInfo {
    MidiEndpointInfo(
        name: midiString(endpoint, kMIDIPropertyName),
        isOffline: midiInteger(endpoint, kMIDIPropertyOffline).map { $0 != 0 },
        protocolID: midiInteger(endpoint, kMIDIPropertyProtocolID)
    )
}

func midiEntity(_ entity: MIDIEntityRef) -> MidiEntityInfo {
    let sources = (0..<MIDIEntityGetNumberOfSources(entity)).map { index in
        midiEndpoint(MIDIEntityGetSource(entity, index))
    }
    let destinations = (0..<MIDIEntityGetNumberOfDestinations(entity)).map { index in
        midiEndpoint(MIDIEntityGetDestination(entity, index))
    }
    return MidiEntityInfo(name: midiString(entity, kMIDIPropertyName), sources: sources, destinations: destinations)
}

func midiInventory() -> MidiInventory {
    let devices = (0..<MIDIGetNumberOfDevices()).map { index -> MidiDeviceInfo in
        let device = MIDIGetDevice(index)
        let entities = (0..<MIDIDeviceGetNumberOfEntities(device)).map { entityIndex in
            midiEntity(MIDIDeviceGetEntity(device, entityIndex))
        }
        return MidiDeviceInfo(
            name: midiString(device, kMIDIPropertyName),
            manufacturer: midiString(device, kMIDIPropertyManufacturer),
            model: midiString(device, kMIDIPropertyModel),
            driverOwner: midiString(device, kMIDIPropertyDriverOwner),
            isOffline: midiInteger(device, kMIDIPropertyOffline).map { $0 != 0 },
            entities: entities
        )
    }
    return MidiInventory(
        deviceCount: devices.count,
        systemSourceCount: MIDIGetNumberOfSources(),
        systemDestinationCount: MIDIGetNumberOfDestinations(),
        devices: devices
    )
}

// MARK: - Main

let inventory = Inventory(
    schema: "fluxklang.passive-hardware-inventory/2",
    generatedAt: ISO8601DateFormatter().string(from: Date()),
    audioDevices: audioDevices(),
    midi: midiInventory()
)

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
do {
    FileHandle.standardOutput.write(try encoder.encode(inventory))
    FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
    FileHandle.standardError.write(Data("passive-inventory: could not encode JSON: \(error)\n".utf8))
    exit(1)
}
