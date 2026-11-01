import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

enum ProjectPackageTestSupport {
    static func limits(
        entries: Int = 16, depth: Int = 8, pathBytes: Int = 128,
        entryBytes: Int = 8, totalBytes: Int = 16
    ) throws -> ProjectPackageLimits {
        try ProjectPackageLimits(
            maxEntries: entries, maxDepth: depth, maxPathUTF8Bytes: pathBytes,
            maxEntryBytes: entryBytes, maxTotalBytes: totalBytes
        )
    }

    static func expectRefusal(
        _ error: ProjectPackageError,
        in admission: inout ProjectPackageAdmission,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ operation: (inout ProjectPackageAdmission) throws -> Void
    ) {
        let before = admission
        #expect(throws: error, sourceLocation: sourceLocation) { try operation(&admission) }
        #expect(admission == before, sourceLocation: sourceLocation)
    }
}

struct ProjectPackageAdmissionTests {
    @Test func countsDirectoriesAndFilesAtExactEntryLimit() throws {
        var admission = ProjectPackageAdmission(limits: try ProjectPackageTestSupport.limits(entries: 2))
        try admission.admit(path: "dir", kind: .directory)
        try admission.validateComplete()
        try admission.admit(path: "dir/file", kind: .regularFile)
        try admission.finishFile()
        #expect(admission.entryCount == 2)
        ProjectPackageTestSupport.expectRefusal(.entryLimitExceeded, in: &admission) {
            try $0.admit(path: "extra", kind: .directory)
        }
        #expect(admission.totalBytesRead == 0)
    }

    @Test func enforcesParentFirstNamespaceAndCaseSensitiveDuplicates() throws {
        var admission = ProjectPackageAdmission(limits: try ProjectPackageTestSupport.limits())
        ProjectPackageTestSupport.expectRefusal(.missingParent, in: &admission) {
            try $0.admit(path: "dir/sub/file", kind: .regularFile)
        }
        try admission.admit(path: "dir", kind: .directory)
        ProjectPackageTestSupport.expectRefusal(.missingParent, in: &admission) {
            try $0.admit(path: "dir/sub/file", kind: .regularFile)
        }
        try admission.admit(path: "dir/sub", kind: .directory)
        try admission.admit(path: "dir/sub/file", kind: .regularFile)
        try admission.finishFile()
        ProjectPackageTestSupport.expectRefusal(.parentNotDirectory, in: &admission) {
            try $0.admit(path: "dir/sub/file/child", kind: .directory)
        }
        for kind in [ProjectPackageEntryKind.directory, .regularFile] {
            for name in ["dir", "dir/sub/file"] {
                ProjectPackageTestSupport.expectRefusal(.duplicatePath, in: &admission) {
                    try $0.admit(path: name, kind: kind)
                }
            }
        }
        try admission.admit(path: "Dir", kind: .directory)
        try admission.admit(path: "Dir/File", kind: .regularFile)
        try admission.finishFile()
        #expect(admission.entryCount == 5)
        try admission.admit(path: "é", kind: .directory)
        ProjectPackageTestSupport.expectRefusal(.nonNFCPath, in: &admission) {
            try $0.admit(path: "e\u{301}", kind: .directory)
        }
        ProjectPackageTestSupport.expectRefusal(.duplicatePath, in: &admission) {
            try $0.admit(path: "é", kind: .directory)
        }
    }

    @Test func refusesLinksUnsupportedKindsAndDirectoryDeclarations() throws {
        var admission = ProjectPackageAdmission(limits: try ProjectPackageTestSupport.limits())
        for kind in [ProjectPackageEntryKind.symbolicLink, .unsupported] {
            ProjectPackageTestSupport.expectRefusal(.unsupportedKind, in: &admission) {
                try $0.admit(path: "name", kind: kind)
            }
        }
        for count in [-1, 0, 1] {
            ProjectPackageTestSupport.expectRefusal(.directoryByteCount, in: &admission) {
                try $0.admit(path: "name", kind: .directory, declaredByteCount: count)
            }
        }
        try admission.admit(path: "name", kind: .directory)
        #expect(admission.entryCount == 1)
        try admission.validateComplete()
    }

