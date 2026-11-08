//
//  PerformRecallReason.swift
//  FluxKlang
//
//  The events a perform recall cell takes and the reasons it gives back (#102 RCL1).
//

enum PerformRecallEvent: Equatable, Sendable {
    case press
    case confirm
    case cancel
    case settle
}

/// Why an event changed nothing. A refusal keeps the phase.
enum PerformRecallRefusal: Equatable, Sendable {
    case notPermitted
    case noTarget
    case classNotPerformable(ControlClass)
    case alreadyAwaitingConfirm
    case alreadyFired
    case notAwaitingConfirm
    case nothingFired
}

/// Why an event was dropped. A drop sets the phase to idle.
enum PerformRecallDrop: Equatable, Sendable {
    case resyncing
    case staleEpoch
    case notReady(ReadinessState)
}

/// What the caller does next. Only `fire` carries an intent.
enum PerformRecallDecision: Equatable, Sendable {
    case awaitConfirm
    case fire(PerformRecallIntent)
    case released
    case refused(PerformRecallRefusal)
    case dropped(PerformRecallDrop)
}
