import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension ProjectStagingTests {
    private typealias FileOp = Fake.FileOp

    private func seeded(_ contents: ProjectPackageContents) -> Fake { Fixture.volume(source: contents) }

    private func readSource(
        _ fake: inout Fake, policy: ProjectPackageManifestPolicy? = nil,
        chunk: Int = StagedPackageImport.defaultChunkByteCount
    ) throws -> Result<ProjectPackageContents, StagingRefusal> {
        try Fixture.read(policy: policy, chunk: chunk, &fake)
    }

    /// Equal package content regardless of the limits a particular policy attached to the value.
    private func same(
        _ result: Result<ProjectPackageContents, StagingRefusal>, _ contents: ProjectPackageContents
    ) -> Bool {
        guard let read = Fixture.value(result) else { return false }
        return read.manifestBytes == contents.manifestBytes && read.directories == contents.directories
            && read.files == contents.files
    }

    @Test func aWellFormedSourceReadsBackToEqualContentsAndMakesNoMutation() throws {
        let contents = try Fixture.big("src")
        var fake = seeded(contents)
        let before = fake
        let result = try readSource(&fake)
        #expect(Fixture.value(result) == contents)
        #expect(fake.nodes == before.nodes)
        #expect(fake.mutations.isEmpty)
    }

    @Test func theChunkSizeDoesNotChangeTheContentsAndAChunkOfOneByteIsAdmitted() throws {
        let contents = try Fixture.big("src")
        var small = seeded(contents)
        var large = seeded(contents)
        #expect(Fixture.value(try readSource(&small, chunk: 1)) == contents)
        #expect(Fixture.value(try readSource(&large, chunk: 1_000_000)) == contents)
        #expect(small.log.count > large.log.count)
    }

    @Test func aChunkOfZeroOrLessIsRefusedBeforeAnyIO() throws {
        for chunk in [0, -1, Int.min] {
            var fake = seeded(try Fixture.tiny("s"))
            let result = try readSource(&fake, chunk: chunk)
            #expect(Fixture.refusal(result) == .invalidChunkSize, "\(chunk)")
            #expect(fake.log.isEmpty)
        }
    }

    @Test func entryCountAtTheLimitIsAdmittedAndOneBelowIsRefused() throws {
        // tiny: manifest, project.json, d, d/a = 4 entries.
        let contents = try Fixture.tiny("s")
        var fake = seeded(contents)
        #expect(same(try readSource(&fake, policy: try Fixture.policy(entries: 4)), contents))
        var over = seeded(contents)
        let refused = try readSource(&over, policy: try Fixture.policy(entries: 3))
        #expect(Fixture.refusal(refused) == .package(.entryLimitExceeded))
    }

    @Test func nestedEntryCountIsBoundedAcrossDirectoriesAtNAndNPlusOne() throws {
        // big: manifest + 4 directories + 4 files = 9 entries, spread over four directories.
        let contents = try Fixture.big("s")
        var fake = seeded(contents)
        #expect(same(try readSource(&fake, policy: try Fixture.policy(entries: 9)), contents))
        var over = seeded(contents)
        #expect(Fixture.refusal(try readSource(&over, policy: try Fixture.policy(entries: 8)))
            == .package(.entryLimitExceeded))
    }

    @Test func depthAtTheLimitIsAdmittedAndOneBelowIsRefused() throws {
        let contents = try Fixture.contents(StagingFixtureSpec(directories: ["a", "a/b"], files: ["a/b/c": Data([1])]))
        var fake = seeded(contents)
        #expect(same(try readSource(&fake, policy: try Fixture.policy(depth: 3)), contents))
        var over = seeded(contents)
        #expect(Fixture.refusal(try readSource(&over, policy: try Fixture.policy(depth: 2))) == .package(.pathTooDeep))
    }

    @Test func perEntryBytesAtTheLimitAreAdmittedAndOneBelowIsRefused() throws {
        let contents = try Fixture.contents(StagingFixtureSpec(files: ["blob": Data(repeating: 7, count: 1000)]))
        let loose = try Fixture.policy(entryBytes: 1000, manifestBytes: 1000)
        var fake = seeded(contents)
        #expect(same(try readSource(&fake, policy: loose), contents))
        var over = seeded(contents)
        let result = try readSource(&over, policy: try Fixture.policy(entryBytes: 999, manifestBytes: 999))
        #expect(Fixture.refusal(result) == .package(.entryBytesExceeded))
    }

    @Test func anUndeclaredFileOneByteOverTheLimitIsRefusedByTheProbeRead() throws {
        let limit = 1000
        let source = try Fixture.contents(StagingFixtureSpec(declared: false))
        var fake = seeded(source)
        fake.seedFile(Fixture.source + "/blob", Data(repeating: 1, count: limit))
        let policy = try Fixture.policy(entryBytes: limit, manifestBytes: limit)
        #expect(Fixture.value(try readSource(&fake, policy: policy))?.files.count == 2)
        var over = seeded(source)
        over.seedFile(Fixture.source + "/blob", Data(repeating: 1, count: limit + 1))
        let result = try readSource(&over, policy: policy)
        #expect(Fixture.refusal(result) == .package(.entryBytesExceeded))
    }

    @Test func totalBytesAtTheLimitAreAdmittedAndOneBelowIsRefused() throws {
        let contents = try Fixture.tiny("s")
        let size = contents.manifestBytes.count
        let total = size + 3 + 3
        let exact = try Fixture.policy(entryBytes: total, totalBytes: total, manifestBytes: size)
        var fake = seeded(contents)
        #expect(same(try readSource(&fake, policy: exact), contents))
        let below = try Fixture.policy(entryBytes: total - 1, totalBytes: total - 1, manifestBytes: size)
        var over = seeded(contents)
        #expect(Fixture.refusal(try readSource(&over, policy: below)) == .package(.totalBytesExceeded))
    }

    @Test func manifestBytesAtTheCapAreAdmittedAndOneBelowIsRefused() throws {
        let contents = try Fixture.tiny("s")
        let size = contents.manifestBytes.count
        var fake = seeded(contents)
        #expect(same(try readSource(&fake, policy: try Fixture.policy(manifestBytes: size)), contents))
        var over = seeded(contents)
        let result = try readSource(&over, policy: try Fixture.policy(manifestBytes: size - 1))
        #expect(Fixture.refusal(result) == .manifest(.manifestBytesExceeded))
    }

    // MARK: Structure mismatches

    @Test func aMissingOrNonDirectoryRootIsAMissingMember() throws {
        var absent = Fixture.volume()
        #expect(Fixture.refusal(try readSource(&absent)) == .packageIO(.missingMember))
        var file = Fixture.volume()
        file.seedFile(Fixture.source, Data([1]))
        #expect(Fixture.refusal(try readSource(&file)) == .packageIO(.missingMember))
        var link = Fixture.volume()
        link.seedNode(Fixture.source, kind: .symbolicLink)
        #expect(Fixture.refusal(try readSource(&link)) == .packageIO(.missingMember))
        #expect(link.log.count == 1)
    }

    @Test func theFullImportRefusesAChunkBelowOneBeforeAnyIOAndAdmitsOneByte() throws {
        for chunk in [0, -1, Int.min] {
            var fake = seeded(try Fixture.tiny("s"))
            let result = try Fixture.importRun(try Fixture.plan(.createNew), chunk: chunk, &fake)
            #expect(Fixture.refusal(result) == .invalidChunkSize, "\(chunk)")
            #expect(fake.log.isEmpty)
        }
        var one = seeded(try Fixture.tiny("s"))
        let admitted = try Fixture.importRun(try Fixture.plan(.createNew), chunk: 1, &one)
        #expect(Fixture.value(admitted) == StagingReceipt(mode: .createNew, backupRetained: false))
    }

    @Test func aMissingOrNonRegularManifestIsAMissingMember() throws {
        var fake = seeded(try Fixture.tiny("s"))
        fake.unseed(Fixture.source + "/manifest.json")
        #expect(Fixture.refusal(try readSource(&fake)) == .packageIO(.missingMember))
        var directory = seeded(try Fixture.tiny("s"))
        directory.unseed(Fixture.source + "/manifest.json")
        directory.seedDirectory(Fixture.source + "/manifest.json")
        #expect(Fixture.refusal(try readSource(&directory)) == .packageIO(.missingMember))
    }

    @Test func aSymlinkOrSpecialMemberIsRefusedBeforeAnyBytesAreRead() throws {
        for kind in [ProjectPackageEntryKind.symbolicLink, .unsupported] {
            var fake = seeded(try Fixture.tiny("s"))
            fake.seedNode(Fixture.source + "/link", kind: kind)
            let result = try readSource(&fake)
            #expect(Fixture.refusal(result) == .package(.unsupportedKind), "\(kind)")
            let readLink = fake.log.contains {
                if case .read(let path, _, _) = $0.operation { path.hasSuffix("/link") } else { false }
            }
            #expect(!readLink)
        }
    }

    @Test func aHardLinkedMemberAndAMemberOnAnotherVolumeAreRefused() throws {
        var linked = seeded(try Fixture.tiny("s"))
        linked.seedFile(Fixture.source + "/project.json", Data("P-s".utf8), linkCount: 2)
        #expect(Fixture.refusal(try readSource(&linked)) == .packageIO(.hardLinkedMember))
        var other = seeded(try Fixture.tiny("s"))
        other.seedFile(Fixture.source + "/project.json", Data("P-s".utf8), volume: 2)
        #expect(Fixture.refusal(try readSource(&other)) == .packageIO(.crossedMountPoint))
    }

    @Test func aDeclaredSizeThatDisagreesWithTheFileIsRefusedInBothDirections() throws {
        let contents = try Fixture.tiny("s")
        var shorter = seeded(contents)
        shorter.seedFile(Fixture.source + "/project.json", Data("P-".utf8))
        #expect(Fixture.refusal(try readSource(&shorter)) == .package(.declaredByteCountMismatch))
        var longer = seeded(contents)
        longer.seedFile(Fixture.source + "/project.json", Data("P-s!".utf8))
        #expect(Fixture.refusal(try readSource(&longer)) == .package(.declaredBytesExceeded))
    }

    @Test func aMemberThatChangesWhileItIsBeingReadIsRefused() throws {
        for mutation in [Fake.ReadMutation.bumpGeneration, .appendByte] {
            var fake = seeded(try Fixture.tiny("s"))
            fake.arm(Fake.Script(mutateOnRead: [Fixture.source + "/d/a": mutation]))
            #expect(Fixture.refusal(try readSource(&fake)) == .packageIO(.memberChanged), "\(mutation)")
        }
    }

    @Test func aMemberThatVanishesBetweenListingAndStatusIsRefusedAsChanged() throws {
        var fake = seeded(try Fixture.tiny("s"))
        fake.arm(Fake.Script(remove: [12: Fixture.source + "/project.json"]))
        let result = try readSource(&fake)
        #expect(Fixture.refusal(result) == .packageIO(.memberChanged))
    }

    @Test func listingOrderDoesNotChangeTheResult() throws {
        let contents = try Fixture.big("s")
        var fake = seeded(contents)
        fake.arm(Fake.Script(reverseListings: true))
        #expect(Fixture.value(try readSource(&fake)) == contents)
        var plain = seeded(contents)
        _ = try readSource(&plain)
        #expect(fake.log.map(\.operation) == plain.log.map(\.operation))
    }

    @Test func listedNamesThatAreEmptyOrContainASeparatorAreInvalidPaths() throws {
        for name in ["a/b", ""] {
            var fake = seeded(try Fixture.tiny("s"))
            fake.arm(Fake.Script(extraListedNames: [name]))
            #expect(Fixture.refusal(try readSource(&fake)) == .package(.invalidPath), "\(name.debugDescription)")
            let last = try #require(fake.log.last)
            guard case .list = last.operation else {
                Issue.record("a bad name must be refused straight after the listing: \(last.operation)")
                continue
            }
        }
    }

    @Test func aDigestThatDoesNotMatchTheBytesAndAGarbageManifestAreRefused() throws {
        let spec = StagingFixtureSpec(files: ["media/click.wav": Data("abc".utf8)], mediaDigest: Fixture.abcDigest)
        let good = try Fixture.contents(StagingFixtureSpec(
            directories: ["media"], files: ["media/click.wav": Data("abc".utf8)], mediaDigest: Fixture.abcDigest
        ))
        _ = spec
        var fake = seeded(good)
        #expect(Fixture.value(try readSource(&fake)) == good)
        var bad = seeded(good)
        bad.seedFile(Fixture.source + "/media/click.wav", Data("abd".utf8))
        #expect(Fixture.refusal(try readSource(&bad)) == .packageIO(.digestMismatch))
        var garbage = seeded(try Fixture.tiny("s"))
        garbage.seedFile(Fixture.source + "/manifest.json", Data("not json".utf8))
        #expect(Fixture.refusal(try readSource(&garbage)) == .invalidManifest)
    }

    @Test func aReadFaultNamesTheSourceReadStepAndLeavesTheVolumeUnchanged() throws {
        let contents = try Fixture.tiny("s")
        for index in 0..<5 {
            var fake = seeded(contents)
            let before = fake
            fake.arm(.fault(.ioError, at: index))
            let result = try readSource(&fake)
            let step = try #require(Self.step(of: Fixture.refusal(result)))
            #expect(step == .readSource, "index \(index)")
            #expect(fake.nodes == before.nodes)
        }
    }

    // MARK: Import run

    @Test func importCreatesTheDestinationFromTheSourceWithoutTouchingTheSource() throws {
        let contents = try Fixture.big("src")
        var fake = seeded(contents)
        let before = fake
        let result = try Fixture.importRun(try Fixture.plan(.createNew), &fake)
        #expect(Fixture.value(result) == StagingReceipt(mode: .createNew, backupRetained: false))
        #expect(fake.shapes(at: Fixture.destination) == Fake.shapes(of: contents))
        #expect(fake.shapes(at: Fixture.source) == before.shapes(at: Fixture.source))
        #expect(fake.nodes(outside: [Fixture.destination]) == before.nodes)
    }

    @Test func importReplacesAnExistingPackageAndNeverMutatesTheSource() throws {
        let contents = try Fixture.big("src")
        var fake = Fixture.volume(old: try Fixture.big("old"), source: contents)
        let sourceBefore = fake.shapes(at: Fixture.source)
        let result = try Fixture.importRun(try Fixture.plan(.replaceExisting), &fake)
        #expect(Fixture.value(result) == StagingReceipt(mode: .replaceExisting, backupRetained: false))
        #expect(fake.shapes(at: Fixture.destination) == Fake.shapes(of: contents))
        #expect(fake.shapes(at: Fixture.source) == sourceBefore)
        #expect(fake.shapes(at: Fixture.backup).isEmpty)
    }

    @Test func aSourceOverlappingAnyPlanNameIsRefusedBeforeAnyIO() throws {
        let plan = try Fixture.plan(.createNew)
        let overlapping = [
            Fixture.destination, Fixture.staging, Fixture.backup, Fixture.destination + "/inner",
            Fixture.staging + "/inner", Fixture.backup + "/inner"
        ]
        for source in overlapping {
            var fake = Fixture.volume()
            let result = try Fixture.importRun(plan, from: source, &fake)
            #expect(Fixture.refusal(result) == .overlappingPaths, "\(source)")
            #expect(fake.log.isEmpty)
        }
        let wide = try Fixture.plan(.createNew, destination: "a/b/Set.fluxklang")
        for ancestor in ["a/b", "a"] {
            var fake = Fixture.volume()
            #expect(Fixture.refusal(try Fixture.importRun(wide, from: ancestor, &fake)) == .overlappingPaths)
            #expect(fake.log.isEmpty)
        }
        var sibling = Fixture.volume()
        #expect(Fixture.refusal(try Fixture.importRun(wide, from: "a/b/other", &sibling)) != .overlappingPaths)
    }

    @Test func aRefusedSourceLeavesTheDestinationUntouchedAndNeverCreatesStaging() throws {
        var fake = Fixture.volume(old: try Fixture.tiny("old"), source: try Fixture.tiny("src"))
        fake.unseed(Fixture.source + "/manifest.json")
        let before = fake
        let result = try Fixture.importRun(try Fixture.plan(.replaceExisting), &fake)
        #expect(Fixture.refusal(result) == .packageIO(.missingMember))
        #expect(fake.nodes == before.nodes)
        #expect(fake.mutations.isEmpty)
    }

    @Test func importBudgetIsCheckedAgainstTheSourceCountAtNAndNPlusOne() throws {
        let contents = try Fixture.tiny("src")
        var exact = seeded(contents)
        #expect(Fixture.value(try Fixture.importRun(try Fixture.plan(.createNew, ceiling: 9), &exact)) != nil)
        var over = seeded(contents)
        let result = try Fixture.importRun(try Fixture.plan(.createNew, ceiling: 8), &over)
        #expect(Fixture.refusal(result) == .operationBudgetExceeded)
        #expect(over.mutations.isEmpty)
    }

    private static func step(of refusal: StagingRefusal?) -> StagingStep? {
        if case let .ioFailed(step, _, _) = refusal { return step }
        return nil
    }
}
