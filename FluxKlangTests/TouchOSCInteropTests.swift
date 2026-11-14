import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Synthetic client packets (byte arrays) for a TouchOSC-style client, fed through the merged OSC intake, namespace
/// mapper and feedback planner (#91, slice X1). Everything is a value: ticks are integers, and no test touches a
/// socket, clock, `Date`, MIDI, OSC device or network. The split across `+Table`, `+Packets` and `+Feedback`
/// keeps every file small; every fixture is nested in `TouchOSCInteropFixture` so no name leaves this lane.
@Suite("TouchOSC interop", .productionAccessAudit)
struct TouchOSCInteropTests {
    typealias Fixture = TouchOSCInteropFixture
    typealias OSC = OpenSoundControl
}

/// What one packet became after the intake stage and the namespace mapper.
enum TouchOSCDelivery: Equatable {
    case mapped([CommandOperation])
    case intake(OpenSoundControl.IntakeRefusal)
    case namespace(OpenSoundControl.NamespaceBatchRefusal)
}

enum TouchOSCInteropFixture {
    typealias OSC = OpenSoundControl

    static let goAction = ActionID(validated: "act.go")
    static let nextAction = ActionID(validated: "act.next")
    static let alpha = OSC.PeerKey(rawValue: 1)
    /// Twelve bytes that start with neither `/` nor `#`: the decoder refuses them as `unrecognizedPacket`.
    static let garbage = [UInt8](repeating: 0xFF, count: 12)

    // MARK: Table fixtures

    /// One accepted table row as the JSON file lists it.
    struct Row: Decodable {
        let control: String
        let address: String
        let kind: String
        let args: [String]
        let range: [Double]?
        let unit: String?
        let milliseconds: [Int]?
        let ticks: [Int64]?
        let example: [Scalar]
    }

    struct RefusedRow: Decodable {
        let address: String
        let refusal: String
    }

    struct Table: Decodable {
        let namespace: String
        let accepted: [Row]
        let refused: [RefusedRow]
    }

