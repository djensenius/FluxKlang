import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension ProjectStagingTests {
    private typealias FileOp = Fake.FileOp

    private func succeeded(_ ops: [FileOp]) -> [Fake.Entry] {
        ops.map { Fake.Entry(operation: $0, outcome: .succeeded) }
    }

    private func assertUntouched(_ fake: Fake, _ before: Fake, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(fake.nodes == before.nodes, sourceLocation: sourceLocation)
        #expect(fake.mutations == before.mutations, sourceLocation: sourceLocation)
    }

    /// The operations of the verification walk over a staged tiny package (default policy, 65,536-byte chunks).
    private func tinyVerifyOps(root: String, manifestBytes size: Int) -> [FileOp] {
        let manifest = root + "/manifest.json"
        let project = root + "/project.json"
        let nested = root + "/d/a"
        return [
            .status(root), .status(manifest), .read(manifest, 0, 4096), .read(manifest, size, 4096 - size),
            .status(manifest),
            .list(root, 32), .status(root + "/d"), .list(root + "/d", 30), .status(nested), .read(nested, 0, 4096),
            .read(nested, 3, 4093), .status(nested), .status(project), .read(project, 0, 3), .read(project, 3, 1),
            .status(project)
        ]
    }

    @Test func createNewExportStagesVerifiesAndPromotesOntoAnAbsentDestination() throws {
        let contents = try Fixture.big("new")
        var fake = Fixture.volume()
        let before = fake
        let result = Fixture.export(try Fixture.plan(.createNew), contents, &fake)
        #expect(Fixture.value(result) == StagingReceipt(mode: .createNew, backupRetained: false))
        #expect(fake.shapes(at: Fixture.destination) == Fake.shapes(of: contents))
        #expect(fake.shapes(at: Fixture.staging).isEmpty)
        #expect(fake.shapes(at: Fixture.backup).isEmpty)
        #expect(fake.nodes(outside: [Fixture.destination]) == before.nodes)
        var reread = fake
        let imported = try Fixture.read(Fixture.destination, &reread)
        #expect(Fixture.value(imported) == contents)
    }

    @Test func replaceExportSwapsTheOldPackageForTheNewOneAndRetiresTheBackup() throws {
        let old = try Fixture.big("old")
        let new = try Fixture.big("new")
        var fake = Fixture.volume(old: old)
        let before = fake
        let result = Fixture.export(try Fixture.plan(.replaceExisting), new, &fake)
        #expect(Fixture.value(result) == StagingReceipt(mode: .replaceExisting, backupRetained: false))
        #expect(fake.shapes(at: Fixture.destination) == Fake.shapes(of: new))
        #expect(fake.shapes(at: Fixture.destination) != Fake.shapes(of: old))
        #expect(fake.shapes(at: Fixture.backup).isEmpty)
        #expect(fake.shapes(at: Fixture.staging).isEmpty)
        #expect(fake.nodes(outside: [Fixture.destination]) == before.nodes(outside: [Fixture.destination]))
    }

    @Test func theCreateNewOperationLogIsExactlyThePreflightStageSyncVerifyPromoteSequence() throws {
        let contents = try Fixture.tiny("n")
        let size = contents.manifestBytes.count
        let (stg, bak, dst) = (Fixture.staging, Fixture.backup, Fixture.destination)
        var fake = Fixture.volume()
        _ = Fixture.export(try Fixture.plan(.createNew), contents, &fake)
        let expected: [FileOp] = [.status(""), .status(dst), .status(stg), .status(bak)]
            + [.makeDirectory(stg), .createFile(stg + "/manifest.json", size), .makeDirectory(stg + "/d"),
               .createFile(stg + "/d/a", 3), .createFile(stg + "/project.json", 3), .syncDirectory(stg + "/d"),
               .syncDirectory(stg)]
            + tinyVerifyOps(root: stg, manifestBytes: size)
            + [.rename(stg, dst), .syncDirectory("")]
        #expect(fake.log == succeeded(expected))
    }

    @Test func theReplaceMutationLogRetiresThenPromotesThenSyncsThenRemovesTheBackupChildrenFirst() throws {
        let contents = try Fixture.tiny("n")
        let size = contents.manifestBytes.count
        let (stg, bak, dst) = (Fixture.staging, Fixture.backup, Fixture.destination)
        var fake = Fixture.volume(old: try Fixture.tiny("o"))
        _ = Fixture.export(try Fixture.plan(.replaceExisting), contents, &fake)
        let expected: [FileOp] = [
            .makeDirectory(stg), .createFile(stg + "/manifest.json", size), .makeDirectory(stg + "/d"),
            .createFile(stg + "/d/a", 3), .createFile(stg + "/project.json", 3), .syncDirectory(stg + "/d"),
            .syncDirectory(stg),
            .rename(dst, bak), .rename(stg, dst), .syncDirectory(""),
            .removeNode(bak + "/project.json"), .removeNode(bak + "/manifest.json"), .removeNode(bak + "/d/a"),
            .removeNode(bak + "/d"), .removeNode(bak)
        ]
        #expect(fake.mutations == succeeded(expected))
        #expect(fake.log.prefix(4).map(\.operation) == [.status(""), .status(dst), .status(stg), .status(bak)])
    }

    @Test func entriesAreWrittenManifestFirstThenByteOrderAndSyncedChildrenFirst() throws {
        let contents = try Fixture.big("new")
        let stg = Fixture.staging
        var fake = Fixture.volume()
        _ = Fixture.export(try Fixture.plan(.createNew), contents, &fake)
        let sizes = contents.files.reduce(into: [String: Int]()) { $0[$1.path] = $1.bytes.count }
        let expected: [FileOp] = [
            .makeDirectory(stg), .createFile(stg + "/manifest.json", contents.manifestBytes.count),
            .makeDirectory(stg + "/empty"), .makeDirectory(stg + "/graphs"),
            .createFile(stg + "/graphs/main.json", sizes["graphs/main.json"] ?? -1), .makeDirectory(stg + "/notes"),
            .createFile(stg + "/notes/readme.txt", 4), .createFile(stg + "/project.json", sizes["project.json"] ?? -1),
            .makeDirectory(stg + "/state"), .createFile(stg + "/state/draft.bin", 3),
            .syncDirectory(stg + "/state"), .syncDirectory(stg + "/notes"), .syncDirectory(stg + "/graphs"),
            .syncDirectory(stg + "/empty"), .syncDirectory(stg), .rename(stg, Fixture.destination), .syncDirectory("")
        ]
        #expect(fake.mutations == succeeded(expected))
        #expect(sizes["project.json"] == 5)
        #expect(sizes["graphs/main.json"] == 5)
    }

    @Test func emptyDirectoriesUnlistedAndOpaqueMembersSurviveWithTheirExactBytes() throws {
        let contents = try Fixture.big("new")
        var fake = Fixture.volume()
        _ = Fixture.export(try Fixture.plan(.createNew), contents, &fake)
        let shapes = fake.shapes(at: Fixture.destination)
        #expect(shapes["/empty"] == Fake.Shape(kind: .directory, bytes: Data()))
        #expect(shapes["/notes/readme.txt"] == Fake.Shape(kind: .regularFile, bytes: Data("keep".utf8)))
        #expect(shapes["/state/draft.bin"] == Fake.Shape(kind: .regularFile, bytes: Data([0xFF, 0x00, 0xFE])))
        #expect(shapes["/manifest.json"]?.bytes == contents.manifestBytes)
        #expect(shapes.count == 10)
    }

    @Test func theLogAndResultAreIdenticalForTheSameInputAndIndependentOfTheToken() throws {
        let contents = try Fixture.big("new")
        var first = Fixture.volume()
        var second = first
        var third = first
        _ = Fixture.export(try Fixture.plan(.createNew), contents, &first)
        _ = Fixture.export(try Fixture.plan(.createNew), contents, &second)
        #expect(first == second)
        #expect(first.log == second.log)
        _ = Fixture.export(try Fixture.plan(.createNew, token: "zz9"), contents, &third)
        #expect(third.shapes(at: Fixture.destination) == first.shapes(at: Fixture.destination))
        #expect(third.nodes == first.nodes)
        #expect(third.log.count == first.log.count)
    }

    @Test func theOutcomeDoesNotDependOnTheOrderTheVolumeWasBuiltIn() throws {
        let old = try Fixture.big("old")
        let new = try Fixture.big("new")
        var forward = Fake()
        var backward = Fake()
        let names = ["z", "a", "m", "b"]
        for name in names { forward.seedFile("other/" + name, Data(name.utf8)) }
        for name in names.reversed() { backward.seedFile("other/" + name, Data(name.utf8)) }
        forward.seedDirectory("other")
        forward.seed(package: old, at: Fixture.destination)
        backward.seed(package: old, at: Fixture.destination)
        backward.seedDirectory("other")
        #expect(forward == backward)
        _ = Fixture.export(try Fixture.plan(.replaceExisting), new, &forward)
        _ = Fixture.export(try Fixture.plan(.replaceExisting), new, &backward)
        #expect(forward == backward)
        #expect(forward.log == backward.log)
    }

    @Test func theMutationCountEqualsTheCountedOperationsForCreateNew() throws {
        let contents = try Fixture.big("new")
        var fake = Fixture.volume()
        _ = Fixture.export(try Fixture.plan(.createNew), contents, &fake)
        #expect(fake.mutations.count == 17)
        #expect(fake.mutations.count == StagingPlan.operationCount(directories: 4, files: 4, mode: .createNew))
    }

    @Test func theReplaceMutationCountExpandsOnlyTheBackupRemovalToOneOperationPerNode() throws {
        var fake = Fixture.volume(old: try Fixture.big("old"))
        _ = Fixture.export(try Fixture.plan(.replaceExisting), try Fixture.big("new"), &fake)
        // 19 counted operations, with removeTree(backup) counted once but run as the 10 nodes of the old package.
        #expect(StagingPlan.operationCount(directories: 4, files: 4, mode: .replaceExisting) == 19)
        #expect(fake.mutations.count == 19 - 1 + 10)
        #expect(fake.mutations.suffix(10).allSatisfy { if case .removeNode = $0.operation { true } else { false } })
    }

    // MARK: Pre-flight refusals: no mutating operation, volume unchanged

    @Test func createNewRefusesAnExistingDestinationOfAnyKind() throws {
        let contents = try Fixture.tiny("n")
        let kinds: [ProjectPackageEntryKind] = [.directory, .regularFile, .symbolicLink, .unsupported]
        for kind in kinds {
            var fake = Fixture.volume()
            fake.seedNode(Fixture.destination, kind: kind)
            let before = fake
            let result = Fixture.export(try Fixture.plan(.createNew), contents, &fake)
            #expect(Fixture.refusal(result) == .destinationExists, "\(kind)")
            assertUntouched(fake, before)
        }
    }

    @Test func replaceRefusesAMissingFileSymlinkOrSpecialDestination() throws {
        let contents = try Fixture.tiny("n")
        let cases: [(ProjectPackageEntryKind?, StagingRefusal)] = [
            (nil, .destinationMissing), (.regularFile, .destinationNotDirectory),
            (.symbolicLink, .destinationRefused), (.unsupported, .destinationRefused)
        ]
        for (kind, expected) in cases {
            var fake = Fixture.volume()
            if let kind { fake.seedNode(Fixture.destination, kind: kind) }
            let before = fake
            let result = Fixture.export(try Fixture.plan(.replaceExisting), contents, &fake)
            #expect(Fixture.refusal(result) == expected, "\(String(describing: kind))")
            assertUntouched(fake, before)
        }
    }

    @Test func replaceRefusesADestinationOnAnotherVolume() throws {
        var fake = Fixture.volume()
        fake.seedDirectory(Fixture.destination, volume: 2)
        let before = fake
        let result = Fixture.export(try Fixture.plan(.replaceExisting), try Fixture.tiny("n"), &fake)
        #expect(Fixture.refusal(result) == .packageIO(.crossedMountPoint))
        assertUntouched(fake, before)
    }

    @Test func aMissingFileOrSymlinkParentIsRefusedAndNeverCreated() throws {
        let contents = try Fixture.tiny("n")
        let plan = try Fixture.plan(.createNew, destination: "p/Set.fluxklang")
        let cases: [ProjectPackageEntryKind?] = [nil, .regularFile, .symbolicLink, .unsupported]
        for kind in cases {
            var fake = Fixture.volume()
            if let kind { fake.seedNode("p", kind: kind) }
            let before = fake
            let result = Fixture.export(plan, contents, &fake)
            #expect(Fixture.refusal(result) == .packageIO(.destinationParentRefused), "\(String(describing: kind))")
            assertUntouched(fake, before)
        }
    }

    @Test func aNestedDestinationInARealDirectoryIsStagedBesideItAndPromoted() throws {
        let contents = try Fixture.tiny("n")
        var fake = Fixture.volume()
        fake.seedDirectory("p")
        let plan = try Fixture.plan(.createNew, destination: "p/Set.fluxklang")
        let result = Fixture.export(plan, contents, &fake)
        #expect(Fixture.value(result) == StagingReceipt(mode: .createNew, backupRetained: false))
        #expect(fake.shapes(at: "p/Set.fluxklang") == Fake.shapes(of: contents))
        #expect(fake.mutations.last == Fake.Entry(operation: .syncDirectory("p"), outcome: .succeeded))
        #expect(fake.shapes(at: "p/.Set.fluxklang.staging-t1").isEmpty)
    }

    @Test func anExistingStagingOrBackupNameIsInUseAndIsNeverDeleted() throws {
        let contents = try Fixture.tiny("n")
        for (name, mode) in [(Fixture.staging, StagingMode.createNew), (Fixture.backup, .createNew),
                             (Fixture.staging, .replaceExisting), (Fixture.backup, .replaceExisting)] {
            var fake = Fixture.volume(old: mode == .replaceExisting ? try Fixture.tiny("o") : nil)
            fake.seedDirectory(name)
            fake.seedFile(name + "/precious", Data([7]))
            let before = fake
            let result = Fixture.export(try Fixture.plan(mode), contents, &fake)
            #expect(Fixture.refusal(result) == .stagingNameInUse, "\(name) \(mode)")
            assertUntouched(fake, before)
        }
    }

    @Test func anOperationCountAboveTheCeilingRefusesBeforeAnyIOAndTheCountItselfRuns() throws {
        let contents = try Fixture.tiny("n")
        var refused = Fixture.volume()
        let before = refused
        let result = Fixture.export(try Fixture.plan(.createNew, ceiling: 8), contents, &refused)
        #expect(Fixture.refusal(result) == .operationBudgetExceeded)
        #expect(refused == before)
        #expect(refused.log.isEmpty)
        var exact = Fixture.volume()
        let admitted = Fixture.export(try Fixture.plan(.createNew, ceiling: 9), contents, &exact)
        #expect(Fixture.value(admitted) == StagingReceipt(mode: .createNew, backupRetained: false))
    }

    @Test func aReplaceCeilingOfTheCountIsAdmittedAndOneBelowIsRefusedWithoutIO() throws {
        let contents = try Fixture.tiny("n")
        var refused = Fixture.volume(old: try Fixture.tiny("o"))
        let before = refused
        #expect(Fixture.refusal(Fixture.export(try Fixture.plan(.replaceExisting, ceiling: 10), contents, &refused))
            == .operationBudgetExceeded)
        #expect(refused == before)
        var exact = Fixture.volume(old: try Fixture.tiny("o"))
        let admitted = Fixture.export(try Fixture.plan(.replaceExisting, ceiling: 11), contents, &exact)
        #expect(Fixture.value(admitted)?.mode == .replaceExisting)
    }
}
