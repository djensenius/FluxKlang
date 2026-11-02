#if AUDIT_CHECK_TESTS
import Foundation

// Standalone headless fixtures. No Testing runtime, target imports, SDK discovery,
// application execution, repository mutation, or production-manifest refresh.
final class FixtureTests {
    let scratch: URL
    let u1Root: URL
    var passed = 0
    var failed = 0

    init(scratch: URL, u1Root: URL) {
        self.scratch = scratch
        self.u1Root = u1Root
    }

    func test(_ name: String, _ body: () throws -> Void) {
        do {
            try body()
            passed += 1
            print("PASS \(name)")
        } catch {
            failed += 1
            print("FAIL \(name): \(error)")
        }
    }

    func rejects(_ body: () throws -> Void, containing text: String = "") throws {
        do { try body() } catch {
            try require(text.isEmpty || String(describing: error).contains(text),
                        "wrong rejection: \(error); expected \(text)")
            return
        }
        throw AuditFailure("expected rejection containing: \(text)")
    }

    func world(_ name: String, annotated: Bool = false) throws -> FixtureWorld {
        try FixtureWorld(root: scratch.appendingPathComponent(name), annotated: annotated)
    }

    func inputCases() {
        test("strict JSON duplicate and escaped keys at every nesting level") {
            for text in [#"{"a":1,"a":2}"#, #"{"a":1,"\u0061":2}"#, #"{"x":[{"b":0,"b":1}]}"#] {
                try rejects({
                    var check = JSONKeyCheck(bytes: Array(text.utf8))
                    try check.validate()
                }, containing: "duplicate")
            }
            var valid = JSONKeyCheck(bytes: Array(#"{"a":[{"b":"\"a\""},{"b":0}],"s":"a"}"#.utf8))
            try valid.validate()
        }
        test("malformed JSON and trailing input") {
            for text in ["", "{\"x\":}", "{\"x\":1,}", "[1,]", "{}{}", "{\"x\":\"\\q\"}"] {
                try rejects {
                    var check = JSONKeyCheck(bytes: Array(text.utf8))
                    try check.validate()
                }
            }
        }
        test("manifest unknown fields version purpose and nested schema") {
            let fixture = try world("schema")
            for (key, value) in [("schemaVersion", 2 as Any), ("purpose", "runtime"), ("baseline", true)] {
                var object = fixture.manifest
                object[key] = value
                try rejects { _ = try AuditManifest.load(FixtureWorld.json(object)) }
            }
            var object = fixture.manifest
            object["specification"] = ["path": "project.yml", "sha256": digest(Data()), "review": "AUTO"]
            try rejects { _ = try AuditManifest.load(FixtureWorld.json(object)) }
            object = fixture.manifest
            object["sources"] = [["target": "FluxKlangTests", "directories": ["Sources"], "files": [], "exclude": "*"]]
            try rejects { _ = try AuditManifest.load(FixtureWorld.json(object)) }
        }
        test("manifest matrix and duplicate source paths") {
            let fixture = try world("matrix")
            var object = fixture.manifest
            object["matrix"] = Array((object["matrix"] as? [[String: Any]] ?? []).prefix(3))
            try rejects { _ = try AuditManifest.load(FixtureWorld.json(object)) }
            object = fixture.manifest
            object["sources"] = [
                ["target": "FluxKlangTests", "directories": ["Sources", "Sources"], "files": []],
                ["target": "FluxKlangMacTests", "directories": ["Mac"], "files": ["Sources/A.swift"]]
            ]
            try rejects { _ = try AuditManifest.load(FixtureWorld.json(object)) }
        }
        test("normalized paths reject escapes substitutions glob and absolute paths") {
            for path in ["../x", "/x", "a/../b", "a//b", "./x", "a\\b", "$(ROOT)/x", "a/*.swift", ""] {
                try rejects { try SafeInputs.validatePath(path) }
            }
        }
        test("missing file and case-mismatched path") {
            let fixture = try world("paths")
            let inputs = try SafeInputs(root: fixture.root.path)
            try rejects { _ = try inputs.read("Sources/Missing.swift") }
            try rejects { _ = try inputs.read("sources/A.swift") }
            try rejects({ try SafeInputs.validateNames(["A.swift", "a.swift"], at: "fixture") },
                        containing: "case ambiguity")
        }
        test("symlink file and directory rejected") {
            let fixture = try world("symlinks")
            try FileManager.default.createSymbolicLink(atPath: fixture.root.path + "/Sources/Link.swift",
                                                       withDestinationPath: fixture.root.path + "/Sources/A.swift")
            try FileManager.default.createSymbolicLink(atPath: fixture.root.path + "/Alias",
                                                       withDestinationPath: fixture.root.path + "/Sources")
            let inputs = try SafeInputs(root: fixture.root.path)
            try rejects({ _ = try inputs.expand("Sources") }, containing: "symlink")
            try rejects({ _ = try inputs.expand("Alias") }, containing: "symlink")
        }
        test("content and directory changes are detected") {
            let fixture = try world("changing")
            let inputs = try SafeInputs(root: fixture.root.path)
            _ = try inputs.read("Sources/A.swift")
            try fixture.write("Sources/A.swift", "struct Changed {}")
            try rejects({ try inputs.verifyUnchanged() }, containing: "changed")
            let directories = try SafeInputs(root: fixture.root.path)
            _ = try directories.expand("Sources")
            try fixture.write("Sources/Added.swift", "struct Added {}")
            try rejects({ try directories.verifyUnchanged() }, containing: "changed")
        }
        test("digest mismatch cannot be refreshed") {
            let fixture = try world("digest")
            try fixture.write("project.yml", "changed transcription")
            try require(fixture.run().exitCode == 2, "digest drift was accepted")
        }
    }

    func membershipCases() {
        test("directory expansion equals PBX including explicit Mac subset") {
            let fixture = try world("membership")
            let report = fixture.run(mode: "inventory")
            try require(report.exitCode == 0 && report.ownership.count == 16, "fixture membership failed")
        }
        test("directory and PBX drift") {
            let fixture = try world("directory-drift")
            try fixture.write("Sources/Extra.swift", "struct Extra {}")
            try require(fixture.run().exitCode == 2, "directory drift accepted")
            let missing = try world("missing-reference")
            missing.objects["iosSources"]?["files"] = []
            try missing.save()
            try require(missing.run().exitCode == 2, "PBX drift accepted")
        }
        test("Mac explicit subset drift") {
            let fixture = try world("mac-drift")
            fixture.objects["macSources"]?["files"] = ["macB"]
            try fixture.save()
            try require(fixture.run().exitCode == 2, "Mac omission accepted")
        }
        test("duplicate PBX build paths and references") {
            for (name, files) in [("same-reference", ["iosA", "iosA"]), ("same-path", ["iosA", "anotherA"])] {
                let fixture = try world(name)
                fixture.objects["iosSources"]?["files"] = files
                fixture.objects["anotherA"] = ["isa": "PBXBuildFile", "fileRef": "fileA"]
                try fixture.save()
                try require(fixture.run().exitCode == 2, "duplicate PBX membership accepted")
            }
        }
        test("OpenStep duplicate keys and quoted aliases") {
            for text in ["{ a = 1; a = 2; }", "{ a = 1; \"a\" = 2; }"] {
                try rejects({
                    var check = try OpenStepKeys(text)
                    try check.value()
                }, containing: "duplicate")
            }
        }
        membershipMechanismCases()
    }

    func projectLocationCases() {
        test("nested PBX cannot bind a different repository-root source with the same spelling") {
            let fixture = try world("nested-pbx", annotated: true)
            try fixture.register(fixture.run().derivedRegistrations)
            try require(fixture.run().enforcementSatisfied, "root PBX control did not pass")
            try fixture.write("Nested/Sources/A.swift", "struct Hidden { @Test func hidden() {} }")
            try fixture.write("Nested/Mac/B.swift", "// distinct nested project helper")
            let nested = "Nested/Fixture.xcodeproj/project.pbxproj"
            fixture.manifest["pbxPath"] = nested
            try fixture.save()
            let original = fixture.root.appendingPathComponent("Fixture.xcodeproj/project.pbxproj")
            try fixture.write(nested, String(contentsOf: original, encoding: .utf8))
            for mode in ["enforce", "inventory"] {
                let report = fixture.run(mode: mode)
                try report.encoded().write(to: fixture.root.appendingPathComponent(mode + "-result.json"))
                try require(report.exitCode == 2 && !report.analysisComplete &&
                            report.diagnostics.contains { $0.message.contains("repository-root") },
                            "nested PBX was analyzed using the wrong source root")
            }
        }
    }

    func membershipMechanismCases() {
        test("unsupported conditional compiler settings and xcconfig") {
            for key in ["OTHER_SWIFT_FLAGS", "EXCLUDED_SOURCE_FILE_NAMES", "INCLUDED_SOURCE_FILE_NAMES",
                        "SWIFT_ACTIVE_COMPILATION_CONDITIONS[sdk=macosx*]", "SWIFT_INCLUDE_PATHS"] {
                try rejects({ try BuildSettings.validate([key: "-D UNSUPPORTED"]) }, containing: "unsupported")
            }
            for key in ["SWIFT_COMPILATION_MODE", "SWIFT_OPTIMIZATION_LEVEL", "SWIFT_EMIT_LOC_STRINGS"] {
                try rejects({ try BuildSettings.validate([key: "$(OPAQUE)"]) }, containing: "unsupported")
            }
            let fixture = try world("xcconfig")
            fixture.objects["iosDebug"]?["baseConfigurationReference"] = "config"
            try fixture.save()
            try require(fixture.run().exitCode == 2, "xcconfig accepted")
        }
        test("DEBUG platform and module drift") {
            for (name, settings) in [
                ("debug-drift", ["SDKROOT": "iphoneos", "SWIFT_ACTIVE_COMPILATION_CONDITIONS": ""]),
                ("platform-drift", ["SDKROOT": "macosx"]),
                ("module-drift", ["SDKROOT": "iphoneos", "PRODUCT_MODULE_NAME": "Other"])
            ] {
                let fixture = try world(name)
                fixture.objects["iosDebug"]?["buildSettings"] = settings
                try fixture.save()
                try require(fixture.run().exitCode == 2, "configuration drift accepted")
            }
        }
        test("build filters generated rules synchronized groups and shell phases") {
            for (name, object) in [
                ("filter", ["isa": "PBXBuildFile", "fileRef": "fileA", "platformFilter": "ios"]),
                ("settings", ["isa": "PBXBuildFile", "fileRef": "fileA", "settings": ["COMPILER_FLAGS": "-D X"]])
            ] {
                let fixture = try world(name)
                fixture.objects["iosA"] = object
                try fixture.save()
                try require(fixture.run().exitCode == 2, "build filter/settings accepted")
            }
            for mechanism in ["PBXBuildRule", "PBXFileSystemSynchronizedRootGroup", "PBXShellScriptBuildPhase"] {
                let fixture = try world(mechanism)
                fixture.objects["unsupported"] = ["isa": mechanism]
                try fixture.save()
                try require(fixture.run().exitCode == 2, "unsupported PBX mechanism accepted")
            }
        }
        test("group paths are structural not filename matches") {
            let fixture = try world("group-drift")
            fixture.objects["sourcesGroup"]?["path"] = "Other"
            try fixture.save()
            try require(fixture.run().exitCode == 2, "group-path drift accepted")
        }
        test("explicit and recursive source overlap and missing matrix targets fail") {
            let overlap = try world("overlap")
            var sources = overlap.manifest["sources"] as? [[String: Any]] ?? []
            sources[0]["files"] = ["Sources/A.swift"]
            overlap.manifest["sources"] = sources
            try overlap.save()
            try require(overlap.run().exitCode == 2, "expanded overlap accepted")
            let missing = try world("orphan-target")
            missing.objects["project"]?["targets"] = ["ios"]
            try missing.save()
            try require(missing.run().exitCode == 2, "orphan/missing unit target accepted")
        }
        test("non Swift compiled sources and missing source phases fail") {
            let language = try world("language")
            try language.write("Sources/Extra.m", "void helper(void) {}")
            try require(language.run().exitCode == 2, "non-Swift language silently ignored")
            let phase = try world("source-phase")
            phase.objects["ios"]?["buildPhases"] = []
            try phase.save()
            try require(phase.run().exitCode == 2, "missing source phase accepted")
        }
    }

    func reportCases() {
        test("default enforce and explicitly non-enforcing inventory") {
            let fixture = try world("report")
            let enforced = fixture.run()
            let inventory = fixture.run(mode: "inventory")
            try require(enforced.exitCode == 1 && inventory.exitCode == 0, "enforcement exits")
            try require(!inventory.enforcementSatisfied && inventory.analysisComplete, "inventory greenwashing")
            try require(inventory.ownership.allSatisfy { !$0.annotationSatisfied }, "missing failing annotation rows")
            try require(inventory.derivedRegistrations.count == 16, "derived registrations missing on failure")
            try fixture.register(inventory.derivedRegistrations)
            try require(fixture.run().exitCode == 1, "registration must not excuse missing annotation")
        }
        test("canonical registered synthetic roots pass; deterministic JSON and stale/duplicate rows fail") {
            let fixture = try world("registered", annotated: true)
            let initial = fixture.run()
            try require(initial.exitCode == 1, "draft manifest must not be green")
            try fixture.register(initial.derivedRegistrations)
            let green = fixture.run()
            try require(green.exitCode == 0 && green.enforcementSatisfied, "canonical registration failed")
            try require(try green.encoded() == fixture.run().encoded(), "nondeterministic report")
            try fixture.register(green.derivedRegistrations + green.derivedRegistrations)
            try require(fixture.run().diagnostics.contains { $0.message == "duplicate registration" },
                        "duplicates hidden")
            try fixture.write("Sources/A.swift", "@Suite(.productionAccessAudit) struct Renamed {}")
            try require(fixture.run().diagnostics.contains { $0.message == "stale registration" }, "stale row hidden")
        }
        test("missing registration field remains visibly incomplete") {
            let fixture = try world("missing-list", annotated: true)
            fixture.manifest.removeValue(forKey: "registrations")
            try fixture.save()
            let report = fixture.run(mode: "inventory")
            try require(report.exitCode == 0 && !report.enforcementSatisfied, "missing list greenwashed")
            try require(report.diagnostics.contains { $0.message.contains("incomplete") }, "missing list diagnostic")
        }
        test("retained canonical synthetic fixture for CLI exit-zero verification") {
            let fixture = try world("cli-green", annotated: true)
            try fixture.register(fixture.run().derivedRegistrations)
            try require(fixture.run().enforcementSatisfied, "canonical CLI fixture not ready")
        }
        test("CLI defaults strict arguments and text output") {
            let options = try CheckOptions.parse(["--root", scratch.path])
            try require(options.mode == "enforce" && options.format == "json", "wrong CLI defaults")
            for args in [[], ["--root"], ["--root", scratch.path, "--mode", "baseline"],
                         ["--root", scratch.path, "--root", scratch.path], ["--refresh", "true"]] {
                let result = AuditChecker.execute(args)
                try require(result.1 == 2, "invalid CLI accepted")
                _ = try JSONSerialization.jsonObject(with: result.0)
            }
            let fixture = try world("text")
            let result = AuditChecker.execute(["--root", fixture.root.path, "--manifest", "fixture.json",
                                              "--format", "text", "--mode", "inventory"])
            let text = String(data: result.0, encoding: .utf8) ?? ""
            try require(result.1 == 0 && text.contains("enforcementSatisfied=false"),
                        "text report omitted enforcement state")
        }
    }
}

final class FixtureWorld {
    let root: URL
    var manifest: [String: Any]
    var objects: [String: [String: Any]]

    init(root: URL, annotated: Bool) throws {
        self.root = root
        try require(!FileManager.default.fileExists(atPath: root.path), "fixture directory already exists")
        let spec = "Reviewed fixture source transcription: iOS=Sources/**; macOS=Mac/** + Sources/A.swift\n"
        manifest = [
            "schemaVersion": 1, "purpose": "source-registration-only",
            "specification": ["path": "project.yml", "sha256": digest(Data(spec.utf8)), "review": "REVIEWED"],
            "pbxPath": "Fixture.xcodeproj/project.pbxproj", "registrations": [],
            "matrix": ["iOS", "macOS"].flatMap { platform in
                ["Debug", "Release"].map { config in
                    let target = platform == "iOS" ? "FluxKlangTests" : "FluxKlangMacTests"
                    return ["target": target, "module": target, "platform": platform, "configuration": config]
                }
            },
            "sources": [
                ["target": "FluxKlangTests", "directories": ["Sources"], "files": []],
                ["target": "FluxKlangMacTests", "directories": ["Mac"], "files": ["Sources/A.swift"]]
            ]
        ]
        objects = Self.pbxObjects()
        try write("project.yml", spec)
        try write("Sources/A.swift", (annotated ? "@Suite(.productionAccessAudit)\n" : "") +
                  "struct Example { @Test func body() {} }\n")
        try write("Mac/B.swift", "// non-test explicit-directory helper\n")
        try save()
    }

    static func json(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted])
    }

