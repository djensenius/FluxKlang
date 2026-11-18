//
//  MIDICIPropertyReassembler.swift
//  FluxKlang
//
//  Bounded, caller-driven reassembly of multi-chunk MIDI-CI Property Exchange data messages (#83, slice M83-PX1,
//  issue #802). Nothing calls it yet.
//

/// Why `MIDICIPropertyReassembler` refused a factory limit or a chunk. The cases of `accept(_:)` are listed in the
/// order it checks them; any refusal that concerns an open request has already dropped that request.
enum MIDICIPropertyReassemblyRefusal: Error, Equatable, Hashable, Sendable {
    /// The limit `make` refuses.
    enum Limit: Equatable, Hashable, Sendable {
        case openRequests, chunks, propertyBytes
    }

    /// A factory limit outside its hard ceiling.
    case limitOutOfRange(Limit, value: Int)
    /// 1. A chunk count of 0 (unknown, streamed length): not supported here.
    case unknownChunkCount
    /// 2. A chunk number of 0: the sender abandoned the request (Table 29, the final chunk of bad data).
    case senderAbort
    /// 3. A chunk number of 2 or more with no open request for its source and request id.
    case noOpenRequest(chunkNumber: UInt16)
    /// 4. Chunk 1 for a source and request id that is already open.
    case alreadyOpen
    /// 5. Not the next chunk: a duplicate, a gap or a step back.
    case outOfOrder(expected: UInt16, got: UInt16)
    /// 6. The chunk count differs from the one chunk 1 declared.
    case chunkCountChanged(expected: UInt16, got: UInt16)
    /// 7. The message kind differs from chunk 1's.
    case kindChanged(expected: MIDICIPropertyDataKind, got: MIDICIPropertyDataKind)
    /// 8. Header data in a chunk after chunk 1.
    case headerAfterFirstChunk(chunkNumber: UInt16)
    /// 9. A chunk number above the chunk count. A defensive guard: checks 3 and 5 refuse every such chunk first.
    case chunkNumberAboveCount(number: UInt16, count: UInt16)
    /// 10. Chunk 1 declares more chunks than `maximumChunks`.
    case tooManyChunks(count: UInt16, limit: Int)
    /// 11. The property data so far would exceed `maximumPropertyBytes`.
    case tooManyBytes(total: Int, limit: Int)
    /// 12. Opening the request would exceed `maximumOpenRequests`; the other open requests are kept.
    case tooManyOpenRequests(limit: Int)
}

/// One complete Property Exchange message: chunk 1's kind, MIDI-CI header, request id and header data, and the
/// property data of every chunk concatenated in chunk order. The bytes are as received (still Mcoded7 or zlib coded
/// if the header says so, and the header data is unparsed JSON).
struct MIDICIPropertyReassembly: Equatable, Sendable {
    let kind: MIDICIPropertyDataKind
    let header: MIDICIHeader
    let requestID: UInt8
    let headerData: [UInt8]
    let propertyData: [UInt8]
}

/// Reassembles the chunks of Property Exchange data messages (M2-101-UM v1.2, section 8 and Table 29) into one
/// `MIDICIPropertyReassembly`. Pure: no timers, no I/O, no clock. Requests are keyed by source MUID and request id.
/// A message of chunk 1 of 1 completes at once and never takes a slot; otherwise chunk 1 opens a slot, chunks
/// 2...count must follow in order, and the last one frees the slot and returns the result. The outbound inverse,
/// which cuts one message into such chunks, is `MIDICIPropertyChunker`.
///
/// The rules are conservative because the Common Rules for Property Exchange (M2-102) and Mcoded7 (M2-103) were not
/// available: chunks must arrive strictly in order, the chunk count, the kind and the absence of header data after
/// chunk 1 must hold, and any violation drops the open request (fail closed). A chunk count of 0 (unknown, streamed)
/// is refused, not supported. The kinds whose tables fix one chunk with no property data (`hasNoPropertyData`:
/// Get Inquiry and Set Reply) are not special-cased: chunk 1 of 1 passes through like any single chunk, and the
/// content rules for them stay with `MIDICIPropertyDataMessage.encode` (the codec's decoder is lenient on receive).
/// On receive, `MIDICIPropertyContent.decode(_:)` refuses their property data (fail closed); neither type checks
/// their chunk count.
///
/// Bounds: at most `maximumOpenRequests` open requests, `maximumChunks` declared chunks and `maximumPropertyBytes`
/// of property data per request; a value exactly at a limit is accepted. Nothing expires on its own: the caller
/// applies its own timeout or MUID invalidation through `discard(source:requestID:)` and `discardAll(source:)`.
struct MIDICIPropertyReassembler: Sendable {
    static let openRequestsCeiling = 127
    static let chunksCeiling = 256
    static let propertyBytesCeiling = 262_144

    private struct Key: Hashable, Sendable {
        let source: MIDICIMUID
        let requestID: UInt8
    }

    private struct Entry: Sendable {
        let kind: MIDICIPropertyDataKind
        let header: MIDICIHeader
        let headerData: [UInt8]
        let chunkCount: UInt16
        var next: UInt16
        var propertyData: [UInt8]
    }

    let maximumOpenRequests: Int
    let maximumChunks: Int
    let maximumPropertyBytes: Int
    private var open: [Key: Entry] = [:]

    var openCount: Int { open.count }

    private init(maximumOpenRequests: Int, maximumChunks: Int, maximumPropertyBytes: Int) {
        self.maximumOpenRequests = maximumOpenRequests
        self.maximumChunks = maximumChunks
        self.maximumPropertyBytes = maximumPropertyBytes
    }

