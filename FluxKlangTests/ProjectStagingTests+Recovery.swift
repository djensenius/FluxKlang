import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension ProjectStagingTests {
    private typealias FileOp = Fake.FileOp

    private func state(
        destination: Bool, staging: Bool, backup: Bool, mode: StagingMode = .replaceExisting
    ) throws -> (Fake, StagingPlan) {
        var fake = Fixture.volume()
        if destination { fake.seed(package: try Fixture.tiny("dst"), at: Fixture.destination) }
        if staging { fake.seed(package: try Fixture.big("stg"), at: Fixture.staging) }
        if backup { fake.seed(package: try Fixture.tiny("bak"), at: Fixture.backup) }
        return (fake, try Fixture.plan(mode))
    }

    private func recoverTable() -> [RecoveryCase] {
        [
            RecoveryCase(destination: false, staging: false, backup: false, outcome: [.noChange]),
            RecoveryCase(destination: true, staging: false, backup: false, outcome: [.noChange]),
            RecoveryCase(destination: false, staging: true, backup: false, outcome: [.removedStaging]),
            RecoveryCase(destination: true, staging: true, backup: false, outcome: [.removedStaging]),
            RecoveryCase(destination: true, staging: false, backup: true, outcome: [.removedBackup]),
            RecoveryCase(destination: true, staging: true, backup: true, outcome: [.removedBackup, .removedStaging]),
            RecoveryCase(destination: false, staging: false, backup: true, outcome: [.restoredPrevious]),
            RecoveryCase(destination: false, staging: true, backup: true, outcome: [.restoredPrevious, .removedStaging])
        ]
    }

    @Test func recoveryHandlesEveryCombinationOfTheThreeNamesWithExactOutcomes() throws {
        for row in recoverTable() {
            let (destination, staging, backup, outcome) = (row.destination, row.staging, row.backup, row.outcome)
            for mode in [StagingMode.createNew, .replaceExisting] where !(backup && mode == .createNew) {
                var (fake, plan) = try state(destination: destination, staging: staging, backup: backup, mode: mode)
                let before = fake
                let result = Fixture.recover(plan, &fake)
                let label = "d\(destination) stg\(staging) bak\(backup) \(mode)"
                #expect(Fixture.value(result) == outcome, "\(label)")
                #expect(fake.shapes(at: Fixture.staging).isEmpty, "\(label)")
                #expect(fake.shapes(at: Fixture.backup).isEmpty, "\(label)")
                #expect(fake.nodes(outside: [Fixture.staging, Fixture.backup, Fixture.destination])
                    == before.nodes(outside: [Fixture.staging, Fixture.backup, Fixture.destination]), "\(label)")
                let expectedDestination = backup && !destination
                    ? before.shapes(at: Fixture.backup) : before.shapes(at: Fixture.destination)
                #expect(fake.shapes(at: Fixture.destination) == expectedDestination, "\(label)")
            }
        }
    }

    @Test func recoveryIsIdempotentAndTheSecondRunReportsNoChange() throws {
        for row in recoverTable() {
            let (destination, staging, backup) = (row.destination, row.staging, row.backup)
            var (fake, plan) = try state(destination: destination, staging: staging, backup: backup)
            _ = Fixture.recover(plan, &fake)
            let settled = fake
            #expect(Fixture.value(Fixture.recover(plan, &fake)) == [.noChange])
            #expect(fake.nodes == settled.nodes)
            #expect(fake.mutations == settled.mutations)
        }
    }

    @Test func recoveryLooksAtExactlyTheThreeNamesInOrderAndNeverListsOrPromotes() throws {
        let (stg, dst, bak) = (Fixture.staging, Fixture.destination, Fixture.backup)
        var (fake, plan) = try state(destination: true, staging: true, backup: true)
        _ = Fixture.recover(plan, &fake)
        #expect(fake.log.prefix(3).map(\.operation) == [.status(stg), .status(dst), .status(bak)])
        for entry in fake.log {
            switch entry.operation {
            case let .status(path), let .removeNode(path):
                #expect(Self.inside(path, [stg, dst, bak]), "\(entry.operation)")
            case .list, .read, .makeDirectory, .createFile, .syncDirectory:
                Issue.record("unexpected \(entry.operation)")
            case let .rename(from, to): Issue.record("unexpected rename \(from) \(to)")
            }
        }
        #expect(!fake.log.contains { $0.operation == .removeNode(dst) })
    }

    @Test func restoringAPreviousPackageIsASingleRenameFromTheBackupToTheDestination() throws {
        var (fake, plan) = try state(destination: false, staging: false, backup: true)
        _ = Fixture.recover(plan, &fake)
        let restore = Fake.Entry(operation: .rename(Fixture.backup, Fixture.destination), outcome: .succeeded)
        #expect(fake.mutations == [restore])
    }

    @Test func recoveryNeverRemovesTheDestinationNorPromotesTheStagedTree() throws {
        for row in recoverTable() {
            let (destination, staging, backup) = (row.destination, row.staging, row.backup)
            var (fake, plan) = try state(destination: destination, staging: staging, backup: backup)
            let staged = fake.shapes(at: Fixture.staging)
            _ = Fixture.recover(plan, &fake)
            #expect(!fake.mutations.contains { $0.operation == .rename(Fixture.staging, Fixture.destination) })
            if staging && !destination { #expect(fake.shapes(at: Fixture.destination) != staged || staged.isEmpty) }
            if destination { #expect(!fake.mutations.contains { $0.operation == .removeNode(Fixture.destination) }) }
        }
    }

    @Test func aRecoveryStatusFaultNamesPreflightAndChangesNothing() throws {
        for index in 0..<3 {
            var (fake, plan) = try state(destination: true, staging: true, backup: true)
            let before = fake.nodes
            fake.arm(.fault(.ioError, at: index))
            let result = Fixture.recover(plan, &fake)
            let want = StagingRefusal.ioFailed(step: .preflight, fault: .ioError, cleanup: .notNeeded)
            #expect(Fixture.refusal(result) == want, "\(index)")
            #expect(fake.nodes == before)
        }
    }

    @Test func aRecoveryRenameFaultNamesRestorePreviousAndAnotherFaultNamesCleanup() throws {
        var (fake, plan) = try state(destination: false, staging: true, backup: true)
        fake.arm(.fault(.denied, at: 3))
        #expect(Fixture.refusal(Fixture.recover(plan, &fake))
            == .ioFailed(step: .restorePrevious, fault: .denied, cleanup: .notNeeded))
        #expect(fake.shapes(at: Fixture.destination).isEmpty)
        fake.arm()
        #expect(Fixture.value(Fixture.recover(plan, &fake)) == [.restoredPrevious, .removedStaging])
        var (second, secondPlan) = try state(destination: true, staging: true, backup: false)
        second.arm(.fault(.noSpace, at: 3))
        #expect(Fixture.refusal(Fixture.recover(secondPlan, &second))
            == .ioFailed(step: .cleanup, fault: .noSpace, cleanup: .notNeeded))
        second.arm()
        #expect(Fixture.value(Fixture.recover(secondPlan, &second)) == [.removedStaging])
    }

    @Test func aCreateNewRecoveryNeverTouchesAPlantedBackupWhenTheDestinationIsAbsent() throws {
        for staging in [false, true] {
            var (fake, plan) = try state(destination: false, staging: staging, backup: true, mode: .createNew)
            let planted = fake.shapes(at: Fixture.backup)
            #expect(!planted.isEmpty)
            let result = Fixture.recover(plan, &fake)
            #expect(Fixture.value(result) == (staging ? [.removedStaging] : [.noChange]), "staging \(staging)")
            #expect(fake.shapes(at: Fixture.destination).isEmpty)
            #expect(fake.shapes(at: Fixture.backup) == planted)
            #expect(fake.shapes(at: Fixture.staging).isEmpty)
            #expect(!fake.log.contains { $0.operation == .status(Fixture.backup) })
        }
    }

    @Test func aCreateNewRecoveryNeverRemovesAPlantedBackupWhenTheDestinationExists() throws {
        var (fake, plan) = try state(destination: true, staging: false, backup: true, mode: .createNew)
        let planted = fake.shapes(at: Fixture.backup)
        let destination = fake.shapes(at: Fixture.destination)
        #expect(!planted.isEmpty)
        #expect(Fixture.value(Fixture.recover(plan, &fake)) == [.noChange])
        #expect(fake.shapes(at: Fixture.backup) == planted)
        #expect(fake.shapes(at: Fixture.destination) == destination)
        #expect(fake.mutations.isEmpty)
    }

    private static func inside(_ path: String, _ roots: [String]) -> Bool {
        roots.contains { StagingPlan.isWithin(path, of: $0) }
    }
}

struct RecoveryCase {
    let destination: Bool
    let staging: Bool
    let backup: Bool
    let outcome: [StagingRecoveryOutcome]
}
