import Foundation

// Only an OpenStep duplicate-key/syntax preflight. Foundation remains the PBX reader.
// Quoted keys use JSON-compatible escapes; exotic OpenStep escapes fail closed.
struct OpenStepKeys {
    let tokens: [String]
    var offset = 0

    init(_ text: String) throws {
        let pattern = #"(?s)\s+|//[^\n]*|/\*.*?\*/|"(?:[^"\\]|\\.)*"|[{}()=;,]|[A-Za-z0-9_./$<>+\-]+"#
        let regex = try NSRegularExpression(pattern: pattern)
        let string = text as NSString
        var end = 0
        var result: [String] = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: string.length)) {
            try require(match.range.location == end, "unsupported OpenStep token")
            end = NSMaxRange(match.range)
            let token = string.substring(with: match.range)
            if token.hasPrefix("//") || token.hasPrefix("/*") ||
                token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            result.append(token)
        }
        try require(end == string.length, "OpenStep trailing/unterminated input")
        tokens = result
    }

    mutating func take(_ token: String) -> Bool {
        guard offset < tokens.count, tokens[offset] == token else { return false }
        offset += 1
        return true
    }

    mutating func atom() throws -> String {
        try require(offset < tokens.count, "OpenStep atom expected")
        let token = tokens[offset]
        offset += 1
        try require(!["{", "}", "(", ")", "=", ";", ","].contains(token), "OpenStep atom expected")
        if token.hasPrefix("\"") { return try JSONDecoder().decode(String.self, from: Data(token.utf8)) }
        return token
    }

    mutating func value(depth: Int = 0) throws {
        try require(depth < 128, "OpenStep nesting limit")
        if take("{") {
            var keys = Set<String>()
            while !take("}") {
                let key = try atom()
                try require(keys.insert(key).inserted, "duplicate OpenStep key: \(key)")
                try require(take("="), "OpenStep equals expected")
                try value(depth: depth + 1)
                try require(take(";"), "OpenStep semicolon expected")
            }
        } else if take("(") {
            while !take(")") {
                try value(depth: depth + 1)
                if take(")") { return }
                try require(take(","), "OpenStep comma expected")
            }
        } else {
            _ = try atom()
        }
    }
}

struct ProjectMembership {
    let objects: [String: [String: Any]]
    let project: [String: Any]
    private var filePaths: [String: String] = [:]
    private var visited = Set<String>()

    init(data: Data) throws {
        try require(data.count <= 32_000_000, "PBX size limit")
        guard let text = String(data: data, encoding: .utf8) else { throw AuditFailure("PBX is not UTF8") }
        var preflight = try OpenStepKeys(text)
        try require(preflight.tokens.first == "{", "PBX must use supported OpenStep format")
        try preflight.value()
        try require(preflight.offset == preflight.tokens.count, "PBX trailing tokens")
        var format = PropertyListSerialization.PropertyListFormat.openStep
        guard let root = try PropertyListSerialization.propertyList(from: data, format: &format) as? [String: Any],
              let objects = root["objects"] as? [String: [String: Any]],
              let rootID = root["rootObject"] as? String, let project = objects[rootID] else {
            throw AuditFailure("invalid PBX object graph")
        }
        try require(format == .openStep && project["isa"] as? String == "PBXProject", "invalid PBX root")
        try require(Set(root.keys) == ["objects", "rootObject", "archiveVersion", "objectVersion", "classes"] &&
                    root["archiveVersion"] as? String == "1" && root["objectVersion"] as? String == "77" &&
                    (root["classes"] as? [String: Any])?.isEmpty == true, "unsupported PBX document version/fields")
        self.objects = objects
        self.project = project
        try supportedGraph()
        try require(Set(project.keys).isSubset(of: [
            "isa", "attributes", "buildConfigurationList", "developmentRegion", "hasScannedForEncodings",
            "knownRegions", "mainGroup", "minimizedProjectReferenceProxies", "packageReferences",
            "preferredProjectObjectVersion", "productRefGroup", "projectDirPath", "projectRoot", "targets"
        ]), "unsupported PBX project fields")
        try require((project["projectDirPath"] as? String ?? "").isEmpty &&
                    (project["projectRoot"] as? String ?? "").isEmpty, "unsupported PBX project root")
        try indexGroup(string(project, "mainGroup"), parent: "")
    }

