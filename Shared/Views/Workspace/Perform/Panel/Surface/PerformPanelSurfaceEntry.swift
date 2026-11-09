//
//  PerformPanelSurfaceEntry.swift
//  FluxKlang
//
//  The requests a perform panel surface is built from: one XY pad cell and one recall cell (#102 PNS1). Plain
//  values: nothing here is checked by being built, `PerformPanelSurface.make` validates them.
//

enum PerformPanelSurfaceCellTag: ContractIDTag {}

/// The id of an XY or a recall cell; one namespace holds both kinds.
typealias PerformPanelSurfaceCellID = ContractID<PerformPanelSurfaceCellTag>

/// What the caller knows about an XY pad's targets. Each field is a total type, so there is nothing to validate.
struct PerformPanelSurfaceXYFacts: Equatable, Sendable {
    let resyncing: Bool
    let permitted: Bool
    let targetExists: Bool
}

/// A request for one XY pad cell. The pad is built by `PerformXYPad.make`; the two targets are bare parameter ids and
/// the caller guarantees that the pair matches the pad.
struct PerformPanelSurfaceXYEntry: Equatable, Sendable {
    let id: PerformPanelSurfaceCellID
    let label: String
    let xTarget: ParameterID
    let yTarget: ParameterID
    let controlClass: ControlClass
    let pad: PerformXYPad
    let facts: PerformPanelSurfaceXYFacts
}

/// A request for one recall cell. `phase` is the cell's phase as the caller keeps it; the surface never changes it.
struct PerformPanelSurfaceRecallEntry: Equatable, Sendable {
    let id: PerformPanelSurfaceCellID
    let label: String
    let target: PerformRecallTarget
    let phase: PerformRecallPhase
    let facts: PerformRecallFacts
}
