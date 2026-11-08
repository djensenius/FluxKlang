//
//  ClockGenerationAdapters.swift
//  FluxKlang
//
//  Exact adapters between `ClockGenerationSnapshot` and the three local mirrors
//  it replaces, in both directions (#108 GU1, slice a). Extensions only: the
//  mirrors are not edited, and each adapter forwards `Generation` values from
//  one memberwise initializer to the other, so none builds a generation from an
//  integer. A later slice (GU1b) deletes the mirrors by editing their callers.
//
//  Not adapted, on purpose: `CalibrationGenerations` (device and calibration
//  latency epochs), `GenerationSlot` and `GenerationAnchor` (recording take
//  bookkeeping) and `RuntimeGenerationKey` (the fixed-size kernel vocabulary).
//  Their generations belong to other domains and are not the (sample clock,
//  transport, musical map) triple, so no adapter could be exact for them.
//

extension ClockGenerationSnapshot {
    init(_ generations: MetronomeGenerations) {
        self.init(sample: generations.sample, transport: generations.transport, musicalMap: generations.musicalMap)
    }

    init(_ generations: MIDIClipGenerations) {
        self.init(sample: generations.sample, transport: generations.transport, musicalMap: generations.musicalMap)
    }

    init(_ generations: AutomationRenderGenerations) {
        self.init(sample: generations.sample, transport: generations.transport, musicalMap: generations.musicalMap)
    }
}

extension MetronomeGenerations {
    init(_ snapshot: ClockGenerationSnapshot) {
        self.init(sample: snapshot.sample, transport: snapshot.transport, musicalMap: snapshot.musicalMap)
    }
}

extension MIDIClipGenerations {
    init(_ snapshot: ClockGenerationSnapshot) {
        self.init(sample: snapshot.sample, transport: snapshot.transport, musicalMap: snapshot.musicalMap)
    }
}

extension AutomationRenderGenerations {
    init(_ snapshot: ClockGenerationSnapshot) {
        self.init(sample: snapshot.sample, transport: snapshot.transport, musicalMap: snapshot.musicalMap)
    }
}
