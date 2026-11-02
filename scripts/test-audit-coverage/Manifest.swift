import CryptoKit
import Foundation

struct AuditFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw AuditFailure(message) }
}

func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

// Foundation decoders discard duplicate keys. This independent lexical pass validates
// every object (including escaped key spellings) BEFORE Foundation decodes the schema.
struct JSONKeyCheck {
    let bytes: [UInt8]
    var offset = 0

    mutating func validate() throws {
        try value(depth: 0)
        space()
        try require(offset == bytes.count, "JSON trailing input")
    }

    mutating func space() {
        while offset < bytes.count && [9, 10, 13, 32].contains(bytes[offset]) { offset += 1 }
    }

    mutating func take(_ byte: UInt8) -> Bool {
        space()
        guard offset < bytes.count, bytes[offset] == byte else { return false }
        offset += 1
        return true
    }

    mutating func string() throws -> String {
        space()
        let start = offset
        try require(take(34), "JSON string expected")
        while offset < bytes.count {
            let byte = bytes[offset]
            offset += 1
            if byte == 34 {
                return try JSONDecoder().decode(String.self, from: Data(bytes[start..<offset]))
            }
            if byte == 92 { offset += 1 }
        }
        throw AuditFailure("JSON unterminated string")
    }

    mutating func value(depth: Int) throws {
        try require(depth < 128, "JSON nesting limit")
        space()
        if take(123) {
            var keys = Set<String>()
            if take(125) { return }
            repeat {
                let key = try string()
                try require(keys.insert(key).inserted, "JSON duplicate key: \(key)")
                try require(take(58), "JSON colon expected")
                try value(depth: depth + 1)
            } while take(44)
            try require(take(125), "JSON closing object expected")
        } else if take(91) {
            if take(93) { return }
            repeat { try value(depth: depth + 1) } while take(44)
            try require(take(93), "JSON closing array expected")
        } else if offset < bytes.count && bytes[offset] == 34 {
            _ = try string()
        } else {
            let start = offset
            while offset < bytes.count && ![9, 10, 13, 32, 44, 93, 125].contains(bytes[offset]) { offset += 1 }
            try require(offset > start, "JSON value expected")
            _ = try JSONSerialization.jsonObject(with: Data(bytes[start..<offset]), options: .fragmentsAllowed)
        }
    }
}

struct MatrixRow: Codable, Hashable {
    let target: String
    let module: String
    let platform: String
    let configuration: String
}

struct SourceMembership: Codable {
    let target: String
    let directories: [String]
    let files: [String]
}

// Each row is one SOURCE obligation in one configuration/symbolic variant.
// `name` is a qualified nominal name or normalized free-function signature tokens.
// These values are never Testing.Test.ID, case IDs, or receipt expectations.
struct Registration: Codable, Hashable {
    let target: String
    let module: String
    let path: String
    let kind: String
    let name: String
    let configuration: String
    let guardExpression: String
    let requirement: String

    var sortKey: String {
        [target, module, path, kind, name, configuration, guardExpression, requirement].joined(separator: "\u{1F}")
    }
}

struct AuditManifest: Decodable {
    struct Specification: Decodable {
        let path: String
        let sha256: String
        let review: String
    }
    let schemaVersion: Int
    let purpose: String
    let specification: Specification
    let pbxPath: String
    let matrix: [MatrixRow]
    let sources: [SourceMembership]
    let registrations: [Registration]?

    static func load(_ data: Data) throws -> AuditManifest {
        try require(data.count <= 32_000_000, "manifest size limit")
        var keyCheck = JSONKeyCheck(bytes: Array(data))
        try keyCheck.validate()
        let object = try JSONSerialization.jsonObject(with: data)
        let root = try fields(object, required: [
            "schemaVersion", "purpose", "specification", "pbxPath", "matrix", "sources"
        ], optional: ["registrations"])
        _ = try fields(root["specification"], required: ["path", "sha256", "review"])
        try rows(root["matrix"], keys: ["target", "module", "platform", "configuration"])
        try rows(root["sources"], keys: ["target", "directories", "files"])
        if let registrations = root["registrations"] {
            try rows(registrations, keys: [
                "target", "module", "path", "kind", "name", "configuration", "guardExpression", "requirement"
            ])
        }
        let manifest = try JSONDecoder().decode(Self.self, from: data)
        try manifest.validate()
        return manifest
    }

