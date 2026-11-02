import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

enum ManifestTestSupport {
    static let digest = "sha256:" + String(repeating: "0123456789abcdef", count: 4)
    static let otherDigest = "sha256:" + String(repeating: "a", count: 64)

    static func policy(
        entries: Int = 100, depth: Int = 8, pathBytes: Int = 256,
        entryBytes: Int = 10_000, totalBytes: Int = 100_000, manifestBytes: Int = 10_000
    ) throws -> ProjectPackageManifestPolicy {
        try ProjectPackageManifestPolicy(
            packageLimits: ProjectPackageLimits(
                maxEntries: entries, maxDepth: depth, maxPathUTF8Bytes: pathBytes,
                maxEntryBytes: entryBytes, maxTotalBytes: totalBytes
            ),
            maxManifestBytes: manifestBytes
        )
    }

    static func manifest() -> ProjectPackageManifest {
        ProjectPackageManifest(
            project: ProjectPackageProjectReference(
                id: ProjectID(validated: "prj.set"), revision: .initial,
                member: ProjectPackageMember(path: "documents/project.json")
            ),
            graphs: [], resources: [], opaqueState: []
        )
    }

    static func fullManifest() -> ProjectPackageManifest {
        var value = manifest()
        value.graphs = [ProjectPackageGraphReference(
            graph: GraphID(validated: "gph.main"), revision: .initial,
            member: ProjectPackageMember(path: "graphs/main.json", byteCount: 20)
        )]
        value.resources = [ProjectPackageResource(
            contentDigest: digest, media: ProjectPackageMember(path: "media/click.wav", byteCount: 30),
            bookmarks: [
                ProjectPackageMember(path: "references/b.bookmark", byteCount: 4),
                ProjectPackageMember(path: "references/a.bookmark", byteCount: 5)
            ]
        )]
        value.opaqueState = [ProjectPackageMember(path: "state/draft.bin", byteCount: 6)]
        return value
    }

