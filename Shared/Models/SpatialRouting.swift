//
//  SpatialRouting.swift
//  FluxKlang
//
//  Compiles a placed source into the WING bus sends that pan it across the
//  speaker array, using `SpatialPanner` (DBAP). Speakers are buses, so a placed
//  voice simply turns on a send to each speaker bus at the panned level. This is
//  purely additive: it never touches the main, so surround placement coexists
//  with the dry/effect-return mix that still feeds the main.
//

import Foundation

enum SpatialRouting {
    /// The WING settings that pan `source` across `speakers` (only the bus-backed
    /// ones — a speaker driven by a non-bus node can't receive channel sends).
    /// Each of the source's channels gets a send to every speaker bus at its DBAP
    /// level in dB. Returns an empty array when there are no bus speakers.
    static func settings(for source: SpatialSource, speakers: [Speaker]) -> [WingSetting] {
        let busSpeakers = speakers.filter { $0.node.kind == .bus }
        guard !busSpeakers.isEmpty else { return [] }
        let positions = busSpeakers.map(\.position)
        var result: [WingSetting] = []
        for placement in source.channelPlacements() {
            let gains = SpatialPanner.gains(source: placement.point, speakers: positions)
            let channel = placement.channel.index
            for (index, speaker) in busSpeakers.enumerated() {
                let bus = speaker.node.index
                let decibels = SpatialPanner.decibels(forGain: gains[index])
                result.append(WingSetting(address: WingAddress.sendOn(.channel, channel, toBus: bus), value: .int(1)))
                result.append(
                    WingSetting(address: WingAddress.sendLevel(.channel, channel, toBus: bus), value: .float(decibels))
                )
            }
        }
        return result
    }
}
