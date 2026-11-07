import Foundation
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// A value-type fake volume for `StagingFileSystem`. Every primitive is logged with its outcome and consults a
/// script by index (relative to `arm`), so tests can inject faults, crashes (before or after a primitive, or a torn
/// `createFile`), planted nodes and silent corruption. `removeTree` is expanded into one primitive per node.
/// The script-keyed maps (plant, remove, mutateOnRead, statusSizeSkew, silent) match by exact spelling and are not
/// folded under `caseInsensitive`.
struct InMemoryStagingFileSystem: StagingFileSystem, Equatable {
    struct Node: Equatable, Sendable {
        var kind: ProjectPackageEntryKind
        var bytes = Data()
        var linkCount = 1
        var volume = 1
        var generation: UInt64 = 1
        /// Unique per node and kept by a rename; assigned when the node is placed.
        var identity: UInt64 = 0
    }

    struct Shape: Equatable, Sendable {
        let kind: ProjectPackageEntryKind
        let bytes: Data
    }

    enum FileOp: Equatable, Sendable {
        case status(String), list(String, Int), read(String, Int, Int)
        case makeDirectory(String), createFile(String, Int), syncDirectory(String)
        case rename(String, String), removeNode(String)

        var isMutating: Bool {
            switch self {
            case .status, .list, .read: false
            case .makeDirectory, .createFile, .syncDirectory, .rename, .removeNode: true
            }
        }
    }

    enum Outcome: Equatable, Sendable {
        case succeeded, fault(StagingIOFault), crashedBefore, crashedAfter, torn(Int), down
    }

    struct Entry: Equatable, Sendable {
        let operation: FileOp
        let outcome: Outcome
    }

    enum Crash: Equatable, Sendable {
        case before, after, torn(prefix: Int)
    }

    enum Silent: Equatable, Sendable {
        case shorten(to: Int), flipFirstByte, dropDirectory, plantSibling(String)
    }

    enum ReadMutation: Equatable, Sendable {
        case bumpGeneration, appendByte, addLink, changeVolume, changeKind
    }

    struct Script: Equatable, Sendable {
        var faults: [Int: StagingIOFault] = [:]
        var crashIndex: Int?
        var crash = Crash.before
        var plant: [Int: String] = [:]
        var remove: [Int: String] = [:]
        var reverseListings = false
        var extraListedNames: [String] = []
        var silent: [String: Silent] = [:]
        var mutateOnRead: [String: ReadMutation] = [:]
        /// Added to the byte count every status reports for the path; the bytes themselves are untouched.
        var statusSizeSkew: [String: Int] = [:]

        static func fault(_ fault: StagingIOFault, at index: Int) -> Script {
            Script(faults: [index: fault])
        }

        static func crash(_ crash: Crash, at index: Int) -> Script {
            Script(crashIndex: index, crash: crash)
        }
    }

    private(set) var nodes: [String: Node] = [:]
    private(set) var log: [Entry] = []
    private(set) var isDown = false
    private var script = Script()
    private var base = 0
    private var nextGeneration: UInt64 = 2
    private var nextIdentity: UInt64 = 1
    /// When true every path is folded with `lowercased()` on entry, so `Set` and `set` name one node.
    let caseInsensitive: Bool

    init(caseInsensitive: Bool = false) {
        self.caseInsensitive = caseInsensitive
    }

    var mutations: [Entry] { log.filter(\.operation.isMutating) }

    /// Starts a fresh script; indexes count from the current log end. Also revives a crashed volume.
    mutating func arm(_ script: Script = Script()) {
        self.script = script
        base = log.count
        isDown = false
    }

    // MARK: Seeding (not logged)

    mutating func seedDirectory(_ path: String, volume: Int = 1) {
        place(fold(path), Node(kind: .directory, volume: volume))
    }

    mutating func seedFile(_ path: String, _ bytes: Data, linkCount: Int = 1, volume: Int = 1) {
        place(fold(path), Node(kind: .regularFile, bytes: bytes, linkCount: linkCount, volume: volume))
    }

    mutating func unseed(_ path: String) {
        nodes[fold(path)] = nil
    }

    /// Forces a node's identity so a test can give nodes of two volumes the same one.
    mutating func setIdentity(_ path: String, to identity: UInt64) {
        nodes[fold(path)]?.identity = identity
    }

    mutating func seedNode(_ path: String, kind: ProjectPackageEntryKind) {
        place(fold(path), Node(kind: kind))
    }

    mutating func seed(package contents: ProjectPackageContents, at root: String, volume: Int = 1) {
        seedDirectory(root, volume: volume)
        seedFile(Self.join(root, "manifest.json"), contents.manifestBytes, volume: volume)
        for directory in contents.directories { seedDirectory(Self.join(root, directory), volume: volume) }
        for file in contents.files { seedFile(Self.join(root, file.path), file.bytes, volume: volume) }
    }

    // MARK: Inspection

