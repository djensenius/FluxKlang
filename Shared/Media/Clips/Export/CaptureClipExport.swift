//
//  CaptureClipExport.swift
//  FluxKlang
//
//  Converts the MIDI 1 channel-voice captures of a `MIDICaptureLog` into a validated `MIDIClip` and, through the
//  existing `StandardMIDIFile.write`, into a Standard MIDI File (#112 CL5, media-contract.md §9.3). Captures that
//  are not MIDI 1 channel voice are counted, never silently skipped; this slice translates no MIDI 2 data.
//

/// A clip converted from captures, with what the conversion counted. Built only by `make`.
///
/// The clip's tick scale is the log's musical ticks (`MusicalTime.ticksPerQuarter`, 15,360 per quarter) and its
/// tempo is synthetic: the file carries no tempo, so `smf()` always reports `.syntheticTempoMap`.
struct CaptureClipExport: Equatable, Sendable {
    private(set) var clip: MIDIClip
    /// Selected captures that are not MIDI 1 channel voice (MIDI 2 channel voice and every other message type).
    private(set) var droppedUMPOnly: Int
    /// Note Offs (or velocity-0 Note Ons) with no open note, dropped.
    private(set) var unpairedOffs: Int
    /// Notes still open at the end, closed at the clip length.
    private(set) var openNotesClosed: Int
    /// Zero-length notes, widened by one tick.
    private(set) var widenedNotes: Int
    /// True when any selected capture has an unknown endpoint protocol or was translated by the OS.
    private(set) var fidelityUnverified: Bool
    /// Selected captures outside the lowest group when the selection spans more than one group. Counted over every
    /// selected capture, those dropped as UMP-only included, and only for types that carry a group; pairing stays
    /// keyed by (channel, note), so an off of one group can close a note of another.
    private(set) var groupsFlattened: Int

    private init(clip: MIDIClip, droppedUMPOnly: Int, pairing: CaptureNotePairing, fidelityUnverified: Bool,
                 groupsFlattened: Int) {
        self.clip = clip
        self.droppedUMPOnly = droppedUMPOnly
        unpairedOffs = pairing.unpairedOffs
        openNotesClosed = pairing.openNotesClosed
        widenedNotes = pairing.widenedNotes
        self.fidelityUnverified = fidelityUnverified
        self.groupsFlattened = groupsFlattened
    }

    /// One selected capture with its musical ticks.
    private struct Selected {
        let index: Int
        let record: MIDICaptureRecord
        let ticks: Int64
    }

    /// One selected MIDI 1 channel-voice capture, ready to merge.
    private struct Converted {
        let ticks: Int64
        let stream: StreamID
        let index: Int
        let message: MIDI1Semantic

        func precedes(_ other: Converted) -> Bool {
            if ticks != other.ticks { return ticks < other.ticks }
            if stream != other.stream {
                return stream.rawValue.utf8.lexicographicallyPrecedes(other.stream.rawValue.utf8)
            }
            return index < other.index
        }
    }

    /// What conversion made of the selected captures.
    private struct Conversion {
        var messages: [Converted] = []
        var dropped = 0
        var unverified = false
    }

    /// Exports the captures of `streams`. `lengthTicks` is the clip length in `1...MIDIClip.maximumLengthTicks`, or
    /// nil for the next quarter boundary strictly after the last message (one quarter at least). Messages merge by
    /// (ticks, stream id by UTF-8 bytes ascending, record index), so the order of `streams` never matters. The
    /// refusal order is that of `CaptureClipExportRefusal`. Nothing in `log` changes.
    static func make(from log: MIDICaptureLog, streams: [StreamID],
                     lengthTicks: Int64?) throws(CaptureClipExportRefusal) -> CaptureClipExport {
        let selected = try select(streams, in: log)
        var records: [Selected] = []
        var firstUntimed: Selected?
        for (index, record) in log.records.enumerated() where selected.contains(record.stream) {
            guard let ticks = record.musicalTicks else {
                firstUntimed = firstUntimed ?? Selected(index: index, record: record, ticks: 0)
                continue
            }
            records.append(Selected(index: index, record: record, ticks: ticks))
        }
        if let untimed = firstUntimed {
            throw .noMusicalTime(stream: untimed.record.stream, index: untimed.index)
        }
        guard !records.isEmpty else { throw .capture(.exportHasNoCaptures) }
        if let lengthTicks, !(1...MIDIClip.maximumLengthTicks).contains(lengthTicks) {
            throw .lengthOutOfRange(lengthTicks)
        }
        let conversion = try convert(records)
        guard !conversion.messages.isEmpty else { throw .nothingExportable(dropped: conversion.dropped) }
        let converted = conversion.messages.sorted { $0.precedes($1) }
        let length: Int64
        if let lengthTicks {
            length = lengthTicks
        } else {
            length = try defaultLength(lastTicks: converted.reduce(0) { max($0, $1.ticks) })
        }
        let timed = converted.map { CaptureTimedMessage(ticks: $0.ticks, message: $0.message) }
        let pairing = try CaptureNotePairing.pair(timed, lengthTicks: length)
        let clip: MIDIClip
        do throws(MIDIClipRefusal) {
            clip = try MIDIClip.make(lengthTicks: length, items: pairing.items)
        } catch {
            throw .clip(error)
        }
        return CaptureClipExport(clip: clip, droppedUMPOnly: conversion.dropped, pairing: pairing,
                                 fidelityUnverified: conversion.unverified,
                                 groupsFlattened: groupsFlattened(in: records))
    }