    @Test func pathRefusalsPreserveCompleteState() throws {
        let limits = try ProjectPackageTestSupport.limits(depth: 2, pathBytes: 8)
        var admission = ProjectPackageAdmission(limits: limits)
        try admission.admit(path: "ok", kind: .regularFile, declaredByteCount: 2)
        try admission.consume(byteCount: 2)
        try admission.finishFile()
        let invalid: [(String, ProjectPackageError)] = [
            ("", .invalidPath), ("a/../b", .pathTooDeep), ("a/./b", .pathTooDeep),
            ("a.", .invalidPath), ("a:b", .invalidPath), ("123456789", .pathTooLong),
            ("e\u{301}", .nonNFCPath)
        ]
        for (name, error) in invalid {
            ProjectPackageTestSupport.expectRefusal(error, in: &admission) {
                try $0.admit(path: name, kind: .regularFile)
            }
        }
    }

    @Test func onlyOneFileCanBeOpenAndCompletionDoesNotSealValue() throws {
        var admission = ProjectPackageAdmission(limits: try ProjectPackageTestSupport.limits())
        try admission.validateComplete()
        #expect(admission.remainingReadableBytes == 0)
        ProjectPackageTestSupport.expectRefusal(.noOpenFile, in: &admission) { try $0.consume(byteCount: 0) }
        ProjectPackageTestSupport.expectRefusal(.noOpenFile, in: &admission) { try $0.finishFile() }
        try admission.admit(path: "file", kind: .regularFile, declaredByteCount: 2)
        for kind in [ProjectPackageEntryKind.directory, .regularFile] {
            ProjectPackageTestSupport.expectRefusal(.fileAlreadyOpen, in: &admission) {
                try $0.admit(path: "next", kind: kind)
            }
        }
        ProjectPackageTestSupport.expectRefusal(.fileAlreadyOpen, in: &admission) { try $0.validateComplete() }
        ProjectPackageTestSupport.expectRefusal(.declaredByteCountMismatch, in: &admission) { try $0.finishFile() }
        try admission.consume(byteCount: 1)
        ProjectPackageTestSupport.expectRefusal(.declaredByteCountMismatch, in: &admission) { try $0.finishFile() }
        try admission.consume(byteCount: 1)
        try admission.finishFile()
        let before = admission
        try admission.validateComplete()
        try admission.validateComplete()
        #expect(admission == before)
        try admission.admit(path: "next", kind: .directory)
        #expect(admission.entryCount == 2)
        #expect(admission.activeFileBytesRead == nil)
    }

    @Test func declaredLengthBoundsAndNegativeCountsAreAtomic() throws {
        let limits = try ProjectPackageTestSupport.limits(entryBytes: 4, totalBytes: 6)
        var admission = ProjectPackageAdmission(limits: limits)
        ProjectPackageTestSupport.expectRefusal(.negativeByteCount, in: &admission) {
            try $0.admit(path: "file", kind: .regularFile, declaredByteCount: -1)
        }
        ProjectPackageTestSupport.expectRefusal(.entryBytesExceeded, in: &admission) {
            try $0.admit(path: "file", kind: .regularFile, declaredByteCount: 5)
        }
        try admission.admit(path: "file", kind: .regularFile, declaredByteCount: 4)
        #expect(admission.totalBytesRead == 0)
        ProjectPackageTestSupport.expectRefusal(.negativeByteCount, in: &admission) {
            try $0.consume(byteCount: .min)
        }
        try admission.consume(byteCount: 4)
        ProjectPackageTestSupport.expectRefusal(.entryBytesExceeded, in: &admission) { try $0.consume(byteCount: 1) }
        try admission.finishFile()
        ProjectPackageTestSupport.expectRefusal(.totalBytesExceeded, in: &admission) {
            try $0.admit(path: "next", kind: .regularFile, declaredByteCount: 3)
        }
        try admission.admit(path: "next", kind: .regularFile, declaredByteCount: 1)
        ProjectPackageTestSupport.expectRefusal(.declaredBytesExceeded, in: &admission) {
            try $0.consume(byteCount: 2)
        }
        try admission.consume(byteCount: 1)
        try admission.finishFile()
        #expect(admission.totalBytesRead == 5)
    }