    static func join(_ base: String, _ child: String) -> String { base.isEmpty ? child : base + "/" + child }

    func shapes(at root: String) -> [String: Shape] {
        let root = fold(root)
        var result: [String: Shape] = [:]
        for (path, node) in nodes where StagingPlan.isWithin(path, of: root) {
            let suffix = StagingPlan.remainder(of: path, beneath: root).map { "/" + $0 } ?? ""
            result[suffix] = Shape(kind: node.kind, bytes: node.bytes)
        }
        return result
    }

    static func shapes(of contents: ProjectPackageContents) -> [String: Shape] {
        var result = ["": Shape(kind: .directory, bytes: Data())]
        result["/manifest.json"] = Shape(kind: .regularFile, bytes: contents.manifestBytes)
        for directory in contents.directories { result["/" + directory] = Shape(kind: .directory, bytes: Data()) }
        for file in contents.files { result["/" + file.path] = Shape(kind: .regularFile, bytes: file.bytes) }
        return result
    }

    /// The nodes with identities zeroed, for comparing two volumes that were built in different orders.
    var nodesIgnoringIdentity: [String: Node] {
        nodes.mapValues { node in
            var copy = node
            copy.identity = 0
            return copy
        }
    }

    func nodes(outside roots: [String]) -> [String: Node] {
        let folded = roots.map(fold)
        return nodes.filter { path, _ in !folded.contains { StagingPlan.isWithin(path, of: $0) } }
    }

    // MARK: StagingFileSystem

    mutating func status(at path: String) throws(StagingIOFault) -> StagingNodeStatus? {
        let path = fold(path)
        return try perform(.status(path)) { store throws(StagingIOFault) in
            guard !path.isEmpty else {
                return StagingNodeStatus(
                    kind: .directory, byteCount: 0, linkCount: 1, volume: 1, generation: 0, identity: 0
                )
            }
            guard let node = store.nodes[path] else { return nil }
            return StagingNodeStatus(
                kind: node.kind, byteCount: node.bytes.count + (store.script.statusSizeSkew[path] ?? 0),
                linkCount: node.linkCount, volume: node.volume, generation: node.generation,
                identity: node.identity
            )
        }
    }

    mutating func listDirectory(at path: String, limit: Int) throws(StagingIOFault) -> [String] {
        let path = fold(path)
        return try perform(.list(path, limit)) { store throws(StagingIOFault) in
            guard path.isEmpty || store.nodes[path]?.kind == .directory else { throw .notFound }
            let names = store.nodes.keys.compactMap { key -> String? in
                Self.parent(of: key) == path ? Self.leaf(of: key) : nil
            }
            let listed = names + store.script.extraListedNames
            guard listed.count <= limit else { throw .tooManyEntries }
            let sorted = listed.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
            return store.script.reverseListings ? sorted.reversed() : sorted
        }
    }

    mutating func read(at path: String, offset: Int, count: Int) throws(StagingIOFault) -> Data {
        let path = fold(path)
        return try perform(.read(path, offset, count)) { store throws(StagingIOFault) in
            guard let node = store.nodes[path], node.kind == .regularFile, offset >= 0, count >= 0 else {
                throw .notFound
            }
            let slice = Data(node.bytes.dropFirst(offset).prefix(count))
            switch store.script.mutateOnRead[path] {
            case .bumpGeneration where offset == 0: store.nodes[path]?.generation += 100
            case .appendByte where offset == 0: store.nodes[path]?.bytes.append(0x58)
            case .addLink where offset == 0: store.nodes[path]?.linkCount += 1
            case .changeVolume where offset == 0: store.nodes[path]?.volume += 1
            case .changeKind where slice.isEmpty: store.nodes[path]?.kind = .symbolicLink
            default: break
            }
            return slice
        }
    }

    mutating func makeDirectory(at path: String) throws(StagingIOFault) {
        let path = fold(path)
        try perform(.makeDirectory(path)) { store throws(StagingIOFault) in
            try store.checkCreatable(path)
            if store.script.silent[path] == .dropDirectory { return }
            store.insert(path, Node(kind: .directory, volume: store.parentVolume(of: path)))
        }
    }

    mutating func createFile(at path: String, bytes: Data) throws(StagingIOFault) {
        let path = fold(path)
        let index = log.count - base
        if !isDown, script.crashIndex == index, case let .torn(prefix) = script.crash {
            if (try? checkCreatable(path)) != nil {
                let tornVolume = parentVolume(of: path)
                insert(path, Node(kind: .regularFile, bytes: bytes.prefix(prefix), volume: tornVolume))
            }
            isDown = true
            log.append(Entry(operation: .createFile(path, bytes.count), outcome: .torn(prefix)))
            throw .interrupted
        }
        try perform(.createFile(path, bytes.count)) { store throws(StagingIOFault) in
            try store.checkCreatable(path)
            var stored = bytes
            switch store.script.silent[path] {
            case let .shorten(count): stored = Data(bytes.prefix(count))
            case .flipFirstByte: if !stored.isEmpty { stored[stored.startIndex] ^= 0xFF }
            case let .plantSibling(name):
                let sibling = Self.join(Self.parent(of: path), name)
                store.insert(sibling, Node(kind: .regularFile, volume: store.parentVolume(of: sibling)))
            case .dropDirectory, nil: break
            }
            store.insert(path, Node(kind: .regularFile, bytes: stored, volume: store.parentVolume(of: path)))
        }
    }

