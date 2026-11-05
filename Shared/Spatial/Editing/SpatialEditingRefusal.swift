//
//  SpatialEditingRefusal.swift
//  FluxKlang
//
//  Typed refusals for spatial placement editing and the calibration flow
//  (#116 PL1). A refused edit or event changes nothing.
//

/// Why a placement edit was refused. The editor's placement is unchanged.
enum SpatialEditingRefusal: Error, Equatable, Sendable {
    /// An exact entry or a drag coordinate is NaN or infinite.
    case nonFiniteValue(SpatialEditAxis)
    /// An exact entry outside the axis range. Exact entry never clamps.
    case valueOutOfRange(SpatialEditAxis, Double)
    /// The snap target is not a speaker in the layout.
    case unknownSpeaker(SpeakerID)
    /// Width only spreads a stereo source; a mono source has no width to edit.
    case widthRequiresStereo(SpatialSourceID)
    /// Rebuilding the placement failed validation. Defensive: every edit
    /// supplies an in-range position and width, so this is not expected.
    case placement(SpatialLayoutError)
}

/// Which binding of an authorization does not match the current review.
/// Checked in this order; the first mismatch is reported.
enum SpatialCalibrationAuthorizationDefect: Hashable, Sendable, CaseIterable {
    /// The authorization was issued by another flow.
    case flowID
    case planID
    /// Same plan ID, but the reviewed contents (outputs, routes, level or
    /// duration, and so the digest) differ.
    case digest
    case generation
}

/// Why a calibration plan or flow event was refused. The flow is unchanged.
enum SpatialCalibrationRefusal: Error, Equatable, Sendable {
    /// The event is not allowed in the current phase.
    case illegalTransition(from: SpatialCalibrationPhase, event: SpatialCalibrationEventKind)
    /// The authorization was issued by another flow, or for another plan ID,
    /// digest or review.
    case authorizationMismatch(SpatialCalibrationAuthorizationDefect)
    /// The review generation counter cannot advance.
    case reviewGenerationExhausted
    case noOutputs
    case tooManyOutputs(Int)
    case duplicateOutput(SpeakerID)
    case unknownOutput(SpeakerID)
    /// The speaker has no route, or its route is not present on this host.
    case unroutedOutput(SpeakerID)
    /// The maximum test level is non-finite or outside `SpatialCalibrationPlan.levelRange`.
    case invalidMaximumLevel
    /// The per-output duration is non-finite or outside `SpatialCalibrationPlan.durationRange`.
    case invalidDuration
    /// An injected elapsed time is NaN or infinite.
    case invalidElapsed
    /// An injected elapsed time is earlier than the last one.
    case elapsedRegressed
    /// An injected elapsed time is later than the plan's total duration.
    case elapsedBeyondPlan
    /// Results arrived before the injected elapsed time reached the plan's
    /// total. Checked before the results themselves.
    case runIncomplete(elapsedSeconds: Double, totalSeconds: Double)
    case duplicateResult(SpeakerID)
    /// A result names a speaker the plan did not test.
    case unplannedResult(SpeakerID)
    /// A planned output has no result.
    case missingResult(SpeakerID)
    /// Building or staging the calibration set was refused.
    case calibration(SpatialRenderError)
    /// The draft to commit is not the one this flow staged.
    case draftMismatch
}