    func write(_ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func save() throws {
        try Self.json(manifest).write(to: root.appendingPathComponent("fixture.json"))
        let pbx: [String: Any] = ["objects": objects, "rootObject": "project", "objectVersion": "77",
                                  "archiveVersion": "1", "classes": [:]]
        try write("Fixture.xcodeproj/project.pbxproj", Self.openStep(pbx))
    }

    func register(_ rows: [Registration]) throws {
        manifest["registrations"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(rows))
        try save()
    }

    func run(mode: String = "enforce") -> AuditReport {
        AuditChecker.run(CheckOptions(root: root.path, manifest: "fixture.json", mode: mode))
    }

    static func openStep(_ value: Any) throws -> String {
        if let dictionary = value as? [String: Any] {
            return try "{\n" + dictionary.keys.sorted().map {
                guard let value = dictionary[$0] else { throw AuditFailure("missing fixture PBX value") }
                return try openStep($0) + " = " + openStep(value) + ";"
            }.joined(separator: "\n") + "\n}"
        }
        if let array = value as? [Any] {
            return try "(" + array.map(openStep).joined(separator: ",") + ")"
        }
        guard let string = value as? String else { throw AuditFailure("unsupported fixture PBX value") }
        guard let encoded = String(data: try JSONEncoder().encode(string), encoding: .utf8) else {
            throw AuditFailure("fixture PBX string encoding")
        }
        return encoded
    }

    static func pbxObjects() -> [String: [String: Any]] {
        var objects: [String: [String: Any]] = [
            "project": ["isa": "PBXProject", "mainGroup": "main", "targets": ["ios", "mac"],
                        "buildConfigurationList": "projectConfigs"],
            "main": ["isa": "PBXGroup", "sourceTree": "<group>", "children": ["sourcesGroup", "macGroup"]],
            "sourcesGroup": ["isa": "PBXGroup", "path": "Sources", "sourceTree": "<group>", "children": ["fileA"]],
            "macGroup": ["isa": "PBXGroup", "path": "Mac", "sourceTree": "<group>", "children": ["fileB"]],
            "fileA": ["isa": "PBXFileReference", "path": "A.swift",
                      "sourceTree": "<group>", "lastKnownFileType": "sourcecode.swift"],
            "fileB": ["isa": "PBXFileReference", "path": "B.swift",
                      "sourceTree": "<group>", "lastKnownFileType": "sourcecode.swift"]
        ]
        for prefix in ["project", "ios", "mac"] {
            objects[prefix + "Configs"] = ["isa": "XCConfigurationList",
                                           "buildConfigurations": [prefix + "Debug", prefix + "Release"]]
            for config in ["Debug", "Release"] {
                var settings: [String: Any] = prefix == "project" ? ["SWIFT_VERSION": "6"] :
                    ["SDKROOT": prefix == "ios" ? "iphoneos" : "macosx"]
                if prefix == "project" && config == "Debug" {
                    settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "DEBUG"
                }
                objects[prefix + config] = ["isa": "XCBuildConfiguration", "name": config, "buildSettings": settings]
            }
        }
        for prefix in ["ios", "mac"] {
            objects[prefix] = ["isa": "PBXNativeTarget",
                               "name": prefix == "ios" ? "FluxKlangTests" : "FluxKlangMacTests",
                               "productType": "com.apple.product-type.bundle.unit-test", "buildRules": [],
                               "buildConfigurationList": prefix + "Configs", "buildPhases": [prefix + "Sources"]]
            objects[prefix + "Sources"] = [
                "isa": "PBXSourcesBuildPhase", "buildActionMask": "2147483647",
                "runOnlyForDeploymentPostprocessing": "0",
                "files": prefix == "ios" ? ["iosA"] : ["macA", "macB"]
            ]
            objects[prefix + "A"] = ["isa": "PBXBuildFile", "fileRef": "fileA"]
        }
        objects["macB"] = ["isa": "PBXBuildFile", "fileRef": "fileB"]
        return objects
    }
}

@main
enum FixtureMain {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 4, arguments[0] == "--scratch", arguments[2] == "--u1-root" else {
            print("usage: CheckTests --scratch NEW_DIRECTORY --u1-root FROZEN_SOURCE_SNAPSHOT_DIRECTORY")
            exit(2)
        }
        let tests = FixtureTests(scratch: URL(fileURLWithPath: arguments[1]),
                                 u1Root: URL(fileURLWithPath: arguments[3]))
        tests.inputCases()
        tests.membershipCases()
        tests.projectLocationCases()
        tests.reportCases()
        tests.sourceCases()
        print("RESULT \(tests.passed) passed; \(tests.failed) failed")
        exit(tests.failed == 0 ? 0 : 1)
    }
}
#endif