    @Test func undeclaredFilesRespectExactEntryAndAggregateBudgets() throws {
        let limits = try ProjectPackageTestSupport.limits(entryBytes: 4, totalBytes: 6)
        var admission = ProjectPackageAdmission(limits: limits)
        try admission.admit(path: "first", kind: .regularFile)
        #expect(admission.remainingReadableBytes == 4)
        ProjectPackageTestSupport.expectRefusal(.entryBytesExceeded, in: &admission) { try $0.consume(byteCount: 5) }
        try admission.consume(byteCount: 4)
        try admission.finishFile()
        try admission.admit(path: "second", kind: .regularFile)
        #expect(admission.remainingReadableBytes == 2)
        ProjectPackageTestSupport.expectRefusal(.totalBytesExceeded, in: &admission) { try $0.consume(byteCount: 3) }
        try admission.consume(byteCount: 2)
        #expect(admission.remainingReadableBytes == 0)
        ProjectPackageTestSupport.expectRefusal(.totalBytesExceeded, in: &admission) { try $0.consume(byteCount: 1) }
        try admission.finishFile()
        #expect(admission.totalBytesRead == 6)
        try admission.validateComplete()
    }

    @Test func zeroBytePolicyAllowsDirectoriesAndEmptyFiles() throws {
        let limits = try ProjectPackageTestSupport.limits(entryBytes: 0, totalBytes: 0)
        var admission = ProjectPackageAdmission(limits: limits)
        try admission.admit(path: "dir", kind: .directory)
        for (name, declaration) in [("dir/declared", Optional(0)), ("dir/unknown", nil)] {
            try admission.admit(path: name, kind: .regularFile, declaredByteCount: declaration)
            #expect(admission.remainingReadableBytes == 0)
            let before = admission
            try admission.consume(byteCount: 0)
            #expect(admission == before)
            ProjectPackageTestSupport.expectRefusal(.entryBytesExceeded, in: &admission) {
                try $0.consume(byteCount: 1)
            }
            try admission.finishFile()
        }
        #expect(admission.entryCount == 3)
        #expect(admission.totalBytesRead == 0)
        try admission.validateComplete()
    }

    @Test func intMaxEntryAndTotalArithmeticCannotWrap() throws {
        let limits = try ProjectPackageTestSupport.limits(entryBytes: .max, totalBytes: .max)
        var admission = ProjectPackageAdmission(limits: limits)
        try admission.admit(path: "huge", kind: .regularFile, declaredByteCount: .max)
        #expect(admission.remainingReadableBytes == Int.max)
        try admission.consume(byteCount: Int.max - 1)
        #expect(admission.remainingReadableBytes == 1)
        ProjectPackageTestSupport.expectRefusal(.byteCountOverflow, in: &admission) {
            try $0.consume(byteCount: 2)
        }
        try admission.consume(byteCount: 1)
        #expect(admission.totalBytesRead == Int.max)
        ProjectPackageTestSupport.expectRefusal(.byteCountOverflow, in: &admission) {
            try $0.consume(byteCount: 1)
        }
        try admission.finishFile()
        ProjectPackageTestSupport.expectRefusal(.totalBytesExceeded, in: &admission) {
            try $0.admit(path: "declared", kind: .regularFile, declaredByteCount: 1)
        }
        try admission.admit(path: "empty", kind: .regularFile)
        #expect(admission.remainingReadableBytes == 0)
        ProjectPackageTestSupport.expectRefusal(.byteCountOverflow, in: &admission) {
            try $0.consume(byteCount: 1)
        }
        #expect(admission.activeFileBytesRead == 0)
        try admission.finishFile()
        try admission.validateComplete()
    }
}
