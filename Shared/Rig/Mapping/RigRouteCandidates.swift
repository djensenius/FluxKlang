//
//  RigRouteCandidates.swift
//  FluxKlang
//
//  Lists the device channel blocks an audio role could bind: the same
//  direction, exactly the role's channel count, on a device that is present.
//
//  Deliberate limit (#100 RG1): candidates are CONTIGUOUS blocks only
//  (`first ..< first + count`), never arbitrary channel sets. Follow-up: a
//  caller-composed, non-contiguous channel set needs its own review path.
//  Nothing here assumes a USB channel numbering; channels are the device
//  contract's 0-based indices.
//

/// One contiguous block on one device that fits one role. Only this module creates candidates.
struct RigRouteCandidate: Hashable, Sendable {
    /// The role the block fits.
    let role: RoleID
    /// The present device that offers the block.
    let device: DeviceID
    /// The role's (and the block's) direction.
    let direction: RouteDirection
    /// The first 0-based device channel of the block.
    let firstChannel: Int
    /// The block width: exactly the role's channel count.
    let channelCount: Int

    /// The block's 0-based device channels, ascending.
    var channels: [Int] { Array(firstChannel..<(firstChannel + channelCount)) }

    fileprivate init(role: RoleID, device: DeviceID, direction: RouteDirection, firstChannel: Int, channelCount: Int) {
        self.role = role
        self.device = device
        self.direction = direction
        self.firstChannel = firstChannel
        self.channelCount = channelCount
    }
}

/// Reports that more blocks fit a role than `RigMappingLimits.candidatesPerRole` lists.
struct RigCandidateTruncation: Hashable, Sendable {
    /// How many candidates are listed (the cap).
    let listed: Int
    /// How many compatible blocks exist in total.
    let total: Int
    /// How many compatible blocks are not listed.
    var omitted: Int { total - listed }
}

/// The candidates for one role, in (device, first channel) order, with any truncation stated.
struct RigRoleCandidates: Hashable, Sendable {
    /// The listed candidates, at most `RigMappingLimits.candidatesPerRole`.
    let candidates: [RigRouteCandidate]
    /// Non-nil exactly when compatible blocks exist beyond the listed ones.
    let truncation: RigCandidateTruncation?
}

/// Enumerates contiguous candidate blocks.
enum RigRouteCandidates {
    /// Devices that may offer audio blocks: present, with a channel layout, and not a MIDI
    /// controller. Missing or stale devices never offer candidates. Sorted by `DeviceID`.
    static func eligibleDevices(_ devices: [DeviceDescriptor]) -> [DeviceDescriptor] {
        devices.filter { $0.presence == .present && $0.layout != nil && $0.kind != .midiController }
            .sorted { $0.id < $1.id }
    }

    /// The contiguous blocks of `requirement` on `devices` (already eligible and sorted), capped
    /// at `RigMappingLimits.candidatesPerRole`. The total is counted arithmetically, so the work
    /// per role is bounded by the device count and the cap, not by the channel count.
    static func candidates(
        for role: RoleID, requirement: RouteRoleRequirement, on devices: [DeviceDescriptor]
    ) -> RigRoleCandidates {
        let width = requirement.channelCount
        var listed: [RigRouteCandidate] = []
        var total = 0
        for device in devices {
            guard let layout = device.layout, width > 0 else { continue }
            let blocks = max(0, layout.channelCount(requirement.direction) - width + 1)
            total += blocks
            for first in 0..<min(blocks, RigMappingLimits.candidatesPerRole - listed.count) {
                listed.append(RigRouteCandidate(
                    role: role, device: device.id, direction: requirement.direction,
                    firstChannel: first, channelCount: width
                ))
            }
        }
        let truncation = total > listed.count ? RigCandidateTruncation(listed: listed.count, total: total) : nil
        return RigRoleCandidates(candidates: listed, truncation: truncation)
    }
}