    /// The group count of the media contract's `groupsFlattened`: the selected captures whose type carries a group
    /// (system, MIDI 1 and MIDI 2 channel voice, both data types and flex data), outside the lowest group seen,
    /// when more than one group is seen. Utility, stream and reserved types have no group and never count.
    private static func groupsFlattened(in records: [Selected]) -> Int {
        let groups = records.compactMap { $0.record.packet.group?.value }
        guard let lowest = groups.min() else { return 0 }
        return groups.count { $0 != lowest }
    }

    /// Decodes the MIDI 1 channel-voice captures and counts the rest, in capture order.
    private static func convert(_ records: [Selected]) throws(CaptureClipExportRefusal) -> Conversion {
        var conversion = Conversion()
        for item in records {
            let stamp = item.record.protocolStamp
            if !stamp.verified || stamp.translatedByOS { conversion.unverified = true }
            guard item.record.packet.messageType == .midi1ChannelVoice else {
                conversion.dropped += 1
                continue
            }
            let message: MIDI1Semantic
            do throws(UMPRefusal) {
                message = try UMPMIDI1ChannelVoice(decoding: item.record.packet).semantic
            } catch {
                throw .invalidChannelVoice(stream: item.record.stream, index: item.index, error)
            }
            conversion.messages.append(Converted(ticks: item.ticks, stream: item.record.stream, index: item.index,
                                                 message: message))
        }
        return conversion
    }

    /// The file for `clip`, written by `StandardMIDIFile.write`, with the losses of this export: the synthetic tempo
    /// map always, `umpOnlyDropped` for the dropped captures, `fidelityUnverified` when flagged and `groupsFlattened`
    /// when the selection spans groups. Unpaired Note Offs, closed open notes and widened notes are counted on this
    /// value, not as §9.3 categories.
    func smf() -> SMFWriteResult {
        let written = StandardMIDIFile.write(clip)
        var losses = written.losses.losses
        losses[.syntheticTempoMap] = 1
        if droppedUMPOnly > 0 { losses[.umpOnlyDropped] = droppedUMPOnly }
        if fidelityUnverified { losses[.fidelityUnverified] = 1 }
        if groupsFlattened > 0 { losses[.groupsFlattened] = groupsFlattened }
        return SMFWriteResult(bytes: written.bytes, losses: SMFExportLossReport(losses: losses),
                              reorderedItems: written.reorderedItems)
    }

    /// The distinct declared, untainted streams of an export.
    private static func select(_ streams: [StreamID],
                               in log: MIDICaptureLog) throws(CaptureClipExportRefusal) -> Set<StreamID> {
        guard !streams.isEmpty else { throw .capture(.exportStreamsEmpty) }
        guard streams.count <= MIDICaptureLog.maximumStreams else {
            throw .tooManyStreams(count: streams.count, limit: MIDICaptureLog.maximumStreams)
        }
        var selected = Set<StreamID>()
        for stream in streams where !selected.insert(stream).inserted {
            throw .capture(.exportStreamsDuplicate(stream))
        }
        let declared = Set(log.streams)
        for stream in streams where !declared.contains(stream) {
            throw .capture(.undeclaredStream(stream))
        }
        for stream in streams {
            switch log.taints[stream] {
            case .unsupportedCapture: throw .capture(.containsUnsupportedCapture(stream: stream))
            case .refusedAtCapacity: throw .capture(.captureRefusedAtCapacity(stream: stream))
            case nil: break
            }
        }
        return selected
    }

    /// The first quarter boundary strictly after `lastTicks` (so the last message lies inside the clip), at least
    /// one quarter; refused when it is beyond `MIDIClip.maximumLengthTicks`. `lastTicks` is never negative, so the
    /// quarter count cannot overflow on its own; only its product with a quarter can, which is reported as
    /// `Int64.max`.
    private static func defaultLength(lastTicks: Int64) throws(CaptureClipExportRefusal) -> Int64 {
        let quarter = MusicalTime.ticksPerQuarter
        let quarters = lastTicks / quarter + 1
        let (length, mulOverflow) = quarters.multipliedReportingOverflow(by: quarter)
        guard !mulOverflow else { throw .lengthOutOfRange(Int64.max) }
        guard length <= MIDIClip.maximumLengthTicks else { throw .lengthOutOfRange(length) }
        return length
    }
}
