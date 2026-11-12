//
//  CaptureClipExport.swift
//  FluxKlang
//
//  Converts the MIDI 1 channel-voice captures of a `MIDICaptureLog` into a validated `MIDIClip` and, through the
//  existing `StandardMIDIFile.write`, into a Standard MIDI File (#112 CL5, media-contract.md §9.3). The SysEx7
//  (MT 0x3) captures are assembled into messages and written as SysEx events beside the clip (#584 SMF2a). The
//  MIDI 2.0 channel-voice (MT 0x4) captures are translated to MIDI 1 messages (#584 SMF2b-2). Other captures are
//  counted, never silently skipped.
//

/// A clip and SysEx events converted from captures, with what the conversion counted. Built only by `make`.
///
/// The clip's tick scale is the log's musical ticks (`MusicalTime.ticksPerQuarter`, 15,360 per quarter) and the
/// file carries no tempo event, so a position needs no tempo map and §9.3's `syntheticTempoMap` (an event without a
/// musical stamp) cannot occur: `make` refuses such captures. Rounding capture positions to ticks is declared as
/// `.timingQuantized` with its count, and captures of later passes, which the file lays on the same tick line as the
/// earliest pass, as `.passesOverlaid`.
struct CaptureClipExport: Equatable, Sendable {
    private(set) var clip: MIDIClip
    /// The delivered SysEx7 messages, in merge order, written beside the clip, which cannot hold them.
    private(set) var sysEx: [SMFSysExEvent]
    /// The §9.3 losses of the selected captures themselves, summed from `SMFCaptureLossClassifier` over every
    /// selected capture (MT 0x4 included), plus `umpOnlyDropped` for each MT 0x4 capture that translated to no MIDI 1
    /// message and that the classifier counted neither as `perNoteDropped` nor as `umpOnlyDropped`, plus one
    /// `umpOnlyDropped` for each packet of a SysEx message that was aborted, orphaned or never finished. The
    /// translator's own losses are never added: §9.3 has no category for some of them. Opcode 0x7 is refused when
    /// the capture is decoded, so the classifier's branch for it cannot be reached through `make`. Only nonzero
    /// counts are stored.
    private(set) var captureLosses: [SMFExportLoss: Int]
    /// The `umpOnlyDropped` count of `captureLosses`: selected captures of a type other than MT 0x2, 0x3 and 0x4,
    /// the packets of broken SysEx messages, and the MIDI 2.0 captures that translated to nothing (unless counted
    /// as `perNoteDropped`). It is not the number of captures the file lacks.
    var droppedUMPOnly: Int { captureLosses[.umpOnlyDropped] ?? 0 }
    /// Note Offs (or velocity-0 Note Ons) with no open note, dropped.
    private(set) var unpairedOffs: Int
    /// Notes still open at the end, closed at the clip length.
    private(set) var openNotesClosed: Int
    /// Zero-length notes, widened by one tick.
    private(set) var widenedNotes: Int
    /// Notes closed by a later Note On of the same channel and note, release velocity 64. A pairing repair count
    /// like the three above: it is not a loss and is outside `smf().losses` and §9.3.
    private(set) var retriggeredNotes: Int
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

