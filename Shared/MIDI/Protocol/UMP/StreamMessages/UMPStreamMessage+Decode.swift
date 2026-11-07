/// The 2-bit format of a Stream message (word 0 bits 27...26).
enum UMPStreamFormat: UInt8, Equatable, Sendable {
    case complete = 0
    case start = 1
    case continuation = 2
    case end = 3

    init(bits: UInt32) {
        switch bits & 0x3 {
        case 0: self = .complete
        case 1: self = .start
        case 2: self = .continuation
        default: self = .end
        }
    }
}

/// The ten statuses this codec decodes.
enum UMPStreamStatus: UInt16, Equatable, Sendable {
    case endpointDiscovery = 0x000
    case endpointInfo = 0x001
    case deviceIdentity = 0x002
    case endpointName = 0x003
    case productInstanceID = 0x004
    case streamConfigRequest = 0x005
    case streamConfigNotification = 0x006
    case functionBlockDiscovery = 0x010
    case functionBlockInfo = 0x011
    case functionBlockName = 0x012
}

/// Word 0 of a Stream packet, split into its fields. Built only from a Message Type 0xF packet.
struct UMPStreamHeader: Equatable, Sendable {
    let format: UMPStreamFormat
    let status: UInt16
    let payload: UInt16
    let words: [UInt32]

    init(_ packet: UMPPacket) throws(UMPStreamRefusal) {
        guard packet.messageType == .stream else { throw .notStream(actual: packet.messageType) }
        let words = packet.words
        self.words = words
        format = UMPStreamFormat(bits: words[0] >> 26)
        status = UInt16((words[0] >> 16) & 0x3FF)
        payload = UInt16(words[0] & 0xFFFF)
    }
}

extension UMPStreamUIHint {
    init(bits: UInt16) {
        switch bits & 0x3 {
        case 1: self = .receiver
        case 2: self = .sender
        case 3: self = .both
        default: self = .unknown
        }
    }
}

extension UMPStreamMessage {
    /// Decodes one Stream packet. Text messages are accepted only as one complete (format 0) packet; use
    /// `UMPStreamTextAssembler` for start/continue/end sequences. Order of refusals: not MT 0xF, unknown status,
    /// format, reserved bits, field ranges.
    static func decode(_ packet: UMPPacket, limits: UMPStreamLimits) throws(UMPStreamRefusal) -> UMPStreamMessage {
        let header = try UMPStreamHeader(packet)
        guard let status = UMPStreamStatus(rawValue: header.status) else { throw .unknownStatus(header.status) }
        guard header.format == .complete else {
            throw .wrongFormat(status: header.status, format: header.format.rawValue)
        }
        switch status {
        case .endpointDiscovery: return try decodeEndpointDiscovery(header)
        case .endpointInfo: return try decodeEndpointInfo(header)
        case .deviceIdentity: return try decodeDeviceIdentity(header)
        case .streamConfigRequest: return .streamConfigRequest(try decodeConfiguration(header))
        case .streamConfigNotification: return .streamConfigNotification(try decodeConfiguration(header))
        case .functionBlockDiscovery: return try decodeFunctionBlockDiscovery(header)
        case .functionBlockInfo: return try decodeFunctionBlockInfo(header)
        case .endpointName, .productInstanceID, .functionBlockName:
            return try decodeText(packet, header, limits)
        }
    }

    private static func decodeText(
        _ packet: UMPPacket,
        _ header: UMPStreamHeader,
        _ limits: UMPStreamLimits
    ) throws(UMPStreamRefusal) -> UMPStreamMessage {
        var assembler = UMPStreamTextAssembler(limits: limits)
        guard case .complete(let message) = try assembler.feed(packet) else {
            throw .wrongFormat(status: header.status, format: header.format.rawValue)
        }
        return message
    }

    private static func requireZero(_ reserved: Bool, _ header: UMPStreamHeader) throws(UMPStreamRefusal) {
        if reserved { throw .reservedBitsSet(status: header.status) }
    }

    private static func flag(_ word: UInt32, _ bit: Int) -> Bool {
        (word >> UInt32(bit)) & 1 == 1
    }

    private static func version(_ payload: UInt16) -> UMPStreamVersion {
        UMPStreamVersion(major: UInt8(payload >> 8), minor: UInt8(payload & 0xFF))
    }

    private static func decodeEndpointDiscovery(_ header: UMPStreamHeader) throws(UMPStreamRefusal) -> Self {
        let words = header.words
        try requireZero(words[1] & 0xFFFF_FFE0 != 0 || words[2] != 0 || words[3] != 0, header)
        let filter = UMPStreamEndpointFilter(
            info: flag(words[1], 0),
            deviceIdentity: flag(words[1], 1),
            name: flag(words[1], 2),
            productInstanceID: flag(words[1], 3),
            streamConfiguration: flag(words[1], 4)
        )
        return .endpointDiscovery(version: version(header.payload), filter: filter)
    }

