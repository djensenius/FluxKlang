import Darwin
import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Each mutation is made from the writer's stage hook, so it lands between two specific checks.
extension ProjectPackageIOTests {
    private typealias Support = PackageIOTestSupport

    private static func writer(
        at stage: ProjectPackageWriteStage, of path: String, mutate: @escaping @Sendable () -> Void
    ) -> ProjectPackageWriter {
        var writer = ProjectPackageWriter()
        writer.stageHookForTesting = { observed, observedPath in
            guard observed == stage, observedPath == path else { return }
            mutate()
        }
        return writer
    }

    private static func names(_ url: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
    }

    @Test func replacedSubdirectoryIsRefused() throws {
        let scratch = try Support.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let contents = try Support.read(Support.makePackage(in: Support.scratchChild(scratch, "source")))
        let destination = scratch.appendingPathComponent("dest.fluxklang")
        let original = destination.appendingPathComponent("documents")
        let aside = scratch.appendingPathComponent("aside")
        let writer = Self.writer(at: .afterCreate, of: "documents") {
            #expect(rename(original.path, aside.path) == 0)
            #expect(mkdir(original.path, 0o755) == 0)
        }
        #expect(throws: ProjectPackageIOError.destinationChanged) { try writer.write(contents, to: destination) }
        // Refused before the member was created in either directory.
        #expect(try Self.names(original).isEmpty)
        #expect(try Self.names(aside).isEmpty)
    }

    @Test func renamedDestinationRootIsRefused() throws {
        let scratch = try Support.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let contents = try Support.read(Support.makePackage(in: Support.scratchChild(scratch, "source")))
        let destination = scratch.appendingPathComponent("dest.fluxklang")
        let renamed = scratch.appendingPathComponent("renamed.fluxklang")
        let writer = Self.writer(at: .beforeCreate, of: "documents") {
            #expect(rename(destination.path, renamed.path) == 0)
            #expect(mkdir(destination.path, 0o755) == 0)
        }
        #expect(throws: ProjectPackageIOError.destinationChanged) { try writer.write(contents, to: destination) }
        #expect(try Self.names(destination).isEmpty)
        // Residue: the entry created through the held root descriptor stays in the renamed directory.
        #expect(try Self.names(renamed) == ["documents", "manifest.json"])
    }

