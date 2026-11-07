extension UMPStreamMessage {
    /// Encodes one message into its canonical packets: zero padding and the lowest packet count. Every field of a
    /// caller-built payload is checked again here (block index, counts, groups, 7-bit bytes, text length, limits).
    static func encode(
        _ message: UMPStreamMessage,
        limits: UMPStreamLimits
    ) throws(UMPStreamRefusal) -> [UMPPacket] {
        switch message {
        case .endpointName(let name):
            return try UMPStreamText.packets(kind: .endpointName, index: 0, text: name, limits: limits)
        case .productInstanceID(let name):
            return try UMPStreamText.packets(kind: .productInstanceID, index: 0, text: name, limits: limits)
        case .functionBlockName(let index, let name):
            return try UMPStreamText.packets(kind: .functionBlockName, index: index, text: name, limits: limits)
        case .endpointDiscovery, .endpointInfo, .deviceIdentity, .streamConfigRequest, .streamConfigNotification,
             .functionBlockDiscovery, .functionBlockInfo:
            return [try encodeSinglePacket(message)]
        }
    }

    private static func bit(_ flag: Bool, _ position: UInt32) -> UInt32 {
        flag ? 1 << position : 0
    }

    private static func single(
        _ status: UMPStreamStatus,
        payload: UInt32,
        _ word1: UInt32 = 0,
        _ word2: UInt32 = 0,
        _ word3: UInt32 = 0
    ) throws(UMPStreamRefusal) -> UMPPacket {
        let first = 0xF000_0000 | UInt32(status.rawValue) << 16 | (payload & 0xFFFF)
        do {
            return try UMPPacket(words: [first, word1, word2, word3])
        } catch {
            throw .packet(error)
        }
    }

    private static func encodeSinglePacket(_ message: UMPStreamMessage) throws(UMPStreamRefusal) -> UMPPacket {
        switch message {
        case .endpointDiscovery(let version, let filter):
            let bits = bit(filter.info, 0) | bit(filter.deviceIdentity, 1) | bit(filter.name, 2)
                | bit(filter.productInstanceID, 3) | bit(filter.streamConfiguration, 4)
            return try single(.endpointDiscovery, payload: payload(version), bits)
        case .endpointInfo(let info):
            try info.validate()
            let word1 = bit(info.hasStaticFunctionBlocks, 31) | UInt32(info.functionBlockCount) << 24
                | bit(info.supportsMIDI2, 9) | bit(info.supportsMIDI1, 8)
                | bit(info.receivesJitterReduction, 1) | bit(info.transmitsJitterReduction, 0)
            return try single(.endpointInfo, payload: payload(info.version), word1)
        case .deviceIdentity(let identity):
            return try encodeDeviceIdentity(identity)
        case .streamConfigRequest(let configuration):
            return try single(.streamConfigRequest, payload: payload(configuration))
        case .streamConfigNotification(let configuration):
            return try single(.streamConfigNotification, payload: payload(configuration))
        case .functionBlockDiscovery(let query):
            try query.validate()
            var target: UInt32 = 0xFF
            if case .block(let index) = query.target { target = UInt32(index) }
            let flags = bit(query.wantsName, 1) | bit(query.wantsInfo, 0)
            return try single(.functionBlockDiscovery, payload: target << 8 | flags)
        case .functionBlockInfo(let info):
            return try encodeFunctionBlockInfo(info)
        case .endpointName, .productInstanceID, .functionBlockName:
            // Unreachable: `encode` sends the text messages to `UMPStreamText`.
            throw .unknownStatus(UInt16.max)
        }
    }

    private static func payload(_ version: UMPStreamVersion) -> UInt32 {
        UInt32(version.major) << 8 | UInt32(version.minor)
    }

    private static func payload(_ configuration: UMPStreamConfiguration) -> UInt32 {
        UInt32(configuration.streamProtocol.rawValue) << 8
            | bit(configuration.receivesJitterReduction, 1) | bit(configuration.transmitsJitterReduction, 0)
    }

    private static func encodeDeviceIdentity(
        _ identity: UMPStreamDeviceIdentity
    ) throws(UMPStreamRefusal) -> UMPPacket {
        try identity.validate()
        func word(_ first: UInt8, _ second: UInt8, _ third: UInt8, _ fourth: UInt8) -> UInt32 {
            UInt32(first) << 24 | UInt32(second) << 16 | UInt32(third) << 8 | UInt32(fourth)
        }
        return try single(
            .deviceIdentity,
            payload: 0,
            word(0, identity.manufacturer1, identity.manufacturer2, identity.manufacturer3),
            word(identity.familyLSB, identity.familyMSB, identity.modelLSB, identity.modelMSB),
            word(identity.revision1, identity.revision2, identity.revision3, identity.revision4)
        )
    }

    private static func encodeFunctionBlockInfo(
        _ info: UMPStreamFunctionBlockInfo
    ) throws(UMPStreamRefusal) -> UMPPacket {
        try info.validate()
        let payload = bit(info.isActive, 15) | UInt32(info.index) << 8 | UInt32(info.uiHint.rawValue) << 4
            | UInt32(info.midi1Mode.rawValue) << 2 | UInt32(info.direction.rawValue)
        let word1 = UInt32(info.firstGroup) << 24 | UInt32(info.groupCount) << 16
            | UInt32(info.midiCIVersion) << 8 | UInt32(info.maximumSysEx8Streams)
        return try single(.functionBlockInfo, payload: payload, word1)
    }
}
