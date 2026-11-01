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

        @Test func decodedDocumentReencodesToIdenticalBytes() throws {
            let bytes = try document(identity: Set(kinds)).encoded()
            for _ in 0..<16 {
                let decoded = try DeviceCapabilityDocument.decode(from: bytes)
                #expect(try decoded.encoded() == bytes)
            }
        }
    }
}
