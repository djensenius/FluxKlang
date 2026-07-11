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

    // MARK: - I/O connector names (provisional)

    /// Number of LOCAL line-output connectors FluxKlang reads/labels. Matches the
    /// output range the effect editor offers.
    static let localOutputCount = 8

    /// Physical *input* connector scribble name, e.g. `/io/in/LCL/1/name`. This
    /// is a best guess at the WING I/O name node and is provisional until
    /// verified against hardware. Covers the LOCAL preamp bank that channel
    /// inputs patch from, so the app can show what's plugged into each input.
    static func inputName(_ connector: Int) -> String {
        "/io/in/LCL/\(connector)/name"
    }

    /// Physical *output* connector scribble name, e.g. `/io/out/LCL/1/name`.
    /// Best guess, provisional until verified against hardware. Covers the LOCAL
    /// line-output bank effects are sent out of.
    static func outputName(_ connector: Int) -> String {
        localOutput(connector) + "/name"
    }

    // MARK: - Bulk refresh

    /// Every node address worth querying to pre-populate the value cache after
    /// connecting, so the UI reflects the console's current state immediately
    /// instead of filling in node-by-node as broadcasts arrive. Covers the
    /// per-strip basics (fader, mute, name, pan, colour), the channel input
    /// patches, and the send/main matrices across all `WingNodeKind` cases.
    static func allQueryAddresses() -> [String] {
        var addresses: [String] = []
        let busCount = WingNodeKind.bus.count
        let mainCount = WingNodeKind.main.count
        for kind in WingNodeKind.allCases {
            for index in 1...kind.count {
                addresses.append(fader(kind, index))
                addresses.append(mute(kind, index))
                addresses.append(name(kind, index))
                addresses.append(pan(kind, index))
                addresses.append(color(kind, index))
                for bus in 1...busCount {
                    addresses.append(sendOn(kind, index, toBus: bus))
                    addresses.append(sendLevel(kind, index, toBus: bus))
                }
                for main in 1...mainCount {
                    addresses.append(mainOn(kind, index, toMain: main))
                    addresses.append(mainLevel(kind, index, toMain: main))
                }
            }
        }
        for channel in 1...WingNodeKind.channel.count {
            addresses.append(channelSourceGroup(channel))
            addresses.append(channelSourceIndex(channel))
        }
        // Physical output socket source patches (which internal main/bus/matrix
        // feeds each local output), so the patchbay and routing snapshots reflect
        // the console's current output routing.
        for output in 1...localOutputCount {
            addresses.append(outputSourceGroup(output))
            addresses.append(outputSourceIndex(output))
        }
        // Best-guess physical I/O connector names (LOCAL bank); provisional until
        // verified against hardware.
        for connector in 1...WingSourceGroup.local.count {
            addresses.append(inputName(connector))
        }
        for connector in 1...localOutputCount {
            addresses.append(outputName(connector))
        }
        return addresses
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

    /// Number of GET queries issued per batch during a bulk refresh. Querying
    /// every node is a lot of OSC traffic, so it is paced in small batches to
    /// avoid overwhelming the console or dropping UDP replies.
    static let bulkRefreshBatchSize = 32

    /// Pause between bulk-refresh batches, giving the console time to reply.
    static let bulkRefreshBatchDelay: Duration = .milliseconds(20)
}
