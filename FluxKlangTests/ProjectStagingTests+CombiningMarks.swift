import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension ProjectStagingTests {
    private static let marked = "a/\u{301}b"

    private func plain(_ destination: String, mode: StagingMode = .createNew) throws -> StagingPlan {
        try Fixture.plan(mode, destination: destination)
    }

    @Test func aLeafStartingWithACombiningMarkKeepsItInEveryDerivedName() throws {
        let withMark = try plain(Self.marked)
        let without = try plain("a/b")
        #expect(withMark.parentPath == "a")
        #expect(withMark.stagingPath.unicodeScalars.contains("\u{301}"))
        #expect(withMark.backupPath.unicodeScalars.contains("\u{301}"))
        #expect(withMark.stagingPath == "a/.\u{301}b.staging-t1")
        #expect(withMark.backupPath == "a/.\u{301}b.previous-t1")
        let names = [withMark.stagingPath, withMark.backupPath, without.stagingPath, without.backupPath]
        #expect(Set(names).count == 4)
        #expect(without.stagingPath == "a/.b.staging-t1")
    }

    @Test func aSourceBeneathOrAboveADestinationWithACombiningMarkOverlapsIt() throws {
        let top = try plain("a")
        #expect(top.overlaps(Self.marked))
        #expect(StagingPlan.isWithin(Self.marked, of: "a"))
        let marked = try plain(Self.marked)
        #expect(marked.overlaps("a"))
        #expect(marked.overlaps(Self.marked + "/child"))
        #expect(StagingPlan.isWithin(Self.marked + "/x", of: Self.marked))
    }

    @Test func siblingsThatDifferOnlyByACombiningMarkDoNotOverlap() throws {
        let marked = try plain(Self.marked)
        let without = try plain("a/b")
        #expect(!marked.overlaps("a/b"))
        #expect(!without.overlaps(Self.marked))
        #expect(!StagingPlan.isWithin("a/b", of: Self.marked))
        #expect(!StagingPlan.isWithin(Self.marked, of: "a/b"))
        #expect(!StagingPlan.isWithin("ab", of: "a"))
    }

    private func markedVolume() -> Fake {
        var fake = Fixture.volume()
        fake.seedDirectory("a")
        fake.seedFile(Self.marked, Data([1]))
        fake.seedFile("a/b", Data([2]))
        fake.seedFile("a2", Data([3]))
        return fake
    }

    @Test func aRenameMovesACombiningMarkChildWithItsParentAndKeepsTheSiblingApart() throws {
        var fake = markedVolume()
        try fake.rename(from: "a", to: "c")
        let moved = fake.shapes(at: "c")
        #expect(Set(moved.keys) == ["", "/\u{301}b", "/b"])
        #expect(moved["/\u{301}b"]?.bytes == Data([1]))
        #expect(moved["/b"]?.bytes == Data([2]))
        #expect(fake.shapes(at: "a").isEmpty)
        #expect(fake.nodes["a2"]?.bytes == Data([3]))
        #expect(Set(fake.nodes.keys) == ["c", "c/\u{301}b", "c/b", "a2", "other", "other/keep", "sibling.txt"])
    }

    @Test func aRemovalDeletesACombiningMarkChildWithItsParentAndNotTheSibling() throws {
        var fake = markedVolume()
        try fake.removeTree(at: "a")
        #expect(Set(fake.nodes.keys) == ["a2", "other", "other/keep", "sibling.txt"])
        var child = markedVolume()
        try child.removeTree(at: "a/b")
        #expect(child.nodes[Self.marked]?.bytes == Data([1]))
        #expect(child.nodes["a/b"] == nil)
    }

    @Test func aListingOfAParentReturnsACombiningMarkChildAsItsOwnName() throws {
        var fake = markedVolume()
        let listed = try fake.listDirectory(at: "a", limit: 10)
        #expect(listed.map { Array($0.unicodeScalars) } == [["b"], ["\u{301}", "b"]])
        #expect(fake.shapes(at: "a").count == 3)
    }
}
