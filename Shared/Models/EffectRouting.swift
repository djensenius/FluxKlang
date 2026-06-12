//
//  EffectRouting.swift
//  FluxKlang
//
//  Turns a list of `Effect`s into concrete WING OSC settings, handling the bus
//  plumbing automatically. Each effect is an aux send: the instruments that feed
//  it get a send turned on to an auto-allocated bus, that bus is patched to the
//  effect's physical output jack(s), and the effect's return input jack(s) are
//  patched to a return channel that is assigned to the main so it's audible.
//
//  Buses are reserved from the top down (bus 16 first) and return channels from
//  the top down (channel 40 first), assigned in effect order, so the low channels
//  and buses stay free for the instrument rig and hand-built routing.
//

import Foundation

enum EffectRouting {
    /// Highest bus number; effect buses are allocated downward from here.
    static let highestBus = WingNodeKind.bus.count
    /// Highest channel number; return channels are allocated downward from here.
    static let highestReturnChannel = WingNodeKind.channel.count
    /// The main bus an effect's return channel is assigned to so it's heard.
    static let returnMain = 1

    /// Send level, in decibels, used to feed an effect at unity gain. Bus-send
    /// `/lvl` nodes are in dB (unlike fader positions, which are normalised), so
    /// unity is 0 dB — see `WingController.setSendLevel`.
    static let unitySendDecibels: Float = 0

    /// The buses and return channels reserved for an effect.
    struct Allocation: Hashable, Sendable {
        var buses: [Int]
        var returnChannels: [Int]
    }

    /// Deterministically reserves a bus (pair) and return channel (pair) for each
    /// effect, in list order, counting down from the top of each pool. Allocation
    /// is all-or-nothing per effect: an effect that can't fit a full set (e.g.
    /// when there are more effects than free buses) gets an empty allocation and
    /// is skipped, rather than collapsing a stereo effect onto a single bus.
    static func allocations(for effects: [Effect]) -> [Effect.ID: Allocation] {
        var result: [Effect.ID: Allocation] = [:]
        var nextBus = highestBus
        var nextChannel = highestReturnChannel
        for effect in effects {
            let width = effect.isStereo ? 2 : 1
            guard nextBus - width + 1 >= 1, nextChannel - width + 1 >= 1 else {
                result[effect.id] = Allocation(buses: [], returnChannels: [])
                continue
            }
            var buses: [Int] = []
            var channels: [Int] = []
            for _ in 0..<width {
                buses.append(nextBus); nextBus -= 1
                channels.append(nextChannel); nextChannel -= 1
            }
            result[effect.id] = Allocation(buses: buses, returnChannels: channels)
        }
        return result
    }

    /// All WING settings implied by the effects and the current channel rig.
    static func settings(
        for effects: [Effect],
        assignments: [Equipment.ChannelAssignment]
    ) -> [WingSetting] {
        let allocations = allocations(for: effects)
        let channelByInstrument = Dictionary(
            assignments.map { ($0.equipment.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var result: [WingSetting] = []
        for effect in effects {
            guard let allocation = allocations[effect.id], let busLeft = allocation.buses.first else { continue }
            let busRight = effect.isStereo ? (allocation.buses.last ?? busLeft) : busLeft

            result.append(contentsOf: sends(for: effect, busLeft: busLeft, busRight: busRight, channelByInstrument))
            result.append(contentsOf: outputPatches(for: effect, busLeft: busLeft, busRight: busRight))
            result.append(contentsOf: returns(for: effect, allocation: allocation))
        }
        return result
    }

    // MARK: - Steps

    /// Instrument → bus sends. A stereo effect sends each source's left/right to
    /// the bus pair (a mono source is centred to both); a mono effect sums every
    /// source channel into its single bus.
    private static func sends(
        for effect: Effect,
        busLeft: Int,
        busRight: Int,
        _ channelByInstrument: [Equipment.ID: Equipment.ChannelAssignment]
    ) -> [WingSetting] {
        var result: [WingSetting] = []
        for instrument in effect.sourceInstruments {
            guard let assignment = channelByInstrument[instrument] else { continue }
            if effect.isStereo {
                let left = assignment.leftChannel
                let right = assignment.rightChannel ?? assignment.leftChannel
                result.append(contentsOf: send(channel: left, toBus: busLeft))
                result.append(contentsOf: send(channel: right, toBus: busRight))
            } else {
                for channel in [assignment.leftChannel, assignment.rightChannel].compactMap({ $0 }) {
                    result.append(contentsOf: send(channel: channel, toBus: busLeft))
                }
            }
        }
        return result
    }

    /// Patches the effect's bus(es) onto the physical output jack(s) feeding it.
    private static func outputPatches(for effect: Effect, busLeft: Int, busRight: Int) -> [WingSetting] {
        var result: [WingSetting] = []
        if let output = effect.sendOutputs.first {
            result.append(contentsOf: outputLeg(bus: busLeft, output: output))
        }
        if effect.isStereo, effect.sendOutputs.count > 1 {
            result.append(contentsOf: outputLeg(bus: busRight, output: effect.sendOutputs[1]))
        }
        return result
    }

    /// Patches the effect's return input jack(s) to its return channel(s) and
    /// assigns those channels to the main so the wet signal is audible.
    private static func returns(for effect: Effect, allocation: Allocation) -> [WingSetting] {
        var result: [WingSetting] = []
        if let channel = allocation.returnChannels.first, let input = effect.returnInputs.first {
            result.append(contentsOf: returnLeg(input: input, channel: channel))
        }
        if effect.isStereo, allocation.returnChannels.count > 1, effect.returnInputs.count > 1 {
            result.append(contentsOf: returnLeg(input: effect.returnInputs[1], channel: allocation.returnChannels[1]))
        }
        return result
    }

    /// Patches a single bus onto a physical output jack.
    private static func outputLeg(bus: Int, output: Int) -> [WingSetting] {
        WingOutputSource(group: .bus, index: bus).settings(forOutput: output)
    }

    /// Patches a single return input jack to a channel and assigns it to the main.
    private static func returnLeg(input: Int, channel: Int) -> [WingSetting] {
        let mainAddress = WingAddress.mainOn(.channel, channel, toMain: returnMain)
        return WingSource(group: .local, index: input).settings(forChannel: channel)
            + [WingSetting(address: mainAddress, value: .int(1))]
    }

    /// Turns a channel's send to a bus on at unity gain.
    private static func send(channel: Int, toBus bus: Int) -> [WingSetting] {
        let levelAddress = WingAddress.sendLevel(.channel, channel, toBus: bus)
        return [
            WingSetting(address: WingAddress.sendOn(.channel, channel, toBus: bus), value: .int(1)),
            WingSetting(address: levelAddress, value: .float(unitySendDecibels))
        ]
    }
}
