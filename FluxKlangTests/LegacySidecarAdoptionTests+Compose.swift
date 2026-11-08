import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// `LegacySidecarPlan.extending`: composing a plan with an adopted result into a new verified package.
extension LegacySidecarAdoptionTests {
    private static let projectPath = "project.json"
    private static let graphPath = "graphs/legacy-studio.json"
    private static let originalGraphPath = "legacy/StudioGraph.json"
    private static let originalEndpointsPath = "legacy/StudioEndpoints.json"

    private static func fullPlan() throws -> LegacySidecarPlan {
        try LegacySidecarPlan.make(
            draft: Fixture.draftBytes, connections: Fixture.connectionsBytes, limits: Fixture.limits()
        )
    }

    private static func paths(_ members: [ProjectPackageMember]) -> [[UInt8]] {
        members.map { Array($0.path.utf8) }
    }

    @Test
    func composedSidecarFilesKeepTheirExactBytesAtTheFixedPathsAsOpaqueState() throws {
        let result = try Fixture.adopted(endpoints: nil)
        let composed = try Self.fullPlan().extending(result, policy: Fixture.policy())
        let draft = try #require(Fixture.file(LegacySidecarPlan.draftPath, in: composed))
        let connections = try #require(Fixture.file(LegacySidecarPlan.connectionsPath, in: composed))
        #expect(Array(draft.bytes) == Array(Fixture.draftBytes))
        #expect(Array(connections.bytes) == Array(Fixture.connectionsBytes))
        #expect(draft.role == .opaqueState)
        #expect(connections.role == .opaqueState)
    }

    @Test
    func composedProjectAndGraphMembersAreByteIdenticalToTheResultsMembers() throws {
        let result = try Fixture.adopted(endpoints: nil)
        let composed = try Self.fullPlan().extending(result, policy: Fixture.policy())
        let project = try #require(Fixture.file(Self.projectPath, in: composed))
        let graph = try #require(Fixture.file(Self.graphPath, in: composed))
        let originalProject = try #require(Fixture.file(Self.projectPath, in: result.contents))
        let originalGraph = try #require(Fixture.file(Self.graphPath, in: result.contents))
        #expect(Array(project.bytes) == Array(originalProject.bytes))
        #expect(Array(graph.bytes) == Array(originalGraph.bytes))
        #expect(project.role == originalProject.role)
        #expect(graph.role == originalGraph.role)
    }

    @Test
    func composingKeepsTheOriginalGraphAndEndpointsBytesAndAddsOnlyTheSidecarFiles() throws {
        let result = try Fixture.adopted(endpoints: Fixture.standardEndpoints)
        let composed = try Self.fullPlan().extending(result, policy: Fixture.policy())
        let graph = try #require(Fixture.file(Self.originalGraphPath, in: composed))
        let endpoints = try #require(Fixture.file(Self.originalEndpointsPath, in: composed))
        #expect(Array(graph.bytes) == Array(Fixture.graph))
        #expect(Array(endpoints.bytes) == Array(Fixture.standardEndpoints))
        let composedPaths = composed.files.map { Array($0.path.utf8) }
        let expected: [[UInt8]] = [
            Self.projectPath, Self.graphPath, Self.originalGraphPath, Self.originalEndpointsPath,
            LegacySidecarPlan.draftPath, LegacySidecarPlan.connectionsPath
        ].map { Array($0.utf8) }
        #expect(Set(composedPaths) == Set(expected))
        #expect(composedPaths.count == 6)
    }

    @Test
    func composedOpaqueStateMembersAreTheResultsMembersPlusTheTwoSidecarPathsAsASet() throws {
        let result = try Fixture.adopted(endpoints: Fixture.standardEndpoints)
        let composed = try Self.fullPlan().extending(result, policy: Fixture.policy())
        let before = Set(Self.paths(result.contents.manifest.opaqueState))
        let after = Set(Self.paths(composed.manifest.opaqueState))
        let added: Set<[UInt8]> = [
            Array(LegacySidecarPlan.draftPath.utf8), Array(LegacySidecarPlan.connectionsPath.utf8)
        ]
        let expected = before.union(added)
        #expect(after == expected)
        #expect(before.count == 2)
        #expect(Self.paths(composed.manifest.opaqueState).count == 4)
    }

    @Test
    func composedOpaqueStateIsListedAsTheResultsFilesInPathOrderThenTheDraftThenTheConnections() throws {
        let result = try Fixture.adopted(endpoints: Fixture.standardEndpoints)
        let composed = try Self.fullPlan().extending(result, policy: Fixture.policy())
        let listed = Self.paths(composed.manifest.opaqueState)
        let expected: [[UInt8]] = [
            Self.originalEndpointsPath, Self.originalGraphPath, LegacySidecarPlan.draftPath,
            LegacySidecarPlan.connectionsPath
        ].map { Array($0.utf8) }
        #expect(listed == expected)
    }

