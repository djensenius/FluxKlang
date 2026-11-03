#if AUDIT_CHECK_TESTS
import Foundation

extension FixtureTests {
    func roleMembershipCases() {
        roleMatrixCases()
        roleClosureCases()
        rolePBXCases()
        roleOverlapCases()
        roleConfigurationCases()
        test("qualification canonical registration entries remain invalid rather than exempt") {
            let fixture = try qualificationWorld("role-registration")
            let row = Registration(
                target: FixtureWorld.qualificationTarget, module: FixtureWorld.qualificationTarget,
                path: FixtureWorld.qualificationPaths[0], kind: "root", name: "FoundationModelActionLiveTests",
                configuration: "Debug", guardExpression: SourceVariant.guards.sorted()[0],
                requirement: "canonicalProductionAccessAudit")
            try fixture.register([row])
            try rejectRoleFixture(fixture)
        }
    }

    private func roleMatrixCases() {
        test("v2 exact matrix checks all target platform module and configuration identities") {
            let keys = ["target", "module", "platform", "configuration", "missing", "duplicate"]
            for (number, key) in keys.enumerated() {
                let fixture = try qualificationWorld("role-matrix-\(number)")
                var rows = fixture.manifest["matrix"] as? [[String: String]] ?? []
                if key == "missing" { rows.removeLast() } else if key == "duplicate" {
                    rows[5] = rows[4]
                } else { rows[4][key] = "Other" }
                fixture.manifest["matrix"] = rows
                try fixture.save()
                try rejectRoleFixture(fixture)
            }
        }
    }

    private func roleClosureCases() {
        test("v2 explicit qualification source closure cannot be expanded substituted or directory-derived") {
            let mutations = ["missing", "extra", "duplicate", "substitute", "directory", "target"]
            for (number, mutation) in mutations.enumerated() {
                let fixture = try qualificationWorld("role-source-membership-\(number)")
                var sources = fixture.manifest["sources"] as? [[String: Any]] ?? []
                var files = FixtureWorld.qualificationPaths
                switch mutation {
                case "missing": files.removeLast()
                case "extra": files.append("Sources/A.swift")
                case "duplicate": files[1] = files[0]
                case "substitute": files[2] = "Sources/A.swift"
                case "directory": sources[2]["directories"] = [FixtureWorld.qualificationTarget]
                default: sources[2]["target"] = "Other"
                }
                sources[2]["files"] = files
                fixture.manifest["sources"] = sources
                try fixture.save()
                try rejectRoleFixture(fixture)
            }
        }
    }

    private func rolePBXCases() {
        test("v2 PBX actual target set and qualification phases remain exact") {
            for (number, mutation) in ["extraTarget", "missingTarget", "missingFile", "duplicateFile", "filtered",
                                       "extraFile", "substitutedFile"].enumerated() {
                let fixture = try qualificationWorld("role-pbx-\(number)")
                switch mutation {
                case "extraTarget":
                    fixture.objects["extra"] = fixture.objects["qualification"]
                    fixture.objects["extra"]?["name"] = "ExtraUnitTests"
                    fixture.objects["project"]?["targets"] = ["ios", "mac", "qualification", "extra"]
                case "missingTarget":
                    fixture.objects.removeValue(forKey: "qualification")
                    fixture.objects["project"]?["targets"] = ["ios", "mac"]
                case "missingFile":
                    fixture.objects["qualificationSources"]?["files"] = ["qualification0", "qualification1"]
                case "duplicateFile":
                    fixture.objects["qualificationSources"]?["files"] =
                        ["qualification0", "qualification0", "qualification2"]
                case "filtered": fixture.objects["qualification0"]?["platformFilter"] = "ios"
                case "extraFile":
                    fixture.objects["qualificationSources"]?["files"] =
                        ["qualification0", "qualification1", "qualification2", "iosA"]
                default: fixture.objects["qualification2"]?["fileRef"] = "fileA"
                }
                try fixture.save()
                try rejectRoleFixture(fixture)
            }
        }
    }

    private func roleOverlapCases() {
        test("v2 rejects coherent audited overlap and shared-helper membership changes") {
            for (number, mutation) in ["iosOwner", "macOwner", "removeShared", "macShared"].enumerated() {
                let fixture = try qualificationWorld("role-overlap-\(number)")
                var sources = fixture.manifest["sources"] as? [[String: Any]] ?? []
                let index = mutation.hasPrefix("mac") ? 1 : 0
                let prefix = index == 0 ? "ios" : "mac"
                var files = sources[index]["files"] as? [String] ?? []
                var builds = fixture.objects[prefix + "Sources"]?["files"] as? [String] ?? []
                if mutation == "removeShared" {
                    files = []; builds = ["iosA"]
                } else {
                    let source = mutation == "macShared" ? 2 : 0
                    files.append(FixtureWorld.qualificationPaths[source])
                    fixture.objects["overlap"] = ["isa": "PBXBuildFile", "fileRef": "roleFile\(source)"]
                    builds.append("overlap")
                }
                sources[index]["files"] = files
                fixture.manifest["sources"] = sources
                fixture.objects[prefix + "Sources"]?["files"] = builds
                try fixture.save()
                try rejectRoleFixture(fixture)
                try require(fixture.run().diagnostics.contains {
                    $0.message.contains("audited target") || $0.message.contains("audited membership")
                }, "coherent overlap did not reach role membership validation")
            }
        }
    }

    private func roleConfigurationCases() {
        test("qualification PBX Debug and Release each enforce module SDK Swift and symbolic settings") {
            for configuration in ["Debug", "Release"] {
                for (number, settings) in [
                    ["SDKROOT": "macosx"],
                    ["SDKROOT": "iphoneos", "PRODUCT_MODULE_NAME": "Other"],
                    ["SDKROOT": "iphoneos", "SWIFT_VERSION": "5"],
                    ["SDKROOT": "iphoneos", "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "EXTRA"],
                    ["SDKROOT": "iphoneos", "OTHER_SWIFT_FLAGS": "-D EXTRA"],
                    ["SDKROOT": "iphoneos", "EXCLUDED_SOURCE_FILE_NAMES": "*"],
                    ["SDKROOT": "iphoneos", "PRODUCT_NAME": "Other"]
                ].enumerated() {
                    let fixture = try qualificationWorld("role-config-\(configuration)-\(number)")
                    fixture.objects["qualification" + configuration]?["buildSettings"] = settings
                    try fixture.save()
                    try rejectRoleFixture(fixture)
                }
            }
        }
    }
}
#endif