    mutating func syncDirectory(at path: String) throws(StagingIOFault) {
        let path = fold(path)
        try perform(.syncDirectory(path)) { store throws(StagingIOFault) in
            let dropped = store.script.silent[path] == .dropDirectory
            guard path.isEmpty || dropped || store.nodes[path]?.kind == .directory else {
                throw .notFound
            }
        }
    }

    mutating func rename(from source: String, to destination: String) throws(StagingIOFault) {
        let (source, destination) = (fold(source), fold(destination))
        try perform(.rename(source, destination)) { store throws(StagingIOFault) in
            guard let node = store.nodes[source] else { throw .notFound }
            guard store.nodes[destination] == nil else { throw .exists }
            let parent = Self.parent(of: destination)
            guard parent.isEmpty || store.nodes[parent]?.kind == .directory else { throw .notFound }
            guard node.volume == (parent.isEmpty ? 1 : store.nodes[parent]?.volume) else { throw .crossVolume }
            for (path, value) in store.nodes where StagingPlan.isWithin(path, of: source) {
                store.nodes[path] = nil
                let suffix = StagingPlan.remainder(of: path, beneath: source).map { "/" + $0 } ?? ""
                store.nodes[destination + suffix] = value
            }
        }
    }

    mutating func removeTree(at path: String) throws(StagingIOFault) {
        let path = fold(path)
        let doomed = nodes.keys.filter { StagingPlan.isWithin($0, of: path) }
            .sorted { $1.utf8.lexicographicallyPrecedes($0.utf8) }
        if doomed.isEmpty {
            try perform(.removeNode(path)) { _ throws(StagingIOFault) in throw .notFound }
        }
        for node in doomed {
            try perform(.removeNode(node)) { store throws(StagingIOFault) in store.nodes[node] = nil }
        }
    }

    // MARK: Internals

    private static func leaf(of path: String) -> String {
        guard let slash = path.unicodeScalars.lastIndex(of: "/") else { return path }
        return String(path.unicodeScalars[path.unicodeScalars.index(after: slash)...])
    }

    private static func parent(of path: String) -> String {
        guard let slash = path.unicodeScalars.lastIndex(of: "/") else { return "" }
        return String(path.unicodeScalars[..<slash])
    }

    private func checkCreatable(_ path: String) throws(StagingIOFault) {
        guard nodes[path] == nil else { throw .exists }
        let parent = Self.parent(of: path)
        guard parent.isEmpty || nodes[parent]?.kind == .directory else { throw .notFound }
    }

    /// A new node takes the volume of the directory it is created in (the root volume is 1).
    private func parentVolume(of path: String) -> Int {
        let parent = Self.parent(of: path)
        return parent.isEmpty ? 1 : nodes[parent]?.volume ?? 1
    }

    private func fold(_ path: String) -> String {
        caseInsensitive ? path.lowercased() : path
    }

    private mutating func place(_ path: String, _ node: Node) {
        var stamped = node
        stamped.identity = nextIdentity
        nextIdentity += 1
        nodes[path] = stamped
    }

    private mutating func insert(_ path: String, _ node: Node) {
        var stamped = node
        stamped.generation = nextGeneration
        nextGeneration += 1
        place(path, stamped)
    }

    private mutating func perform<Value>(
        _ operation: FileOp, _ body: (inout Self) throws(StagingIOFault) -> Value
    ) throws(StagingIOFault) -> Value {
        let index = log.count - base
        guard !isDown else {
            log.append(Entry(operation: operation, outcome: .down))
            throw .interrupted
        }
        if let path = script.plant[index] { place(path, Node(kind: .directory)) }
        if let path = script.remove[index] { nodes[path] = nil }
        if script.crashIndex == index, script.crash == .before {
            isDown = true
            log.append(Entry(operation: operation, outcome: .crashedBefore))
            throw .interrupted
        }
        if let fault = script.faults[index] {
            log.append(Entry(operation: operation, outcome: .fault(fault)))
            throw fault
        }
        let value: Value
        do {
            value = try body(&self)
        } catch {
            log.append(Entry(operation: operation, outcome: .fault(error)))
            throw error
        }
        if script.crashIndex == index, script.crash == .after {
            isDown = true
            log.append(Entry(operation: operation, outcome: .crashedAfter))
            throw .interrupted
        }
        log.append(Entry(operation: operation, outcome: .succeeded))
        return value
    }
}