    enum Scalar: Decodable, Equatable {
        case number(Double)
        case word(String)

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Double.self) {
                self = .number(number)
            } else {
                self = .word(try container.decode(String.self))
            }
        }
    }

    enum FixtureError: Error { case badExample(String) }

    static func table() throws -> Table {
        try JSONDecoder().decode(Table.self, from: Data(tableText.utf8))
    }

    /// The example arguments of a row, typed by the row's `args` list.
    static func arguments(of row: Row) throws -> [OSC.Argument] {
        guard row.args.count == row.example.count else { throw FixtureError.badExample(row.address) }
        return try zip(row.args, row.example).map { type, value in
            switch (type, value) {
            case ("float32", .number(let number)): .float32(Float(number))
            case ("int32", .number(let number)): .int32(Int32(number))
            case ("impulse", .word("impulse")): .impulse
            default: throw FixtureError.badExample(row.address)
            }
        }
    }

    // MARK: Mapper

    static func catalog() -> ParameterCatalog { ParameterCatalog.wing }

    static func routeTable() throws -> OSC.RouteTable {
        try OSC.RouteTable(
            parameters: [
                OSC.ParameterRoute(name: "fader", id: ParameterCatalog.wingFaderDecibels),
                OSC.ParameterRoute(name: "mute", id: ParameterCatalog.wingMute),
                OSC.ParameterRoute(name: "pan", id: ParameterCatalog.wingPan),
                OSC.ParameterRoute(name: "send", id: ParameterCatalog.wingSendDecibels),
                OSC.ParameterRoute(name: "colour", id: ParameterCatalog.wingColour)
            ],
            actions: [OSC.ActionRoute(name: "go", id: goAction), OSC.ActionRoute(name: "next", id: nextAction)],
            transport: [.start, .stop, .locate], catalog: catalog()
        )
    }

    static func mapper() throws -> OSC.ControlMapper { OSC.ControlMapper(table: try routeTable()) }

    static func message(_ address: String, _ arguments: [OSC.Argument] = []) throws -> OSC.Message {
        OSC.Message(address: try OSC.AddressPattern(address), arguments: arguments)
    }

    /// The mapped operation or the typed refusal of one message, through the table-driven mapper.
    static func map(
        _ address: String, _ arguments: [OSC.Argument] = []
    ) throws -> Result<CommandOperation, OSC.NamespaceRefusal> {
        let mapper = try mapper()
        let message = try message(address, arguments)
        do throws(OSC.NamespaceRefusal) {
            return .success(try mapper.map(message))
        } catch {
            return .failure(error)
        }
    }

    /// The typed refusal of one message; `nil` when it maps.
    static func refusal(_ address: String, _ arguments: [OSC.Argument] = []) throws -> OSC.NamespaceRefusal? {
        if case .failure(let refusal) = try map(address, arguments) { return refusal }
        return nil
    }

    // MARK: Packets

    static func encode(_ address: String, _ arguments: [OSC.Argument] = []) throws -> [UInt8] {
        try OSC.Encoder().encode(message(address, arguments))
    }

    /// A length-prefixed stream frame of `packet` (the four-byte big-endian header, then the packet).
    static func framed(_ packet: [UInt8]) throws -> [UInt8] {
        try OSC.StreamFramer.frame(packet, framing: .lengthPrefixed)
    }

    // MARK: Pipelines

    /// Every literal table address, so the allow-list admits accepted rows and refused rows alike: the namespace
    /// refusals can then be observed after the intake stage. A wildcard row is not a literal and is left out.
    static func allowList() throws -> OSC.AllowList {
        let table = try table()
        let addresses = table.accepted.map(\.address) + table.refused.map(\.address).filter { !$0.contains("*") }
        return try OSC.AllowList(addresses.map { try OSC.AddressPattern($0) })
    }

    static func budget(packets: Int = 8, bytes: Int = 1 << 20, malformed: Int = 2) throws -> OSC.IntakeBudget {
        try OSC.IntakeBudget(
            windowTicks: 10, maximumPackets: packets, maximumBytes: bytes, maximumMalformed: malformed,
            cooldownTicks: 20
        )
    }

    static func policy(
        _ transport: OSC.EndpointTransport = .datagram, packets: Int = 8
    ) throws -> OSC.EndpointPolicy {
        try OSC.EndpointPolicy(
            transport: transport, allowList: allowList(), budget: budget(packets: packets), maximumPeers: 4,
            idleTicks: 10, maximumPacketBytes: 65_536, maximumBundleDepth: 8
        )
    }

    static func pipeline(
        _ transport: OSC.EndpointTransport = .datagram, packets: Int = 8
    ) throws -> OSC.IntakePipeline {
        var pipeline = OSC.IntakePipeline()
        try pipeline.enable(policy(transport, packets: packets))
        return pipeline
    }

    /// Hands an intake result to the mapper the way a host would: only a successful intake reaches it.
    static func deliver(_ result: OSC.IntakeResult, to mapper: OSC.ControlMapper) -> TouchOSCDelivery {
        switch result {
        case .failure(let refusal):
            return .intake(refusal)
        case .success(let batches):
            do throws(OSC.NamespaceBatchRefusal) {
                return .mapped(try mapper.map(batch: batches.flatMap { $0 }))
            } catch {
                return .namespace(error)
            }
        }
    }

    static func datagram(
        _ pipeline: inout OSC.IntakePipeline, _ bytes: [UInt8], now: UInt64 = 0
    ) throws -> TouchOSCDelivery {
        deliver(pipeline.receive(datagram: bytes, from: alpha, now: now), to: try mapper())
    }

    /// Every result of every chunk, in order; a chunk refused at the gates is returned as the only entry.
    static func chunks(
        _ pipeline: inout OSC.IntakePipeline, _ pieces: [[UInt8]], now: UInt64 = 0
    ) throws -> [TouchOSCDelivery] {
        let mapper = try mapper()
        var deliveries: [TouchOSCDelivery] = []
        for piece in pieces {
            switch pipeline.receive(chunk: piece, from: alpha, now: now) {
            case .refused(let refusal): return deliveries + [.intake(refusal)]
            case .consumed(let results): deliveries += results.map { deliver($0, to: mapper) }
            }
        }
        return deliveries
    }

    // MARK: Addresses

    /// `/fk/v1/param/` followed by `count` bytes of one segment (one 'a' per byte).
    static func longSegment(_ count: Int) -> String { "/fk/v1/param/" + String(repeating: "a", count: count) }

    /// `count` bytes in all, as three short segments and one segment holding the remaining bytes.
    static func address(ofBytes count: Int) -> String { longSegment(count - 13) }
}
