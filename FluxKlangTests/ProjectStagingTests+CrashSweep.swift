import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension ProjectStagingTests {
    private func crashes(for entry: Fake.Entry) -> [Fake.Crash] {
        guard case let .createFile(_, count) = entry.operation else { return [.before, .after] }
        let prefixes = Array(Set([0, max(count - 1, 0), count])).sorted()
        return [.before, .after] + prefixes.map { .torn(prefix: $0) }
    }

    private func assertSettled(
        _ fake: inout Fake, _ scenario: Scenario, _ label: String, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let first = Fixture.recover(scenario.plan, &fake)
        #expect(Fixture.value(first) != nil, "\(label)", sourceLocation: sourceLocation)
        let shape = fake.shapes(at: Fixture.destination)
        #expect(shape == scenario.newShapes || shape == scenario.oldShapes, "\(label)", sourceLocation: sourceLocation)
        #expect(fake.shapes(at: Fixture.staging).isEmpty, "\(label)", sourceLocation: sourceLocation)
        #expect(fake.shapes(at: Fixture.backup).isEmpty, "\(label)", sourceLocation: sourceLocation)
        #expect(scenario.protectedNodes(fake) == scenario.protectedNodes(scenario.start), "\(label)",
                sourceLocation: sourceLocation)
        #expect(Fixture.value(Fixture.recover(scenario.plan, &fake)) == [.noChange], "\(label)",
                sourceLocation: sourceLocation)
    }

    @Test func aCrashAtEveryOperationAndEveryPointLeavesARecoverableVolumeForEveryRunKind() throws {
        for kind in StagingScenarioKind.allCases {
            let scenario = try Scenario(kind)
            let log = try scenario.cleanLog()
            #expect(log.count > 20, "\(kind) log is too short to be a real sweep")
            var points = 0
            for index in log.indices {
                for crash in crashes(for: log[index]) {
                    points += 1
                    var fake = scenario.start
                    fake.arm(.crash(crash, at: index))
                    let result = try scenario.run(&fake)
                    let label = "\(kind) #\(index) \(crash) \(log[index].operation)"
                    let shape = fake.shapes(at: Fixture.destination)
                    let inWindow = shape.isEmpty && scenario.plan.mode == .replaceExisting
                        && fake.shapes(at: Fixture.backup) == scenario.oldShapes
                    #expect(shape == scenario.newShapes || shape == scenario.oldShapes || inWindow, "\(label)")
                    if Fixture.value(result) != nil { #expect(shape == scenario.newShapes, "\(label)") }
                    fake.arm()
                    assertSettled(&fake, scenario, label)
                }
            }
            #expect(points > log.count * 2, "\(kind)")
        }
    }

    @Test func aCrashDuringRecoveryItselfStillConvergesAfterASecondRecovery() throws {
        let bases: [(StagingScenarioKind, Int)] = [(.exportReplace, 0), (.exportCreate, 0), (.exportReplace, 1)]
        for (kind, which) in bases {
            let scenario = try Scenario(kind)
            let log = try scenario.cleanLog()
            let target: Int
            switch which {
            case 0:
                let promote = Fake.FileOp.rename(Fixture.staging, Fixture.destination)
                target = try #require(log.firstIndex { $0.operation == promote })
            default: target = try #require(log.lastIndex { $0.operation == .syncDirectory("") }) + 1
            }
            var crashed = scenario.start
            crashed.arm(.crash(which == 0 ? .before : .after, at: target))
            _ = try scenario.run(&crashed)
            crashed.arm()
            var probe = crashed
            _ = Fixture.recover(scenario.plan, &probe)
            #expect(probe.log.count > crashed.log.count + 3, "\(kind) \(which): recovery must do work to sweep")
            let recoveryLength = probe.log.count - crashed.log.count
            for index in 0..<recoveryLength {
                for crash in [Fake.Crash.before, .after] {
                    var fake = crashed
                    fake.arm(.crash(crash, at: index))
                    _ = Fixture.recover(scenario.plan, &fake)
                    fake.arm()
                    assertSettled(&fake, scenario, "\(kind) \(which) recovery #\(index) \(crash)")
                }
            }
        }
    }

    @Test func aSuccessfulRunIsNeverFollowedByAnythingRecoveryWouldChange() throws {
        for kind in StagingScenarioKind.allCases {
            let scenario = try Scenario(kind)
            var fake = scenario.start
            let result = try scenario.run(&fake)
            #expect(Fixture.value(result)?.backupRetained == false, "\(kind)")
            let settled = fake.nodes
            #expect(Fixture.value(Fixture.recover(scenario.plan, &fake)) == [.noChange], "\(kind)")
            #expect(fake.nodes == settled)
        }
    }
}
