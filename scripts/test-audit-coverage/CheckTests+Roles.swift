#if AUDIT_CHECK_TESTS
import Foundation

extension FixtureWorld {
    static let qualificationTarget = "FluxKlangAppleQualificationTests"
    static let qualificationPaths = [
        "FluxKlangAppleQualificationTests/FoundationModelActionInterpreterLiveTests.swift",
        "FluxKlangAppleQualificationTests/AssistantRoutingChatTests.swift",
        "FluxKlangTests/AssistantRoutingFixture.swift"
    ]
    static let qualificationSources = [
        """
        import Foundation
        import Testing
        struct FoundationModelActionLiveTests {
            @Test(.enabled(if: ProcessInfo.processInfo.environment["FLUXKLANG_RUN_APPLE_MODEL_TESTS"] == "1"))
            func ownerRequestsUseAppleAndHostileLiveMetadataCannotAffectInterpretation() async throws {
                // #if is not a directive in a comment or string.
                let text = "#if DEBUG"
                #expect(!text.isEmpty)
            }
        }
        """,
        """
        import Foundation
        import Testing
        @MainActor
        struct AssistantRoutingChatTests {
            @Test(.enabled(if: ProcessInfo.processInfo.environment["FLUXKLANG_QUALIFY_APPLE_ROUTING"] == "1"))
            func optInNativeOwnerAndPriorMonoQualification() async throws {
                #expect(true)
            }
        }
        """,
        "struct AssistantRoutingFixture { let text = \"#if DEBUG\" }"
    ]

    func addQualification() throws {
        let target = Self.qualificationTarget
        manifest["schemaVersion"] = 2
        manifest["targetRoles"] = [
            ["target": "FluxKlangTests", "role": "audited"],
            ["target": "FluxKlangMacTests", "role": "audited"],
            ["target": target, "role": "appleQualification"]
        ]
        manifest["qualification"] = ["target": target, "tests": [
            ["path": Self.qualificationPaths[0], "owner": "FoundationModelActionLiveTests",
             "signature": "ownerRequestsUseAppleAndHostileLiveMetadataCannotAffectInterpretation ( ) async throws"],
            ["path": Self.qualificationPaths[1], "owner": "AssistantRoutingChatTests",
             "signature": "optInNativeOwnerAndPriorMonoQualification ( ) async throws"]
        ]]
        var matrix = manifest["matrix"] as? [[String: String]] ?? []
        matrix += ["Debug", "Release"].map {
            ["target": target, "module": target, "platform": "iOS", "configuration": $0]
        }
        manifest["matrix"] = matrix
        var sources = manifest["sources"] as? [[String: Any]] ?? []
        sources[0]["files"] = [Self.qualificationPaths[2]]
        sources.append(["target": target, "directories": [], "files": Self.qualificationPaths])
        manifest["sources"] = sources
        objects["project"]?["targets"] = ["ios", "mac", "qualification"]
        objects["qualification"] = [
            "isa": "PBXNativeTarget", "name": target,
            "productType": "com.apple.product-type.bundle.unit-test", "buildRules": [],
            "buildConfigurationList": "qualificationConfigs", "buildPhases": ["qualificationSources"]
        ]
        objects["qualificationConfigs"] = [
            "isa": "XCConfigurationList", "buildConfigurations": ["qualificationDebug", "qualificationRelease"]
        ]
        for configuration in ["Debug", "Release"] {
            objects["qualification" + configuration] = objects["ios" + configuration]
        }
        objects["qualificationSources"] = [
            "isa": "PBXSourcesBuildPhase", "buildActionMask": "2147483647",
            "runOnlyForDeploymentPostprocessing": "0", "files": ["qualification0", "qualification1", "qualification2"]
        ]
        for (number, path) in Self.qualificationPaths.enumerated() {
            try write(path, Self.qualificationSources[number])
            addRoleFile(path, reference: "roleFile\(number)")
            objects["qualification\(number)"] = ["isa": "PBXBuildFile", "fileRef": "roleFile\(number)"]
        }
        objects["iosFixture"] = ["isa": "PBXBuildFile", "fileRef": "roleFile2"]
        objects["iosSources"]?["files"] = ["iosA", "iosFixture"]
        try save()
    }

    func addRoleFile(_ path: String, reference: String) {
        objects[reference] = ["isa": "PBXFileReference", "path": path,
                              "sourceTree": "SOURCE_ROOT", "lastKnownFileType": "sourcecode.swift"]
        var children = objects["main"]?["children"] as? [String] ?? []
        children.append(reference)
        objects["main"]?["children"] = children
    }
}

extension FixtureTests {
    func qualificationWorld(_ name: String, annotated: Bool = true) throws -> FixtureWorld {
        let fixture = try world(name, annotated: annotated)
        try fixture.addQualification()
        return fixture
    }

