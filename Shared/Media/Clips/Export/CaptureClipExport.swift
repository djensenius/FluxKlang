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
/// The clip's tick scale is the log's musical ticks (`MusicalTime.ticksPerQuarter`, 15,360 per quarter) and the
/// file carries no tempo event, so a position needs no tempo map and §9.3's `syntheticTempoMap` (an event without a
/// musical stamp) cannot occur: `make` refuses such captures. Rounding capture positions to ticks is declared as
/// `.timingQuantized` with its count, and captures of later passes, which the file lays on the same tick line as the
/// earliest pass, as `.passesOverlaid`.
struct CaptureClipExport: Equatable, Sendable {
    private(set) var clip: MIDIClip
    /// Every selected capture the file does not contain: all that are not MIDI 1 channel voice (MT 0x2), MIDI 2
    /// channel voice (MT 0x4) and SysEx (MT 0x3) included. §9.3 counts MT 0x3 and OS-upscaled MT 0x4 as lossless and
    /// splits genuine MT 0x4 by opcode, because it assumes they are written; this export drops them, so they are all
    /// counted here until #584 converts them and the per-event counts follow.
    private(set) var droppedUMPOnly: Int
    /// Note Offs (or velocity-0 Note Ons) with no open note, dropped.
    private(set) var unpairedOffs: Int
    /// Notes still open at the end, closed at the clip length.
    private(set) var openNotesClosed: Int
    /// Zero-length notes, widened by one tick.
    private(set) var widenedNotes: Int
    /// Selected captures outside the lowest group when the selection spans more than one group. Counted over every
    /// selected capture, those dropped as UMP-only included, and only for types that carry a group; pairing stays
    /// keyed by (channel, note), so an off of one group can close a note of another.
    private(set) var groupsFlattened: Int
    /// Selected captures, UMP-only ones included, whose musical ticks map back to another frame than the one they
    /// were captured at (or whose map-back is unknown): the export's positions are rounded to ticks.
    private(set) var timingQuantized: Int
    /// Selected captures, UMP-only ones included, in a later pass than the earliest selected capture's (§9.3): a pass
    /// is a loop iteration or the span after a locate or transport restart, and a clock restart continues its pass.
    /// Each such capture counts, not each pass; the file puts all of them on one tick line.
    private(set) var passesOverlaid: Int

    private init(clip: MIDIClip, droppedUMPOnly: Int, pairing: CaptureNotePairing, groupsFlattened: Int,
                 timingQuantized: Int, passesOverlaid: Int) {
        self.clip = clip
        self.droppedUMPOnly = droppedUMPOnly
        unpairedOffs = pairing.unpairedOffs
        openNotesClosed = pairing.openNotesClosed
        widenedNotes = pairing.widenedNotes
        self.timingQuantized = timingQuantized
        self.groupsFlattened = groupsFlattened
        self.passesOverlaid = passesOverlaid
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
    }

    /// Exports the captures of `streams`. `lengthTicks` is the clip length in `1...MIDIClip.maximumLengthTicks`, or
    /// nil for the next quarter boundary strictly after the last MIDI 1 channel-voice capture (one quarter at least);
    /// that default is taken from the selected MT 0x2 captures and checked before any of them is decoded. Messages
    /// merge by (ticks, stream id by UTF-8 bytes ascending, record index), so the order of `streams` never matters.
    /// The refusal order is that of `CaptureClipExportRefusal`. Nothing in `log` changes.
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
        let requested = try resolvedLength(lengthTicks, records)
        let conversion = try convert(records)
        guard let length = requested, !conversion.messages.isEmpty else {
            throw .nothingExportable(dropped: conversion.dropped)
        }
        let converted = conversion.messages.sorted { $0.precedes($1) }
        let timed = converted.map { CaptureTimedMessage(ticks: $0.ticks, message: $0.message) }
        let pairing = try CaptureNotePairing.pair(timed, lengthTicks: length)
        let clip: MIDIClip
        do throws(MIDIClipRefusal) {
            clip = try MIDIClip.make(lengthTicks: length, items: pairing.items)
        } catch {
            throw .clip(error)
        }
        return CaptureClipExport(clip: clip, droppedUMPOnly: conversion.dropped, pairing: pairing,
                                 groupsFlattened: groupsFlattened(in: records),
                                 timingQuantized: timingQuantized(in: records),
                                 passesOverlaid: passesOverlaid(in: records))
    }

    /// The explicit length, checked; or, when nil, the default length of the selected MT 0x2 captures (decodable or
    /// not), nil when there is none so that `nothingExportable` reports.
    private static func resolvedLength(_ lengthTicks: Int64?,
                                       _ records: [Selected]) throws(CaptureClipExportRefusal) -> Int64? {
        if let lengthTicks {
            guard (1...MIDIClip.maximumLengthTicks).contains(lengthTicks) else { throw .lengthOutOfRange(lengthTicks) }
            return lengthTicks
        }
        let voice = records.filter { $0.record.packet.messageType == .midi1ChannelVoice }
        guard !voice.isEmpty else { return nil }
        return try defaultLength(lastTicks: voice.reduce(0) { max($0, $1.ticks) })
    }

    /// The captures whose ticks map back to another frame than the captured one. A nil round trip (the map-back
    /// overflowed) can never equal the frame, so it counts.
    private static func timingQuantized(in records: [Selected]) -> Int {
        records.count { $0.record.musicalRoundTripFrame != $0.record.sample.frame }
    }

    /// The captures in a pass above the lowest pass of the selection, as the media contract's checker counts
    /// `passesOverlaid`: all selected captures, whether or not the file holds them, each one counted.
    private static func passesOverlaid(in records: [Selected]) -> Int {
        let passes = records.compactMap(\.record.pass)
        guard let lowest = passes.min() else { return 0 }
        return passes.count { $0 > lowest }
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

    /// The file for `clip`, written by `StandardMIDIFile.write`, with the losses of this export: `umpOnlyDropped`
    /// for every selected capture the file lacks, `groupsFlattened` when the selection spans groups,
    /// `passesOverlaid` for the captures of later passes and `timingQuantized` (added to whatever the writer
    /// reported) when capture positions were rounded to ticks. No tempo event is written, so `syntheticTempoMap` is
    /// never reported, and `fidelityUnverified` is not either: it qualifies converted MT 0x4 events and none are
    /// converted. Unpaired Note Offs, closed open notes and widened notes are counted on this value, not as §9.3
    /// categories.
    func smf() -> SMFWriteResult {
        let written = StandardMIDIFile.write(clip)
        var losses = written.losses.losses
        if droppedUMPOnly > 0 { losses[.umpOnlyDropped] = droppedUMPOnly }
        if groupsFlattened > 0 { losses[.groupsFlattened] = groupsFlattened }
        if passesOverlaid > 0 { losses[.passesOverlaid] = passesOverlaid }
        if timingQuantized > 0 { losses[.timingQuantized, default: 0] += timingQuantized }
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
