/// A text carried by a Stream message. It compares by utf8 bytes: Swift's `String ==` is canonical equivalence, which
/// would call a precomposed and a decomposed name equal although their wire bytes differ.
struct UMPStreamString: Equatable, Sendable {
    let value: String

    init(_ value: String) {
        self.value = value
    }

    static func == (lhs: UMPStreamString, rhs: UMPStreamString) -> Bool {
        lhs.value.utf8.elementsEqual(rhs.value.utf8)
    }
}

/// The UMP version carried by Endpoint Discovery and Endpoint Info (any byte values are accepted).
struct UMPStreamVersion: Equatable, Sendable {
    var major: UInt8
    var minor: UInt8
}

/// The notifications an Endpoint Discovery asks for (filter byte bits 0...4).
struct UMPStreamEndpointFilter: Equatable, Sendable {
    var info: Bool
    var deviceIdentity: Bool
    var name: Bool
    var productInstanceID: Bool
    var streamConfiguration: Bool
}

/// Endpoint Info Notification. `functionBlockCount` is checked (0...32) on encode and decode.
struct UMPStreamEndpointInfo: Equatable, Sendable {
    var version: UMPStreamVersion
    var hasStaticFunctionBlocks: Bool
    var functionBlockCount: Int
    var supportsMIDI1: Bool
    var supportsMIDI2: Bool
    var receivesJitterReduction: Bool
    var transmitsJitterReduction: Bool

    static let maximumFunctionBlocks = 32

    func validate() throws(UMPStreamRefusal) {
        guard (0...Self.maximumFunctionBlocks).contains(functionBlockCount) else {
            throw .invalidField(.functionBlockCount, value: functionBlockCount)
        }
    }
}

/// The stream protocol of a Stream Configuration message.
enum UMPStreamProtocol: UInt8, Equatable, Sendable {
    case midi1 = 1
    case midi2 = 2
}

/// Stream Configuration Request / Notification.
struct UMPStreamConfiguration: Equatable, Sendable {
    var streamProtocol: UMPStreamProtocol
    var receivesJitterReduction: Bool
    var transmitsJitterReduction: Bool
}

/// Device Identity Notification. Every byte is a 7-bit value (checked on encode, a reserved bit on decode).
struct UMPStreamDeviceIdentity: Equatable, Sendable {
    var manufacturer1: UInt8
    var manufacturer2: UInt8
    var manufacturer3: UInt8
    var familyLSB: UInt8
    var familyMSB: UInt8
    var modelLSB: UInt8
    var modelMSB: UInt8
    var revision1: UInt8
    var revision2: UInt8
    var revision3: UInt8
    var revision4: UInt8

    var bytes: [UInt8] {
        [manufacturer1, manufacturer2, manufacturer3, familyLSB, familyMSB, modelLSB, modelMSB,
         revision1, revision2, revision3, revision4]
    }

    func validate() throws(UMPStreamRefusal) {
        for byte in bytes where byte > 0x7F {
            throw .invalidField(.deviceIdentityByte, value: Int(byte))
        }
    }
}

/// The function block a Function Block Discovery asks about.
enum UMPStreamFunctionBlockTarget: Equatable, Sendable {
    case all
    case block(Int)
}

/// Function Block Discovery: the target and which notifications to send.
struct UMPStreamFunctionBlockQuery: Equatable, Sendable {
    var target: UMPStreamFunctionBlockTarget
    var wantsInfo: Bool
    var wantsName: Bool

    func validate() throws(UMPStreamRefusal) {
        if case .block(let index) = target {
            try UMPStreamFunctionBlockInfo.validateIndex(index)
        }
    }
}

enum UMPStreamUIHint: UInt8, Equatable, Sendable {
    case unknown = 0
    case receiver = 1
    case sender = 2
    case both = 3
}

enum UMPStreamMIDI1Mode: UInt8, Equatable, Sendable {
    case notMIDI1 = 0
    case unrestricted = 1
    case restricted = 2
}

enum UMPStreamDirection: UInt8, Equatable, Sendable {
    case input = 1
    case output = 2
    case bidirectional = 3
}

/// Function Block Info Notification. Index, groups and CI version are checked on encode and decode.
struct UMPStreamFunctionBlockInfo: Equatable, Sendable {
    var index: Int
    var isActive: Bool
    var uiHint: UMPStreamUIHint
    var midi1Mode: UMPStreamMIDI1Mode
    var direction: UMPStreamDirection
    var firstGroup: Int
    var groupCount: Int
    var midiCIVersion: UInt8
    var maximumSysEx8Streams: UInt8

    static let blockIndexRange = 0...31

    static func validateIndex(_ index: Int) throws(UMPStreamRefusal) {
        guard blockIndexRange.contains(index) else { throw .functionBlockOutOfRange(index) }
    }

    func validate() throws(UMPStreamRefusal) {
        try Self.validateIndex(index)
        guard (0...15).contains(firstGroup) else { throw .invalidField(.firstGroup, value: firstGroup) }
        guard (1...16).contains(groupCount), firstGroup + groupCount <= 16 else {
            throw .invalidField(.groupCount, value: groupCount)
        }
        guard midiCIVersion <= 2 else { throw .invalidField(.midiCIVersion, value: Int(midiCIVersion)) }
    }
}

/// A typed UMP Stream message (Message Type 0xF). Text messages are complete values here; their packets are split
/// and joined by `encode` and `UMPStreamTextAssembler`.
enum UMPStreamMessage: Equatable, Sendable {
    case endpointDiscovery(version: UMPStreamVersion, filter: UMPStreamEndpointFilter)
    case endpointInfo(UMPStreamEndpointInfo)
    case deviceIdentity(UMPStreamDeviceIdentity)
    case endpointName(UMPStreamString)
    case productInstanceID(UMPStreamString)
    case streamConfigRequest(UMPStreamConfiguration)
    case streamConfigNotification(UMPStreamConfiguration)
    case functionBlockDiscovery(UMPStreamFunctionBlockQuery)
    case functionBlockInfo(UMPStreamFunctionBlockInfo)
    case functionBlockName(index: Int, name: UMPStreamString)
    /// Start of Clip (status 0x020): one complete packet with no payload; every other bit is reserved.
    case startOfClip
    /// End of Clip (status 0x021): one complete packet with no payload; every other bit is reserved.
    case endOfClip
}