    private init(clip: MIDIClip, sysEx: [SMFSysExEvent], captureLosses: [SMFExportLoss: Int],
                 pairing: CaptureNotePairing, groupsFlattened: Int, timingQuantized: Int, passesOverlaid: Int) {
        self.clip = clip
        self.sysEx = sysEx
        self.captureLosses = captureLosses
        unpairedOffs = pairing.unpairedOffs
        openNotesClosed = pairing.openNotesClosed
        widenedNotes = pairing.widenedNotes
        retriggeredNotes = pairing.retriggeredNotes
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

    /// What conversion made of the selected captures.
    private struct Conversion {
        var queue: [CaptureMergeEntry] = []
        var sysEx: [CaptureSysEx7Message] = []
        /// Selected captures of a type the file never holds (not MT 0x2, 0x3 or 0x4).
        var dropped = 0
        var losses: [SMFExportLoss: Int] = [:]
        /// The group of the first MT 0x4 capture in capture order: the file has no groups, so every MIDI 2.0 voice
        /// is moved to it and the translator keeps its state per channel only.
        var canonicalGroup: UMPGroup?
    }

    /// Exports the captures of `streams`. `lengthTicks` is the clip length in `1...MIDIClip.maximumLengthTicks`, or
    /// nil for the next quarter boundary strictly after the last MIDI 1 channel-voice, SysEx7 or MIDI 2.0
    /// channel-voice capture (one quarter at least); that default is taken from the selected MT 0x2, MT 0x3 and
    /// MT 0x4 captures, decodable or not and delivered or not (so an orphan SysEx packet can lengthen the clip), and
    /// checked before any of them is decoded. MIDI 2.0 voices are translated to MIDI 1 messages with
    /// `UMPMIDI2ToMIDI1Translator` (`CaptureMIDI2Translation`). Messages and voices merge in one queue by (ticks,
    /// stream id by UTF-8 bytes ascending, record index), sorted once and translated in that order, so the order of
    /// `streams` never matters; a SysEx message sits at the tick of its first packet. The refusal order is that of
    /// `CaptureClipExportRefusal`. Nothing in `log` changes.
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
        var conversion = try convert(records)
        let events = conversion.sysEx.sorted { $0.precedes($1) }
        let translation = try CaptureMIDI2Translation.translate(conversion.queue, canonical: conversion.canonicalGroup,
                                                                sysExTicks: events.map(\.ticks))
        guard let length = requested, !translation.messages.isEmpty || !events.isEmpty else {
            throw .nothingExportable(dropped: conversion.dropped + translation.silentVoices)
        }
        if translation.silentUncounted > 0 {
            conversion.losses[.umpOnlyDropped, default: 0] += translation.silentUncounted
        }
        if let late = events.first(where: { $0.ticks >= length }) {
            throw .ticksOutOfRange(ticks: late.ticks, lengthTicks: length)
        }
        let pairing = try CaptureNotePairing.pair(translation.messages, lengthTicks: length, otherItems: events.count)
        let clip: MIDIClip
        do throws(MIDIClipRefusal) {
            clip = try MIDIClip.make(lengthTicks: length, items: pairing.items)
        } catch {
            throw .clip(error)
        }
        return CaptureClipExport(clip: clip, sysEx: events.map { SMFSysExEvent(ticks: $0.ticks, payload: $0.payload) },
                                 captureLosses: conversion.losses, pairing: pairing,
                                 groupsFlattened: groupsFlattened(in: records),
                                 timingQuantized: timingQuantized(in: records),
                                 passesOverlaid: passesOverlaid(in: records))
    }

