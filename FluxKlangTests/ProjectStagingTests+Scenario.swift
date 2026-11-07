import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension ProjectStagingTests {
    /// One runnable staging scenario: a prepared volume, the run to execute, and the two shapes a destination may hold.
    struct Scenario {

        let kind: StagingScenarioKind
        let plan: StagingPlan
        let contents: ProjectPackageContents
        let old: ProjectPackageContents?
        let start: Fake

        init(_ kind: StagingScenarioKind, ceiling: Int = StagingPlan.maximumOperations) throws {
            self.kind = kind
            let replace = kind == .exportReplace || kind == .importReplace
            let new = try Fixture.big("new")
            let old = replace ? try Fixture.tiny("old") : nil
            self.contents = new
            self.old = old
            self.plan = try Fixture.plan(replace ? .replaceExisting : .createNew, ceiling: ceiling)
            let imports = kind == .importCreate || kind == .importReplace
            self.start = Fixture.volume(old: old, source: imports ? new : nil)
        }

        var newShapes: [String: Fake.Shape] { Fake.shapes(of: contents) }
        var oldShapes: [String: Fake.Shape] { old.map(Fake.shapes(of:)) ?? [:] }
        var imports: Bool { kind == .importCreate || kind == .importReplace }

        func run(_ fake: inout Fake) throws -> Result<StagingReceipt, StagingRefusal> {
            imports ? try Fixture.importRun(plan, &fake) : Fixture.export(plan, contents, &fake)
        }

        /// The operation log of an unfaulted run.
        func cleanLog() throws -> [Fake.Entry] {
            var fake = start
            _ = try run(&fake)
            return fake.log
        }

        func protectedNodes(_ fake: Fake) -> [String: Fake.Node] {
            fake.nodes(outside: [Fixture.destination, Fixture.staging, Fixture.backup])
        }

        /// The status calls an import's alias probes make on `fake`, counted from the seeded nodes alone: one per
        /// path component, ending with the first absent prefix. Covers the source, then the three plan names.
        static func aliasProbeCount(source: String, plan: StagingPlan, in fake: Fake) -> Int {
            var total = 0
            for path in [source, plan.destination, plan.stagingPath, plan.backupPath] {
                var prefix = ""
                for component in path.split(separator: "/") {
                    prefix = prefix.isEmpty ? String(component) : prefix + "/" + component
                    total += 1
                    if fake.nodes[prefix] == nil { break }
                }
            }
            return total
        }
    }
}

enum StagingScenarioKind: CaseIterable { case exportCreate, exportReplace, importCreate, importReplace }
