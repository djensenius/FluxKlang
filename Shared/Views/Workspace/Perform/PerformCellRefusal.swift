//
//  PerformCellRefusal.swift
//  FluxKlang
//
//  Typed refusals of the perform cell model (#102 P1).
//

/// Why `PerformCellModel.make` builds no model. The checks run in the order the cases are declared below, and the
/// first failing check decides which one is thrown.
enum PerformCellRefusal: Error, Equatable, Sendable {
    /// Perform edits live-class parameters only (hazardous ones need authorization); the class cannot be performed.
    case classNotPerformable(ControlClass)
    /// The descriptor's own check refuses the shown value (unit, finite, integral, range or ceiling).
    case valueRefused(ParameterValueError)
    /// The cell label has no utf8 bytes.
    case emptyLabel
    case labelTooLong(bytes: Int)
    case bindingLabelTooLong(bytes: Int)
    /// A pickup state or a stale controller is claimed, but the binding label is empty (no binding).
    case bindingFactsWithoutBinding
    /// A hardware position that is not finite or not in `0...1`.
    case invalidHardwarePosition
    /// `PickupState.unavailable` means the controller is stale or missing, so the stale fact must be set.
    case pickupUnavailableWithoutStaleController
    /// A removal that is pending in a draft still has its target; a committed removal has none.
    case pendingRemovalWithoutTarget
    /// A channel display with no channel holds nothing to show and no reason to give.
    case meterHasNoChannels
}

enum PerformCellLimits {
    /// utf8 bytes of the cell label; an empty cell label is refused.
    static let labelBytes = 1...128
    /// utf8 bytes of the binding label; an empty one means no binding.
    static let bindingLabelBytes = 0...128
}
