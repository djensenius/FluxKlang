import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Input-order independence, and the purity scan of the production sources, of the capability negotiation (#83,
/// slice CAP1).
extension MIDICapabilityNegotiationTests {
    static func permutations<Element>(_ items: [Element]) -> [[Element]] {
        guard items.count > 1 else { return [items] }
        var result: [[Element]] = []
        for position in items.indices {
            var rest = items
            let head = rest.remove(at: position)
            for tail in permutations(rest) {
                result.append([head] + tail)
            }
        }
        return result
    }

    // MARK: - Input-order determinism

    @Test func everyPermutationOfFourBlocksGivesTheSameResult() throws {
        let blocks = [
            Self.block(3, first: 0), Self.block(0, first: 12, active: false), Self.block(7, first: 4),
            Self.block(1, first: 8)
        ]
        let reference = try Self.negotiated(try Self.full(blocks: blocks))
        let orders = Self.permutations(blocks)
        #expect(orders.count == 24)
        for order in orders {
            let result = try Self.negotiated(try Self.full(blocks: order))
            #expect(result == reference)
        }
        let indices = reference.functionBlocks.map(\.index)
        let expectedIndices = [0, 1, 3, 7]
        #expect(indices == expectedIndices)
    }

    @Test func reversedAndRotatedOrdersOfSixteenBlocksGiveTheSameResult() throws {
        let blocks = Self.tiles(16)
        let reference = try Self.negotiated(try Self.full(blocks: blocks))
        let reversed = try Self.negotiated(try Self.full(blocks: blocks.reversed()))
        #expect(reversed == reference)
        let rotated = Array(blocks[5...]) + Array(blocks[..<5])
        let rotatedResult = try Self.negotiated(try Self.full(blocks: rotated))
        #expect(rotatedResult == reference)
    }

    @Test func everyPermutationOfFourProfilesGivesTheSameResult() throws {
        let profiles = [try Self.profile(9), try Self.profile(2), try Self.profile(2, 1), try Self.profile(5)]
        let reference = try Self.negotiated(try Self.full(profiles: profiles))
        let orders = Self.permutations(profiles)
        #expect(orders.count == 24)
        for order in orders {
            let result = try Self.negotiated(try Self.full(profiles: order))
            #expect(result == reference)
        }
        let expected = [try Self.profile(2), try Self.profile(2, 1), try Self.profile(5), try Self.profile(9)]
        #expect(reference.profiles == expected)
    }

    @Test func everyPermutationOfBlocksWithSeveralDefectsGivesTheSameRefusal() throws {
        let blocks = [
            Self.block(9, first: 16), Self.block(2, first: 0, count: 0), Self.tile(5), Self.block(5, first: 4, count: 4)
        ]
        let expected: Refusal = .functionBlockInvalid(index: 2, .invalidField(.groupCount, value: 0))
        let orders = Self.permutations(blocks)
        for order in orders {
            let result = Self.refusal(try Self.facts(declared: 4, order))
            #expect(result == expected)
        }
    }

    @Test func everyPermutationOfBlocksWithARepeatedIndexAndOverlapsGivesTheSameRefusal() throws {
        let blocks = [
            Self.block(4, first: 0, count: 4), Self.block(4, first: 8, count: 2), Self.block(1, first: 2, count: 4),
            Self.block(1, first: 12, count: 2)
        ]
        let expected: Refusal = .duplicateFunctionBlockIndex(1)
        for order in Self.permutations(blocks) {
            let result = Self.refusal(try Self.facts(declared: 4, order))
            #expect(result == expected)
        }
    }

    @Test func everyPermutationOfOverlappingBlocksGivesTheSameFirstPair() throws {
        let blocks = [
            Self.block(6, first: 2, count: 4), Self.block(0, first: 0, count: 3), Self.block(3, first: 8, count: 2),
            Self.block(1, first: 5, count: 2)
        ]
        let expected: Refusal = .overlappingFunctionBlockGroups(first: 0, second: 6)
        for order in Self.permutations(blocks) {
            let result = Self.refusal(try Self.facts(declared: 4, order))
            #expect(result == expected)
        }
    }

    @Test func everyPermutationOfRepeatedProfilesGivesTheSameRefusal() throws {
        let profiles = [try Self.profile(5), try Self.profile(2), try Self.profile(5), try Self.profile(2)]
        let expected: Refusal = .duplicateProfile(try Self.profile(2))
        for order in Self.permutations(profiles) {
            let result = Self.refusal(try Self.full(profiles: order))
            #expect(result == expected)
        }
    }

    @Test func twoInvalidBlocksWithTheSameIndexGiveTheSameRefusalInBothOrders() throws {
        let zeroCount = Self.block(5, first: 0, count: 0)
        let highFirst = Self.block(5, first: 16)
        let forward = Self.refusal(try Self.facts(declared: 2, [zeroCount, highFirst]))
        let backward = Self.refusal(try Self.facts(declared: 2, [highFirst, zeroCount]))
        let expected: Refusal = .functionBlockInvalid(index: 5, .invalidField(.groupCount, value: 0))
        #expect(forward == expected)
        #expect(backward == expected)
    }

    // MARK: - Purity of the production sources

    /// Tokens the production sources must not contain, comments included. They are assembled here so that this file
    /// does not contain them either.
    static let forbiddenTokens: [String] = [
        ["import Core", "MIDI"].joined(), ["import Swift", "UI"].joined(), ["Da", "te("].joined(),
        ["Clo", "ck"].joined(), ["Ta", "sk"].joined(), ["Dispatch", "Queue"].joined(), ["defa", "ult:"].joined(),
        ["Ran", "dom"].joined(), ["muta", "nt"].joined(), ["evid", "ence"].joined(), ["CA", "P1"].joined(),
        ["HAND", "OFF"].joined(), ["DES", "IGN"].joined()
    ]

    static let productionFiles = [
        "MIDICapabilityDiscovery.swift", "MIDICapabilityFacts.swift", "MIDICapabilityRefusal.swift",
        "MIDICapabilityResolver+Validate.swift", "MIDICapabilityResolver.swift", "MIDICapabilityResult.swift"
    ]

    static func productionDirectory(from path: String = #filePath) -> URL? {
        let here = URL(fileURLWithPath: path).deletingLastPathComponent()
        let candidates = [
            "../Shared/MIDI/Capability/Negotiation", "../../Sources/FluxKlang/Shared/MIDI/Capability/Negotiation"
        ]
        let marker = "MIDICapabilityResolver.swift"
        return candidates
            .map { here.appendingPathComponent($0).standardizedFileURL }
            .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent(marker).path) }
    }

    static let sourcesAreReachable = productionDirectory() != nil

    /// The forbidden tokens found in `text`, plus `import` for any line that starts with `import `.
    static func findings(in text: String) -> [String] {
        var found = forbiddenTokens.filter { text.contains($0) }
        let imports = text.split(whereSeparator: \.isNewline).filter { $0.hasPrefix("import ") }
        if imports.isEmpty == false { found.append("import") }
        return found
    }

    @Test func theScannerFlagsEveryForbiddenTokenAndAnyImportLineAndNothingElse() {
        for token in Self.forbiddenTokens {
            let found = Self.findings(in: "let value = \(token)")
            #expect(found.contains(token), "\(token)")
        }
        let clean: [String] = []
        #expect(Self.findings(in: "let value = 1\n// plain words") == clean)
        let importFinding = Self.findings(in: "import Swift\nlet value = 1")
        let expected = ["import"]
        #expect(importFinding == expected)
    }

    @Test(.enabled(if: Self.sourcesAreReachable, "the production sources are not next to the tests"))
    func theSixProductionFilesImportNothingAndNameNoForbiddenToken() throws {
        let directory = try #require(Self.productionDirectory())
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".swift") }.sorted()
        #expect(files == Self.productionFiles)
        for file in files {
            let text = try String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8)
            let found = Self.findings(in: text)
            let clean: [String] = []
            #expect(found == clean, "\(file)")
        }
    }
}