    private func string(_ object: [String: Any], _ key: String) throws -> String {
        guard let value = object[key] as? String else { throw AuditFailure("PBX missing string: \(key)") }
        return value
    }

    private func strings(_ object: [String: Any], _ key: String) throws -> [String] {
        guard let values = object[key] as? [String] else { throw AuditFailure("PBX missing array: \(key)") }
        try require(Set(values).count == values.count, "PBX duplicate references: \(key)")
        return values
    }

    private func object(_ reference: String, isa: String) throws -> [String: Any] {
        guard let object = objects[reference], object["isa"] as? String == isa else {
            throw AuditFailure("PBX missing/wrong reference: \(reference), expected \(isa)")
        }
        return object
    }

    private func supportedGraph() throws {
        let allowed = Set([
            "PBXBuildFile", "PBXFileReference", "PBXGroup", "PBXNativeTarget", "PBXProject",
            "PBXFrameworksBuildPhase", "PBXResourcesBuildPhase", "PBXSourcesBuildPhase",
            "PBXContainerItemProxy", "PBXTargetDependency", "XCBuildConfiguration", "XCConfigurationList",
            "XCRemoteSwiftPackageReference", "XCSwiftPackageProductDependency"
        ])
        for key in objects.keys.sorted() {
            let value = objects[key] ?? [:]
            try require(allowed.contains(value["isa"] as? String ?? ""), "unsupported PBX mechanism: \(key)")
            try require(value["baseConfigurationReference"] == nil && value["fileSystemSynchronizedGroups"] == nil,
                        "unsupported xcconfig/synchronized source mechanism")
            if let rules = value["buildRules"] {
                try require((rules as? [String])?.isEmpty == true, "unsupported build rules")
            }
        }
    }

    private mutating func indexGroup(_ reference: String, parent: String) throws {
        try require(visited.insert(reference).inserted, "PBX group cycle/duplicate membership: \(reference)")
        let group = try object(reference, isa: "PBXGroup")
        try require(Set(group.keys).isSubset(of: ["isa", "children", "path", "name", "sourceTree"]),
                    "unsupported PBX group fields")
        let base = try relativePath(group, parent: parent)
        for child in try strings(group, "children") {
            guard let value = objects[child] else { throw AuditFailure("PBX missing group child") }
            if value["isa"] as? String == "PBXGroup" {
                try indexGroup(child, parent: base)
            } else {
                try require(value["isa"] as? String == "PBXFileReference", "unsupported group child")
                try require(visited.insert(child).inserted, "duplicate PBX file/group path")
                let tree = value["sourceTree"] as? String
                if tree == "<group>" || tree == "SOURCE_ROOT" {
                    filePaths[child] = try relativePath(value, parent: base)
                } else {
                    try require(["BUILT_PRODUCTS_DIR", "SDKROOT"].contains(tree ?? ""), "unsupported sourceTree")
                }
            }
        }
    }

    private func relativePath(_ value: [String: Any], parent: String) throws -> String {
        let tree = try string(value, "sourceTree")
        try require(["<group>", "SOURCE_ROOT"].contains(tree), "unsupported PBX path base")
        let path = value["path"] as? String ?? ""
        if !path.isEmpty { try SafeInputs.validatePath(path) }
        let prefix = tree == "SOURCE_ROOT" ? "" : parent
        return [prefix, path].filter { !$0.isEmpty }.joined(separator: "/")
    }

