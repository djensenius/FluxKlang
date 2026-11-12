//
//  RouteChoiceRow.swift
//  FluxKlang
//
//  One row of the compact route picker's list (#100 MAP1): a device channel block, its caller-supplied device name
//  and whether another role already uses it. An output another route writes is shown but disabled with its reason;
//  a shared input stays enabled (RigChannelOverlap.swift). Nothing calls it yet.
//

/// What the host's other routes do with a candidate block. `by` holds the claimant roles in RoleID byte order.
enum RouteChoiceState: Equatable, Sendable {
    case available
    /// Another live route reads the same input channels. Allowed, so the row stays enabled.
    case sharedInput(by: [RoleID]) // swiftlint:disable:this identifier_name
    /// Another live route writes the same output channels. The row is disabled.
    case outputInUse(by: [RoleID]) // swiftlint:disable:this identifier_name

    var isEnabled: Bool {
        switch self {
        case .available, .sharedInput: true
        case .outputInUse: false
        }
    }
}

struct RouteChoiceRow: Equatable, Sendable, Identifiable {
    let candidate: RigRouteCandidate
    /// The caller's name, exactly as given.
    let deviceName: String
    let state: RouteChoiceState
    let stateText: String

    var id: RigRouteCandidate { candidate }

    var isEnabled: Bool { state.isEnabled }

    /// The visible reason a row cannot be picked; equal to `stateText`. `nil` for an enabled row.
    var disabledReason: String? { isEnabled ? nil : stateText }

    var channelsText: String {
        RouteChoiceText.channels(
            direction: candidate.direction, firstChannel: candidate.firstChannel,
            channelCount: candidate.channelCount
        )
    }

    var accessibilityLabel: String {
        RouteChoiceText.accessibilityLabel(
            name: deviceName, channels: channelsText, state: stateText, isEnabled: isEnabled
        )
    }
}
