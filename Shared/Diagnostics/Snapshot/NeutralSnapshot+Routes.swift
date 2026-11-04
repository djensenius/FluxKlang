//
//  NeutralSnapshot+Routes.swift
//  FluxKlang
//
//  Route selection, availability and the device-ID allowlist.
//

import Foundation

extension NeutralSnapshotAssembly {
    /// Unavailable routes win over available ones at the cap, so problems stay visible.
    func routes(_ routes: [NeutralSnapshot.RouteInput]) -> Selection<NeutralSnapshot.Route> {
        let selection = Self.select(routes, limit: limits.routes, id: \.route.id, priority: { input in
            Self.availability(of: input) == .available ? 1 : 0
        })
        let refused = Set(withheld.map { $0.lowercased() })
        let kept = selection.kept.map { input in
            let route = input.route
            let exposed = Self.isNeutralDeviceAlias(route.device.rawValue, refused: refused)
            return NeutralSnapshot.Route(
                id: route.id, role: route.role, device: exposed ? route.device : nil, isDeviceWithheld: !exposed,
                direction: route.direction, channelCount: route.channels.count, binding: route.binding,
                presence: input.presence, availability: Self.availability(of: input)
            )
        }
        return (kept, selection.count)
    }

    static func availability(of input: NeutralSnapshot.RouteInput) -> NeutralSnapshot.RouteAvailability {
        if input.route.binding == .deviceMissing || input.presence == .missing { return .deviceMissing }
        if input.route.binding == .stale || input.presence == .stale { return .stale }
        guard input.presence == .present else { return .deviceUnobserved }
        return input.route.binding == .confirmed ? .available : .unconfirmed
    }

    /// The allowlist for exposing a `DeviceID`. The contracts and examples name
    /// devices by project alias (`dev.iface-a`, `dev.ctl-b`, `dev.phone-audio`).
    /// An ID is exposed only when:
    /// - it starts with `dev.` and is at most 64 bytes long;
    /// - its dot-separated segments each start with `a`–`z` and use only `a`–`z`, `0`–`9` and single hyphens;
    /// - none of its hyphen-separated tokens looks like a serial number (four or more digits, or six or
    ///   more hex digits including a digit);
    /// - it is not equal, ignoring case, to any withheld UID, host or evidence string.
    ///
    /// Anything else, including UUIDs and CoreAudio UIDs, is withheld.
    static func isNeutralDeviceAlias(_ raw: String, refused: Set<String>) -> Bool {
        guard raw.hasPrefix("dev."), raw.utf8.count <= 64, !refused.contains(raw.lowercased()) else { return false }
        let segments = raw.dropFirst(4).split(separator: ".", omittingEmptySubsequences: false)
        return segments.allSatisfy(isAliasSegment)
    }

    private static func isAliasSegment(_ segment: Substring) -> Bool {
        guard let first = segment.first, ("a"..."z").contains(first) else { return false }
        let tokens = segment.split(separator: "-", omittingEmptySubsequences: false)
        return tokens.allSatisfy { token in
            !token.isEmpty && token.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) }
                && !looksLikeSerial(token)
        }
    }

    private static func looksLikeSerial(_ token: Substring) -> Bool {
        let digits = token.count { ("0"..."9").contains($0) }
        return digits >= 4 || (token.count >= 6 && digits > 0 && token.allSatisfy(\.isHexDigit))
    }
}
