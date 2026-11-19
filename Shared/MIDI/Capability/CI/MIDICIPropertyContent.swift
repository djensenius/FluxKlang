//
//  MIDICIPropertyContent.swift
//  FluxKlang
//
//  The content of one reassembled MIDI-CI Property Exchange message (#83, slice M83-PXD, issue #828): its header data
//  parsed and its property data decoded by the encoding that header names. A pure, bounded composition of
//  `MIDICIPropertyHeader.parse(_:)` and `MIDICIPropertyHeader.decodeBody(_:)`, including bounded system zlib (#858).
//  Nothing calls it yet.
//
//  Provenance: the Property Exchange specifications (M2-102-UM, the Common Rules, and M2-103-UM, the resources) were
//  not read. That Get Inquiry and Set Reply carry no property data is `MIDICIPropertyDataKind.hasNoPropertyData`
//  (M2-101-UM v1.2, Tables 33 and 36). Refusing such data on receive, which the codec and the reassembler keep, is
//  this decoder's own fail-closed choice. #846 extends that local receive-content policy: those kinds must have
//  a completed chunk count of one. This is compatibility tightening, not a normative receiver requirement;
//  codec receive leniency and reassembler admission are unchanged. See
//  `docs/transformation/midi-property-content-chunk-count.md`.
//  Rules that depend on the kind for the header data (a resource in an inquiry, a
//  status in a reply) are not checked. That a sender codes the whole body before cutting it into chunks is assumed,
//  as `MIDICIPropertyBody` already does; it was not checked against M2-102.
//

/// One complete Property Exchange message with its header data parsed and its property data decoded: the kind, the
/// MIDI-CI header and the request id of the `MIDICIPropertyReassembly`, the typed header data and the decoded body.
struct MIDICIPropertyContent: Equatable, Hashable, Sendable {
    let kind: MIDICIPropertyDataKind
    let header: MIDICIHeader
    let requestID: UInt8
    /// The parsed header data. For a kind without property data its `encoding` is reported but was not applied.
    let propertyHeader: MIDICIPropertyHeader
    /// The property data decoded by `propertyHeader.encoding`, not checked as JSON or as text. Empty for a kind
    /// without property data (`MIDICIPropertyDataKind.hasNoPropertyData`).
    let body: [UInt8]

    /// Decodes a reassembled message. It refuses, in this order:
    /// 1. property data in a kind without it (Get Inquiry and Set Reply), as `propertyDataNotAllowed`, before reading
    ///    any byte;
    /// 2. a chunk count other than one for those same kinds, as `singleChunkRequired`;
    /// 3. header data that `MIDICIPropertyHeader.parse(_:)` refuses, as `header` with that refusal unchanged (empty
    ///    header data is `unexpectedEnd(offset: 0)`);
    /// 4. property data that `MIDICIPropertyHeader.decodeBody(_:)` refuses, as `body` with that refusal unchanged.
    /// Other kinds acquire no count validation here, including for directly constructed reassemblies.
    ///
    /// The header data is parsed once and the property data is decoded once, after reassembly, so a Mcoded7 group may
    /// span chunks (assuming the body was coded before it was chunked; see the provenance above). A kind without
    /// property data has no body to decode, so the encoding its header names is not applied, and `zlib+Mcoded7` or an
    /// unknown name is not refused there.
    static func decode(
        _ reassembly: MIDICIPropertyReassembly
    ) throws(MIDICIPropertyContentRefusal) -> MIDICIPropertyContent {
        let kind = reassembly.kind
        if kind.hasNoPropertyData && !reassembly.propertyData.isEmpty {
            throw .propertyDataNotAllowed(kind: kind, count: reassembly.propertyData.count)
        }
        if kind.hasNoPropertyData && reassembly.chunkCount != 1 {
            throw .singleChunkRequired(kind: kind, chunkCount: reassembly.chunkCount)
        }
        let propertyHeader: MIDICIPropertyHeader
        do throws(MIDICIPropertyHeaderRefusal) {
            propertyHeader = try MIDICIPropertyHeader.parse(reassembly.headerData)
        } catch {
            throw .header(error)
        }
        var body: [UInt8] = []
        if !kind.hasNoPropertyData {
            do throws(MIDICIPropertyBodyRefusal) {
                body = try propertyHeader.decodeBody(reassembly.propertyData)
            } catch {
                throw .body(error)
            }
        }
        return MIDICIPropertyContent(
            kind: kind, header: reassembly.header, requestID: reassembly.requestID, propertyHeader: propertyHeader,
            body: body)
    }
}