    static func json(_ value: ProjectPackageManifest) throws -> [String: Any] {
        let data = try ContractCoding.makeEncoder().encode(value)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    static func data(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }
}

struct ProjectPackageManifestCodecTests {
    @Test func roundTripsUnknownFieldsAndExtensionsAtEveryRecordLevel() throws {
        let extras: [String: JSONValue] = ["future": .array([.null, .bool(true), .object(["n": .int(42)])])]
        let bag: [String: JSONValue] = ["vendor": .string("preserved")]
        var value = ManifestTestSupport.fullManifest()
        value.unknownFields = extras
        value.extensions = bag
        value.project.unknownFields = extras
        value.project.extensions = bag
        value.project.member.unknownFields = extras
        value.project.member.extensions = bag
        value.graphs[0].unknownFields = extras
        value.graphs[0].extensions = bag
        value.graphs[0].member.unknownFields = extras
        value.graphs[0].member.extensions = bag
        value.resources[0].unknownFields = extras
        value.resources[0].extensions = bag
        value.resources[0].media?.unknownFields = extras
        value.resources[0].media?.extensions = bag
        for index in value.resources[0].bookmarks.indices {
            value.resources[0].bookmarks[index].unknownFields = extras
            value.resources[0].bookmarks[index].extensions = bag
        }
        value.opaqueState[0].unknownFields = extras
        value.opaqueState[0].extensions = bag
        let policy = try ManifestTestSupport.policy()
        let decoded = try ProjectPackageManifest.decode(from: value.encoded(policy: policy), policy: policy)
        #expect(decoded == value)
        #expect(decoded.resources[0].bookmarks.map(\.path) == ["references/b.bookmark", "references/a.bookmark"])
        #expect(ProjectPackageManifest.currentVersion == ContractVersion(
            contract: "fluxklang.project-package", version: 1
        ))
        #expect(ProjectPackageManifest.manifestMemberPath == "manifest.json")
    }

    @Test func requiredArraysRejectAbsentAndNullButAllowEmpty() throws {
        let policy = try ManifestTestSupport.policy()
        let base = try ManifestTestSupport.json(ManifestTestSupport.manifest())
        for key in ["graphs", "resources", "opaqueState"] {
            var missing = base
            missing.removeValue(forKey: key)
            #expect(throws: (any Error).self) {
                try ProjectPackageManifest.decode(from: ManifestTestSupport.data(missing), policy: policy)
            }
            missing[key] = NSNull()
            #expect(throws: (any Error).self) {
                try ProjectPackageManifest.decode(from: ManifestTestSupport.data(missing), policy: policy)
            }
        }
        for bookmarks in [nil, NSNull()] as [Any?] {
            var object = base
            var resource: [String: Any] = [
                "contentDigest": ManifestTestSupport.digest, "media": ["path": "media/a"]
            ]
            resource["bookmarks"] = bookmarks
            object["resources"] = [resource]
            #expect(throws: (any Error).self) {
                try ProjectPackageManifest.decode(from: ManifestTestSupport.data(object), policy: policy)
            }
        }
        #expect(try ProjectPackageManifest.decode(from: ManifestTestSupport.data(base), policy: policy)
            == ManifestTestSupport.manifest())
        var embedded = ManifestTestSupport.manifest()
        embedded.resources = [ProjectPackageResource(
            contentDigest: ManifestTestSupport.digest, media: ProjectPackageMember(path: "media/a"), bookmarks: []
        )]
        #expect(try ProjectPackageManifest.decode(from: embedded.encoded(policy: policy), policy: policy) == embedded)
    }

    @Test func refusesMalformedAndUnsupportedEnvelopes() throws {
        let policy = try ManifestTestSupport.policy()
        let base = try ManifestTestSupport.json(ManifestTestSupport.manifest())
        for version in [nil, NSNull(), 0, -1, 2, "1", 1.5] as [Any?] {
            var object = base
            object["version"] = version
            #expect(throws: (any Error).self) {
                try ProjectPackageManifest.decode(from: ManifestTestSupport.data(object), policy: policy)
            }
        }
        for contract in [nil, NSNull(), "fluxklang.project", 1] as [Any?] {
            var object = base
            object["contract"] = contract
            #expect(throws: (any Error).self) {
                try ProjectPackageManifest.decode(from: ManifestTestSupport.data(object), policy: policy)
            }
        }
        for text in ["{", "[]", "null", #"{"contract":"fluxklang.project-package","version":1}"#] {
            #expect(throws: (any Error).self) {
                try ProjectPackageManifest.decode(from: Data(text.utf8), policy: policy)
            }
        }
    }

    @Test func requiredFeaturesCannotBecomeOptionalUnknownData() throws {
        let policy = try ManifestTestSupport.policy()
        var object = try ManifestTestSupport.json(ManifestTestSupport.manifest())
        object["requiredFeatures"] = ["future"]
        #expect(throws: ProjectGraphVersionError.unsupportedRequiredFeatures(["future"])) {
            try ProjectPackageManifest.decode(from: ManifestTestSupport.data(object), policy: policy)
        }
        for malformed in ["future", [1], true] as [Any] {
            object["requiredFeatures"] = malformed
            #expect(throws: (any Error).self) {
                try ProjectPackageManifest.decode(from: ManifestTestSupport.data(object), policy: policy)
            }
        }
        for empty in [[], NSNull()] as [Any] {
            object["requiredFeatures"] = empty
            let decoded = try ProjectPackageManifest.decode(from: ManifestTestSupport.data(object), policy: policy)
            #expect(decoded.unknownFields["requiredFeatures"] == nil)
        }
        var value = ManifestTestSupport.manifest()
        value.unknownFields = [
            "requiredFeatures": .array([.string("future")]), "version": .int(999),
            "contract": .string("other"), "graphs": .null
        ]
        let decoded = try ProjectPackageManifest.decode(from: value.encoded(policy: policy), policy: policy)
        #expect(decoded == ManifestTestSupport.manifest())
    }

    @Test func rejectsDuplicateJSONMembersIncludingNestedAndCanonicalEquivalentNames() throws {
        let policy = try ManifestTestSupport.policy()
        let data = try ManifestTestSupport.fullManifest().encoded(policy: policy)
        let text = try #require(String(data: data, encoding: .utf8))
        let duplicates = [
            text.replacingOccurrences(of: #""version":1"#, with: #""version":1,"version":1"#),
            text.replacingOccurrences(of: #""path":"#, with: #""path":"unused","path":"#),
            text.replacingOccurrences(of: #""bookmarks":["#, with: #""bookmarks":[],"bookmarks":["#),
            text.replacingOccurrences(of: #""revision":0"#, with: #""revision":0,"revision":0"#),
            text.replacingOccurrences(of: #""version":1"#, with: #""version":1,"é":1,"e\u0301":2"#)
        ]
        for duplicate in duplicates {
            #expect(throws: DecodingError.self) {
                try ProjectPackageManifest.decode(from: Data(duplicate.utf8), policy: policy)
            }
        }
    }

    @Test func inputByteCeilingRunsBeforeJSONDecode() throws {
        let policy = try ManifestTestSupport.policy(manifestBytes: 2)
        #expect(throws: ProjectPackageManifestError.manifestBytesExceeded) {
            try ProjectPackageManifest.decode(from: Data("{{{".utf8), policy: policy)
        }
        #expect(throws: DecodingError.self) {
            try ProjectPackageManifest.decode(from: Data("{{".utf8), policy: policy)
        }
        let value = ManifestTestSupport.manifest()
        let bytes = try value.encoded(policy: ManifestTestSupport.policy())
        let exact = try ManifestTestSupport.policy(manifestBytes: bytes.count)
        #expect(try ProjectPackageManifest.decode(from: bytes, policy: exact) == value)
        #expect(try value.encoded(policy: exact) == bytes)
        let short = try ManifestTestSupport.policy(manifestBytes: bytes.count - 1)
        #expect(throws: ProjectPackageManifestError.manifestBytesExceeded) {
            try ProjectPackageManifest.decode(from: bytes, policy: short)
        }
        #expect(throws: ProjectPackageManifestError.manifestBytesExceeded) { try value.encoded(policy: short) }
    }

    @Test func totalsUseOriginalInputAndActualOutputNotReencoding() throws {
        var value = ManifestTestSupport.manifest()
        value.project.member.byteCount = 10
        let canonical = try value.encoded(policy: ManifestTestSupport.policy())
        let padded = Data(" \n ".utf8) + canonical + Data("\n".utf8)
        let exact = try ManifestTestSupport.policy(
            entryBytes: padded.count, totalBytes: padded.count + 10, manifestBytes: padded.count
        )
        #expect(try ProjectPackageManifest.decode(from: padded, policy: exact) == value)
        let short = try ManifestTestSupport.policy(
            entryBytes: padded.count, totalBytes: padded.count + 9, manifestBytes: padded.count
        )
        #expect(throws: ProjectPackageError.totalBytesExceeded) {
            try ProjectPackageManifest.decode(from: padded, policy: short)
        }
        #expect(try value.encoded(policy: short) == canonical)
        let outputShort = try ManifestTestSupport.policy(
            entryBytes: canonical.count, totalBytes: canonical.count + 9, manifestBytes: canonical.count
        )
        #expect(throws: ProjectPackageError.totalBytesExceeded) { try value.encoded(policy: outputShort) }
        let outputExact = try ManifestTestSupport.policy(
            entryBytes: canonical.count, totalBytes: canonical.count + 10, manifestBytes: canonical.count
        )
        #expect(try value.encoded(policy: outputExact) == canonical)
    }

    @Test func requiredRecordFieldsAndScalarTypesRejectMalformedClaims() throws {
        let policy = try ManifestTestSupport.policy()
        let base = try ManifestTestSupport.json(ManifestTestSupport.fullManifest())
        var records: [[String: Any]] = []
        for key in ["id", "revision", "member"] {
            var object = base
            var project = try #require(base["project"] as? [String: Any])
            project.removeValue(forKey: key)
            object["project"] = project
            records.append(object)
            project[key] = NSNull()
            object["project"] = project
            records.append(object)
        }
        for key in ["graph", "revision", "member"] {
            var object = base
            var graph = try #require((base["graphs"] as? [[String: Any]])?.first)
            graph.removeValue(forKey: key)
            object["graphs"] = [graph]
            records.append(object)
            graph[key] = NSNull()
            object["graphs"] = [graph]
            records.append(object)
        }
        for member in [[:], ["path": NSNull()], ["path": 1], ["path": "p", "byteCount": "1"]] as [[String: Any]] {
            var object = base
            object["opaqueState"] = [member]
            records.append(object)
        }
        for resource in [["bookmarks": []], ["contentDigest": NSNull(), "bookmarks": []]] as [[String: Any]] {
            var object = base
            object["resources"] = [resource]
            records.append(object)
        }
        for object in records {
            #expect(throws: DecodingError.self) {
                try ProjectPackageManifest.decode(from: ManifestTestSupport.data(object), policy: policy)
            }
        }
    }
}
