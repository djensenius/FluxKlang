//
//  SMFTempoScan+Track.swift
//  FluxKlang
//
//  The per-track event walk of the tempo and meter scan (#112 CL6). It follows
//  the CL2 reader's track parser event for event (same bounds, same refusals,
//  same running status rules) but builds no notes: channel messages and SysEx
//  events are skipped by length, and only FF 51 and FF 58 are kept.
//

extension SMFTempoScan {
    /// Where an event is: its track, its index in the track and its clip tick.
    struct Place {
        let track: Int
        let position: Int
        let ticks: Int64
    }

    /// Walks MTrk bodies in order, counting events file-wide against `SMFReadLimits.maximumEvents`, and collects the
    /// tempo and time signature events with their clip tick and place in the file.
    struct TrackScanner {
        let bytes: [UInt8]
        let scale: Int64
        let limits: SMFReadLimits
        private(set) var events = 0
        private(set) var tempos: [TempoEvent] = []
        private(set) var meters: [MeterEvent] = []

        init(bytes: [UInt8], scale: Int64, limits: SMFReadLimits) {
            self.bytes = bytes
            self.scale = scale
            self.limits = limits
        }

        /// Scans one track body. Time is in clip ticks: each file tick is `scale` of them. A delta below 2^28 times a
        /// scale of at most 15,360 is below 2^42, and the running time is checked against
        /// `MIDIClip.maximumLengthTicks` after every delta, so the arithmetic cannot overflow `Int64`.
        mutating func scan(track: Int, body: Range<Int>) throws(SMFTempoRefusal) {
            var offset = body.lowerBound
            let end = body.upperBound
            var ticks: Int64 = 0
            var running: UInt8?
            var position = 0
            while offset < end {
                events += 1
                guard events <= limits.maximumEvents else { throw .file(.tooManyEvents(limit: limits.maximumEvents)) }
                ticks += Int64(try quantity(at: &offset, end: end)) * scale
                guard ticks <= MIDIClip.maximumLengthTicks else {
                    throw .file(.timeBeyondLimit(track: track, ticks: ticks))
                }
                guard offset < end else { throw .file(.truncated(offset: offset)) }
                let start = offset
                switch bytes[start] {
                case 0xFF:
                    running = nil
                    let place = Place(track: track, position: position, ticks: ticks)
                    if try meta(at: &offset, end: end, place: place) { return }
                case 0xF0, 0xF7:
                    running = nil
                    try sysEx(at: &offset, end: end)
                case 0xF1...0xFE:
                    throw .file(.invalidStatus(track: track, offset: start, status: bytes[start]))
                default:
                    try channelMessage(track: track, at: &offset, end: end, running: &running)
                }
                position += 1
            }
            throw .file(.missingEndOfTrack(track: track))
        }

        private func quantity(at offset: inout Int, end: Int) throws(SMFTempoRefusal) -> UInt32 {
            do {
                return try StandardMIDIFile.readQuantity(bytes, at: &offset, end: end)
            } catch {
                throw .file(error)
            }
        }

        /// Reads the meta event at `offset`, keeping tempo and time signature, and returns `true` exactly at a
        /// well-formed End of Track that ends the chunk. A length that overruns the chunk is `truncated` for every
        /// type, ahead of any type specific length check.
        private mutating func meta(at offset: inout Int, end: Int, place: Place) throws(SMFTempoRefusal) -> Bool {
            let start = offset
            offset += 1
            guard offset < end else { throw .file(.truncated(offset: start)) }
            let type = bytes[offset]
            offset += 1
            let length = Int(try quantity(at: &offset, end: end))
            guard length <= end - offset else { throw .file(.truncated(offset: start)) }
            let payload = offset
            offset += length
            switch type {
            case 0x2F:
                guard length == 0 else { throw .file(.malformedEndOfTrack(track: place.track, offset: start)) }
                guard offset == end else { throw .file(.eventAfterEndOfTrack(track: place.track, offset: offset)) }
                return true
            case 0x51:
                guard length == 3 else { throw .malformedTempo(track: place.track, offset: start) }
                let micros = Int64(bytes[payload]) << 16 | Int64(bytes[payload + 1]) << 8 | Int64(bytes[payload + 2])
                let segment = try SMFTempoScan.segment(atTicks: place.ticks, microsPerQuarter: micros)
                tempos.append(TempoEvent(segment: segment, track: place.track, position: place.position))
            case 0x58:
                guard length == 4 else { throw .malformedTimeSignature(track: place.track, offset: start) }
                try appendMeter(numerator: Int(bytes[payload]), power: Int(bytes[payload + 1]), place: place)
            default:
                break
            }
            return false
        }

        /// Keeps a time signature `numerator / 2^power`; `MeterFields` decides validity. Swift's shift gives 0 or
        /// `Int.min` for a power of 63 or more, which it refuses too.
        private mutating func appendMeter(numerator: Int, power: Int, place: Place) throws(SMFTempoRefusal) {
            let meter: MusicalMeter
            do {
                meter = try MusicalMeter(MeterFields(numerator: numerator, denominator: 1 << power))
            } catch {
                throw .invalidMeter(numerator: numerator, denominatorPower: power)
            }
            meters.append(MeterEvent(ticks: place.ticks, meter: meter, track: place.track, position: place.position))
        }

        /// Skips the SysEx event at `offset`: F0 or F7, its length, then that many bytes.
        private func sysEx(at offset: inout Int, end: Int) throws(SMFTempoRefusal) {
            let start = offset
            offset += 1
            let length = Int(try quantity(at: &offset, end: end))
            guard length <= end - offset else { throw .file(.truncated(offset: start)) }
            offset += length
        }

        /// Skips the channel message at `offset`, with its own status or the running one, checking its data bytes.
        private func channelMessage(track: Int, at offset: inout Int, end: Int,
                                    running: inout UInt8?) throws(SMFTempoRefusal) {
            let start = offset
            if bytes[offset] >= 0x80 {
                running = bytes[offset]
                offset += 1
            }
            guard let status = running else { throw .file(.missingRunningStatus(track: track, offset: start)) }
            let count = status & 0xE0 == 0xC0 ? 1 : 2
            guard end - offset >= count else { throw .file(.truncated(offset: start)) }
            let data = offset
            offset += count
            guard bytes[data..<offset].allSatisfy({ $0 < 0x80 }) else {
                throw .file(.invalidDataByte(track: track, offset: data))
            }
        }
    }
}