    private static func fields(
        _ value: Any?, required: Set<String>, optional: Set<String> = []
    ) throws -> [String: Any] {
        guard let object = value as? [String: Any] else { throw AuditFailure("manifest object expected") }
        let keys = Set(object.keys)
        try require(required.isSubset(of: keys) && keys.isSubset(of: required.union(optional)),
                    "manifest missing/unknown fields: \(keys.sorted())")
        return object
    }

    private static func rows(_ value: Any?, keys: Set<String>) throws {
        guard let array = value as? [Any] else { throw AuditFailure("manifest array expected") }
        for row in array { _ = try fields(row, required: keys) }
    }

    private func validate() throws {
        try require(schemaVersion == 1 && purpose == "source-registration-only", "manifest version/purpose")
        try require(specification.path == "project.yml" && specification.review == "REVIEWED",
                    "specification must be an explicitly REVIEWED project.yml transcription")
        try require(specification.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                    "specification SHA256 must be lowercase hex")
        try SafeInputs.validatePath(pbxPath)
        try require(pbxPath.split(separator: "/").count == 2 &&
                    pbxPath.hasSuffix(".xcodeproj/project.pbxproj"),
                    "PBX path must name one repository-root .xcodeproj/project.pbxproj")
        try require(matrix.count == 4 && Set(matrix).count == 4, "matrix requires four unique rows")
        for platform in ["iOS", "macOS"] {
            let rows = matrix.filter { $0.platform == platform }
            try require(rows.count == 2 && Set(rows.map(\.configuration)) == ["Debug", "Release"],
                        "matrix requires Debug/Release for \(platform)")
            try require(Set(rows.map(\.target)).count == 1 && Set(rows.map(\.module)).count == 1,
                        "matrix target/module drift")
        }
        try require(Set(matrix.map(\.target)).count == 2, "matrix requires two distinct unit targets")
        for row in matrix {
            for name in [row.target, row.module] {
                try require(name.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil,
                            "unsupported target/module identifier")
            }
        }
        try require(sources.count == 2 && Set(sources.map(\.target)) == Set(matrix.map(\.target)),
                    "source memberships must bind both targets exactly once")
        for source in sources {
            let paths = source.directories + source.files
            try require(!paths.isEmpty && Set(paths).count == paths.count, "empty/duplicate source entries")
            for path in paths { try SafeInputs.validatePath(path) }
            try require(source.files.allSatisfy { $0.hasSuffix(".swift") }, "explicit sources must be Swift")
        }
        for row in registrations ?? [] {
            try SafeInputs.validatePath(row.path)
            try require(["root", "freeTest"].contains(row.kind) && !row.name.isEmpty, "registration kind/name")
            try require(row.requirement == "canonicalProductionAccessAudit", "unsupported registration requirement")
            try require(matrix.contains {
                $0.target == row.target && $0.module == row.module && $0.configuration == row.configuration
            }, "registration outside matrix")
            try require(SourceVariant.guards.contains(row.guardExpression), "unsupported registration guard")
        }
        // Duplicate/stale/missing registrations are reported as obligations, not hidden by schema decoding.
    }
}

// Captures content, metadata and directory listings, then rereads them after analysis.
// This detects observed input changes; it is not a filesystem transaction or a YAML parser.
final class SafeInputs {
    let root: URL
    private var stamps: [String: String] = [:]
    private var contents: [String: Data] = [:]
    private var listings: [String: [String]] = [:]
    private let manager = FileManager.default

