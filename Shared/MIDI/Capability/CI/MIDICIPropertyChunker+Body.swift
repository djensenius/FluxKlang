//
//  MIDICIPropertyChunker+Body.swift
//  FluxKlang
//
//  Raw-body preparation for the existing pure outbound chunker (#865, part of #83/#48).
//  RFC1950 compression -> whole-body Mcoded7 -> greedy chunks is ratified LOCAL policy, not
//  specification verification or peer qualification. No sender, transport or application adoption.
//

import zlib

extension MIDICIPropertyChunker {
    private static let rawBodyCeiling = 262_144
    private static let encodedBodyCeiling = 262_144
    // Fixed for every compression call, not sized by input or grown on failure. The extra 1 KiB allows
    // wrapper/block overhead at the raw ceiling; compressBound is checked before using this storage.
    private static let compressionCapacity = 263_168

    /// Prepares ORIGINAL body bytes and delegates to the existing encoded-byte `chunks` overload.
    /// Refusal order: forbidden nonempty raw body -> raw ceiling -> header parser ->
    /// encoding/compression/encoded ceiling -> existing chunker. Both byte ceilings are inclusive.
    ///
    /// Header parsing selects encoding only: the caller's original header bytes (including unknown values
    /// discarded by the parser) go unchanged to the chunker. ASCII reuses the existing byte validator.
    /// Get Inquiry and Set Reply skip encoding of an empty raw body, even for unknown names; header parsing
    /// and downstream chunker checks still run. Other kinds encode empty bodies normally.
    ///
    /// This pure preparation returns messages, not wire emission or sender authority. Addressing validation
    /// remains in message `encode(limits:)`. The chunker's 16,383-count policy is not reduced to the
    /// reassembler's independent 256-count policy. SDK allocation and Swift arrays are not realtime-safe
    /// or whole-operation allocation-free. Compressed bytes need not be identical across SDK versions.
    static func chunks( // swiftlint:disable:this function_parameter_count
        _ kind: MIDICIPropertyDataKind, header: MIDICIHeader, requestID: UInt8, headerData: [UInt8],
        rawBody: [UInt8], limits: MIDICILimits
    ) throws(MIDICIPropertyPreparationRefusal) -> [MIDICIPropertyDataMessage] {
        if kind.hasNoPropertyData && !rawBody.isEmpty {
            throw .rawBodyNotAllowed(kind: kind, count: rawBody.count)
        }
        guard rawBody.count <= rawBodyCeiling else {
            throw .rawBodyTooLong(count: rawBody.count, limit: rawBodyCeiling)
        }
        let propertyHeader: MIDICIPropertyHeader
        do throws(MIDICIPropertyHeaderRefusal) {
            propertyHeader = try MIDICIPropertyHeader.parse(headerData)
        } catch {
            throw .header(error)
        }
        let encoded = try kind.hasNoPropertyData ? [] : encodeRawBody(rawBody, encoding: propertyHeader.encoding)
        do throws(MIDICIPropertyChunkingRefusal) {
            return try chunks(
                kind, header: header, requestID: requestID, headerData: headerData,
                propertyData: encoded, limits: limits)
        } catch {
            throw .chunking(error)
        }
    }

    private static func encodeRawBody(
        _ raw: [UInt8], encoding: MIDICIPropertyEncoding
    ) throws(MIDICIPropertyPreparationRefusal) -> [UInt8] {
        switch encoding {
        case .ascii:
            do throws(MIDICIPropertyBodyRefusal) {
                // ASCII is identical in both directions: preserve all control bytes and DEL.
                return try MIDICIPropertyBody.decode(raw, encoding: .ascii)
            } catch {
                throw .body(error)
            }
        case .mcoded7:
            try checkPackedBodySize(raw.count)
            return MIDICIMcoded7.encode(raw)
        case .zlibMcoded7:
            return MIDICIMcoded7.encode(try compressRawBody(raw))
        case .other:
            throw .body(.unsupportedEncoding(encoding))
        }
    }

    /// n + ceil(n / 7), including zero. All callers already bound n to rawBodyCeiling or compressionCapacity,
    /// so this arithmetic cannot overflow. At 262,144 encoded bytes, at most 229,376 prepacking bytes fit.
    private static func checkPackedBodySize(_ count: Int) throws(MIDICIPropertyPreparationRefusal) {
        let packedCount = count + (count + 6) / 7
        guard packedCount <= encodedBodyCeiling else {
            throw .encodedBodyTooLong(count: packedCount, limit: encodedBodyCeiling)
        }
    }

    /// One RFC1950 stream from one compress2 call. The installed SDK's zlib.h requires capacity at least
    /// compressBound(sourceLen) and documents Z_OK for complete success. Check the bound before allocation;
    /// any SDK failure discards output, with no dictionary, fallback, retry or partial return.
    private static func compressRawBody(_ raw: [UInt8]) throws(MIDICIPropertyPreparationRefusal) -> [UInt8] {
        guard compressBound(uLong(raw.count)) <= uLong(compressionCapacity) else { throw .compressionFailed }
        var output = [UInt8](repeating: 0, count: compressionCapacity)
        var produced = uLongf(output.count)
        // Supply a valid pointer even for an empty body, but keep sourceLen zero. Never pass a null source.
        let source = raw.isEmpty ? [UInt8(0)] : raw
        let status = source.withUnsafeBufferPointer { input in
            output.withUnsafeMutableBufferPointer { destination in
                compress2(
                    destination.baseAddress, &produced, input.baseAddress, uLong(raw.count), Z_DEFAULT_COMPRESSION)
            }
        }
        guard status == Z_OK, produced <= compressionCapacity else { throw .compressionFailed }
        try checkPackedBodySize(Int(produced))
        return Array(output.prefix(Int(produced)))
    }
}
