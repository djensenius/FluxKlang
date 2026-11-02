import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

struct ProjectPackageManifestReferenceTests {
    private func project(_ manifest: ProjectPackageManifest) -> ProjectDocument {
        ProjectDocument(
            id: manifest.project.id, revision: manifest.project.revision, name: "Set",
            graphs: manifest.graphs.map { ProjectGraphReference(graph: $0.graph, revision: $0.revision) }
        )
    }

    private func graphs(_ manifest: ProjectPackageManifest) -> [(path: String, document: GraphDocument)] {
        manifest.graphs.map { ($0.member.path, GraphDocument(id: $0.graph, revision: $0.revision)) }
    }

    private func asset(_ id: String, digest: String = ManifestTestSupport.digest, bytes: Int?) throws -> ProjectAsset {
        ProjectAsset(id: try AssetID(id), label: id, media: .document, contentDigest: digest, byteCount: bytes)
    }

    private func check(
        _ manifest: ProjectPackageManifest, project: ProjectDocument,
        policy: ProjectPackageManifestPolicy? = nil
    ) throws {
        try manifest.validateReferences(
            project: project, projectPath: manifest.project.member.path, graphs: graphs(manifest),
            policy: policy ?? ManifestTestSupport.policy()
        )
    }

    @Test func acceptsReorderedExactMappingsAndPreservesReviewRequiredIntent() throws {
        var manifest = ManifestTestSupport.fullManifest()
        manifest.graphs.append(ProjectPackageGraphReference(
            graph: GraphID(validated: "gph.second"), revision: try ContractRevision(43),
            member: ProjectPackageMember(path: "explicit/not-an-id.json")
        ))
        var document = project(manifest)
        document.graphs.reverse()
        var supplied = graphs(manifest)
        supplied[0].document.requiresReview = true
        supplied.reverse()
        let before = manifest
        try manifest.validateReferences(
            project: document, projectPath: manifest.project.member.path,
            graphs: supplied, policy: ManifestTestSupport.policy()
        )
        #expect(manifest == before)
        #expect(supplied[1].document.requiresReview)
        #expect(document.validationErrors(graphs: supplied.map(\.document)).contains(
            .graph(manifest.graphs[0].graph, .reviewRequired)
        ))
    }

    @Test func projectIdentityRevisionAndExplicitPathMustAgree() throws {
        let manifest = ManifestTestSupport.manifest()
        let policy = try ManifestTestSupport.policy()
        var document = project(manifest)
        document.id = ProjectID(validated: "prj.other")
        #expect(throws: ProjectPackageManifestError.projectMismatch) { try check(manifest, project: document) }
        document = project(manifest)
        document.revision = try ContractRevision(1)
        #expect(throws: ProjectPackageManifestError.projectMismatch) { try check(manifest, project: document) }
        for path in ["project.json", "Documents/project.json", "prj.set"] {
            #expect(throws: ProjectPackageManifestError.projectMismatch) {
                try manifest.validateReferences(
                    project: project(manifest), projectPath: path, graphs: [], policy: policy
                )
            }
        }
    }

    @Test func rejectsMissingExtraDuplicateAndMismatchedProjectGraphMappings() throws {
        var manifest = ManifestTestSupport.fullManifest()
        manifest.graphs.append(ProjectPackageGraphReference(
            graph: GraphID(validated: "gph.second"), revision: .initial,
            member: ProjectPackageMember(path: "graphs/second")
        ))
        let original = project(manifest)
        var variants: [ProjectDocument] = []
        var document = original
        document.graphs.removeLast()
        variants.append(document)
        document = original
        document.graphs.append(ProjectGraphReference(graph: GraphID(validated: "gph.extra"), revision: .initial))
        variants.append(document)
        document = original
        document.graphs[1] = document.graphs[0]
        variants.append(document)
        document = original
        document.graphs[0].revision = try ContractRevision(1)
        variants.append(document)
        document = original
        document.graphs[0].graph = GraphID(validated: "gph.other")
        variants.append(document)
        for invalid in variants {
            #expect(throws: ProjectPackageManifestError.graphMismatch) { try check(manifest, project: invalid) }
        }
    }

    @Test func rejectsMissingExtraDuplicateAndMismatchedSuppliedGraphs() throws {
        var manifest = ManifestTestSupport.fullManifest()
        manifest.graphs.append(ProjectPackageGraphReference(
            graph: GraphID(validated: "gph.second"), revision: .initial,
            member: ProjectPackageMember(path: "graphs/second")
        ))
        let original = graphs(manifest)
        var variants: [[(path: String, document: GraphDocument)]] = []
        variants.append(Array(original.dropLast()))
        variants.append(original + [("graphs/extra", GraphDocument(id: GraphID(validated: "gph.extra")))])
        variants.append([original[0], original[0]])
        var supplied = original
        supplied[0].document.revision = try ContractRevision(1)
        variants.append(supplied)
        supplied = original
        supplied[0].document.id = GraphID(validated: "gph.other")
        variants.append(supplied)
        supplied = original
        supplied[0].path = "Graphs/main.json"
        variants.append(supplied)
        supplied = original
        supplied[0].path = supplied[1].path
        variants.append(supplied)
        supplied = original
        supplied[1].document.id = supplied[0].document.id
        supplied[1].document.revision = try ContractRevision(1)
        variants.append(supplied)
        for invalid in variants {
            #expect(throws: ProjectPackageManifestError.graphMismatch) {
                try manifest.validateReferences(
                    project: project(manifest), projectPath: manifest.project.member.path,
                    graphs: invalid, policy: ManifestTestSupport.policy()
                )
            }
        }
    }

    @Test func checksManifestDeclarationsAndCallerCollectionsBeforeReferenceIndexes() throws {
        var manifest = ManifestTestSupport.fullManifest()
        manifest.graphs.append(manifest.graphs[0])
        #expect(throws: ProjectPackageManifestError.duplicateGraph) { try check(manifest, project: project(manifest)) }
        manifest = ManifestTestSupport.fullManifest()
        manifest.resources.append(manifest.resources[0])
        #expect(throws: ProjectPackageManifestError.duplicateResource) {
            try check(manifest, project: project(manifest))
        }
        manifest = ManifestTestSupport.manifest()
        var document = project(manifest)
        document.assets = Array(
            repeating: try asset("ast.same", bytes: nil), count: ProjectGraphLimits.projectRecords + 1
        )
        let maximum = ProjectGraphLimits.projectRecords
        #expect(throws: ProjectGraphLimitError.exceeded(path: "$.assets", maximum: maximum)) {
            try check(manifest, project: document)
        }
        let graph = GraphDocument(id: GraphID(validated: "gph.same"))
        #expect(throws: ProjectGraphLimitError.exceeded(path: "$supplied", maximum: maximum)) {
            try manifest.validateReferences(
                project: project(manifest), projectPath: manifest.project.member.path,
                graphs: Array(repeating: ("same", graph), count: ProjectGraphLimits.projectRecords + 1),
                policy: ManifestTestSupport.policy()
            )
        }
    }

    @Test func sharedDigestAssetsAcceptNilAndEqualLengthsInEitherOrder() throws {
        let manifest = ManifestTestSupport.fullManifest()
        for lengths in [[nil, 30, 30], [30, nil, 30], [30, 30, nil], [nil, nil, nil]] as [[Int?]] {
            var document = project(manifest)
            document.assets = try lengths.enumerated().map { try asset("ast.\($0.offset)", bytes: $0.element) }
            try check(manifest, project: document)
        }
        var unknownMediaLength = manifest
        unknownMediaLength.resources[0].media?.byteCount = nil
        var document = project(manifest)
        document.assets = [try asset("ast.a", bytes: 42)]
        try check(unknownMediaLength, project: document)
    }

    @Test func rejectsConflictingSharedDigestAndEmbeddedLengths() throws {
        let manifest = ManifestTestSupport.fullManifest()
        for lengths in [[30, 31], [31, 30], [nil, 31], [31, nil]] as [[Int?]] {
            var document = project(manifest)
            document.assets = try lengths.enumerated().map { try asset("ast.\($0.offset)", bytes: $0.element) }
            #expect(throws: ProjectPackageManifestError.conflictingAssetByteCount) {
                try check(manifest, project: document)
            }
        }
        var unknown = manifest
        unknown.resources[0].media?.byteCount = nil
        var document = project(manifest)
        document.assets = [try asset("ast.a", bytes: 30), try asset("ast.b", bytes: nil), try asset("ast.c", bytes: 31)]
        #expect(throws: ProjectPackageManifestError.conflictingAssetByteCount) { try check(unknown, project: document) }
        unknown.resources = []
        #expect(throws: ProjectPackageManifestError.conflictingAssetByteCount) { try check(unknown, project: document) }
    }

    @Test func rejectsInvalidAssetDigestsAndNegativeLengthsEvenWithoutResources() throws {
        var manifest = ManifestTestSupport.manifest()
        var document = project(manifest)
        for digest in ["", "sha256:xyz", ManifestTestSupport.digest.uppercased(), ManifestTestSupport.digest + "a"] {
            document.assets = [try asset("ast.bad", digest: digest, bytes: nil)]
            #expect(throws: ProjectPackageManifestError.invalidContentDigest) { try check(manifest, project: document) }
        }
        for bytes in [-1, Int.min] {
            document.assets = [try asset("ast.bad", bytes: bytes)]
            #expect(throws: ProjectPackageError.negativeByteCount) { try check(manifest, project: document) }
        }
        manifest.resources = [ProjectPackageResource(
            contentDigest: ManifestTestSupport.digest, bookmarks: [ProjectPackageMember(path: "bookmark")]
        )]
        #expect(throws: ProjectPackageError.negativeByteCount) { try check(manifest, project: document) }
    }

    @Test func externalContentLengthIsNeitherBookmarkLengthNorPackageConsumption() throws {
        var manifest = ManifestTestSupport.manifest()
        manifest.resources = [ProjectPackageResource(
            contentDigest: ManifestTestSupport.digest,
            bookmarks: [ProjectPackageMember(path: "a", byteCount: 3), ProjectPackageMember(path: "b", byteCount: 5)]
        )]
        var document = project(manifest)
        document.assets = [try asset("ast.large", bytes: .max), try asset("ast.shared", bytes: .max)]
        let policy = try ManifestTestSupport.policy(entryBytes: 1_000, totalBytes: 1_000, manifestBytes: 1_000)
        try check(manifest, project: document, policy: policy)
        let bytes = try manifest.encoded(policy: policy)
        #expect(try ProjectPackageManifest.decode(from: bytes, policy: policy) == manifest)
        manifest.resources[0].media = ProjectPackageMember(path: "media", byteCount: 8)
        #expect(throws: ProjectPackageManifestError.conflictingAssetByteCount) {
            try check(manifest, project: document, policy: policy)
        }
    }

    @Test func retainsUnreferencedResourcesAndUnresolvedAssetsWithoutInventingUsability() throws {
        let manifest = ManifestTestSupport.fullManifest()
        var document = project(manifest)
        document.assets = [try asset("ast.unresolved", digest: ManifestTestSupport.otherDigest, bytes: .max)]
        let before = document
        try check(manifest, project: document)
        #expect(document == before)
        #expect(manifest.resources.count == 1)
        #expect(!manifest.resources.contains { $0.contentDigest == document.assets[0].contentDigest })
    }

    @Test func referenceCheckDoesNotReconstructManifestOrDocumentByteLengths() throws {
        var manifest = ManifestTestSupport.manifest()
        manifest.project.member.byteCount = 0
        manifest.unknownFields = ["future": .string(String(repeating: "x", count: 100))]
        let policy = try ManifestTestSupport.policy(entryBytes: 1, totalBytes: 1, manifestBytes: 1)
        try check(manifest, project: project(manifest), policy: policy)
        #expect(throws: ProjectPackageManifestError.manifestBytesExceeded) { try manifest.encoded(policy: policy) }
        let maximum = try ManifestTestSupport.policy(entryBytes: .max, totalBytes: .max)
        manifest.opaqueState = [ProjectPackageMember(path: "opaque", byteCount: .max)]
        try check(manifest, project: project(manifest), policy: maximum)
        #expect(throws: ProjectPackageError.byteCountOverflow) { try manifest.encoded(policy: maximum) }
    }

    @Test func suppliedPathsMustObeyP1EvenWhenCanonicallyEquivalent() throws {
        var manifest = ManifestTestSupport.fullManifest()
        manifest.project.member.path = "café/project"
        manifest.graphs[0].member.path = "café/graph"
        let policy = try ManifestTestSupport.policy()
        let decomposed = "cafe\u{301}/project"
        #expect(decomposed == manifest.project.member.path)
        #expect(throws: ProjectPackageError.nonNFCPath) {
            try manifest.validateReferences(
                project: project(manifest), projectPath: decomposed, graphs: graphs(manifest), policy: policy
            )
        }
        #expect(throws: ProjectPackageError.invalidPath) {
            try manifest.validateReferences(
                project: project(manifest), projectPath: "../project", graphs: graphs(manifest), policy: policy
            )
        }
        var supplied = graphs(manifest)
        supplied[0].path = "cafe\u{301}/graph"
        #expect(throws: ProjectPackageError.nonNFCPath) {
            try manifest.validateReferences(
                project: project(manifest), projectPath: manifest.project.member.path, graphs: supplied, policy: policy
            )
        }
    }
}