    @Test func parentMovedOutsideWhileHeldIsRefused() throws {
        let scratch = try Support.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let contents = try Support.read(Support.makePackage(in: Support.scratchChild(scratch, "source")))
        let destination = scratch.appendingPathComponent("dest.fluxklang")
        let notes = destination.appendingPathComponent("notes")
        let outside = scratch.appendingPathComponent("outside-notes")
        let writer = Self.writer(at: .beforeCreate, of: "notes/readme.txt") {
            #expect(rename(notes.path, outside.path) == 0)
        }
        #expect(throws: ProjectPackageIOError.destinationChanged) { try writer.write(contents, to: destination) }
        #expect(!FileManager.default.fileExists(atPath: notes.path))
        // Refused right after the member was created, before the next entry.
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("references").path))
        // Residue: detection follows the write, so the stray member exists outside the destination.
        let stray = try Data(contentsOf: outside.appendingPathComponent("readme.txt"))
        #expect(stray == Support.files["notes/readme.txt"])
    }

    @Test func subdirectorySwappedForSymlinkIsRefused() throws {
        let scratch = try Support.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let contents = try Support.read(Support.makePackage(in: Support.scratchChild(scratch, "source")))
        let destination = scratch.appendingPathComponent("dest.fluxklang")
        let documents = destination.appendingPathComponent("documents")
        let real = scratch.appendingPathComponent("real")
        let writer = Self.writer(at: .afterCreate, of: "documents") {
            #expect(rename(documents.path, real.path) == 0)
            #expect(symlink(real.path, documents.path) == 0)
        }
        #expect(throws: ProjectPackageIOError.destinationChanged) { try writer.write(contents, to: destination) }
        // The link was never followed.
        #expect(try Self.names(real).isEmpty)
    }

    @Test func completedSubdirectoryRenamedAfterLastEntryIsRefused() throws {
        let scratch = try Support.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let contents = try Support.read(Support.makePackage(in: Support.scratchChild(scratch, "source")))
        let last = try #require(contents.entries.map(\.path).max { $0.utf8.lexicographicallyPrecedes($1.utf8) })
        #expect(last == "unknown.bin")
        let destination = scratch.appendingPathComponent("dest.fluxklang")
        let state = destination.appendingPathComponent("state")
        let moved = destination.appendingPathComponent("state-moved")
        let writer = Self.writer(at: .afterCreate, of: last) {
            #expect(rename(state.path, moved.path) == 0)
        }
        #expect(throws: ProjectPackageIOError.destinationChanged) { try writer.write(contents, to: destination) }
        // Every entry was written, so only the final re-walk could refuse.
        #expect(try Data(contentsOf: destination.appendingPathComponent(last)) == Support.files[last])
        #expect(try Data(contentsOf: moved.appendingPathComponent("draft.bin")) == Support.files["state/draft.bin"])
    }

    @Test func nestedDirectoryReplacedAfterLastEntryIsRefused() throws {
        let scratch = try Support.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let contents = try Support.read(Support.makePackage(in: Support.scratchChild(scratch, "source")))
        let last = try #require(contents.entries.map(\.path).max { $0.utf8.lexicographicallyPrecedes($1.utf8) })
        #expect(last == "unknown.bin")
        let destination = scratch.appendingPathComponent("dest.fluxklang")
        let nested = destination.appendingPathComponent("empty/nested")
        let aside = scratch.appendingPathComponent("aside")
        let writer = Self.writer(at: .afterCreate, of: last) {
            #expect(rename(nested.path, aside.path) == 0)
            #expect(mkdir(nested.path, 0o755) == 0)
        }
        // Only the final re-walk of the nested path can refuse; its parent `empty` is unchanged.
        #expect(throws: ProjectPackageIOError.destinationChanged) { try writer.write(contents, to: destination) }
        #expect(try Data(contentsOf: destination.appendingPathComponent(last)) == Support.files[last])
    }

    @Test func intermediateDirectorySwappedAroundNestedParentIsRefused() throws {
        let scratch = try Support.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        var files = Support.files
        files["empty/nested/leaf.bin"] = Data([9])
        let source = try Support.scratchChild(scratch, "source")
        let contents = try Support.read(Support.makePackage(in: source, files: files))
        let destination = scratch.appendingPathComponent("dest.fluxklang")
        let empty = destination.appendingPathComponent("empty")
        let nested = empty.appendingPathComponent("nested")
        let aside = scratch.appendingPathComponent("aside")
        let asideNested = aside.appendingPathComponent("nested")
        let spare = scratch.appendingPathComponent("spare")
        var writer = ProjectPackageWriter()
        // `empty` is swapped while the held `nested` keeps its identity, then restored before the
        // next entry, so only the intermediate comparison after the create can refuse.
        writer.stageHookForTesting = { stage, path in
            guard stage == .beforeCreate else { return }
            if path == "empty/nested/leaf.bin" {
                #expect(rename(empty.path, aside.path) == 0)
                #expect(mkdir(empty.path, 0o755) == 0)
                #expect(rename(asideNested.path, nested.path) == 0)
            } else if path == "graphs" {
                #expect(rename(nested.path, asideNested.path) == 0)
                #expect(rename(empty.path, spare.path) == 0)
                #expect(rename(aside.path, empty.path) == 0)
            }
        }
        #expect(throws: ProjectPackageIOError.destinationChanged) { try writer.write(contents, to: destination) }
        // Refused before the restore ran; the member sits in the held directory under the new `empty`.
        #expect(!FileManager.default.fileExists(atPath: spare.path))
        #expect(try Self.names(aside).isEmpty)
        #expect(try Data(contentsOf: nested.appendingPathComponent("leaf.bin")) == Data([9]))
    }

    @Test func noOpHookStillRoundTripsByteIdentically() throws {
        let scratch = try Support.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let original = try Support.read(Support.makePackage(in: Support.scratchChild(scratch, "source")))
        let destination = scratch.appendingPathComponent("dest.fluxklang")
        var writer = ProjectPackageWriter()
        writer.stageHookForTesting = { _, _ in }
        try writer.write(original, to: destination)

        #expect(try Support.read(destination, chunk: 4096) == original)
        #expect(try Data(contentsOf: destination.appendingPathComponent("manifest.json")) == original.manifestBytes)
        for (path, bytes) in Support.files {
            #expect(try Data(contentsOf: destination.appendingPathComponent(path)) == bytes)
        }
    }
}