    func validate(_ manifest: AuditManifest, inputs: SafeInputs) throws -> [String: [String]] {
        let references = try strings(project, "targets")
        let nativeIDs = objects.keys.filter { objects[$0]?["isa"] as? String == "PBXNativeTarget" }
        try require(Set(references) == Set(nativeIDs), "missing/orphaned PBX native target")
        let targets = try references.map { try object($0, isa: "PBXNativeTarget") }
        let units = targets.filter { $0["productType"] as? String == "com.apple.product-type.bundle.unit-test" }
        let names = try units.map { try string($0, "name") }
        try require(names.count == 2 && Set(names) == Set(manifest.matrix.map(\.target)),
                    "PBX unit-target set does not match matrix")
        var result: [String: [String]] = [:]
        for membership in manifest.sources {
            guard let target = units.first(where: { $0["name"] as? String == membership.target }) else {
                throw AuditFailure("PBX missing unit target")
            }
            try validateConfigurations(target, manifest: manifest, name: membership.target)
            let actual = try sourcePaths(target)
            var expected = membership.files
            for directory in membership.directories { expected += try inputs.expand(directory) }
            try require(Set(expected).count == expected.count, "overlapping/duplicate expanded sources")
            let missing = Set(expected).subtracting(actual).sorted()
            try require(!expected.isEmpty && Set(expected) == Set(actual),
                        "source drift for \(membership.target): missing=\(missing) " +
                        "unexpected=\(Set(actual).subtracting(expected).sorted())")
            for path in expected.sorted() { _ = try inputs.read(path) }
            result[membership.target] = expected.sorted()
        }
        return result
    }

    private func sourcePaths(_ target: [String: Any]) throws -> [String] {
        try require(Set(target.keys).isSubset(of: [
            "isa", "name", "productName", "productType", "productReference", "buildConfigurationList",
            "buildPhases", "buildRules", "dependencies", "packageProductDependencies"
        ]), "unsupported unit target fields")
        let phases = try strings(target, "buildPhases").map { reference -> [String: Any] in
            guard let phase = objects[reference] else { throw AuditFailure("missing PBX phase") }
            try require(["PBXSourcesBuildPhase", "PBXResourcesBuildPhase", "PBXFrameworksBuildPhase"]
                .contains(phase["isa"] as? String ?? ""), "unsupported unit build phase")
            return phase
        }
        let sources = phases.filter { $0["isa"] as? String == "PBXSourcesBuildPhase" }
        try require(sources.count == 1, "unit target needs exactly one sources phase")
        guard let phase = sources.first else { throw AuditFailure("missing sources phase") }
        let phaseKeys: Set<String> = ["isa", "buildActionMask", "files", "runOnlyForDeploymentPostprocessing"]
        try require(Set(phase.keys) == phaseKeys,
                    "unsupported sources-phase fields")
        try require(phase["buildActionMask"] as? String == "2147483647" &&
                    phase["runOnlyForDeploymentPostprocessing"] as? String == "0", "conditional sources phase")
        let paths = try strings(phase, "files").map { reference -> String in
            let build = try object(reference, isa: "PBXBuildFile")
            try require(Set(build.keys) == ["isa", "fileRef"], "unsupported build-file settings/filters")
            let fileID = try string(build, "fileRef")
            let file = try object(fileID, isa: "PBXFileReference")
            try require(Set(file.keys).isSubset(of: [
                "isa", "path", "name", "sourceTree", "lastKnownFileType", "explicitFileType", "includeInIndex"
            ]), "unsupported source file reference")
            guard let path = filePaths[fileID], path.hasSuffix(".swift") else {
                throw AuditFailure("unresolved/non-Swift source file/group path")
            }
            let type = file["explicitFileType"] as? String ?? file["lastKnownFileType"] as? String
            try require(type == "sourcecode.swift", "unsupported source file type")
            return path
        }
        try require(Set(paths).count == paths.count, "duplicate PBX source path")
        return paths.sorted()
    }

    private func configurations(_ owner: [String: Any]) throws -> [String: [String: Any]] {
        let list = try object(string(owner, "buildConfigurationList"), isa: "XCConfigurationList")
        var result: [String: [String: Any]] = [:]
        for reference in try strings(list, "buildConfigurations") {
            let config = try object(reference, isa: "XCBuildConfiguration")
            try require(Set(config.keys) == ["isa", "name", "buildSettings"], "unsupported configuration fields")
            let name = try string(config, "name")
            guard let settings = config["buildSettings"] as? [String: Any] else {
                throw AuditFailure("missing build settings")
            }
            try require(result[name] == nil, "duplicate configuration name")
            try BuildSettings.validate(settings)
            result[name] = settings
        }
        try require(Set(result.keys) == ["Debug", "Release"], "unsupported/missing configuration")
        return result
    }

