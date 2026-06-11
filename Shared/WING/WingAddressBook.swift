//
//  WingAddressBook.swift
//  FluxKlang
//
//  Typed builders for the Behringer WING OSC address space. Paths follow the
//  WING OSC node tree (e.g. /ch/1/fdr, /bus/2/mute, /ch/3/in/conn/grp). Faders
//  are normalised floats (see FaderMath), /lvl send values are in dB, mutes are
//  ints (0 = unmuted, 1 = muted) and names are strings.
//

import Foundation

/// The strip types FluxKlang addresses on the WING.
enum WingNodeKind: String, CaseIterable, Sendable, Codable {
    case channel = "ch"
    case aux
    case bus
    case main
    case matrix = "mtx"
    case dca

    /// Number of strips of this kind on a WING Rack.
    var count: Int {
        switch self {
        case .channel: return 40
        case .aux: return 8
        case .bus: return 16
        case .main: return 4
        case .matrix: return 8
        case .dca: return 16
        }
    }

    /// Human-readable singular label for a strip of this kind.
    var label: String {
        switch self {
        case .channel: return "Channel"
        case .aux: return "Aux"
        case .bus: return "Bus"
        case .main: return "Main"
        case .matrix: return "Matrix"
        case .dca: return "DCA"
        }
    }
}

/// Builds WING OSC address strings. All strip indices are 1-based, matching the
/// numbering used on the console and in the WING Co-Pilot app.
enum WingAddress {
    /// Root node for a strip, e.g. `/ch/1`.
    static func node(_ kind: WingNodeKind, _ index: Int) -> String {
        "/\(kind.rawValue)/\(index)"
    }

    /// Fader position node (normalised `0.0...1.0`), e.g. `/ch/1/fdr`.
    static func fader(_ kind: WingNodeKind, _ index: Int) -> String {
        node(kind, index) + "/fdr"
    }

    /// Mute node (int `0`/`1`), e.g. `/ch/1/mute`.
    static func mute(_ kind: WingNodeKind, _ index: Int) -> String {
        node(kind, index) + "/mute"
    }

    /// Scribble-strip name node (string), e.g. `/ch/1/name`.
    static func name(_ kind: WingNodeKind, _ index: Int) -> String {
        node(kind, index) + "/name"
    }

    /// Pan node, e.g. `/ch/1/pan`.
    static func pan(_ kind: WingNodeKind, _ index: Int) -> String {
        node(kind, index) + "/pan"
    }

    /// Colour node, e.g. `/ch/1/col`.
    static func color(_ kind: WingNodeKind, _ index: Int) -> String {
        node(kind, index) + "/col"
    }

    // MARK: - Input source patching (channels)

    /// Input source group for a channel, e.g. `/ch/1/in/conn/grp`.
    static func channelSourceGroup(_ channel: Int) -> String {
        "/ch/\(channel)/in/conn/grp"
    }

    /// Input source index within the group, e.g. `/ch/1/in/conn/in`.
    static func channelSourceIndex(_ channel: Int) -> String {
        "/ch/\(channel)/in/conn/in"
    }

    // MARK: - Sends

    /// Bus-send on/off, e.g. `/ch/1/send/3/on`.
    static func sendOn(_ kind: WingNodeKind, _ index: Int, toBus bus: Int) -> String {
        node(kind, index) + "/send/\(bus)/on"
    }

    /// Bus-send level in dB, e.g. `/ch/1/send/3/lvl`.
    static func sendLevel(_ kind: WingNodeKind, _ index: Int, toBus bus: Int) -> String {
        node(kind, index) + "/send/\(bus)/lvl"
    }

    /// Main-assignment on/off, e.g. `/ch/1/main/1/on`.
    static func mainOn(_ kind: WingNodeKind, _ index: Int, toMain main: Int) -> String {
        node(kind, index) + "/main/\(main)/on"
    }

    /// Main-send level in dB, e.g. `/ch/1/main/1/lvl`.
    static func mainLevel(_ kind: WingNodeKind, _ index: Int, toMain main: Int) -> String {
        node(kind, index) + "/main/\(main)/lvl"
    }

    // MARK: - Output patching

    /// Root node for a physical local output socket, e.g. `/io/out/LCL/1`. On the
    /// WING the I/O tree groups outputs by connector bank; FluxKlang's "Output N"
    /// nodes are the local line outputs, which live under the `LCL` bank.
    private static func localOutput(_ output: Int) -> String {
        "/io/out/LCL/\(output)"
    }

    /// Source *group* node for a physical output, e.g. `/io/out/LCL/1/grp`. This
    /// patches which internal signal (a main, bus or matrix) feeds the output your
    /// speakers are plugged into — i.e. how a chain "reaches the speakers". The
    /// value is a source-group token such as `MAIN`, `BUS`, `MTX` or `OFF`
    /// (see `WingOutputSource`).
    static func outputSourceGroup(_ output: Int) -> String {
        localOutput(output) + "/grp"
    }

    /// Source *index* within the group for a physical output, e.g.
    /// `/io/out/LCL/1/in`. 1-based, addressing a strip within the group selected
    /// by the matching `/grp` node.
    static func outputSourceIndex(_ output: Int) -> String {
        localOutput(output) + "/in"
    }

    // MARK: - Console

    /// Subscription / keep-alive command. Send periodically to keep receiving
    /// value updates (including changes made in the WING Co-Pilot app).
    static let subscribe = "/*S"

    /// Console information request, used during discovery.
    static let info = "/?"
}

/// Network constants for talking to a WING over OSC/UDP.
enum WingNetwork {
    /// The WING OSC server port.
    static let defaultPort: UInt16 = 2223

    /// How often the subscription must be renewed to keep updates flowing.
    static let subscriptionRenewInterval: Duration = .seconds(9)
}
