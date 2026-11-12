extension MIDICIPropertyDataMessage {
    /// The common header, the request id and the two length bytes of the header data: the shortest payload from which
    /// the length H of the header data can be read.
    private static let lengthOfHeaderEnd = MIDICILayout.headerBytes + 3
    /// Bytes of everything but the header data and the property data (the common header, the request id, three
    /// length or chunk fields of two bytes and the length of the property data).
    private static let fixedBytes = 22

    // MARK: Decode

    /// Decodes a payload without F0 and F7. The first failing step wins; steps 1 to 4 are
    /// `MIDICIMessage.checkEnvelope` and the rest follow the shared header order of
    /// `MIDICIMessage.decode(payload:limits:)`:
    ///  1. more than `limits.maximumPayloadBytes` bytes is `payloadTooLarge`; an empty payload is `truncated(1, 0)`;
    ///  2. byte 0 is not 0x7E, or (with 3 bytes or more) byte 2 is not 0x0D: `notCI`;
    ///  3. the first byte from offset 1 on that is 0x80 or more: `dataByteHigh(offset)` (the whole body is 7-bit
    ///     data: the device id, the MUIDs, the request id, every length, the header, the chunk fields and the
    ///     property data);
    ///  4. fewer than 5 bytes: `truncated(5)`;
    ///  5. sub-id 2 (byte 3) not 0x34 to 0x39 or 0x3F: `unknownSubID`;
    ///  6. format (byte 4) not 1 or 2: `unsupportedFormat`;
    ///  7. fewer than 13 bytes: `truncated(13)`; fewer than 16: `truncated(16)`;
    ///  8. the length H of the header data (offsets 14 and 15) above 2,048: `propertyHeaderTooLong(H)`, before any
    ///     further length is read, so that a hostile length is named as such;
    ///  9. fewer than `22 + H` bytes: `truncated(22 + H)`;
    /// 10. with the length D of the property data read: fewer than `22 + H + D` bytes is `truncated(22 + H + D)`,
    ///     more is `trailingBytes`;
    /// 11. a source or destination MUID that is not assignable: `invalidMUID` (the source first);
    /// 12. addressing: `sourceIsBroadcast`, then `destinationIsBroadcast`;
    /// 13. the device id, wrapped as received (any 7-bit value);
    /// 14. the body through `MIDICIPropertyChunk.make`. The chunk fields and, for 0x34 and 0x37, a non-empty property
    ///     data or chunk fields other than 1 and 1 are kept as received: they are rules of `encode`.
    /// The device id wrapper of step 13 and the `fieldOutOfRange` refusals of step 14 are defensive: step 3 makes them
    /// unreachable (by inspection; no test reaches them).
    static func decode(payload: [UInt8], limits: MIDICILimits) throws(MIDICIRefusal) -> MIDICIPropertyDataMessage {
        try MIDICIMessage.checkEnvelope(payload, limits: limits)
        guard let kind = MIDICIPropertyDataKind(rawValue: payload[3]) else { throw .unknownSubID(payload[3]) }
        guard let format = MIDICIFormat(rawValue: payload[4]) else { throw .unsupportedFormat(payload[4]) }
        guard payload.count >= MIDICILayout.headerBytes else {
            throw .truncated(need: MIDICILayout.headerBytes, have: payload.count)
        }
        guard payload.count >= lengthOfHeaderEnd else {
            throw .truncated(need: lengthOfHeaderEnd, have: payload.count)
        }
        let headerLength = Int(MIDICIWire.decode(Array(payload[14...15])))
        guard headerLength <= MIDICIPropertyChunk.maximumHeaderBytes else {
            throw .propertyHeaderTooLong(headerLength)
        }
        let beforeData = fixedBytes + headerLength
        guard payload.count >= beforeData else { throw .truncated(need: beforeData, have: payload.count) }
        let dataLength = Int(MIDICIWire.decode(Array(payload[(beforeData - 2)...(beforeData - 1)])))
        let expected = beforeData + dataLength
        guard payload.count >= expected else { throw .truncated(need: expected, have: payload.count) }
        guard payload.count == expected else { throw .trailingBytes(payload.count - expected) }
        var reader = MIDICIReader(payload, offset: MIDICILayout.prefixBytes)
        let source = try MIDICIMUID.make(reader.wireValue(byteCount: 4))
        let destination = try MIDICIMUID.make(reader.wireValue(byteCount: 4))
        try MIDICIMessage.validateAddressing(destinationRule, source: source, destination: destination)
        let device = try MIDICIMessage.wrapDevice(payload[1])
        let header = MIDICIHeader(device: device, format: format, source: source, destination: destination)
        return make(kind, header: header, chunk: try readChunk(&reader))
    }

    private static func readChunk(_ reader: inout MIDICIReader) throws(MIDICIRefusal) -> MIDICIPropertyChunk {
        let requestID = try reader.byte()
        let headerLength = try reader.wireValue(byteCount: 2)
        let headerData = try reader.take(Int(headerLength))
        let chunkCount = try reader.wireValue(byteCount: 2)
        let chunkNumber = try reader.wireValue(byteCount: 2)
        let dataLength = try reader.wireValue(byteCount: 2)
        let propertyData = try reader.take(Int(dataLength))
        return try MIDICIPropertyChunk.make(
            requestID: requestID, headerData: headerData, chunkCount: UInt16(chunkCount),
            chunkNumber: UInt16(chunkNumber), propertyData: propertyData)
    }

    // MARK: Encode

    /// The canonical payload (without F0 and F7). Refusal order: `sourceIsBroadcast`, `destinationIsBroadcast`,
    /// `deviceNotFunctionBlock` (a device id other than 0x7F), then for 0x34 and 0x37 `propertyDataNotAllowed` and
    /// `singleChunkRequired` (chunk count and number other than 1 and 1), then for every kind
    /// `headerOnlyInFirstChunk` (a chunk number of 2 or more with header data), last `payloadTooLarge`. The chunk is
    /// 7-bit and within its lengths by construction (`MIDICIPropertyChunk.make`). Both CI formats are written.
    func encode(limits: MIDICILimits) throws(MIDICIRefusal) -> [UInt8] {
        let header = self.header
        let chunk = self.chunk
        try MIDICIMessage.validateAddressing(
            Self.destinationRule, source: header.source, destination: header.destination)
        guard header.device.isAllCall else { throw .deviceNotFunctionBlock(header.device.rawValue) }
        if kind.hasNoPropertyData {
            guard chunk.propertyData.isEmpty else { throw .propertyDataNotAllowed(chunk.propertyData.count) }
            guard chunk.chunkCount == 1, chunk.chunkNumber == 1 else {
                throw .singleChunkRequired(count: chunk.chunkCount, number: chunk.chunkNumber)
            }
        }
        if chunk.chunkNumber >= 2, !chunk.headerData.isEmpty { throw .headerOnlyInFirstChunk(chunk.chunkNumber) }
        let total = Self.fixedBytes + chunk.headerData.count + chunk.propertyData.count
        guard total <= limits.maximumPayloadBytes else { throw .payloadTooLarge(total) }
        let prefix: [UInt8] = [
            MIDICILayout.universalNonRealTime, header.device.rawValue, MIDICILayout.ciSubID1,
            kind.rawValue, header.format.rawValue
        ]
        return prefix + MIDICIWire.encode(header.source.rawValue, byteCount: 4)
            + MIDICIWire.encode(header.destination.rawValue, byteCount: 4) + [chunk.requestID]
            + MIDICIWire.encode(UInt32(chunk.headerData.count), byteCount: 2) + chunk.headerData
            + MIDICIWire.encode(UInt32(chunk.chunkCount), byteCount: 2)
            + MIDICIWire.encode(UInt32(chunk.chunkNumber), byteCount: 2)
            + MIDICIWire.encode(UInt32(chunk.propertyData.count), byteCount: 2) + chunk.propertyData
    }
}
