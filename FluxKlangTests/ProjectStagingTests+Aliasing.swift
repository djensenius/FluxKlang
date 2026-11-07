import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension ProjectStagingTests {
    private static let aliasedSource = "set.fluxklang/source"

    /// A volume holding an old package at `Set.fluxklang` and a source package at `set.fluxklang/source`.
    private static func aliasVolume(caseInsensitive: Bool) throws -> Fake {
        var fake = Fake(caseInsensitive: caseInsensitive)
        if !caseInsensitive { fake.seedDirectory("set.fluxklang") }
        fake.seed(package: try Fixture.tiny("old"), at: Fixture.destination)
        fake.seed(package: try Fixture.tiny("new"), at: aliasedSource)
        return fake
    }

    @Test func anAliasedSourceBeneathTheDestinationIsRefusedAndTheStoreIsUntouched() throws {
        var fake = try Self.aliasVolume(caseInsensitive: true)
        let before = fake.nodes
        let result = try Fixture.importRun(Fixture.plan(.replaceExisting), from: Self.aliasedSource, &fake)
        #expect(Fixture.refusal(result) == .overlappingPaths)
        #expect(fake.nodes == before)
        #expect(fake.mutations.isEmpty)
        #expect(fake.shapes(at: Self.aliasedSource) == Fixture.shapes(try Fixture.tiny("new")))
    }

    @Test func aSourceNamedByAnAliasOfTheDestinationIsRefused() throws {
        var fake = try Self.aliasVolume(caseInsensitive: true)
        let before = fake.nodes
        let result = try Fixture.importRun(Fixture.plan(.replaceExisting), from: "SET.FLUXKLANG", &fake)
        #expect(Fixture.refusal(result) == .overlappingPaths)
        #expect(fake.nodes == before)
        #expect(fake.mutations.isEmpty)
    }

    @Test func aDestinationBeneathAnAliasedSourceIsRefused() throws {
        var fake = Fake(caseInsensitive: true)
        fake.seed(package: try Fixture.tiny("new"), at: "dir")
        let before = fake.nodes
        let plan = try Fixture.plan(.createNew, destination: "DIR/Out.fluxklang")
        let result = try Fixture.importRun(plan, from: "Dir", &fake)
        #expect(Fixture.refusal(result) == .overlappingPaths)
        #expect(fake.nodes == before)
        #expect(fake.mutations.isEmpty)
    }

    @Test func aSourceNamedByAnAliasOfTheStagingOrBackupNameIsRefused() throws {
        for alias in [".SET.FLUXKLANG.STAGING-T1", ".SET.FLUXKLANG.PREVIOUS-T1"] {
            var fake = Fake(caseInsensitive: true)
            fake.seed(package: try Fixture.tiny("new"), at: alias)
            let before = fake.nodes
            let result = try Fixture.importRun(Fixture.plan(.createNew), from: alias, &fake)
            #expect(Fixture.refusal(result) == .overlappingPaths, "\(alias)")
            #expect(fake.nodes == before)
            #expect(fake.mutations.isEmpty)
        }
    }

    @Test func theSameSpellingsOnACaseSensitiveStoreAreDifferentNodesAndTheImportSucceeds() throws {
        var fake = try Self.aliasVolume(caseInsensitive: false)
        let result = try Fixture.importRun(Fixture.plan(.replaceExisting), from: Self.aliasedSource, &fake)
        #expect(Fixture.value(result) != nil)
        #expect(fake.shapes(at: Fixture.destination) == Fixture.shapes(try Fixture.tiny("new")))
        #expect(fake.shapes(at: Self.aliasedSource) == Fixture.shapes(try Fixture.tiny("new")))
    }

    @Test func aStatusFaultDuringTheIdentityProbesIsATypedRefusalThatLeavesTheStoreUnchanged() throws {
        let plan = try Fixture.plan(.createNew)
        let start = Fixture.volume(source: try Fixture.tiny("new"))
        let probes = Scenario.aliasProbeCount(source: Fixture.source, plan: plan, in: start)
        #expect(probes == 4)
        for index in 0..<probes {
            var fake = start
            let before = fake.nodes
            fake.arm(.fault(.ioError, at: index))
            let result = try Fixture.importRun(plan, &fake)
            let expected = StagingRefusal.ioFailed(step: .preflight, fault: .ioError, cleanup: .notNeeded)
            #expect(Fixture.refusal(result) == expected, "\(index)")
            #expect(fake.nodes == before)
            #expect(fake.mutations.isEmpty)
        }
    }

    @Test func aSourceAtTheDeepestAcceptedDepthIsProbedOncePerPrefixWithoutTrapping() throws {
        let deepest = "a/b/c/d/e/f"
        var fake = Fake()
        for path in ["a", "a/b", "a/b/c", "a/b/c/d", "a/b/c/d/e", deepest] { fake.seedDirectory(path) }
        let result = try Fixture.importRun(Fixture.plan(.createNew), from: deepest, &fake)
        #expect(Fixture.refusal(result) != .overlappingPaths)
        let probed = try #require(fake.log.count >= 9 ? fake.log.prefix(9).map(\.operation) : nil)
        let chain: [Fake.FileOp] = ["a", "a/b", "a/b/c", "a/b/c/d", "a/b/c/d/e", deepest].map { .status($0) }
        let planned: [Fake.FileOp] = [Fixture.destination, Fixture.staging, Fixture.backup].map { .status($0) }
        #expect(probed == chain + planned)
    }

    @Test func nodesOnDifferentVolumesWithOneIdentityAreNotTheSameNode() throws {
        var fake = Fixture.volume()
        fake.seed(package: try Fixture.tiny("old"), at: Fixture.destination)
        fake.seed(package: try Fixture.tiny("new"), at: Fixture.source, volume: 2)
        fake.setIdentity(Fixture.destination, to: 900)
        fake.setIdentity(Fixture.source, to: 900)
        let result = try Fixture.importRun(Fixture.plan(.replaceExisting), &fake)
        #expect(Fixture.value(result) != nil)
        #expect(fake.shapes(at: Fixture.destination) == Fixture.shapes(try Fixture.tiny("new")))
    }

    @Test func anAbsentAliasedSourceIsLeftToTheLaterReadAndNotReportedAsAnOverlap() throws {
        var fake = try Self.aliasVolume(caseInsensitive: true)
        let before = fake.nodes
        let result = try Fixture.importRun(Fixture.plan(.replaceExisting), from: "set.fluxklang/missing", &fake)
        let refusal = try #require(Fixture.refusal(result))
        #expect(refusal != .overlappingPaths)
        #expect(fake.nodes == before)
    }

    // MARK: Symlinked prefixes

    private static let linkKinds: [ProjectPackageEntryKind] = [.symbolicLink, .unsupported]

    /// Models `link -> destination`: the link's status shows the link's own identity, and `link/source` shares
    /// one node identity with the destination's `source`.
    @Test func aSourceBeneathASymlinkToTheDestinationIsRefusedAndTheStoreIsUntouched() throws {
        var fake = Fixture.volume(old: try Fixture.tiny("old"))
        fake.seed(package: try Fixture.tiny("new"), at: Fixture.destination + "/source")
        let real = try #require(fake.nodes[Fixture.destination + "/source"]?.identity)
        fake.seedNode("link", kind: .symbolicLink)
        fake.seed(package: try Fixture.tiny("new"), at: "link/source")
        fake.setIdentity("link/source", to: real)
        let before = fake.nodes
        let result = try Fixture.importRun(Fixture.plan(.replaceExisting), from: "link/source", &fake)
        #expect(Fixture.refusal(result) == .overlappingPaths)
        #expect(fake.nodes == before)
        #expect(fake.mutations.isEmpty)
        #expect(fake.nodes[Fixture.destination + "/source"]?.identity == real)
        #expect(fake.shapes(at: Fixture.destination + "/source") == Fixture.shapes(try Fixture.tiny("new")))
    }

    @Test func aSymlinkPrefixOnAnyPlanNameIsRefusedBeforeAnyMutation() throws {
        // The staging and backup names share the destination's parent, so the destination chain is the only
        // distinct reachable case.
        for kind in Self.linkKinds {
            var fake = Fixture.volume(source: try Fixture.tiny("new"))
            fake.seedNode("p", kind: kind)
            fake.seedDirectory("p/inner")
            let before = fake.nodes
            let plan = try Fixture.plan(.createNew, destination: "p/inner/Set.fluxklang")
            let result = try Fixture.importRun(plan, &fake)
            #expect(Fixture.refusal(result) == .overlappingPaths, "\(kind)")
            #expect(fake.nodes == before)
            #expect(fake.mutations.isEmpty)
        }
    }

    @Test func aSymlinkAtTheOutermostOrDeepestStrictPrefixIsRefusedButRealDirectoriesSucceed() throws {
        let plan = try Fixture.plan(.createNew, destination: "a/b/Out.fluxklang")
        for fromSource in [false, true] {
            for linked in ["a", "a/b", ""] {
                for kind in Self.linkKinds {
                    var fake = fromSource ? Fixture.volume() : Fixture.volume(source: try Fixture.tiny("new"))
                    for directory in ["a", "a/b"] {
                        if directory == linked {
                            fake.seedNode(directory, kind: kind)
                        } else {
                            fake.seedDirectory(directory)
                        }
                    }
                    if fromSource { fake.seed(package: try Fixture.tiny("new"), at: "a/b/src") }
                    let before = fake.nodes
                    let path = fromSource ? "a/b/src" : Fixture.source
                    let result = try Fixture.importRun(plan, from: path, &fake)
                    let label = "\(fromSource) \(linked) \(kind)"
                    if linked.isEmpty {
                        #expect(Fixture.value(result) != nil, "\(label)")
                    } else {
                        #expect(Fixture.refusal(result) == .overlappingPaths, "\(label)")
                        #expect(fake.nodes == before, "\(label)")
                        #expect(fake.mutations.isEmpty, "\(label)")
                    }
                }
            }
        }
    }

    @Test func aSymlinkOrUnsupportedLeafKeepsItsLaterKindRefusal() throws {
        for kind in Self.linkKinds {
            var source = Fixture.volume()
            source.seedNode(Fixture.source, kind: kind)
            let sourceResult = try Fixture.importRun(Fixture.plan(.createNew), &source)
            #expect(Fixture.refusal(sourceResult) == .packageIO(.missingMember), "\(kind)")
            var destination = Fixture.volume(source: try Fixture.tiny("new"))
            destination.seedNode(Fixture.destination, kind: kind)
            let destinationResult = try Fixture.importRun(Fixture.plan(.replaceExisting), &destination)
            #expect(Fixture.refusal(destinationResult) == .destinationRefused, "\(kind)")
            #expect(destination.mutations.isEmpty)
        }
    }

    @Test func aSymlinkPrefixEndsTheProbesSoALaterStatusFaultIsNeverReached() throws {
        var fake = Fixture.volume()
        fake.seedNode("a", kind: .symbolicLink)
        fake.seedDirectory("a/b")
        fake.seed(package: try Fixture.tiny("new"), at: "a/b/src")
        fake.arm(.fault(.ioError, at: 1))
        let result = try Fixture.importRun(Fixture.plan(.createNew), from: "a/b/src", &fake)
        #expect(Fixture.refusal(result) == .overlappingPaths)
        #expect(fake.log.count == 1)
        var faulted = fake
        faulted.arm(.fault(.ioError, at: 0))
        let early = try Fixture.importRun(Fixture.plan(.createNew), from: "a/b/src", &faulted)
        let expected = StagingRefusal.ioFailed(step: .preflight, fault: .ioError, cleanup: .notNeeded)
        #expect(Fixture.refusal(early) == expected)
    }
}
