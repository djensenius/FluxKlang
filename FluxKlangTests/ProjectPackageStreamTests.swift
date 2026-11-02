import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

struct ProjectPackageStreamTests {
    private struct Entry {
        let path: String
        let kind: ProjectPackageEntryKind
        let declared: Int?
        let chunks: [Int]
    }

    @Test func syntheticParentFirstStreamReachesExactAggregateWithoutPayloads() throws {
        let limits = try ProjectPackageTestSupport.limits(entries: 6, entryBytes: 5, totalBytes: 9)
        let stream = [
            Entry(path: "media", kind: .directory, declared: nil, chunks: []),
            Entry(path: "media/takes", kind: .directory, declared: nil, chunks: []),
            Entry(path: "media/takes/é", kind: .regularFile, declared: 5, chunks: [2, 0, 3]),
            Entry(path: "notes", kind: .regularFile, declared: nil, chunks: [1, 3]),
            Entry(path: "empty", kind: .regularFile, declared: 0, chunks: []),
            Entry(path: "unknownEmpty", kind: .regularFile, declared: nil, chunks: [0])
        ]
        var admission = ProjectPackageAdmission(limits: limits)
        for entry in stream {
            try admission.admit(path: entry.path, kind: entry.kind, declaredByteCount: entry.declared)
            if entry.kind == .regularFile {
                for chunk in entry.chunks {
                    #expect(chunk <= admission.remainingReadableBytes)
                    try admission.consume(byteCount: chunk)
                }
                try admission.finishFile()
            }
        }
        #expect(admission.entryCount == 6)
        #expect(admission.totalBytesRead == 9)
        #expect(admission.remainingReadableBytes == 0)
        try admission.validateComplete()
    }

    @Test func chunkPartitionsProduceIdenticalEntireValues() throws {
        let partitions = [[6], [1, 5], [2, 2, 2], [1, 1, 1, 1, 1, 1], [0, 3, 0, 3, 0]]
        let limits = try ProjectPackageTestSupport.limits(entryBytes: 6, totalBytes: 6)
        for declared in [Optional(6), nil] {
            var expected: ProjectPackageAdmission?
            for chunks in partitions {
                var admission = ProjectPackageAdmission(limits: limits)
                try admission.admit(path: "dir", kind: .directory)
                try admission.admit(path: "dir/file", kind: .regularFile, declaredByteCount: declared)
                for chunk in chunks {
                    try admission.consume(byteCount: chunk)
                }
                #expect(admission.activeFileBytesRead == 6)
                if let expected {
                    #expect(admission == expected)
                } else {
                    expected = admission
                }
                try admission.finishFile()
                try admission.validateComplete()
            }
        }
    }

    @Test func refusedChunksAndEntriesPermitValidProgressWithoutRefunds() throws {
        let limits = try ProjectPackageTestSupport.limits(entryBytes: 5, totalBytes: 8)
        var admission = ProjectPackageAdmission(limits: limits)
        try admission.admit(path: "dir", kind: .directory)
        try admission.admit(path: "dir/first", kind: .regularFile, declaredByteCount: 3)
        try admission.consume(byteCount: 1)
        ProjectPackageTestSupport.expectRefusal(.declaredBytesExceeded, in: &admission) {
            try $0.consume(byteCount: 3)
        }
        ProjectPackageTestSupport.expectRefusal(.declaredByteCountMismatch, in: &admission) {
            try $0.finishFile()
        }
        try admission.consume(byteCount: 2)
        try admission.finishFile()
        ProjectPackageTestSupport.expectRefusal(.duplicatePath, in: &admission) {
            try $0.admit(path: "dir/first", kind: .regularFile)
        }
        try admission.admit(path: "dir/second", kind: .regularFile)
        try admission.consume(byteCount: 4)
        ProjectPackageTestSupport.expectRefusal(.entryBytesExceeded, in: &admission) {
            try $0.consume(byteCount: 2)
        }
        try admission.consume(byteCount: 1)
        try admission.finishFile()
        #expect(admission.entryCount == 3)
        #expect(admission.totalBytesRead == 8)
        try admission.validateComplete()
    }

    @Test func unfinishedUnknownAndDeclaredFilesPreventCompletionEvenAtZeroAllowance() throws {
        let limits = try ProjectPackageTestSupport.limits(entryBytes: 2, totalBytes: 2)
        for declared in [Optional(2), nil] {
            var admission = ProjectPackageAdmission(limits: limits)
            try admission.admit(path: "file", kind: .regularFile, declaredByteCount: declared)
            ProjectPackageTestSupport.expectRefusal(.fileAlreadyOpen, in: &admission) {
                try $0.validateComplete()
            }
            try admission.consume(byteCount: 2)
            #expect(admission.remainingReadableBytes == 0)
            ProjectPackageTestSupport.expectRefusal(.fileAlreadyOpen, in: &admission) {
                try $0.validateComplete()
            }
            try admission.finishFile()
            try admission.validateComplete()
        }
    }

    @Test func readRequestSchedulingUsesMinimumOfEveryApplicableAllowance() throws {
        let limits = try ProjectPackageTestSupport.limits(entryBytes: 7, totalBytes: 10)
        var admission = ProjectPackageAdmission(limits: limits)
        try admission.admit(path: "declared", kind: .regularFile, declaredByteCount: 4)
        #expect(admission.remainingReadableBytes == 4)
        var requests: [Int] = []
        while admission.remainingReadableBytes > 0 {
            let request = min(3, admission.remainingReadableBytes)
            requests.append(request)
            try admission.consume(byteCount: request)
        }
        #expect(requests == [3, 1])
        try admission.finishFile()
        try admission.admit(path: "undeclared", kind: .regularFile)
        #expect(admission.remainingReadableBytes == 6)
        try admission.consume(byteCount: 2)
        #expect(admission.remainingReadableBytes == 4)
        // Simulate a caller-observed EOF before the budget is exhausted.
        try admission.finishFile()
        #expect(admission.totalBytesRead == 6)
        try admission.admit(path: "last", kind: .regularFile, declaredByteCount: 4)
        #expect(admission.remainingReadableBytes == 4)
        try admission.consume(byteCount: 4)
        #expect(admission.remainingReadableBytes == 0)
        try admission.finishFile()
        try admission.validateComplete()
    }
}
