//
//  MIDICIPropertyChunker.swift
//  FluxKlang
//
//  Cuts one coded MIDI-CI Property Exchange message into chunk messages 1...n that each fit a payload limit (#83,
//  slice M83-PXO, issue #831): the outbound inverse of `MIDICIPropertyReassembler`. A pure, bounded function that uses
//  only the standard library. It sends nothing, and nothing calls it yet.
//
//  Provenance: the chunk fields follow M2-101-UM v1.2, section 8 and Tables 29 and 33 to 39, as the codec already
//  enforces them. The Property Exchange specifications (M2-102-UM, the Common Rules, and M2-103-UM, the resources)
//  were not read. These are this chunker's own judgment calls, not checked against them:
//  - The property data is taken as already coded (Mcoded7 or ASCII) as a whole, and the coded bytes are cut where the
//    limit falls, inside a Mcoded7 group if need be. `MIDICIPropertyContent.decode(_:)` assumes the same on receive.
//  - Chunks are filled greedily, so when the header data leaves no room in chunk 1, chunk 1 carries the header data
//    and no property data, and the property data starts in chunk 2.
//  - The chunk count is bounded only by the 14-bit wire maximum (16,383); a lower bound, like a receiver's
//    `MIDICIPropertyReassembler.maximumChunks`, is the caller's policy.
//

/// Cuts the header data and the property data of one Property Exchange message into the chunks of section 8: every
/// chunk has the same kind, MIDI-CI header, request id and chunk count n, the chunk numbers run 1...n, and only chunk
/// 1 carries the header data. Each chunk takes as much of the remaining property data as the payload limit allows, so
/// every chunk but the last is exactly `limits.maximumPayloadBytes` bytes long (the payload without F0 and F7; mapping
/// a receiver's Maximum SysEx Message Size, which may count them, is the caller's). Empty property data gives one
/// chunk 1 of 1, for every kind.
///
/// Every message returned passes the content checks of `MIDICIPropertyDataMessage.encode(limits:)` with the same
/// limits: `propertyDataNotAllowed`, `singleChunkRequired`, `headerOnlyInFirstChunk` and `payloadTooLarge`. The
/// addressing checks (`sourceIsBroadcast`, `destinationIsBroadcast` and `deviceNotFunctionBlock`) are not made here
/// and stay with `encode(limits:)`, so a message returned may still be refused there.
enum MIDICIPropertyChunker {
    /// The chunk messages of one Property Exchange message, in chunk order. It refuses, in this order:
    /// 1. property data in a kind without it (Get Inquiry and Set Reply), as `propertyDataNotAllowed`;
    /// 2. more than `MIDICIPropertyReassembler.propertyBytesCeiling` (262,144) bytes of property data, as
    ///    `propertyDataTooLong`;
    /// 3. a payload limit below `22 + H` (H the length of the header data), or below 23 for non-empty property data,
    ///    as `payloadLimitTooSmall` with the larger of the two as `needed`;
    /// 4. more than 16,383 chunks, as `tooManyChunks`;
    /// 5. a chunk `MIDICIPropertyChunk.make` refuses, as `chunk` with that refusal unchanged: a request id of 0x80 or
    ///    more, header data above 2,048 bytes or with a byte of 0x80 or more, or a property data byte of 0x80 or more
    ///    (in the first chunk that holds one). Its chunk count, chunk number and property data length refusals are
    ///    defensive: check 4 makes the chunk count and number refusals unreachable, and the 4,096-byte
    ///    `MIDICILimits` ceiling makes the property data length refusal unreachable (a chunk holds at most 4,074
    ///    bytes of property data).
    /// Checks 1 to 4 read no byte and build no chunk. The six parameters are the five fields of one message and the
    /// limits.
    static func chunks( // swiftlint:disable:this function_parameter_count
        _ kind: MIDICIPropertyDataKind, header: MIDICIHeader, requestID: UInt8, headerData: [UInt8],
        propertyData: [UInt8], limits: MIDICILimits
    ) throws(MIDICIPropertyChunkingRefusal) -> [MIDICIPropertyDataMessage] {
        let dataCount = propertyData.count
        if kind.hasNoPropertyData && dataCount > 0 { throw .propertyDataNotAllowed(kind: kind, count: dataCount) }
        let dataLimit = MIDICIPropertyReassembler.propertyBytesCeiling
        guard dataCount <= dataLimit else { throw .propertyDataTooLong(count: dataCount, limit: dataLimit) }
        let limit = limits.maximumPayloadBytes
        let fixed = MIDICIPropertyDataMessage.fixedBytes
        let needed = fixed + max(headerData.count, dataCount > 0 ? 1 : 0)
        guard needed <= limit else { throw .payloadLimitTooSmall(needed: needed, limit: limit) }
        let firstCapacity = limit - fixed - headerData.count
        let nextCapacity = limit - fixed
        let count = chunkCount(dataCount, firstCapacity: firstCapacity, nextCapacity: nextCapacity)
        let countLimit = MIDICIPropertyChunk.maximumFieldValue
        guard count <= countLimit else { throw .tooManyChunks(count: count, limit: countLimit) }
        var messages: [MIDICIPropertyDataMessage] = []
        messages.reserveCapacity(count)
        var start = 0
        for number in 1...count {
            let end = min(dataCount, start + (number == 1 ? firstCapacity : nextCapacity))
            let chunk = try makeChunk(
                requestID: requestID, headerData: number == 1 ? headerData : [], count: count, number: number,
                propertyData: Array(propertyData[start..<end]))
            messages.append(MIDICIPropertyDataMessage.make(kind, header: header, chunk: chunk))
            start = end
        }
        return messages
    }

    /// The number of chunks for `dataCount` bytes of property data: 1 while it fits in chunk 1, else 1 plus as many
    /// full or partial chunks of `nextCapacity` (at least 1) as the rest needs.
    private static func chunkCount(_ dataCount: Int, firstCapacity: Int, nextCapacity: Int) -> Int {
        guard dataCount > firstCapacity else { return 1 }
        let rest = dataCount - firstCapacity
        return 1 + (rest + nextCapacity - 1) / nextCapacity
    }

    /// `MIDICIPropertyChunk.make`, with its refusal wrapped as `chunk`. `count` and `number` are at most 16,383.
    private static func makeChunk(
        requestID: UInt8, headerData: [UInt8], count: Int, number: Int, propertyData: [UInt8]
    ) throws(MIDICIPropertyChunkingRefusal) -> MIDICIPropertyChunk {
        do throws(MIDICIRefusal) {
            return try MIDICIPropertyChunk.make(
                requestID: requestID, headerData: headerData, chunkCount: UInt16(count), chunkNumber: UInt16(number),
                propertyData: propertyData)
        } catch {
            throw .chunk(error)
        }
    }
}