    private static func decodeEndpointInfo(_ header: UMPStreamHeader) throws(UMPStreamRefusal) -> Self {
        let words = header.words
        try requireZero(words[1] & 0x00FF_FCFC != 0 || words[2] != 0 || words[3] != 0, header)
        let info = UMPStreamEndpointInfo(
            version: version(header.payload),
            hasStaticFunctionBlocks: flag(words[1], 31),
            functionBlockCount: Int((words[1] >> 24) & 0x7F),
            supportsMIDI1: flag(words[1], 8),
            supportsMIDI2: flag(words[1], 9),
            receivesJitterReduction: flag(words[1], 1),
            transmitsJitterReduction: flag(words[1], 0)
        )
        try info.validate()
        return .endpointInfo(info)
    }

    private static func decodeDeviceIdentity(_ header: UMPStreamHeader) throws(UMPStreamRefusal) -> Self {
        let words = header.words
        let reserved = header.payload != 0 || words[1] & 0xFF80_8080 != 0
            || words[2] & 0x8080_8080 != 0 || words[3] & 0x8080_8080 != 0
        try requireZero(reserved, header)
        func byte(_ word: UInt32, _ shift: UInt32) -> UInt8 { UInt8((word >> shift) & 0xFF) }
        return .deviceIdentity(UMPStreamDeviceIdentity(
            manufacturer1: byte(words[1], 16), manufacturer2: byte(words[1], 8), manufacturer3: byte(words[1], 0),
            familyLSB: byte(words[2], 24), familyMSB: byte(words[2], 16),
            modelLSB: byte(words[2], 8), modelMSB: byte(words[2], 0),
            revision1: byte(words[3], 24), revision2: byte(words[3], 16),
            revision3: byte(words[3], 8), revision4: byte(words[3], 0)
        ))
    }

    private static func decodeConfiguration(
        _ header: UMPStreamHeader
    ) throws(UMPStreamRefusal) -> UMPStreamConfiguration {
        let words = header.words
        try requireZero(header.payload & 0x00FC != 0 || words[1] != 0 || words[2] != 0 || words[3] != 0, header)
        let wire = UInt8(header.payload >> 8)
        guard let streamProtocol = UMPStreamProtocol(rawValue: wire) else { throw .invalidProtocol(wire) }
        return UMPStreamConfiguration(
            streamProtocol: streamProtocol,
            receivesJitterReduction: flag(UInt32(header.payload), 1),
            transmitsJitterReduction: flag(UInt32(header.payload), 0)
        )
    }

    private static func decodeFunctionBlockDiscovery(_ header: UMPStreamHeader) throws(UMPStreamRefusal) -> Self {
        let words = header.words
        try requireZero(header.payload & 0x00FC != 0 || words[1] != 0 || words[2] != 0 || words[3] != 0, header)
        let wire = Int(header.payload >> 8)
        let query = UMPStreamFunctionBlockQuery(
            target: wire == 0xFF ? .all : .block(wire),
            wantsInfo: flag(UInt32(header.payload), 0),
            wantsName: flag(UInt32(header.payload), 1)
        )
        try query.validate()
        return .functionBlockDiscovery(query)
    }

    private static func decodeFunctionBlockInfo(_ header: UMPStreamHeader) throws(UMPStreamRefusal) -> Self {
        let words = header.words
        try requireZero(header.payload & 0x00C0 != 0 || words[2] != 0 || words[3] != 0, header)
        let index = Int((header.payload >> 8) & 0x7F)
        try UMPStreamFunctionBlockInfo.validateIndex(index)
        let modeBits = UInt8((header.payload >> 2) & 0x3)
        guard let mode = UMPStreamMIDI1Mode(rawValue: modeBits) else {
            throw .invalidField(.midi1Mode, value: Int(modeBits))
        }
        let directionBits = UInt8(header.payload & 0x3)
        guard let direction = UMPStreamDirection(rawValue: directionBits) else {
            throw .invalidField(.direction, value: Int(directionBits))
        }
        let info = UMPStreamFunctionBlockInfo(
            index: index,
            isActive: flag(UInt32(header.payload), 15),
            uiHint: UMPStreamUIHint(bits: header.payload >> 4),
            midi1Mode: mode,
            direction: direction,
            firstGroup: Int((words[1] >> 24) & 0xFF),
            groupCount: Int((words[1] >> 16) & 0xFF),
            midiCIVersion: UInt8((words[1] >> 8) & 0xFF),
            maximumSysEx8Streams: UInt8(words[1] & 0xFF)
        )
        try info.validate()
        return .functionBlockInfo(info)
    }
}