    /// The explicit length, checked; or, when nil, the default length of the selected MT 0x2, MT 0x3 and MT 0x4
    /// captures (decodable or not, delivered or not), nil when there is none so that `nothingExportable` reports.
    private static func resolvedLength(_ lengthTicks: Int64?,
                                       _ records: [Selected]) throws(CaptureClipExportRefusal) -> Int64? {
        if let lengthTicks {
            guard (1...MIDIClip.maximumLengthTicks).contains(lengthTicks) else { throw .lengthOutOfRange(lengthTicks) }
            return lengthTicks
        }
        let voice = records.filter {
            [.midi1ChannelVoice, .data64, .midi2ChannelVoice].contains($0.record.packet.messageType)
        }
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

    /// Decodes the MIDI 1 and MIDI 2.0 channel-voice captures into one queue, assembles the SysEx7 ones and counts
    /// the rest, in capture order. The classifier's per-capture losses are summed over every selected capture.
    private static func convert(_ records: [Selected]) throws(CaptureClipExportRefusal) -> Conversion {
        var conversion = Conversion()
        var assembler = CaptureSysEx7Assembler()
        for item in records {
            let record = item.record
            let classified = SMFCaptureLossClassifier.losses(of: record.packet, stamp: record.protocolStamp)
            for (loss, count) in classified { conversion.losses[loss, default: 0] += count }
            switch record.packet.messageType {
            case .data64:
                if let message = try accept(item, into: &assembler) { conversion.sysEx.append(message) }
            case .midi1ChannelVoice:
                do throws(UMPRefusal) {
                    let message = try UMPMIDI1ChannelVoice(decoding: record.packet).semantic
                    let resets = try resetChannel(of: message, in: record.packet)
                    conversion.queue.append(CaptureMergeEntry(ticks: item.ticks, stream: record.stream,
                                                              index: item.index,
                                                              content: .midi1(message, resets: resets)))
                } catch {
                    throw .invalidChannelVoice(stream: record.stream, index: item.index, error)
                }
            case .midi2ChannelVoice:
                do throws(UMPRefusal) {
                    conversion.queue.append(try voiceEntry(item, classified: classified, in: &conversion))
                } catch {
                    throw .invalidChannelVoice(stream: record.stream, index: item.index, error)
                }
            default:
                conversion.dropped += 1
            }
        }
        assembler.finish()
        conversion.dropped += assembler.dropped
        if assembler.dropped > 0 { conversion.losses[.umpOnlyDropped, default: 0] += assembler.dropped }
        return conversion
    }

    /// Feeds one SysEx7 capture to the assembler; the message it completes, when it does.
    private static func accept(_ item: Selected,
                               into assembler: inout CaptureSysEx7Assembler) throws(CaptureClipExportRefusal)
        -> CaptureSysEx7Message? {
        let record = item.record
        let packet: UMPSysEx7Packet
        do throws(UMPRefusal) {
            packet = try UMPSysEx7Packet(decoding: record.packet)
        } catch {
            throw .invalidSysEx7(stream: record.stream, index: item.index, error)
        }
        return assembler.accept(packet, stream: record.stream, ticks: item.ticks, index: item.index)
    }

    /// The queue entry of a MIDI 2.0 channel voice capture, flattened to the export's one canonical group (the first
    /// voice's), and whether the classifier already counted it as dropped.
    private static func voiceEntry(_ item: Selected, classified: [SMFExportLoss: Int],
                                   in conversion: inout Conversion) throws(UMPRefusal) -> CaptureMergeEntry {
        let decoded = try UMPMIDI2ChannelVoice(decoding: item.record.packet)
        let group = conversion.canonicalGroup ?? decoded.group
        conversion.canonicalGroup = group
        let voice = UMPMIDI2ChannelVoice(group: group, channel: decoded.channel, message: decoded.message)
        let counted = classified[.perNoteDropped] != nil || classified[.umpOnlyDropped] != nil
        return CaptureMergeEntry(ticks: item.ticks, stream: item.record.stream, index: item.index,
                                 content: .midi2(voice, classified: counted))
    }

    /// The channel of a MIDI 1 Control Change whose controller makes the translator's cached state stale
    /// (`CaptureMIDI2Translation.resetsTranslator`), nil for any other message.
    private static func resetChannel(of message: MIDI1Semantic,
                                     in packet: UMPPacket) throws(UMPRefusal) -> UMPChannel? {
        guard case let .controlChange(_, controller, _) = message,
              CaptureMIDI2Translation.resetsTranslator(controller: controller) else { return nil }
        return try UMPChannel(UInt8((packet.words[0] >> 16) & 0x0F))
    }

    /// The file for `clip` and the SysEx events, written by `StandardMIDIFile.write`, with the losses of this export:
    /// the `captureLosses` (the per-capture §9.3 counts, which include `umpOnlyDropped` for the MIDI 2.0 captures
    /// the file lacks), `groupsFlattened` when the selection spans groups, `passesOverlaid` for the captures of
    /// later passes and `timingQuantized` (added to whatever the writer reported) when capture positions were
    /// rounded to ticks. No tempo event is written, so `syntheticTempoMap` is never reported. Unpaired Note Offs,
    /// closed open notes, widened notes and retriggered notes are counted on this value, not as §9.3 categories.
    func smf() -> SMFWriteResult {
        let written = StandardMIDIFile.write(clip, sysEx: sysEx)
        var losses = written.losses.losses
        for (loss, count) in captureLosses { losses[loss, default: 0] += count }
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
