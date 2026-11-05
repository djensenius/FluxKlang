//
//  SpatialRenderError.swift
//  FluxKlang
//
//  Typed refusals for the control-rate spatial render planner (#115 M1).
//

import Foundation

/// Why a spatial render plan, mask set, calibration value or ramp is invalid.
enum SpatialRenderError: Error, Equatable, Sendable {
    /// The layout law refused its inputs (rolloff or blur out of domain).
    case layout(SpatialLayoutError)
    case tooManySources(Int)
    case duplicateSource(SpatialSourceID)
    case tooManyMasks(Int)
    case duplicateMask(SpeakerID)
    case unknownMaskSpeaker(SpeakerID)
    case tooManyCalibrationEntries(Int)
    case duplicateCalibration(SpeakerID)
    case unknownCalibrationSpeaker(SpeakerID)
    case invalidTrim(SpeakerID)
    case invalidDelay(SpeakerID)
    case invalidSampleRate
    case invalidRampFrames(Int)
    /// A calibration generation is negative or cannot follow the applied one.
    case invalidGeneration(Int)
    /// A staged calibration must be exactly one generation after the applied one.
    case staleCalibration(expected: Int, found: Int)
    case noPendingCalibration
    /// `promote` was asked to apply a set other than the one pending.
    case pendingMismatch
    /// Two plans with different rows or speaker counts cannot be ramped.
    case shapeMismatch
    /// Two plans with the same speaker count but different ordered speaker IDs
    /// (a layout reorder or membership change) cannot be ramped; use a fresh plan.
    case columnMismatch
}

/// Wraps a render validation failure as `DecodingError.dataCorrupted`, keeping
/// the typed error as `underlyingError` (same convention as `SpatialDecoding`).
enum SpatialRenderDecoding {
    static func corrupted(_ decoder: any Decoder, _ error: SpatialRenderError) -> DecodingError {
        .dataCorrupted(.init(
            codingPath: decoder.codingPath,
            debugDescription: "Invalid spatial render value: \(error)",
            underlyingError: error
        ))
    }
}
