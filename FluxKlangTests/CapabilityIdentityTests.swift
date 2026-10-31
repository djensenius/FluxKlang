import Foundation
import Testing
@testable import FluxKlang

struct CapabilityIdentityTests {
    @Test func reservedExtensionsAreSeparateFromUnknownMetadata() throws {
        let input = Data("""
        {"id":"cap.audio","label":"Audio","extensions":{"vendor":"wide"},"future":"kept"}
        """.utf8)
        let capability = try ContractCoding.decode(CapabilityDefinition.self, from: input)
        #expect(capability.extensions == ["vendor": .string("wide")])
        #expect(capability.unknownFields == ["future": .string("kept")])

        let output = try ContractCoding.makeEncoder().encode(capability)
        #expect(try ContractCoding.decode(JSONValue.self, from: output)
            == ContractCoding.decode(JSONValue.self, from: input))
    }

    @Test func editingLabelPreservesFutureMetadata() throws {
        let input = Data("""
        {"id":"cap.audio.multichannel","label":"Original","vendor":{"formats":["audio"],"revision":2},"optional":null}
        """.utf8)
        var capability = try ContractCoding.decode(CapabilityDefinition.self, from: input)
        capability.label = "Multichannel audio"

        let output = try ContractCoding.makeEncoder().encode(capability)
        let decoded = try ContractCoding.decode(CapabilityDefinition.self, from: output)
        let expected = Data("""
        {"id":"cap.audio.multichannel","label":"Multichannel audio",\
        "vendor":{"formats":["audio"],"revision":2},"optional":null}
        """.utf8)
        #expect(decoded == capability)
        #expect(try ContractCoding.decode(JSONValue.self, from: output)
            == ContractCoding.decode(JSONValue.self, from: expected))
    }

    @Test func unknownMetadataCannotOverrideCatalogIdentity() throws {
        var capability = CapabilityDefinition(id: CapabilityID(validated: "cap.audio"), label: "Audio")
        capability.unknownFields = ["id": .string("cap.other"), "label": .string("Other")]

        let output = try ContractCoding.makeEncoder().encode(capability)
        let decoded = try ContractCoding.decode(CapabilityDefinition.self, from: output)
        #expect(decoded.id == capability.id)
        #expect(decoded.label == capability.label)
        #expect(decoded.unknownFields.isEmpty)
    }
}
