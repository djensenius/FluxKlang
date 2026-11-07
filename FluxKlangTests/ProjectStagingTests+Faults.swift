import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension ProjectStagingTests {
    private typealias FileOp = Fake.FileOp

    /// What a single fault at `index` of a clean log must produce; nil means the run still succeeds.
    private func expected(
        _ fault: StagingIOFault, at index: Int, log: [Fake.Entry], scenario: Scenario
    ) -> StagingRefusal? {
        let (stg, dst, bak) = (Fixture.staging, Fixture.destination, Fixture.backup)
        let firstMutation = log.firstIndex { $0.operation.isMutating } ?? log.count
        let replace = scenario.plan.mode == .replaceExisting
        func failed(_ step: StagingStep, _ cleanup: StagingCleanup) -> StagingRefusal {
            .ioFailed(step: step, fault: fault, cleanup: cleanup)
        }
        switch log[index].operation {
        case .status, .list, .read:
            if index < 4 { return failed(.preflight, .notNeeded) }
            return index < firstMutation ? failed(.readSource, .notNeeded) : failed(.verifyReread, .removed)
        case let .makeDirectory(path):
            return path == stg ? failed(.createStagingRoot, .notNeeded) : failed(.writeEntry, .removed)
        case let .createFile(path, _):
            let isManifest = path == stg + "/" + ProjectPackageManifest.manifestMemberPath
            return failed(isManifest ? .writeManifest : .writeEntry, .removed)
        case let .syncDirectory(path):
            return path.isEmpty ? failed(.syncParent, .notNeeded) : failed(.syncStaging, .removed)
        case let .rename(from, to):
            if from == dst && to == bak { return failed(.retireExisting, .removed) }
            return replace
                ? .promotionFailed(fault: fault, rolledBack: true, cleanup: .removed) : failed(.promote, .removed)
        case .removeNode: return nil
        }
    }

    @Test func aSingleFaultAtEveryOperationOfEveryRunKindFailsTypedOrKeepsTheBackupAndNeverCorruptsTheVolume() throws {
        for kind in StagingScenarioKind.allCases {
            let scenario = try Scenario(kind)
            let log = try scenario.cleanLog()
            #expect(log.count > 20, "\(kind) log is too short to be a real sweep")
            for index in log.indices {
                for fault in [StagingIOFault.noSpace, .denied, .ioError] {
                    var fake = scenario.start
                    fake.arm(.fault(fault, at: index))
                    let result = try scenario.run(&fake)
                    let want = expected(fault, at: index, log: log, scenario: scenario)
                    let label = "\(kind) #\(index) \(fault) \(log[index].operation)"
                    if let want {
                        #expect(Fixture.refusal(result) == want, "\(label)")
                    } else {
                        #expect(Fixture.value(result)?.backupRetained == true, "\(label)")
                    }
                    let shape = fake.shapes(at: Fixture.destination)
                    #expect(shape == scenario.newShapes || shape == scenario.oldShapes, "\(label)")
                    #expect(scenario.protectedNodes(fake) == scenario.protectedNodes(scenario.start), "\(label)")
                    if let want {
                        let promoted = want == .ioFailed(step: .syncParent, fault: fault, cleanup: .notNeeded)
                        #expect(shape == (promoted ? scenario.newShapes : scenario.oldShapes), "\(label)")
                    }
                    if Fixture.value(result) != nil { #expect(shape == scenario.newShapes, "\(label)") }
                    if case .removed? = Self.cleanup(of: want) {
                        #expect(fake.shapes(at: Fixture.staging).isEmpty, "\(label)")
                    }
                }
            }
        }
    }

    @Test func aFaultBeforeTheRetireOrPromoteStepLeavesTheOriginalDestinationByteIdentical() throws {
        for kind in [StagingScenarioKind.exportReplace, .importReplace] {
            let scenario = try Scenario(kind)
            let log = try scenario.cleanLog()
            let retire = try #require(log.firstIndex { $0.operation == .rename(Fixture.destination, Fixture.backup) })
            for index in 0..<retire {
                var fake = scenario.start
                fake.arm(.fault(.ioError, at: index))
                _ = try scenario.run(&fake)
                #expect(fake.shapes(at: Fixture.destination) == scenario.oldShapes, "\(kind) #\(index)")
                #expect(fake.shapes(at: Fixture.backup).isEmpty)
            }
        }
    }

    @Test func aSecondFaultWhileRemovingStagingReportsTheLeftoverInsteadOfHidingIt() throws {
        let scenario = try Scenario(.exportCreate)
        let log = try scenario.cleanLog()
        let target = FileOp.createFile(Fixture.staging + "/graphs/main.json", 5)
        let write = try #require(log.firstIndex { $0.operation == target })
        var fake = scenario.start
        fake.arm(Fake.Script(faults: [write: .noSpace, write + 1: .ioError]))
        let result = try scenario.run(&fake)
        #expect(Fixture.refusal(result) == .ioFailed(step: .writeEntry, fault: .noSpace, cleanup: .leftBehind))
        #expect(!fake.shapes(at: Fixture.staging).isEmpty)
        #expect(fake.shapes(at: Fixture.destination).isEmpty)
    }

    @Test func aFailedSecondRenameRollsTheBackupBackAndReportsTheRollback() throws {
        let scenario = try Scenario(.exportReplace)
        let log = try scenario.cleanLog()
        let promote = try #require(log.firstIndex { $0.operation == .rename(Fixture.staging, Fixture.destination) })
        var fake = scenario.start
        fake.arm(.fault(.denied, at: promote))
        let result = try scenario.run(&fake)
        #expect(Fixture.refusal(result) == .promotionFailed(fault: .denied, rolledBack: true, cleanup: .removed))
        #expect(fake.shapes(at: Fixture.destination) == scenario.oldShapes)
        #expect(fake.shapes(at: Fixture.backup).isEmpty)
        #expect(fake.shapes(at: Fixture.staging).isEmpty)
    }

    @Test func anInterruptedSecondRenameIsNotRolledBack() throws {
        let scenario = try Scenario(.exportReplace)
        let log = try scenario.cleanLog()
        let promote = try #require(log.firstIndex { $0.operation == .rename(Fixture.staging, Fixture.destination) })
        var fake = scenario.start
        fake.arm(.fault(.interrupted, at: promote))
        let result = try scenario.run(&fake)
        #expect(Fixture.refusal(result) == .ioFailed(step: .promote, fault: .interrupted, cleanup: .notAttempted))
        #expect(!fake.log.contains { $0.operation == .rename(Fixture.backup, Fixture.destination) })
    }

    @Test func aFailedRollbackLeavesEverythingInPlaceAndRecoveryRestoresTheOldPackage() throws {
        let scenario = try Scenario(.exportReplace)
        let log = try scenario.cleanLog()
        let promote = try #require(log.firstIndex { $0.operation == .rename(Fixture.staging, Fixture.destination) })
        var fake = scenario.start
        fake.arm(Fake.Script(faults: [promote: .ioError, promote + 1: .ioError]))
        let result = try scenario.run(&fake)
        #expect(Fixture.refusal(result) == .promotionFailed(fault: .ioError, rolledBack: false, cleanup: .notAttempted))
        #expect(fake.shapes(at: Fixture.destination).isEmpty)
        #expect(fake.shapes(at: Fixture.backup) == scenario.oldShapes)
        #expect(fake.shapes(at: Fixture.staging) == scenario.newShapes)
        fake.arm()
        let recovered = Fixture.recover(scenario.plan, &fake)
        #expect(Fixture.value(recovered) == [.restoredPrevious, .removedStaging])
        #expect(fake.shapes(at: Fixture.destination) == scenario.oldShapes)
        #expect(fake.shapes(at: Fixture.backup).isEmpty)
        #expect(fake.shapes(at: Fixture.staging).isEmpty)
    }

    @Test func aBackupThatCannotBeRemovedIsKeptAndTheNewPackageStillSucceeds() throws {
        let scenario = try Scenario(.exportReplace)
        let log = try scenario.cleanLog()
        let firstRemoval = try #require(log.firstIndex { if case .removeNode = $0.operation { true } else { false } })
        var fake = scenario.start
        fake.arm(.fault(.ioError, at: firstRemoval))
        let result = try scenario.run(&fake)
        #expect(Fixture.value(result) == StagingReceipt(mode: .replaceExisting, backupRetained: true))
        #expect(fake.shapes(at: Fixture.destination) == scenario.newShapes)
        #expect(fake.shapes(at: Fixture.backup) == scenario.oldShapes)
        fake.arm()
        #expect(Fixture.value(Fixture.recover(scenario.plan, &fake)) == [.removedBackup])
        #expect(fake.shapes(at: Fixture.backup).isEmpty)
    }

    @Test func aCrashWhileRemovingTheBackupIsInterruptedAndNotACleanup() throws {
        let scenario = try Scenario(.exportReplace)
        let log = try scenario.cleanLog()
        let firstRemoval = try #require(log.firstIndex { if case .removeNode = $0.operation { true } else { false } })
        var fake = scenario.start
        fake.arm(.crash(.before, at: firstRemoval))
        let result = try scenario.run(&fake)
        #expect(Fixture.refusal(result) == .ioFailed(step: .retireBackup, fault: .interrupted, cleanup: .notAttempted))
        #expect(fake.shapes(at: Fixture.destination) == scenario.newShapes)
    }

    @Test func aFailedParentSyncReportsItAndKeepsTheNewPackageAndTheBackup() throws {
        for kind in [StagingScenarioKind.exportCreate, .exportReplace] {
            let scenario = try Scenario(kind)
            let log = try scenario.cleanLog()
            let sync = try #require(log.lastIndex { $0.operation == .syncDirectory("") })
            var fake = scenario.start
            fake.arm(.fault(.ioError, at: sync))
            let result = try scenario.run(&fake)
            let want = StagingRefusal.ioFailed(step: .syncParent, fault: .ioError, cleanup: .notNeeded)
            #expect(Fixture.refusal(result) == want, "\(kind)")
            #expect(fake.shapes(at: Fixture.destination) == scenario.newShapes)
            #expect(fake.shapes(at: Fixture.backup) == scenario.oldShapes)
            #expect(fake.shapes(at: Fixture.staging).isEmpty)
        }
    }

    // MARK: Silent corruption is caught by verification

    @Test func aStagedFileThatSilentlyShrinksFailsVerificationAndIsRemoved() throws {
        let scenario = try Scenario(.exportReplace)
        var fake = scenario.start
        fake.arm(Fake.Script(silent: [Fixture.staging + "/project.json": .shorten(to: 1)]))
        let result = try scenario.run(&fake)
        #expect(Fixture.refusal(result) == .verificationFailed(cleanup: .removed))
        #expect(fake.shapes(at: Fixture.destination) == scenario.oldShapes)
        #expect(fake.shapes(at: Fixture.staging).isEmpty)
    }

    @Test func aStagedFileWithAFlippedByteFailsVerificationEvenWhenTheSizeMatches() throws {
        let scenario = try Scenario(.exportCreate)
        var fake = scenario.start
        fake.arm(Fake.Script(silent: [Fixture.staging + "/notes/readme.txt": .flipFirstByte]))
        let result = try scenario.run(&fake)
        #expect(Fixture.refusal(result) == .verificationFailed(cleanup: .removed))
        #expect(fake.shapes(at: Fixture.destination).isEmpty)
    }

    @Test func aSilentlyMissingEmptyDirectoryFailsVerification() throws {
        let scenario = try Scenario(.exportCreate)
        var fake = scenario.start
        fake.arm(Fake.Script(silent: [Fixture.staging + "/empty": .dropDirectory]))
        let result = try scenario.run(&fake)
        #expect(Fixture.refusal(result) == .verificationFailed(cleanup: .removed))
        #expect(fake.shapes(at: Fixture.destination).isEmpty)
    }

    @Test func anExtraFileAppearingInTheStagedTreeFailsVerification() throws {
        let scenario = try Scenario(.exportReplace)
        var fake = scenario.start
        fake.arm(Fake.Script(silent: [Fixture.staging + "/project.json": .plantSibling("extra")]))
        let result = try scenario.run(&fake)
        #expect(Fixture.refusal(result) == .verificationFailed(cleanup: .removed))
        #expect(fake.shapes(at: Fixture.destination) == scenario.oldShapes)
    }

    @Test func aDestinationPlantedBeforePromotionIsNeverOverwrittenOrDeleted() throws {
        let scenario = try Scenario(.exportCreate)
        let log = try scenario.cleanLog()
        let promote = try #require(log.firstIndex { $0.operation == .rename(Fixture.staging, Fixture.destination) })
        var fake = scenario.start
        fake.arm(Fake.Script(plant: [promote: Fixture.destination]))
        let result = try scenario.run(&fake)
        #expect(Fixture.refusal(result) == .ioFailed(step: .promote, fault: .exists, cleanup: .removed))
        #expect(fake.shapes(at: Fixture.destination) == ["": Fake.Shape(kind: .directory, bytes: Data())])
        #expect(fake.shapes(at: Fixture.staging).isEmpty)
    }

    private static func cleanup(of refusal: StagingRefusal?) -> StagingCleanup? {
        switch refusal {
        case let .ioFailed(_, _, cleanup)?, let .promotionFailed(_, _, cleanup)?,
             let .verificationFailed(cleanup)?: cleanup
        default: nil
        }
    }
}
