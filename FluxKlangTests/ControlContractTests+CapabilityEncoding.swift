import Foundation
import Testing
@testable import FluxKlang

private let kinds: [IdentityEvidence] = [.deviceUID, .endpointUID, .transport, .channelLayout, .modelUID]

private func document(identity evidence: Set<IdentityEvidence>) throws -> DeviceCapabilityDocument {
    let device = try DeviceDescriptor(
        id: DeviceID(validated: "dev.interface"), kind: .audioInterface,
        layout: ChannelLayout(inputs: 2, outputs: 2, sampleRate: 48_000), binding: .reported,
        identity: DeviceIdentity(.init(uid: "physical-interface-1", evidence: evidence))
    )
    return try DeviceCapabilityDocument(revision: .initial, host: HostID(validated: "host.encoding"),
                                        hostEpoch: .initial, devices: [device], routes: [])
}

/// The reference document carrying `number` as a top-level and a nested extension value.
private func document(extension number: JSONValue) throws -> DeviceCapabilityDocument {
    var value = try document(identity: [.deviceUID])
    value.extensions = ["gain": number, "nested": .object(["values": .array([number])])]
    return value
}

/// An evidence set equal to `kinds`, built in a rotated order with its own
/// capacity and a removal, so its hash-iteration order is independent of others.
private func rebuilt(trial: Int) -> Set<IdentityEvidence> {
    var set = Set<IdentityEvidence>(minimumCapacity: 1 + 3 * trial)
    let shift = trial % kinds.count
    for kind in kinds[shift...] + kinds[..<shift] { set.insert(kind) }
    let removed = kinds[trial % kinds.count]
    set.remove(removed)
    set.insert(removed)
    return set
}

extension ControlContractTests {
    /// Capability documents are compared by their encoded bytes (activation
    /// staleness at commit), so their encoding must be canonical: documents
    /// compared by bytes must not encode unordered collections in iteration order.
    struct CapabilityEncoding {
        @Test func equalEvidenceSetsEncodeIdentically() throws {
            let expected = try document(identity: Set(kinds)).encoded()
            for trial in 0..<64 {
                let evidence = rebuilt(trial: trial)
                #expect(evidence == Set(kinds))
                #expect(try document(identity: evidence).encoded() == expected, "trial \(trial)")
            }
        }

        @Test func evidenceIsWrittenSortedByRawValue() throws {
            let identity = try DeviceIdentity(.init(uid: "physical-interface-1", evidence: rebuilt(trial: 3)))
            let written = try ControlJSON.value(identity)
            let sorted = kinds.map(\.rawValue).sorted().map(JSONValue.string)
            #expect(written == .object(["uid": .string("physical-interface-1"), "evidence": .array(sorted)]))
        }

        /// Each pair is equal under `JSONValue`'s numeric equality, so the integral
        /// double must encode exactly like the integer it equals.
        @Test(arguments: [
            (JSONValue.double(9_223_372_036_854_775_808), JSONValue.uint(1 << 63)),
            (.double(18_446_744_073_709_549_568), .uint(18_446_744_073_709_549_568)),
            (.double(-9_223_372_036_854_775_808), .int(.min)),
            (.double(-0.0), .int(0)),
            (.double(48_000), .int(48_000))
        ])
        func integralDoubleEncodesLikeItsInteger(double: JSONValue, integer: JSONValue) throws {
            let doubled = try document(extension: double)
            let integral = try document(extension: integer)
            #expect(double == integer && doubled == integral)
            let bytes = try integral.encoded()
            #expect(try doubled.encoded() == bytes)
            #expect(try DeviceCapabilityDocument.decode(from: bytes).encoded() == bytes)
        }

        /// Non-integral doubles, and integral ones outside both Int64 and UInt64,
        /// keep Foundation's `Double` form and re-encode stably.
        @Test(arguments: [0.5, -1.5, 1e300, 18_446_744_073_709_551_616, -9_223_372_036_854_777_856])
        func otherDoublesKeepTheirDoubleForm(value: Double) throws {
            let encoder = ContractCoding.makeEncoder()
            #expect(try encoder.encode(JSONValue.double(value)) == encoder.encode(value))
            let bytes = try document(extension: .double(value)).encoded()
            #expect(try DeviceCapabilityDocument.decode(from: bytes).encoded() == bytes)
        }

        @Test func decodedDocumentReencodesToIdenticalBytes() throws {
            let bytes = try document(identity: Set(kinds)).encoded()
            for _ in 0..<16 {
                let decoded = try DeviceCapabilityDocument.decode(from: bytes)
                #expect(try decoded.encoded() == bytes)
            }
        }
    }
}