    /// Refuses, in this order, each limit outside its hard ceiling: 1...127 open requests, 1...256 chunks and
    /// 1...262,144 property bytes.
    static func make(
        maximumOpenRequests: Int = 8, maximumChunks: Int = 64, maximumPropertyBytes: Int = 65_536
    ) throws(MIDICIPropertyReassemblyRefusal) -> MIDICIPropertyReassembler {
        guard (1...openRequestsCeiling).contains(maximumOpenRequests) else {
            throw .limitOutOfRange(.openRequests, value: maximumOpenRequests)
        }
        guard (1...chunksCeiling).contains(maximumChunks) else {
            throw .limitOutOfRange(.chunks, value: maximumChunks)
        }
        guard (1...propertyBytesCeiling).contains(maximumPropertyBytes) else {
            throw .limitOutOfRange(.propertyBytes, value: maximumPropertyBytes)
        }
        return MIDICIPropertyReassembler(
            maximumOpenRequests: maximumOpenRequests, maximumChunks: maximumChunks,
            maximumPropertyBytes: maximumPropertyBytes)
    }

    /// The complete message once its last chunk arrives, nil while chunks are pending. Refuses in the order of
    /// `MIDICIPropertyReassemblyRefusal` (1 to 12); a refusal drops the open request it concerns, except
    /// `tooManyOpenRequests`, which concerns a request that never opened.
    mutating func accept(
        _ message: MIDICIPropertyDataMessage
    ) throws(MIDICIPropertyReassemblyRefusal) -> MIDICIPropertyReassembly? {
        let chunk = message.chunk
        let key = Key(source: message.header.source, requestID: chunk.requestID)
        guard chunk.chunkCount != 0 else { throw drop(key, .unknownChunkCount) }
        guard chunk.chunkNumber != 0 else { throw drop(key, .senderAbort) }
        guard let entry = open[key] else {
            guard chunk.chunkNumber == 1 else { throw .noOpenRequest(chunkNumber: chunk.chunkNumber) }
            return try first(message, key: key)
        }
        return try following(message, entry: entry, key: key)
    }

    /// A chunk for an open request: refusals 4 to 9 and 11, each dropping it; the last chunk completes it.
    private mutating func following(
        _ message: MIDICIPropertyDataMessage, entry: Entry, key: Key
    ) throws(MIDICIPropertyReassemblyRefusal) -> MIDICIPropertyReassembly? {
        var entry = entry
        let chunk = message.chunk
        let number = chunk.chunkNumber
        let count = chunk.chunkCount
        guard number != 1 else { throw drop(key, .alreadyOpen) }
        guard number == entry.next else { throw drop(key, .outOfOrder(expected: entry.next, got: number)) }
        guard count == entry.chunkCount else {
            throw drop(key, .chunkCountChanged(expected: entry.chunkCount, got: count))
        }
        guard message.kind == entry.kind else {
            throw drop(key, .kindChanged(expected: entry.kind, got: message.kind))
        }
        guard chunk.headerData.isEmpty else { throw drop(key, .headerAfterFirstChunk(chunkNumber: number)) }
        guard number <= count else { throw drop(key, .chunkNumberAboveCount(number: number, count: count)) }
        let total = entry.propertyData.count + chunk.propertyData.count
        if total > maximumPropertyBytes { throw drop(key, .tooManyBytes(total: total, limit: maximumPropertyBytes)) }
        entry.propertyData.append(contentsOf: chunk.propertyData)
        guard number == count else {
            entry.next = number + 1
            open[key] = entry
            return nil
        }
        open[key] = nil
        return MIDICIPropertyReassembly(
            kind: entry.kind, header: entry.header, requestID: chunk.requestID, headerData: entry.headerData,
            propertyData: entry.propertyData)
    }

    /// Drops the open request of `source` and `requestID`; true if there was one.
    mutating func discard(source: MIDICIMUID, requestID: UInt8) -> Bool {
        open.removeValue(forKey: Key(source: source, requestID: requestID)) != nil
    }

    /// Drops every open request of `source`; returns how many there were.
    mutating func discardAll(source: MIDICIMUID) -> Int {
        let before = open.count
        open = open.filter { $0.key.source != source }
        return before - open.count
    }

    /// Chunk 1 with no open request: completes at once when it is 1 of 1, else opens a slot.
    private mutating func first(
        _ message: MIDICIPropertyDataMessage, key: Key
    ) throws(MIDICIPropertyReassemblyRefusal) -> MIDICIPropertyReassembly? {
        let chunk = message.chunk
        if Int(chunk.chunkCount) > maximumChunks { throw .tooManyChunks(count: chunk.chunkCount, limit: maximumChunks) }
        if chunk.propertyData.count > maximumPropertyBytes {
            throw .tooManyBytes(total: chunk.propertyData.count, limit: maximumPropertyBytes)
        }
        guard chunk.chunkCount > 1 else {
            return MIDICIPropertyReassembly(
                kind: message.kind, header: message.header, requestID: chunk.requestID, headerData: chunk.headerData,
                propertyData: chunk.propertyData)
        }
        if open.count + 1 > maximumOpenRequests { throw .tooManyOpenRequests(limit: maximumOpenRequests) }
        open[key] = Entry(
            kind: message.kind, header: message.header, headerData: chunk.headerData, chunkCount: chunk.chunkCount,
            next: 2, propertyData: chunk.propertyData)
        return nil
    }

    /// Removes the open request of `key`, if any, and returns `refusal` for the caller to throw.
    private mutating func drop(
        _ key: Key, _ refusal: MIDICIPropertyReassemblyRefusal
    ) -> MIDICIPropertyReassemblyRefusal {
        open[key] = nil
        return refusal
    }
}
