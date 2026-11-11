// #364 E5c, slice KCR1: control's view of the re-admitted retirement carry. In this file because `KernelCycle.swift`
// is at the file-length cap. Reference model; not RT-certified.

/// Re-admission (the rules of `KernelCarryReadmission`, summarised). A `.replacingCycle` cycle plans the carry it
/// inherited in `init` and re-admits it in step 4 in timeline order: carried and own events apply by original frame
/// (a carried one first on a tie), as one cycle would have applied them, so a carried event stamped after an own event
/// for the same target is still delivered, and an own event supersedes only carried ones at or before its frame. At
/// its own `retire()` a replacement records its own pending events first, then each still pending carried event no
/// pending own event covers (same target, own frame at or after it); covered ones are superseded, not lost. The slots
/// hold at most `carryReadmissionCapacity` (`min(256, blockCapacity)`) events; the rest of the carry is cut (lost).
extension KernelCycle {
    /// Any thread: `inheritedRetirementLoss` less the carried stateful events this cycle has since delivered, or found
    /// replaced by its own later state (each with the carried events of its key it superseded). Its
    /// `receiverStateMayBeStale` is `true` only while some dropped stateful event is unresolved: cut by the capacity,
    /// never recorded (carry full), an invalid ramp, refused on apply, or still pending. Each kind only decreases
    /// (render's counters only grow).
    ///
    /// Per hop: this covers only the immediate predecessor's retirement. Events still pending when this cycle retires
    /// move into its own `retire()` loss and carry, which the next replacement inherits, so control must read every
    /// hop's `unresolvedRetirementLoss` (each replacement's in turn) to know whether receiver state may be stale.
    var unresolvedRetirementLoss: KernelRetirementLoss {
        let resolved = carryResolution
        return inheritedRetirementLoss.resolving(controls: resolved.controls, programs: resolved.programs,
                                                 ramps: resolved.ramps)
    }
}