    private func validateConfigurations(_ target: [String: Any], manifest: AuditManifest, name: String) throws {
        let projectConfigs = try configurations(project)
        let targetConfigs = try configurations(target)
        for row in manifest.matrix.filter({ $0.target == name }) {
            let base = projectConfigs[row.configuration] ?? [:]
            let local = targetConfigs[row.configuration] ?? [:]
            let effective = base.merging(local) { _, new in new }
            try require(effective["SWIFT_VERSION"] as? String == "6", "unsupported Swift language version")
            try require(effective["SDKROOT"] as? String == (row.platform == "iOS" ? "iphoneos" : "macosx"),
                        "matrix/PBX platform mismatch")
            let module = effective["PRODUCT_MODULE_NAME"] as? String ?? name
            let product = effective["PRODUCT_NAME"] as? String ?? "$(TARGET_NAME)"
            try require(module == row.module && (product == name || product == "$(TARGET_NAME)"),
                        "unsupported module/product name substitution")
            let baseFlags = try BuildSettings.conditions(base["SWIFT_ACTIVE_COMPILATION_CONDITIONS"])
            let localFlags = try BuildSettings.conditions(local["SWIFT_ACTIVE_COMPILATION_CONDITIONS"])
            let flags = local["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] == nil ? baseFlags :
                localFlags.flatMap { $0 == "$(inherited)" ? baseFlags : [$0] }
            let expected: Set<String> = row.configuration == "Debug" ? ["DEBUG"] : []
            try require(Set(flags.filter { $0 != "$(inherited)" }) == expected, "DEBUG configuration drift")
        }
    }
}

enum BuildSettings {
    // Only settings reviewed as irrelevant to Swift source membership, plus the
    // explicitly validated language/module/SDK/DEBUG fields. No prefix wildcard.
    static let allowed = Set("""
        ALWAYS_SEARCH_USER_PATHS CLANG_ANALYZER_NONNULL CLANG_ANALYZER_NUMBER_OBJECT_CONVERSION
        CLANG_CXX_LANGUAGE_STANDARD CLANG_CXX_LIBRARY CLANG_ENABLE_MODULES CLANG_ENABLE_OBJC_ARC
        CLANG_ENABLE_OBJC_WEAK CLANG_WARN_BLOCK_CAPTURE_AUTORELEASING CLANG_WARN_BOOL_CONVERSION
        CLANG_WARN_COMMA CLANG_WARN_CONSTANT_CONVERSION CLANG_WARN_DEPRECATED_OBJC_IMPLEMENTATIONS
        CLANG_WARN_DIRECT_OBJC_ISA_USAGE CLANG_WARN_DOCUMENTATION_COMMENTS CLANG_WARN_EMPTY_BODY
        CLANG_WARN_ENUM_CONVERSION CLANG_WARN_INFINITE_RECURSION CLANG_WARN_INT_CONVERSION
        CLANG_WARN_NON_LITERAL_NULL_CONVERSION CLANG_WARN_OBJC_IMPLICIT_RETAIN_SELF CLANG_WARN_OBJC_LITERAL_CONVERSION
        CLANG_WARN_OBJC_ROOT_CLASS CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER CLANG_WARN_RANGE_LOOP_ANALYSIS
        CLANG_WARN_STRICT_PROTOTYPES CLANG_WARN_SUSPICIOUS_MOVE CLANG_WARN_UNGUARDED_AVAILABILITY
        CLANG_WARN_UNREACHABLE_CODE
        CLANG_WARN__DUPLICATE_METHOD_MATCH COPY_PHASE_STRIP CURRENT_PROJECT_VERSION DEAD_CODE_STRIPPING
        DEBUG_INFORMATION_FORMAT DEVELOPMENT_TEAM ENABLE_NS_ASSERTIONS ENABLE_STRICT_OBJC_MSGSEND ENABLE_TESTABILITY
        ENABLE_USER_SCRIPT_SANDBOXING GCC_C_LANGUAGE_STANDARD GCC_DYNAMIC_NO_PIC GCC_NO_COMMON_BLOCKS
        GCC_OPTIMIZATION_LEVEL GCC_PREPROCESSOR_DEFINITIONS GCC_WARN_64_TO_32_BIT_CONVERSION GCC_WARN_ABOUT_RETURN_TYPE
        GCC_WARN_UNDECLARED_SELECTOR GCC_WARN_UNINITIALIZED_AUTOS GCC_WARN_UNUSED_FUNCTION GCC_WARN_UNUSED_VARIABLE
        IPHONEOS_DEPLOYMENT_TARGET MACOSX_DEPLOYMENT_TARGET MARKETING_VERSION MTL_ENABLE_DEBUG_INFO MTL_FAST_MATH
        ONLY_ACTIVE_ARCH PRODUCT_NAME PRODUCT_MODULE_NAME SWIFT_ACTIVE_COMPILATION_CONDITIONS SWIFT_COMPILATION_MODE
        SWIFT_EMIT_LOC_STRINGS SWIFT_OPTIMIZATION_LEVEL SWIFT_VERSION BUNDLE_LOADER COMBINE_HIDPI_IMAGES
        GENERATE_INFOPLIST_FILE LD_RUNPATH_SEARCH_PATHS PRODUCT_BUNDLE_IDENTIFIER SDKROOT
        TARGETED_DEVICE_FAMILY TEST_HOST
        """.split(whereSeparator: \.isWhitespace).map(String.init))

