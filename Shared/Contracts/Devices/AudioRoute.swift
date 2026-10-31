//
//  AudioRoute.swift
//  FluxKlang
//
//  Host-local audio routes: a portable role bound to 0-based channel indices on
//  one device. Every route, proposed or confirmed, must stay inside the device's
//  channel bounds for the role's direction and carry exactly the role's channel
//  count (the #98 checker left these checks to the typed contract).
//

import Foundation

enum RouteTag: ContractIDTag {}
typealias RouteID = ContractID<RouteTag>

/// Signal direction from the host's point of view.
enum RouteDirection: String, Codable, Sendable, CaseIterable {
    case input
    case output
}

/// The lifecycle of a route binding on this host.
enum RouteBinding: String, Codable, Sendable, CaseIterable {
    case proposed
    case confirmed
    case stale
    case deviceMissing
}

/// What a portable role needs from any route that binds it.
struct RouteRoleRequirement: Hashable, Sendable {
    let direction: RouteDirection
    let channelCount: Int
}

/// Why a route or device document is invalid.
enum RouteValidationError: Error, Equatable, Sendable {
    case duplicateID(String)
    case unknownDevice(RouteID, DeviceID)
    case unknownRole(RouteID, RoleID)
    case noChannelLayout(RouteID)
    case directionMismatch(RouteID, expected: RouteDirection, found: RouteDirection)
    case channelCountMismatch(RouteID, expected: Int, found: Int)
    case emptyChannels(RouteID)
    case channelOutOfBounds(RouteID, channel: Int, count: Int)
    case duplicateChannel(RouteID, channel: Int)
}

/// One audio route. `channels` are 0-based device channel indices.
struct AudioRoute: Hashable, Sendable, Codable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, role, device, direction, channels, binding, confirmedHost, confirmedEpoch, confirmedDeviceUID, evidence
    }

    var id: RouteID {
        didSet { if id != oldValue { invalidateConfirmation() } }
    }
    var role: RoleID {
        didSet { if role != oldValue { invalidateConfirmation() } }
    }
    var device: DeviceID {
        didSet { if device != oldValue { invalidateConfirmation() } }
    }
    var direction: RouteDirection {
        didSet { if direction != oldValue { invalidateConfirmation() } }
    }
    var channels: [Int] {
        didSet { if channels != oldValue { invalidateConfirmation() } }
    }
    var binding: RouteBinding
    var unknownFields: [String: JSONValue] = [:]
    var confirmedHost: HostID?
    var confirmedEpoch: Generation?
    var confirmedDeviceUID: String?
    var evidence: String?

    init(id: RouteID, role: RoleID, device: DeviceID, direction: RouteDirection,
         channels: [Int], binding: RouteBinding) {
        self.id = id
        self.role = role
        self.device = device
        self.direction = direction
        self.channels = channels
        self.binding = binding
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(RouteID.self, forKey: .id)
        role = try container.decode(RoleID.self, forKey: .role)
        device = try container.decode(DeviceID.self, forKey: .device)
        direction = try container.decode(RouteDirection.self, forKey: .direction)
        channels = try container.decode([Int].self, forKey: .channels)
        binding = try container.decode(RouteBinding.self, forKey: .binding)
        confirmedHost = try container.decodeIfPresent(HostID.self, forKey: .confirmedHost)
        confirmedEpoch = try container.decodeIfPresent(Generation.self, forKey: .confirmedEpoch)
        confirmedDeviceUID = try container.decodeIfPresent(String.self, forKey: .confirmedDeviceUID)
        evidence = try container.decodeIfPresent(String.self, forKey: .evidence)
        unknownFields = try ExtensionFields.decode(from: decoder, knownKeys: CodingKeys.self)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(role, forKey: .role)
        try container.encode(device, forKey: .device)
        try container.encode(direction, forKey: .direction)
        try container.encode(channels, forKey: .channels)
        try container.encode(binding, forKey: .binding)
        try container.encodeIfPresent(confirmedHost, forKey: .confirmedHost)
        try container.encodeIfPresent(confirmedEpoch, forKey: .confirmedEpoch)
        try container.encodeIfPresent(confirmedDeviceUID, forKey: .confirmedDeviceUID)
        try container.encodeIfPresent(evidence, forKey: .evidence)
        try ExtensionFields.encode(unknownFields, to: encoder, knownKeys: CodingKeys.self)
    }

    /// Evidence belongs to the exact route that was reviewed, not its later edits.
    /// Keep diagnostic binding states explicit; only a confirmed route becomes proposed.
    private mutating func invalidateConfirmation() {
        if binding == .confirmed { binding = .proposed }
        confirmedHost = nil
        confirmedEpoch = nil
        confirmedDeviceUID = nil
        evidence = nil
    }

    /// Contextual role checks supplement the intrinsic channel/layout checks.
    func validate(layout: ChannelLayout?, role: RouteRoleRequirement) throws(RouteValidationError) {
        guard direction == role.direction else {
            throw .directionMismatch(id, expected: role.direction, found: direction)
        }
        guard role.channelCount > 0, channels.count == role.channelCount else {
            throw .channelCountMismatch(id, expected: role.channelCount, found: channels.count)
        }
        try validate(layout: layout)
    }

    /// All binding states obey device bounds, independently of any external role catalog.
    func validate(layout: ChannelLayout?) throws(RouteValidationError) {
        guard let layout else { throw .noChannelLayout(id) }
        guard !channels.isEmpty else { throw .emptyChannels(id) }
        let count = layout.channelCount(direction)
        var seen = Set<Int>()
        for channel in channels {
            guard (0..<count).contains(channel) else { throw .channelOutOfBounds(id, channel: channel, count: count) }
            guard seen.insert(channel).inserted else { throw .duplicateChannel(id, channel: channel) }
        }
    }
}
