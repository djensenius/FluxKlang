//
//  MetronomeConfiguration.swift
//  FluxKlang
//
//  The metronome's musical grid (#111 K1): one meter for the whole map
//  (meter changes inside a map are media-contract.md §14 Q10), the beat unit,
//  and how many clicks split each beat. Beat and bar lengths are exact integer
//  ticks. Subdivision ticks are rounded once per click from the beat start
//  (half-up; ties cannot occur for 1…8 here), so the error is at most ½ tick
//  (3/7 for septuplets): with 15,360 ticks per quarter, ½ tick is ≈ 16.3 µs
//  at 120 BPM and ≈ 6.5 µs at 300 BPM. Rounding never accumulates.
//

/// Which note value gets a beat click.
enum MetronomeBeatUnit: Hashable, Sendable {
    /// One beat per denominator note (4/4: quarters, 6/8: eighths).
    case denominator
    /// One beat per three denominator notes, for compound meters such as 6/8, 9/8 and 12/8.
    case dottedCompound
}

/// A validated metronome grid.
struct MetronomeConfiguration: Hashable, Sendable {
    static let maximumSubdivisions = 8
    /// Ticks in a whole note.
    static let wholeNoteTicks = MusicalTime.ticksPerQuarter * 4

    let meter: MusicalMeter
    let beatUnit: MetronomeBeatUnit
    /// Clicks per beat; 1 means no subdivision clicks.
    let subdivisions: Int

    let noteTicks: Int64
    let beatTicks: Int64
    let beatsPerBar: Int
    let barTicks: Int64

    init(meter: MusicalMeter, beatUnit: MetronomeBeatUnit = .denominator,
         subdivisions: Int = 1) throws(MetronomeRefusal) {
        let numerator = meter.numerator
        let denominator = meter.denominator
        guard (1...Self.maximumSubdivisions).contains(subdivisions) else {
            throw .subdivisionsOutOfRange(subdivisions)
        }
        let notesPerBeat: Int
        switch beatUnit {
        case .denominator:
            notesPerBeat = 1
        case .dottedCompound:
            guard numerator > 3, numerator.isMultiple(of: 3) else {
                throw .invalidCompoundMeter(numerator: numerator, denominator: denominator)
            }
            notesPerBeat = 3
        }
        // MeterFields bounds numerator to 1…64 and denominator to powers of two up to 32,
        // so these products stay far below Int64.max.
        let noteTicks = Self.wholeNoteTicks / Int64(denominator)
        let beatTicks = noteTicks * Int64(notesPerBeat)
        self.meter = meter
        self.beatUnit = beatUnit
        self.subdivisions = subdivisions
        self.noteTicks = noteTicks
        self.beatTicks = beatTicks
        beatsPerBar = numerator / notesPerBeat
        barTicks = noteTicks * Int64(numerator)
    }

    /// Ticks from the beat start to click `index` (`0..<subdivisions`): `index · beatTicks / subdivisions`
    /// rounded half-up, computed independently for every click.
    func offset(ofSubdivision index: Int) -> Int64 {
        let divisor = Int64(subdivisions)
        return (2 * Int64(index) * beatTicks + divisor) / (2 * divisor)
    }

    /// The bar and beat of a beat start `beatStart >= 0` (a multiple of `beatTicks`) and a click index.
    func position(beatStart: Int64, subdivision: Int) -> MetronomeGridPosition {
        MetronomeGridPosition(bar: beatStart / barTicks, beat: Int(beatStart % barTicks / beatTicks),
                              subdivision: subdivision)
    }
}
