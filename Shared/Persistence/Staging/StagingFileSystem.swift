import Foundation

/// What a volume reports about one node, without following links.
struct StagingNodeStatus: Sendable, Equatable {
    let kind: ProjectPackageEntryKind
    let byteCount: Int
    let linkCount: Int
    let volume: Int
    /// Changes whenever the node's content changes; used to detect a member that moved under a read.
    let generation: UInt64
}

/// The injected volume the staging pipeline runs against. Paths are relative to the volume root, which is the
/// empty path; `/` separates components. Nothing here is a file coordinator and nothing is atomic across
/// processes: each primitive reports a typed fault and the pipeline reasons only about those results.
protocol StagingFileSystem {
    /// `nil` when the node is absent. The empty path is the volume root and is always a directory.
    mutating func status(at path: String) throws(StagingIOFault) -> StagingNodeStatus?
    /// Child names (not paths) in any order; throws `.tooManyEntries` when there are more than `limit`.
    mutating func listDirectory(at path: String, limit: Int) throws(StagingIOFault) -> [String]
    /// At most `count` bytes from `offset`; fewer only at end of file.
    mutating func read(at path: String, offset: Int, count: Int) throws(StagingIOFault) -> Data
    mutating func makeDirectory(at path: String) throws(StagingIOFault)
    /// Creates a new file; throws `.exists` rather than replacing.
    mutating func createFile(at path: String, bytes: Data) throws(StagingIOFault)
    mutating func syncDirectory(at path: String) throws(StagingIOFault)
    /// Moves a node; throws `.exists` rather than replacing the destination.
    mutating func rename(from source: String, to destination: String) throws(StagingIOFault)
    mutating func removeTree(at path: String) throws(StagingIOFault)
}