    static func validate(_ settings: [String: Any]) throws {
        for key in settings.keys.sorted() {
            try require(allowed.contains(key), "unsupported build setting: \(key)")
            try require(settings[key] is String || settings[key] is [String], "unsupported build setting value")
        }
        let swiftValues = [
            "SWIFT_COMPILATION_MODE": ["singlefile", "wholemodule"],
            "SWIFT_OPTIMIZATION_LEVEL": ["-Onone", "-O", "-Osize"],
            "SWIFT_EMIT_LOC_STRINGS": ["YES", "NO"]
        ]
        for (key, allowedValues) in swiftValues {
            if let value = settings[key] {
                try require(allowedValues.contains(value as? String ?? ""), "unsupported Swift setting value: \(key)")
            }
        }
        _ = try conditions(settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"])
    }

    static func conditions(_ value: Any?) throws -> [String] {
        guard let value else { return [] }
        let tokens: [String]
        if let string = value as? String {
            tokens = string.split(whereSeparator: \.isWhitespace).map(String.init)
        } else if let array = value as? [String] {
            tokens = array
        } else {
            throw AuditFailure("unsupported compilation conditions")
        }
        try require(tokens.allSatisfy { ["DEBUG", "$(inherited)"].contains($0) } &&
                    Set(tokens).count == tokens.count, "unsupported/duplicate compilation conditions")
        return tokens
    }
}

#if AUDIT_CHECK_TESTS
// The unchanged pure PBX fixture builder lives here to keep both fixture files
// within the existing strict size limit; it is absent from normal CLI builds.
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

extension FixtureTests {
    func unqualifiedAncestryCases() {
        let globals = """
        import class XCTest.XCTestCase
        enum Names { class Base {} }
        enum Holder { typealias Base = XCTestCase }
        typealias Parent = Names.Base
        """
        test("nearest unqualified ancestry alias cannot be obscured by an ordinary global alias") {
            try rejectLegacy("unqualified-shadow", first: globals + """

            enum Outer { typealias Parent = Holder.Base; class Legacy: Parent {} }
            """)
        }
        test("cross-file unqualified ancestry hops bind in each alias declaration scope") {
            let nested = """
            enum Outer {
                typealias Parent = Holder.Base
                typealias Middle = Parent
                class Legacy: Middle {}
            }
            """
            try rejectLegacy("unqualified-chain", first: globals, second: nested)
            for ordered in [[("A.swift", globals), ("B.swift", nested)], [("B.swift", nested), ("A.swift", globals)]] {
                try rejects({ _ = try sourceReport(ordered) }, containing: "XCTest")
            }
        }
    }
}
#endif
