//
//  LaunchControlXLConfiguration.swift
//  FluxKlang
//

import Foundation

enum LaunchControlXLMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case disabled
    case monitor
    case control

    var id: String { rawValue }

    var label: String {
        switch self {
        case .disabled: "Disabled"
        case .monitor: "Monitor (WING handles MIDI)"
        case .control: "Control through FluxKlang (USB only)"
        }
    }
}

struct LaunchControlXLMapping: Codable, Equatable, Sendable {
    var sourceNameContains: [String]
    var channel: Int
    var faderCCs: [UInt8]
    var panOrBalanceCCs: [UInt8]
    var selectCCs: [UInt8]
    var muteCCs: [UInt8]
    var bankPreviousCC: UInt8
    var bankNextCC: UInt8

    func action(for message: MIDIControlChange) -> LaunchControlXLAction? {
        guard message.channel == channel else { return nil }
        if let slot = faderCCs.firstIndex(of: message.controller) {
            return .fader(slot: slot, value: message.normalizedValue)
        }
        if let slot = panOrBalanceCCs.firstIndex(of: message.controller) {
            return .panOrBalance(slot: slot, value: message.bipolarValue)
        }
        guard message.value > 0 else { return nil }
        if let slot = selectCCs.firstIndex(of: message.controller) {
            return .select(slot: slot)
        }
        if let slot = muteCCs.firstIndex(of: message.controller) {
            return .toggleMute(slot: slot)
        }
        if message.controller == bankPreviousCC {
            return .moveBank(-1)
        }
        if message.controller == bankNextCC {
            return .moveBank(1)
        }
        return nil
    }
}

struct LaunchControlXLConfiguration: Codable, Equatable, Sendable {
    var version: Int
    var mode: LaunchControlXLMode
    var mapping: LaunchControlXLMapping

    static func bundled() -> LaunchControlXLConfiguration? {
        let bundles = [Bundle.main, Bundle(for: BundleToken.self)]
        for bundle in bundles {
            guard let url = bundle.url(forResource: "launch-control-xl", withExtension: "json"),
                  let data = try? Data(contentsOf: url),
                  let configuration = try? JSONDecoder().decode(Self.self, from: data) else {
                continue
            }
            return configuration
        }
        return nil
    }
}

struct MIDIControlChange: Equatable, Sendable {
    var channel: Int
    var controller: UInt8
    var value: UInt8

    var normalizedValue: Float { Float(value) / 127 }
    var bipolarValue: Float { normalizedValue * 2 - 1 }

    static func decode(_ bytes: [UInt8]) -> [MIDIControlChange] {
        guard var parser = MIDI1Parser(maximumSysExPayloadBytes: 256) else { return [] }
        var messages: [MIDIControlChange] = []
        for byte in bytes {
            guard case let .channel(status, controller, value?)? = parser.consume(byte),
                  status & 0xF0 == 0xB0 else {
                continue
            }
            messages.append(MIDIControlChange(
                channel: Int(status & 0x0F) + 1,
                controller: controller,
                value: value
            ))
        }
        return messages
    }
}

enum LaunchControlXLAction: Equatable, Sendable {
    case fader(slot: Int, value: Float)
    case panOrBalance(slot: Int, value: Float)
    case select(slot: Int)
    case toggleMute(slot: Int)
    case moveBank(Int)
}

private final class BundleToken {}
