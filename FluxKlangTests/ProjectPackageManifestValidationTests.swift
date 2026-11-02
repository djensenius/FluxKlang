import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

struct ProjectPackageManifestValidationTests {
    @Test func requiresExplicitPositiveManifestCeilingWithinEntryLimit() throws {
        let limits = try ManifestTestSupport.policy().packageLimits
        for ceiling in [Int.min, -1, 0, limits.maxEntryBytes + 1] {
            #expect(throws: ProjectPackageError.invalidLimits) {
                try ProjectPackageManifestPolicy(packageLimits: limits, maxManifestBytes: ceiling)
            }
        }
        let zero = try ProjectPackageLimits(
            maxEntries: 1, maxDepth: 1, maxPathUTF8Bytes: 1, maxEntryBytes: 0, maxTotalBytes: 0
        )
        #expect(throws: ProjectPackageError.invalidLimits) {
            try ProjectPackageManifestPolicy(packageLimits: zero, maxManifestBytes: 1)
        }
        #expect(try ProjectPackageManifestPolicy(packageLimits: limits, maxManifestBytes: 1).maxManifestBytes == 1)
        #expect(try ProjectPackageManifestPolicy(
            packageLimits: limits, maxManifestBytes: limits.maxEntryBytes
        ).maxManifestBytes == limits.maxEntryBytes)
    }

    @Test func countsFilesAndSharedImpliedDirectoriesExactlyOnce() throws {
        var value = ManifestTestSupport.manifest()
        value.project.member.path = "shared/nested/project"
        value.opaqueState = [ProjectPackageMember(path: "shared/nested/state")]
        let exact = try ManifestTestSupport.policy(entries: 5)
        _ = try value.encoded(policy: exact)
        #expect(throws: ProjectPackageError.entryLimitExceeded) {
            try value.encoded(policy: ManifestTestSupport.policy(entries: 4))
        }
        value.opaqueState.append(ProjectPackageMember(path: "other/nested/state"))
        _ = try value.encoded(policy: ManifestTestSupport.policy(entries: 8))
        #expect(throws: ProjectPackageError.entryLimitExceeded) {
            try value.encoded(policy: ManifestTestSupport.policy(entries: 7))
        }
        let full = ManifestTestSupport.fullManifest()
        _ = try full.encoded(policy: ManifestTestSupport.policy(entries: 12))
        #expect(throws: ProjectPackageError.entryLimitExceeded) {
            try full.encoded(policy: ManifestTestSupport.policy(entries: 11))
        }
    }

    @Test func countPreflightPrecedesPathAndLookupWork() throws {
        let policy = try ManifestTestSupport.policy(entries: 3)
        var value = ManifestTestSupport.manifest()
        value.project.member.path = "../invalid"
        value.graphs = Array(repeating: ProjectPackageGraphReference(
            graph: GraphID(validated: "gph.same"), revision: .initial,
            member: ProjectPackageMember(path: "../invalid")
        ), count: 2)
        #expect(throws: ProjectPackageError.entryLimitExceeded) { try value.encoded(policy: policy) }
        value.graphs = []
        value.opaqueState = Array(repeating: ProjectPackageMember(path: "../invalid"), count: 2)
        #expect(throws: ProjectPackageError.entryLimitExceeded) { try value.encoded(policy: policy) }
        value.opaqueState = []
        value.resources = Array(repeating: ProjectPackageResource(
            contentDigest: "invalid", bookmarks: []
        ), count: 4)
        #expect(throws: ProjectPackageError.entryLimitExceeded) { try value.encoded(policy: policy) }
        value.resources = [ProjectPackageResource(
            contentDigest: "invalid", bookmarks: Array(repeating: ProjectPackageMember(path: "x"), count: 2)
        )]
        #expect(throws: ProjectPackageError.entryLimitExceeded) { try value.encoded(policy: policy) }
        value.resources = [
            ProjectPackageResource(contentDigest: "invalid", bookmarks: [ProjectPackageMember(path: "x")]),
            ProjectPackageResource(contentDigest: "invalid", bookmarks: [ProjectPackageMember(path: "y")])
        ]
        #expect(throws: ProjectPackageError.entryLimitExceeded) { try value.encoded(policy: policy) }
    }

    @Test func rejectsCrossOwnerDuplicatesAndReservedManifestOwnership() throws {
        let policy = try ManifestTestSupport.policy()
        let original = ManifestTestSupport.fullManifest()
        let paths = [
            original.project.member.path, original.graphs[0].member.path,
            try #require(original.resources[0].media?.path),
            original.resources[0].bookmarks[0].path, original.opaqueState[0].path, "manifest.json"
        ]
        for path in paths {
            var value = original
            value.opaqueState.append(ProjectPackageMember(path: path))
            #expect(throws: ProjectPackageError.duplicatePath) { try value.encoded(policy: policy) }
        }
        var value = original
        value.resources[0].bookmarks[1].path = value.resources[0].bookmarks[0].path
        #expect(throws: ProjectPackageError.duplicatePath) { try value.encoded(policy: policy) }
        value = original
        value.graphs[0].member.path = value.project.member.path
        #expect(throws: ProjectPackageError.duplicatePath) { try value.encoded(policy: policy) }
        value = original
        value.resources[0].media?.path = value.graphs[0].member.path
        #expect(throws: ProjectPackageError.duplicatePath) { try value.encoded(policy: policy) }
        value = original
        value.resources[0].bookmarks[0].path = try #require(value.resources[0].media?.path)
        #expect(throws: ProjectPackageError.duplicatePath) { try value.encoded(policy: policy) }
        value = original
        value.project.member.path = "manifest.json"
        #expect(throws: ProjectPackageError.duplicatePath) { try value.encoded(policy: policy) }
    }

    @Test func rejectsFileDirectoryAncestorCollisionsInBothOrders() throws {
        let policy = try ManifestTestSupport.policy()
        for paths in [["a", "a/b/c"], ["a/b/c", "a"], ["a/b", "a/b/c"], ["a/b/c", "a/b"]] {
            var value = ManifestTestSupport.manifest()
            value.project.member.path = paths[0]
            value.opaqueState = [ProjectPackageMember(path: paths[1])]
            #expect(throws: ProjectPackageError.parentNotDirectory) { try value.encoded(policy: policy) }
        }
        var value = ManifestTestSupport.manifest()
        value.project.member.path = "manifest.json/child"
        #expect(throws: ProjectPackageError.parentNotDirectory) { try value.encoded(policy: policy) }
    }

    @Test func usesP1PathPolicyForEveryCategoryIncludingReservedName() throws {
        let policy = try ManifestTestSupport.policy()
        let bad = "../outside"
        var variants: [ProjectPackageManifest] = []
        var value = ManifestTestSupport.fullManifest()
        value.project.member.path = bad
        variants.append(value)
        value = ManifestTestSupport.fullManifest()
        value.graphs[0].member.path = bad
        variants.append(value)
        value = ManifestTestSupport.fullManifest()
        value.resources[0].media?.path = bad
        variants.append(value)
        value = ManifestTestSupport.fullManifest()
        value.resources[0].bookmarks[0].path = bad
        variants.append(value)
        value = ManifestTestSupport.fullManifest()
        value.opaqueState[0].path = bad
        variants.append(value)
        for invalid in variants {
            #expect(throws: ProjectPackageError.invalidPath) { try invalid.encoded(policy: policy) }
        }
        value = ManifestTestSupport.manifest()
        value.project.member.path = "p"
        #expect(throws: ProjectPackageError.pathTooLong) {
            try value.encoded(policy: ManifestTestSupport.policy(pathBytes: 12))
        }
        _ = try value.encoded(policy: ManifestTestSupport.policy(depth: 1, pathBytes: 13))
        value.project.member.path = "a/b"
        #expect(throws: ProjectPackageError.pathTooDeep) {
            try value.encoded(policy: ManifestTestSupport.policy(depth: 1))
        }
        for path in ["a%2fb", "a\\b", "/a", "a:b", "a/.", "a\u{0}b", "cafe\u{301}"] {
            value.project.member.path = path
            #expect(throws: (any Error).self) { try value.encoded(policy: policy) }
        }
        value.project.member.path = "é/Project"
        value.opaqueState = [ProjectPackageMember(path: "é/project"), ProjectPackageMember(path: "Manifest.json")]
        _ = try value.encoded(policy: policy)
    }

    @Test func enforcesUniqueGraphIDsDigestsAndNonemptyResourceCandidates() throws {
        let policy = try ManifestTestSupport.policy()
        var value = ManifestTestSupport.fullManifest()
        var graph = value.graphs[0]
        graph.member.path = "graphs/other"
        graph.revision = try ContractRevision(1)
        value.graphs.append(graph)
        #expect(throws: ProjectPackageManifestError.duplicateGraph) { try value.encoded(policy: policy) }
        value = ManifestTestSupport.fullManifest()
        value.resources.append(ProjectPackageResource(
            contentDigest: ManifestTestSupport.digest, bookmarks: [ProjectPackageMember(path: "other")]
        ))
        #expect(throws: ProjectPackageManifestError.duplicateResource) { try value.encoded(policy: policy) }
        value.resources = [ProjectPackageResource(contentDigest: ManifestTestSupport.digest, bookmarks: [])]
        #expect(throws: ProjectPackageManifestError.emptyResource) { try value.encoded(policy: policy) }
        for digest in ["", "sha256:a", ManifestTestSupport.digest.uppercased(), ManifestTestSupport.digest + "0"] {
            value.resources = [ProjectPackageResource(
                contentDigest: digest, bookmarks: [ProjectPackageMember(path: "bookmark")]
            )]
            #expect(throws: ProjectPackageManifestError.invalidContentDigest) { try value.encoded(policy: policy) }
        }
        value.resources[0].contentDigest = ManifestTestSupport.digest
        _ = try value.encoded(policy: policy)
    }

    @Test func memberLengthsAreOptionalNonnegativeAndEntryBounded() throws {
        let policy = try ManifestTestSupport.policy(entryBytes: 1_000, manifestBytes: 1_000)
        for length in [nil, 0, 1_000] as [Int?] {
            var value = ManifestTestSupport.manifest()
            value.project.member.byteCount = length
            value.opaqueState = [ProjectPackageMember(path: "state", byteCount: length)]
            _ = try value.encoded(policy: policy)
        }
        for length in [-1, Int.min, 1_001, Int.max] {
            var value = ManifestTestSupport.manifest()
            value.project.member.byteCount = length
            let error: ProjectPackageError = length < 0 ? .negativeByteCount : .entryBytesExceeded
            #expect(throws: error) { try value.encoded(policy: policy) }
            value.project.member.byteCount = nil
            value.resources = [ProjectPackageResource(
                contentDigest: ManifestTestSupport.digest,
                bookmarks: [ProjectPackageMember(path: "bookmark", byteCount: length)]
            )]
            #expect(throws: error) { try value.encoded(policy: policy) }
        }
    }

    @Test func documentClaimsAlsoObeyCoreDocumentByteCeiling() throws {
        let ceiling = ProjectGraphLimits.documentBytes
        let policy = try ManifestTestSupport.policy(entryBytes: ceiling + 1, totalBytes: 3 * ceiling)
        var value = ManifestTestSupport.fullManifest()
        value.project.member.byteCount = ceiling
        value.graphs[0].member.byteCount = ceiling
        _ = try value.encoded(policy: policy)
        let error = ProjectGraphLimitError.exceeded(path: "$memberBytes", maximum: ceiling)
        value.project.member.byteCount = ceiling + 1
        #expect(throws: error) { try value.encoded(policy: policy) }
        value.project.member.byteCount = nil
        value.graphs[0].member.byteCount = ceiling + 1
        #expect(throws: error) { try value.encoded(policy: policy) }
        value.graphs[0].member.byteCount = nil
        value.resources[0].media?.byteCount = ceiling + 1
        _ = try value.encoded(policy: policy)
    }

    @Test func checkedSumsRejectDeclaredAndManifestInclusiveOverflow() throws {
        let policy = try ManifestTestSupport.policy(entryBytes: .max, totalBytes: .max)
        var value = ManifestTestSupport.manifest()
        value.opaqueState = [
            ProjectPackageMember(path: "a", byteCount: .max), ProjectPackageMember(path: "b", byteCount: 1)
        ]
        #expect(throws: ProjectPackageError.byteCountOverflow) { try value.encoded(policy: policy) }
        value.opaqueState.removeLast()
        #expect(throws: ProjectPackageError.byteCountOverflow) { try value.encoded(policy: policy) }
        let bytes = try ContractCoding.makeEncoder().encode(value)
        #expect(throws: ProjectPackageError.byteCountOverflow) {
            try ProjectPackageManifest.decode(from: bytes, policy: policy)
        }
        value.opaqueState = [
            ProjectPackageMember(path: "a", byteCount: 6_000), ProjectPackageMember(path: "b", byteCount: 6_000)
        ]
        #expect(throws: ProjectPackageError.totalBytesExceeded) {
            try value.encoded(policy: ManifestTestSupport.policy(entryBytes: 10_000, totalBytes: 10_000))
        }
    }

    @Test func byteArithmeticPreflightPrecedesNamespaceIndexes() throws {
        let policy = try ManifestTestSupport.policy(entryBytes: .max, totalBytes: .max)
        var value = ManifestTestSupport.manifest()
        value.project.member.path = "../invalid"
        value.opaqueState = [
            ProjectPackageMember(path: "a", byteCount: .max), ProjectPackageMember(path: "b", byteCount: 1)
        ]
        #expect(throws: ProjectPackageError.byteCountOverflow) { try value.encoded(policy: policy) }
        value.opaqueState[0].byteCount = -1
        #expect(throws: ProjectPackageError.negativeByteCount) { try value.encoded(policy: policy) }
    }

    @Test func decodeAlsoEnforcesDeclarationRefusalsNotJustEncoding() throws {
        let policy = try ManifestTestSupport.policy()
        let original = ManifestTestSupport.fullManifest()
        var variants: [(ProjectPackageManifest, any Error)] = []
        var value = original
        value.project.member.path = "manifest.json"
        variants.append((value, ProjectPackageError.duplicatePath))
        value = original
        value.opaqueState[0].path = "graphs"
        variants.append((value, ProjectPackageError.parentNotDirectory))
        value = original
        value.graphs.append(value.graphs[0])
        variants.append((value, ProjectPackageManifestError.duplicateGraph))
        value = original
        value.resources.append(value.resources[0])
        variants.append((value, ProjectPackageManifestError.duplicateResource))
        value = original
        value.resources[0].media = nil
        value.resources[0].bookmarks = []
        variants.append((value, ProjectPackageManifestError.emptyResource))
        value = original
        value.resources[0].contentDigest = "invalid"
        variants.append((value, ProjectPackageManifestError.invalidContentDigest))
        value = original
        value.resources[0].bookmarks[0].byteCount = -1
        variants.append((value, ProjectPackageError.negativeByteCount))
        value = original
        value.resources[0].media?.byteCount = 10_001
        variants.append((value, ProjectPackageError.entryBytesExceeded))
        value = original
        value.opaqueState[0].path = "../bad"
        variants.append((value, ProjectPackageError.invalidPath))
        for (invalid, expected) in variants {
            let bytes = try ContractCoding.makeEncoder().encode(invalid)
            if let expected = expected as? ProjectPackageError {
                #expect(throws: expected) {
                    try ProjectPackageManifest.decode(from: bytes, policy: policy)
                }
            } else {
                let expected = try #require(expected as? ProjectPackageManifestError)
                #expect(throws: expected) {
                    try ProjectPackageManifest.decode(from: bytes, policy: policy)
                }
            }
        }
        let bytes = try ContractCoding.makeEncoder().encode(original)
        #expect(throws: ProjectPackageError.entryLimitExceeded) {
            try ProjectPackageManifest.decode(from: bytes, policy: ManifestTestSupport.policy(entries: 11))
        }
    }
}
