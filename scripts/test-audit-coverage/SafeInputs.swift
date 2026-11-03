import Foundation

enum InputRole {
    case source, metadata

    var byteLimit: Int { self == .source ? 8_000_000 : 32_000_000 }
}

// Captures content, metadata and directory listings, then rereads them after analysis.
// This detects observed input changes; it is not a filesystem transaction or a YAML parser.
final class SafeInputs {
    let root: URL
    private var stamps: [String: String] = [:]
    private var contents: [String: Data] = [:]
    private var limits: [String: Int] = [:]
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

    // Read at most one byte beyond the bound, including when the file grows after
    // metadata capture. The extra byte detects overflow and is never appended.
    static func boundedRead(
        limit: Int, path: String, readChunk: (Int) throws -> Data
    ) throws -> Data {
        var data = Data()
        while true {
            let remaining = limit - data.count
            let chunk = try readChunk(min(65_536, remaining + 1))
            if chunk.isEmpty { return data }
            try require(chunk.count <= remaining, "input size limit (\(limit) bytes): \(path)")
            data.append(chunk)
        }
    }

    func read(_ path: String, role: InputRole = .metadata) throws -> Data {
        let limit = min(limits[path] ?? role.byteLimit, role.byteLimit)
        limits[path] = limit
        let url = try location(path)
        let before = try stamp(url)
        try require(try manager.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeRegular,
                    "not a regular input: \(path)")
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try Self.boundedRead(limit: limit, path: path) { count in
            try handle.read(upToCount: count) ?? Data()
        }
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
