//
//  WingSource.swift
//  FluxKlang
//
//  Models the WING input-source space used for channel input patching. A source
//  is a transport group (local preamps, AES50 A/B/C, USB, card, StageConnect)
//  plus a 1-based index within that group. Group tokens follow the WING OSC
//  `/ch/x/in/conn/grp` convention; exact tokens/counts are confirmed against the
//  console during the smoke test.
//

import Foundation

/// A WING input transport group.
enum WingSourceGroup: String, CaseIterable, Codable, Sendable {
    case off = "OFF"
    case local = "LCL"
    case aux = "AUX"
    case aes50A = "A"
    case aes50B = "B"
    case aes50C = "C"
    case stageConnect = "SC"
    case usb = "USB"
    case card = "CRD"

    /// Human-readable group name.
    var label: String {
        switch self {
        case .off: return "None"
        case .local: return "Local"
        case .aux: return "Aux In"
        case .aes50A: return "AES50-A"
        case .aes50B: return "AES50-B"
        case .aes50C: return "AES50-C"
        case .stageConnect: return "StageConnect"
        case .usb: return "USB"
        case .card: return "Expansion Card"
        }
    }

    /// Number of inputs available in this group.
    var count: Int {
        switch self {
        case .off: return 0
        case .local: return 24
        case .aux: return 8
        case .aes50A, .aes50B, .aes50C: return 48
        case .stageConnect: return 32
        case .usb: return 48
        case .card: return 64
        }
    }
}

/// A specific WING input source: a group plus a 1-based index within it.
struct WingSource: Identifiable, Hashable, Sendable {
    var group: WingSourceGroup
    var index: Int

    var id: String { "\(group.rawValue)-\(index)" }

    /// Display label, e.g. "Local 5" or "None".
    var label: String {
        group == .off ? "None" : "\(group.label) \(index)"
    }

    static let none = WingSource(group: .off, index: 0)

    /// The OSC settings that patch this source onto a channel's input.
    func settings(forChannel channel: Int) -> [WingSetting] {
        [
            WingSetting(address: WingAddress.channelSourceGroup(channel), value: .string(group.rawValue)),
            WingSetting(address: WingAddress.channelSourceIndex(channel), value: .int(Int32(index)))
        ]
    }
}

/// The internal signal feeding a physical WING output socket — used to terminate
/// a chain at the speakers. Mirrors `WingSource` but for the *output* side: a
/// group (main, speaker bus, …) plus a 1-based index. Group tokens and node paths
/// are best-effort and must be confirmed against the console during the smoke
/// test (see `WingAddress.outputSource*`).
enum WingOutputSourceGroup: String, CaseIterable, Codable, Sendable {
    case off = "OFF"
    case main = "MAIN"
    case bus = "BUS"
    case matrix = "MTX"
    case channel = "CH"

    /// Human-readable group name.
    var label: String {
        switch self {
        case .off: return "None"
        case .main: return "Main"
        case .bus: return "Bus"
        case .matrix: return "Matrix"
        case .channel: return "Channel"
        }
    }
}

/// A specific WING output source: a group plus a 1-based index within it.
struct WingOutputSource: Identifiable, Hashable, Sendable {
    var group: WingOutputSourceGroup
    var index: Int

    var id: String { "\(group.rawValue)-\(index)" }

    /// Display label, e.g. "Bus 1" or "None".
    var label: String {
        group == .off ? "None" : "\(group.label) \(index)"
    }

    static let none = WingOutputSource(group: .off, index: 0)

    /// The OSC settings that patch this source onto a physical output socket.
    func settings(forOutput output: Int) -> [WingSetting] {
        [
            WingSetting(address: WingAddress.outputSourceGroup(output), value: .string(group.rawValue)),
            WingSetting(address: WingAddress.outputSourceIndex(output), value: .int(Int32(index)))
        ]
    }
}
