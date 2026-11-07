import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension ProjectStagingTests {
    private func make(
        _ destination: String, token: String = "t1", mode: StagingMode = .createNew,
        limits: ProjectPackageLimits? = nil
    ) throws -> Result<StagingPlan, StagingRefusal> {
        let limits = try limits ?? Fixture.limits()
        do throws(StagingRefusal) {
            return try .success(StagingPlan.make(destination: destination, token: token, mode: mode, limits: limits))
        } catch {
            return .failure(error)
        }
    }

    @Test func tokenAcceptsOneAndThirtyTwoBytesAndRefusesZeroAndThirtyThree() throws {
        let longest = String(repeating: "a", count: 32)
        #expect(Fixture.value(try make("Set", token: "a"))?.stagingPath == ".Set.staging-a")
        #expect(Fixture.value(try make("Set", token: longest))?.stagingPath == ".Set.staging-" + longest)
        #expect(Fixture.refusal(try make("Set", token: "")) == .invalidToken)
        #expect(Fixture.refusal(try make("Set", token: longest + "a")) == .invalidToken)
        #expect(Fixture.value(try make("Set", token: "0z9"))?.backupPath == ".Set.previous-0z9")
    }

    @Test func tokenRefusesUppercaseSeparatorsAndNonASCII() throws {
        for token in ["A", "a/b", "a.b", "a-b", "a b", "\u{E9}", "a\u{0}", "t_1"] {
            #expect(Fixture.refusal(try make("Set", token: token)) == .invalidToken, "token \(token.debugDescription)")
        }
    }

    @Test func derivedNamesAreHiddenStagingAndPreviousSiblingsOfTheDestination() throws {
        let top = try #require(Fixture.value(try make("Set.fluxklang", mode: .replaceExisting)))
        #expect(top.destination == "Set.fluxklang")
        #expect(top.parentPath.isEmpty)
        #expect(top.stagingPath == ".Set.fluxklang.staging-t1")
        #expect(top.backupPath == ".Set.fluxklang.previous-t1")
        #expect(top.mode == .replaceExisting)
        #expect(top.operationCeiling == StagingPlan.maximumOperations)
        let nested = try #require(Fixture.value(try make("a/b/Set.fluxklang")))
        #expect(nested.parentPath == "a/b")
        #expect(nested.stagingPath == "a/b/.Set.fluxklang.staging-t1")
        #expect(nested.backupPath == "a/b/.Set.fluxklang.previous-t1")
    }

    @Test func theThreeNamesAreDistinctSiblingsAndNeverAncestorsOfEachOther() throws {
        let destinations = [
            "a", "Set.fluxklang", "a/b", "x/y/z", ".hidden", "a..b", "Set.staging-t1", "d/.d.staging-t1"
        ]
        for destination in destinations {
            for token in ["t1", "0", String(repeating: "z", count: 32)] {
                let plan = try #require(Fixture.value(try make(destination, token: token)))
                let names = [plan.destination, plan.stagingPath, plan.backupPath]
                #expect(Set(names).count == 3, "\(destination) \(token)")
                for name in names {
                    #expect(name.hasPrefix(plan.parentPath.isEmpty ? "" : plan.parentPath + "/"))
                    for other in names where other != name {
                        #expect(!other.hasPrefix(name + "/"), "\(name) must not be an ancestor of \(other)")
                    }
                }
            }
        }
    }

    @Test func derivedPathBytesAreAdmittedAtTheLongestNameAndRefusedOneByteShorter() throws {
        // ".ab.previous-t" is the longest derived name: 1 + 2 + 10 + 1 = 14 UTF-8 bytes.
        let exact = try Fixture.limits(pathBytes: 14)
        let shorter = try Fixture.limits(pathBytes: 13)
        #expect(Fixture.value(try make("ab", token: "t", limits: exact))?.backupPath == ".ab.previous-t")
        #expect(Fixture.refusal(try make("ab", token: "t", limits: shorter)) == .package(.pathTooLong))
        let nested = try Fixture.limits(pathBytes: 17)
        #expect(Fixture.value(try make("dd/ab", token: "t", limits: nested))?.backupPath == "dd/.ab.previous-t")
        #expect(Fixture.refusal(try make("dd/ab", token: "t", limits: try Fixture.limits(pathBytes: 16)))
            == .package(.pathTooLong))
    }

    @Test func destinationDepthAcceptsTheLimitAndRefusesOneMore() throws {
        let three = try Fixture.limits(depth: 3)
        #expect(Fixture.value(try make("a/b/c", limits: three))?.parentPath == "a/b")
        #expect(Fixture.refusal(try make("a/b/c/d", limits: three)) == .package(.pathTooDeep))
        #expect(Fixture.refusal(try make("a/b/c", limits: try Fixture.limits(depth: 2))) == .package(.pathTooDeep))
    }

    @Test func destinationsThatAreNotRelativeNFCNamesAreRefusedWithTheirPathError() throws {
        let invalid = ["", "..", "/abs", "a/../b", "a//b", "a/", "a\\b", "a:b", "a%b", "a\u{7}b", ".", " "]
        for destination in invalid {
            #expect(Fixture.refusal(try make(destination)) == .package(.invalidPath), "\(destination.debugDescription)")
        }
        #expect(Fixture.refusal(try make("e\u{301}")) == .package(.nonNFCPath))
        #expect(Fixture.value(try make("\u{E9}"))?.stagingPath == ".\u{E9}.staging-t1")
    }

    @Test func operationCountMatchesTheHandDerivedFormula() {
        // createNew: root, manifest, d + f entries, d + 1 syncs, rename, parent sync = 5 + 2d + f.
        #expect(StagingPlan.operationCount(directories: 0, files: 0, mode: .createNew) == 5)
        #expect(StagingPlan.operationCount(directories: 4, files: 4, mode: .createNew) == 17)
        #expect(StagingPlan.operationCount(directories: 1, files: 2, mode: .createNew) == 9)
        // replaceExisting adds the retire rename and the backup removal = 7 + 2d + f.
        #expect(StagingPlan.operationCount(directories: 0, files: 0, mode: .replaceExisting) == 7)
        #expect(StagingPlan.operationCount(directories: 4, files: 4, mode: .replaceExisting) == 19)
        #expect(StagingPlan.operationCount(directories: 3, files: 10, mode: .replaceExisting) == 23)
    }

    @Test func operationCountOverflowAndNegativesAreNilNotATrap() {
        for mode in [StagingMode.createNew, .replaceExisting] {
            #expect(StagingPlan.operationCount(directories: Int.max, files: 0, mode: mode) == nil)
            #expect(StagingPlan.operationCount(directories: 0, files: Int.max, mode: mode) == nil)
            #expect(StagingPlan.operationCount(directories: Int.max / 2, files: 0, mode: mode) == nil)
            #expect(StagingPlan.operationCount(directories: Int.max / 2 + 1, files: 0, mode: mode) == nil)
            #expect(StagingPlan.operationCount(directories: Int.max / 2, files: Int.max, mode: mode) == nil)
            #expect(StagingPlan.operationCount(directories: -1, files: 3, mode: mode) == nil)
            #expect(StagingPlan.operationCount(directories: 3, files: -1, mode: mode) == nil)
        }
        #expect(StagingPlan.operationCount(directories: 0, files: Int.max - 5, mode: .createNew) == Int.max)
        #expect(StagingPlan.operationCount(directories: 0, files: Int.max - 4, mode: .createNew) == nil)
    }

    @Test func theRealCeilingAdmitsExactlyOneHundredThousandOperations() throws {
        let create = try Fixture.plan(.createNew)
        try create.admitOperations(directories: 0, files: 99_995)
        try create.admitOperations(directories: 1, files: 99_993)
        #expect(throws: StagingRefusal.operationBudgetExceeded) {
            try create.admitOperations(directories: 0, files: 99_996)
        }
        #expect(throws: StagingRefusal.operationBudgetExceeded) {
            try create.admitOperations(directories: 1, files: 99_994)
        }
        let replace = try Fixture.plan(.replaceExisting)
        try replace.admitOperations(directories: 0, files: 99_993)
        #expect(throws: StagingRefusal.operationBudgetExceeded) {
            try replace.admitOperations(directories: 0, files: 99_994)
        }
        #expect(throws: StagingRefusal.operationBudgetExceeded) {
            try create.admitOperations(directories: Int.max, files: Int.max)
        }
    }

    @Test func operationCeilingAcceptsOneAndMaximumAndRefusesZeroNegativeAndMaximumPlusOne() throws {
        for ceiling in [1, StagingPlan.maximumOperations] {
            let plan = try Fixture.plan(.createNew, ceiling: ceiling)
            #expect(plan.operationCeiling == ceiling)
        }
        for ceiling in [0, -1, StagingPlan.maximumOperations + 1, Int.max, Int.min] {
            #expect(throws: StagingRefusal.invalidOperationCeiling) { try Fixture.plan(.createNew, ceiling: ceiling) }
        }
        #expect(StagingPlan.maximumOperations == 100_000)
    }

    @Test func aCeilingEqualToTheCountIsAdmittedAndOneBelowIsRefused() throws {
        let exact = try Fixture.plan(.createNew, ceiling: 17)
        try exact.admitOperations(directories: 4, files: 4)
        let below = try Fixture.plan(.createNew, ceiling: 16)
        #expect(throws: StagingRefusal.operationBudgetExceeded) { try below.admitOperations(directories: 4, files: 4) }
        let replace = try Fixture.plan(.replaceExisting, ceiling: 19)
        try replace.admitOperations(directories: 4, files: 4)
        #expect(throws: StagingRefusal.operationBudgetExceeded) {
            try Fixture.plan(.replaceExisting, ceiling: 18).admitOperations(directories: 4, files: 4)
        }
    }

    @Test func faultsMapOntoTheRecoveryVocabularyCategories() {
        #expect(StagingIOFault.noSpace.saveFaultCategory == .diskFull)
        #expect(StagingIOFault.denied.saveFaultCategory == .permissionDenied)
        for fault in [StagingIOFault.notFound, .exists, .crossVolume, .tooManyEntries, .ioError, .interrupted] {
            #expect(fault.saveFaultCategory == .unknown, "\(fault)")
        }
    }

    @Test func theRefusalForTheSameConditionIsEqualWhateverThePaths() throws {
        var first = Fixture.volume()
        first.seedDirectory(Fixture.destination)
        var second = Fixture.volume()
        second.seedDirectory("Other.fluxklang")
        let contents = try Fixture.tiny("n")
        let one = Fixture.export(try Fixture.plan(.createNew), contents, &first)
        let otherPlan = try Fixture.plan(.createNew, destination: "Other.fluxklang", token: "zz")
        let two = Fixture.export(otherPlan, contents, &second)
        #expect(Fixture.refusal(one) == .destinationExists)
        #expect(Fixture.refusal(one) == Fixture.refusal(two))
    }
}
