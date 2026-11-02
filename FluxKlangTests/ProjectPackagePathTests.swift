import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

struct ProjectPackagePathTests {
    @Test func acceptsRelativeNestedAndUnicodeNames() throws {
        let limits = try ProjectPackageTestSupport.limits()
        for name in ["file", "dir/file.ext", "é/音楽.wav", "👩‍👩‍👧‍👦/take", ".hidden", " a/b c"] {
            let path = try ProjectPackagePath(name, limits: limits)
            #expect(path.value.utf8.elementsEqual(name.utf8))
            #expect(path.utf8ByteCount == name.utf8.count)
        }
        let nested = try ProjectPackagePath("é/音楽.wav", limits: limits)
        #expect(nested.parent == "é")
        #expect(nested.depth == 2)
        let rootChild = try ProjectPackagePath("file", limits: limits)
        #expect(rootChild.parent == nil)
        #expect(rootChild.depth == 1)
    }

    @Test func rejectsNonNFCBytesDespiteCanonicalStringEquality() throws {
        let limits = try ProjectPackageTestSupport.limits()
        let composed = "café"
        let decomposed = "cafe\u{301}"
        #expect(composed == decomposed)
        #expect(!composed.utf8.elementsEqual(decomposed.utf8))
        #expect(throws: ProjectPackageError.nonNFCPath) {
            try ProjectPackagePath(decomposed, limits: limits)
        }
        for name in ["dir/e\u{301}", "\u{212B}", "\u{1100}\u{1161}"] {
            #expect(throws: ProjectPackageError.nonNFCPath) {
                try ProjectPackagePath(name, limits: limits)
            }
        }
    }

    @Test func acceptsExactByteAndDepthBoundsAndRejectsOneOver() throws {
        let limits = try ProjectPackageTestSupport.limits(depth: 2, pathBytes: 4)
        let path = try ProjectPackagePath("a/é", limits: limits)
        #expect(path.utf8ByteCount == 4)
        #expect(path.depth == 2)
        #expect(throws: ProjectPackageError.pathTooLong) {
            try ProjectPackagePath("a/éx", limits: limits)
        }
        #expect(throws: ProjectPackageError.pathTooDeep) {
            try ProjectPackagePath("a/b/c", limits: limits)
        }
        let single = try ProjectPackageTestSupport.limits(depth: 1, pathBytes: 1)
        #expect(try ProjectPackagePath("a", limits: single).depth == 1)
        #expect(throws: ProjectPackageError.pathTooLong) {
            try ProjectPackagePath("é", limits: single)
        }
    }

    @Test func structuralScanStopsAtFirstLimitBeforeLexicalOrNFCWork() throws {
        let byteFirst = try ProjectPackageTestSupport.limits(depth: 1, pathBytes: 1)
        #expect(throws: ProjectPackageError.pathTooLong) {
            try ProjectPackagePath("a/e\u{301}", limits: byteFirst)
        }
        let depthFirst = try ProjectPackageTestSupport.limits(depth: 1, pathBytes: 2)
        #expect(throws: ProjectPackageError.pathTooDeep) {
            try ProjectPackagePath("a/e\u{301}", limits: depthFirst)
        }
        #expect(throws: ProjectPackageError.pathTooLong) {
            try ProjectPackagePath("e\u{301}", limits: byteFirst)
        }
    }

    @Test func rejectsMalformedAndForbiddenNames() throws {
        let limits = try ProjectPackageTestSupport.limits()
        let invalid = [
            "", "/", "/a", "a/", "a//b", ".", "..", "./a", "../a", "a/./b", "a/../b",
            "a\\b", "a:b", "a%b", "a%2fb", "a.", "a ", "a./b", "a /b", "a/.",
            "a/\u{0}", "a\tb", "a\nb", "a\rb", "a\u{7F}b", "a\u{85}b", "a\u{9F}b"
        ]
        for name in invalid {
            #expect(throws: ProjectPackageError.invalidPath) {
                try ProjectPackagePath(name, limits: limits)
            }
        }
    }

    @Test func slashFollowedByCombiningMarkIsStillASeparator() throws {
        let limits = try ProjectPackageTestSupport.limits()
        let path = try ProjectPackagePath("a/\u{301}b", limits: limits)
        #expect(path.depth == 2)
        #expect(path.parent == "a")
        for name in ["/\u{301}a", "a//\u{301}b", "a./\u{301}b"] {
            #expect(throws: ProjectPackageError.invalidPath) {
                try ProjectPackagePath(name, limits: limits)
            }
        }
    }

    @Test func rejectsInvalidLimitsAndAcceptsZeroByteAndIntMaxPolicies() throws {
        let invalid = [
            (0, 1, 1, 0, 0), (-1, 1, 1, 0, 0), (1, 0, 1, 0, 0), (1, -1, 1, 0, 0),
            (1, 1, 0, 0, 0), (1, 1, -1, 0, 0), (1, 1, 1, -1, 0), (1, 1, 1, 0, -1),
            (1, 1, 1, 2, 1), (1, 1, 1, Int.min, Int.min)
        ]
        for (entries, depth, pathBytes, entryBytes, totalBytes) in invalid {
            #expect(throws: ProjectPackageError.invalidLimits) {
                try ProjectPackageLimits(
                    maxEntries: entries, maxDepth: depth, maxPathUTF8Bytes: pathBytes,
                    maxEntryBytes: entryBytes, maxTotalBytes: totalBytes
                )
            }
        }
        let zero = try ProjectPackageTestSupport.limits(entryBytes: 0, totalBytes: 0)
        #expect(zero.maxEntryBytes == 0)
        let maximum = try ProjectPackageLimits(
            maxEntries: .max, maxDepth: .max, maxPathUTF8Bytes: .max,
            maxEntryBytes: .max, maxTotalBytes: .max
        )
        #expect(try ProjectPackagePath("a/b", limits: maximum).depth == 2)
    }
}