    @Test
    func theComposedPackageDecodesAgainWithTheResultsProjectAndGraphDocuments() throws {
        let result = try Fixture.adopted(endpoints: Fixture.standardEndpoints)
        let composed = try Self.fullPlan().extending(result, policy: Fixture.policy())
        let documents = try ProjectPackageDocuments(contents: composed)
        #expect(documents.project == result.documents.project)
        #expect(documents.graphs == result.documents.graphs)
        #expect(documents.contents == composed)
    }

    @Test
    func anEmptyPlanOverAResultWithoutEndpointsGivesTheResultsFilesAndManifest() throws {
        let result = try Fixture.adopted(endpoints: nil)
        let plan = try LegacySidecarPlan.make(draft: nil, connections: nil, limits: Fixture.limits())
        #expect(plan.isEmpty)
        let composed = try plan.extending(result, policy: Fixture.policy())
        #expect(composed.files == result.contents.files)
        #expect(composed.manifest == result.contents.manifest)
        #expect(composed.directories == result.contents.directories)
    }

    @Test
    func anEmptyPlanOverAResultWithEndpointsGivesTheResultsFilesAndTheSameOpaqueMembersAsASet() throws {
        let result = try Fixture.adopted(endpoints: Fixture.standardEndpoints)
        let plan = try LegacySidecarPlan.make(draft: nil, connections: nil, limits: Fixture.limits())
        let composed = try plan.extending(result, policy: Fixture.policy())
        #expect(composed.files == result.contents.files)
        let before = Set(Self.paths(result.contents.manifest.opaqueState))
        let after = Set(Self.paths(composed.manifest.opaqueState))
        #expect(after == before)
        #expect(after.count == 2)
    }

    @Test
    func composingTwiceGivesIdenticalManifestBytesAndFiles() throws {
        let result = try Fixture.adopted(endpoints: Fixture.standardEndpoints)
        let plan = try Self.fullPlan()
        let first = try plan.extending(result, policy: Fixture.policy())
        let second = try plan.extending(result, policy: Fixture.policy())
        #expect(Array(first.manifestBytes) == Array(second.manifestBytes))
        #expect(first.files == second.files)
        #expect(first == second)
    }

    @Test
    func theTwoSidecarPathsDifferFromEachOtherAndFromTheFourPackagePathsByUTF8Bytes() {
        let all: [String] = [
            LegacySidecarPlan.draftPath, LegacySidecarPlan.connectionsPath, Self.projectPath, Self.graphPath,
            Self.originalGraphPath, Self.originalEndpointsPath
        ]
        let distinct = Set(all.map { Array($0.utf8) })
        #expect(distinct.count == 6)
        #expect(Array(Self.originalGraphPath.utf8) == Array(LegacyAdoption.originalGraphPath.utf8))
        #expect(Array(Self.originalEndpointsPath.utf8) == Array(LegacyAdoption.originalEndpointsPath.utf8))
        #expect(Array(Self.projectPath.utf8) == Array(LegacyAdoption.projectPath.utf8))
        #expect(Array(Self.graphPath.utf8) == Array(LegacyAdoption.graphPath.utf8))
    }

    // MARK: Limits applied at composition

    @Test
    func extraFilesThatFillTheEntryLimitAreComposedAndOneMoreEntryIsRefused() throws {
        let result = try Fixture.adopted(endpoints: nil)
        let plan = try Self.fullPlan()
        let fits = try plan.extending(result, policy: Fixture.policy(entries: 8))
        #expect(fits.files.count == 5)
        let tight = try Fixture.policy(entries: 7)
        let refusal = Fixture.composeRefusal(plan, result, tight)
        let expected: LegacySidecarRefusal = .assembly(.package(.entryLimitExceeded))
        #expect(refusal == expected)
    }

    @Test
    func aPlanBuiltUnderLargerLimitsIsRefusedByAPolicyWithASmallerEntryLimit() throws {
        let result = try Fixture.adopted(endpoints: nil)
        let big = Fixture.object(bytes: 3000)
        let plan = try LegacySidecarPlan.make(
            draft: big, connections: Fixture.connectionsBytes, limits: Fixture.limits()
        )
        let tight = try Fixture.policy(entryBytes: 2999)
        let refusal = Fixture.composeRefusal(plan, result, tight)
        let expected: LegacySidecarRefusal = .assembly(.package(.entryBytesExceeded))
        #expect(refusal == expected)
    }

    @Test
    func sidecarsWithinTheEntryLimitWhoseRunningTotalCrossesThePolicyTotalAreRefusedAsTotalBytes() throws {
        let result = try Fixture.adopted(endpoints: nil)
        let original = try #require(Fixture.file(Self.originalGraphPath, in: result.contents))
        let plan = try LegacySidecarPlan.make(
            draft: Fixture.object(bytes: 3000), connections: Fixture.object(bytes: 2000), limits: Fixture.limits()
        )
        let carriedBytes = original.bytes.count
        let total = carriedBytes + 4999
        let tight = try Fixture.policy(entryBytes: 3000, totalBytes: total)
        let refusal = Fixture.composeRefusal(plan, result, tight)
        let expected: LegacySidecarRefusal = .assembly(.package(.totalBytesExceeded))
        #expect(refusal == expected)
    }
}