    init(root: String) throws {
        let url = URL(fileURLWithPath: root).standardizedFileURL
        try require(root.hasPrefix("/") && url.path == root, "root must be an absolute normalized path")
        try require(url.resolvingSymlinksInPath().path == root, "symlink root/ancestor")
        self.root = url
    }

    static func validatePath(_ path: String) throws {
        let pieces = path.split(separator: "/", omittingEmptySubsequences: false)
        try require(!path.isEmpty && pieces.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." },
                    "path escape/non-normalized path: \(path)")
        try require(path.unicodeScalars.allSatisfy {
            $0.isASCII && $0.value >= 32 && !["\\", ":", "$", "*", "?", "[", "]"].contains(String($0))
        }, "unsupported path spelling: \(path)")
    }

    static func validateNames(_ names: [String], at path: String) throws {
        try require(Set(names.map { $0.lowercased() }).count == names.count, "case ambiguity: \(path)")
    }

    func location(_ path: String) throws -> URL {
        try Self.validatePath(path)
        var url = root
        for part in path.split(separator: "/").map(String.init) {
            let names = try manager.contentsOfDirectory(atPath: url.path)
            try Self.validateNames(names, at: url.path)
            try require(names.contains(part), "missing/case-mismatched path: \(path)")
            url.appendPathComponent(part)
            let attributes = try manager.attributesOfItem(atPath: url.path)
            try require(attributes[.type] as? FileAttributeType != .typeSymbolicLink, "symlink: \(path)")
        }
        return url
    }

    private func stamp(_ url: URL) throws -> String {
        let attributes = try manager.attributesOfItem(atPath: url.path)
        return [FileAttributeKey.type, .size, .systemFileNumber, .modificationDate, .creationDate].map {
            if let date = attributes[$0] as? Date { return String(date.timeIntervalSinceReferenceDate) }
            return String(describing: attributes[$0])
        }.joined(separator: "|")
    }

    func read(_ path: String) throws -> Data {
        let url = try location(path)
        let before = try stamp(url)
        try require(try manager.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeRegular,
                    "not a regular input: \(path)")
        let data = try Data(contentsOf: url)
        try require(before == stamp(url), "input changed during read: \(path)")
        if let old = contents[path] {
            try require(old == data && stamps[path] == before, "input changed: \(path)")
        }
        stamps[path] = before
        contents[path] = data
        return data
    }

    func expand(_ path: String) throws -> [String] {
        let url = try location(path)
        let attributes = try manager.attributesOfItem(atPath: url.path)
        try require(attributes[.type] as? FileAttributeType == .typeDirectory, "not a source directory: \(path)")
        let names = try manager.contentsOfDirectory(atPath: url.path).sorted()
        try Self.validateNames(names, at: path)
        if let old = listings[path] { try require(old == names, "directory changed: \(path)") }
        listings[path] = names
        var sources: [String] = []
        for name in names {
            let child = path + "/" + name
            let childURL = try location(child)
            let kind = try manager.attributesOfItem(atPath: childURL.path)[.type] as? FileAttributeType
            if kind == .typeDirectory {
                sources += try expand(child)
            } else {
                try require(kind == .typeRegular, "unsupported source directory entry: \(child)")
                if child.hasSuffix(".swift") { sources.append(child) }
                try require(!["c", "m", "mm", "cpp", "cc", "cxx", "s", "metal"]
                    .contains(childURL.pathExtension.lowercased()), "unsupported source language: \(child)")
                try require(childURL.pathExtension.lowercased() != "swift" || child.hasSuffix(".swift"),
                            "case-ambiguous Swift suffix: \(child)")
            }
        }
        return sources.sorted()
    }

    func verifyUnchanged() throws {
        for path in contents.keys.sorted() { _ = try read(path) }
        for path in listings.keys.sorted() { _ = try expand(path) }
    }

    var hashes: [String: String] { contents.mapValues(digest) }
}