    func rejectRoleFixture(_ fixture: FixtureWorld, category: String? = nil) throws {
        for mode in ["inventory", "enforce"] {
            let report = fixture.run(mode: mode)
            try report.encoded().write(to: fixture.root.appendingPathComponent(mode + "-result.json"))
            try require(report.exitCode == 2 && !report.analysisComplete && !report.enforcementSatisfied,
                        "role mutation was not structural in \(mode): \(report.diagnostics)")
            if let category {
                try require(report.diagnostics.contains { $0.category == category },
                            "missing \(category) diagnostic: \(report.diagnostics)")
            }
            if report.schemaVersion == 2 {
                try require(report.qualification?.contractSatisfied == false, "failed contract reported satisfied")
            }
        }
    }

    func roleSchemaCases() {
        test("v2 strict role and nested qualification schema rejects mutations in both modes") {
            let mutations: [(inout [String: Any]) -> Void] = [
                { $0["unknown"] = true }, { $0["purpose"] = "runtime" }, { $0["schemaVersion"] = 3 },
                { $0["targetRoles"] = NSNull() }, { $0.removeValue(forKey: "targetRoles") },
                { $0["qualification"] = NSNull() }, { $0.removeValue(forKey: "qualification") },
                { $0["registrations"] = NSNull() },
                { $0["targetRoles"] = [["target": "FluxKlangTests", "role": "exempt"]] },
                { object in
                    var rows = object["targetRoles"] as? [[String: String]] ?? []
                    rows.append(rows[0]); object["targetRoles"] = rows
                },
                { object in
                    var rows = object["targetRoles"] as? [[String: String]] ?? []
                    rows[0]["role"] = "appleQualification"; object["targetRoles"] = rows
                },
                { object in
                    var rows = object["targetRoles"] as? [[String: String]] ?? []
                    rows[0]["other"] = "ignored"; object["targetRoles"] = rows
                },
                { $0["qualification"] = ["target": "Other", "tests": []] },
                { object in
                    var qualification = object["qualification"] as? [String: Any] ?? [:]
                    qualification["extra"] = true; object["qualification"] = qualification
                }
            ]
            for (number, mutate) in mutations.enumerated() {
                let fixture = try qualificationWorld("role-schema-\(number)")
                mutate(&fixture.manifest)
                try fixture.save()
                try rejectRoleFixture(fixture, category: "input")
            }
        }
        test("qualification identities reject null missing duplicate expanded and altered transcription") {
            for (number, mutation) in ["null", "missing", "duplicate", "extra", "path", "owner", "signature",
                                       "unknown"].enumerated() {
                let fixture = try qualificationWorld("role-identity-\(number)")
                var qualification = fixture.manifest["qualification"] as? [String: Any] ?? [:]
                var identities = qualification["tests"] as? [[String: String]] ?? []
                switch mutation {
                case "null": qualification["tests"] = NSNull()
                case "missing": qualification.removeValue(forKey: "tests")
                case "duplicate": identities[1] = identities[0]; qualification["tests"] = identities
                case "extra": identities.append(identities[0]); qualification["tests"] = identities
                default: identities[0][mutation] = "Changed"; qualification["tests"] = identities
                }
                fixture.manifest["qualification"] = qualification
                try fixture.save()
                try rejectRoleFixture(fixture)
            }
        }
        test("v2 escaped duplicate role and identity keys are not discarded by JSON decoding") {
            for (number, pair) in [
                ("\"role\" : \"audited\"", "\"role\": \"audited\", \"r\\u006fle\": \"audited\""),
                ("\"owner\" : \"FoundationModelActionLiveTests\"",
                 "\"owner\": \"FoundationModelActionLiveTests\", \"owner\": \"FoundationModelActionLiveTests\"")
            ].enumerated() {
                let fixture = try qualificationWorld("role-duplicate-key-\(number)")
                let text = String(data: try FixtureWorld.json(fixture.manifest), encoding: .utf8) ?? ""
                let changed = text.replacingOccurrences(of: pair.0, with: pair.1)
                try require(changed != text, "duplicate-key mutation did not apply")
                try fixture.write("fixture.json", changed)
                try rejectRoleFixture(fixture, category: "input")
            }
        }
        test("v1 rejects role keys and coherent downgrade cannot hide the actual third PBX unit target") {
            let extra = try world("v1-role-key")
            extra.manifest["targetRoles"] = []
            try extra.save()
            try rejectRoleFixture(extra)
            let fixture = try qualificationWorld("role-downgrade")
            fixture.manifest["schemaVersion"] = 1
            fixture.manifest.removeValue(forKey: "targetRoles")
            fixture.manifest.removeValue(forKey: "qualification")
            fixture.manifest["matrix"] = Array((fixture.manifest["matrix"] as? [[String: String]] ?? []).prefix(4))
            fixture.manifest["sources"] = Array((fixture.manifest["sources"] as? [[String: Any]] ?? []).prefix(2))
            try fixture.save()
            try rejectRoleFixture(fixture, category: "input")
            try require(fixture.run().diagnostics.contains { $0.message.contains("unit-target set") },
                        "coherent downgrade failed before actual PBX target-set gate")
        }
    }
}
#endif
