//
//  ClockGenerationAdapters.swift
//  FluxKlang
//
//  Exact adapters between `ClockGenerationSnapshot` and the local mirror it
//  replaces, in both directions (#108 GU1, slice a). Extensions only: the
//  remaining mirror is not edited, and each adapter forwards `Generation`
//  values from one memberwise initializer to the other, so none builds a
//  generation from an integer. Slices GU1b-1 and GU1b-2 deleted the
//  metronome's and the MIDI clip's mirrors and their adapters: both now take
//  the snapshot itself. Only GU1b-3 (`AutomationRenderGenerations`) remains;
//  it deletes the last mirror by editing its callers.
//
//  Not adapted, on purpose: `CalibrationGenerations` (device and calibration
//  latency epochs), `GenerationSlot` and `GenerationAnchor` (recording take
//  bookkeeping) and `RuntimeGenerationKey` (the fixed-size kernel vocabulary).
//  Their generations belong to other domains and are not the (sample clock,
//  transport, musical map) triple, so no adapter could be exact for them.
//

extension ClockGenerationSnapshot {
    init(_ generations: AutomationRenderGenerations) {
        self.init(sample: generations.sample, transport: generations.transport, musicalMap: generations.musicalMap)
    }
}

extension AutomationRenderGenerations {
    init(_ snapshot: ClockGenerationSnapshot) {
        self.init(sample: snapshot.sample, transport: snapshot.transport, musicalMap: snapshot.musicalMap)
    }
}
