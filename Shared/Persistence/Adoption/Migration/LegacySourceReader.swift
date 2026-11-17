import Foundation

/// Reads the three legacy files from the local app directory and splits their bytes once with
/// `ProjectMigration.split`. Local files only: no key-value or cloud store is consulted or seeded. Read-only: the core
/// calls only `status` and `read`, and a refused file is left exactly as it was.
///
/// Each file is checked in this order and stops at the first defect: its no-follow status (absent is `missing`), a
/// regular file (a link is never followed), one hard link, the directory's volume, its byte count against
/// `ProjectMigration.entryLimit` (over it is `oversized`, without a read), one read of at most the limit plus one
/// byte, then a second status that must equal the first and agree with the bytes read (otherwise `changed`).
/// Refusals carry no bytes and no paths. Synchronous; it holds no state between calls.
enum LegacySourceReader {
    /// Reads `directory` through a no-follow `DiskStagingFileSystem` that is closed before returning. A missing
    /// directory makes every source `missing`; one that is a link or not a directory refuses every source.
    static func read(directory: URL, limits: ProjectPackageLimits) -> LegacySourceReport {
        var store: DiskStagingFileSystem
        do {
            store = try DiskStagingFileSystem(root: directory, limits: limits)
        } catch {
            return .uniform(rootRefusal(error, directory: directory))
        }
        defer { store.close() }
        return read(in: &store, limits: limits)
    }

    /// The core over any volume whose root (the empty path) is the app directory.
    static func read<FS: StagingFileSystem>(in store: inout FS, limits: ProjectPackageLimits) -> LegacySourceReport {
        let root: StagingNodeStatus
        do {
            guard let status = try store.status(at: "") else { return .uniform(nil) }
            root = status
        } catch {
            return .uniform(.io(.failed(error)))
        }
        guard root.kind == .directory else { return .uniform(.io(.directoryRefused)) }
        let limit = ProjectMigration.entryLimit(limits)
        let connections = gather(.connections, rootVolume: root.volume, limit: limit, &store)
        let usbMap = gather(.usbMap, rootVolume: root.volume, limit: limit, &store)
        let draft = gather(.pendingDraft, rootVolume: root.volume, limit: limit, &store)
        let split = ProjectMigration.split(
            connections: try? connections?.get(), usbMap: try? usbMap?.get(), draft: try? draft?.get(), limits: limits
        )
        return LegacySourceReport(
            homeWiring: outcome(connections, split.homeWiring), hostLocal: outcome(usbMap, split.hostLocal),
            draft: outcome(draft, split.draft)
        )
    }

    /// The file each source is read from, matching `StorageInventory`.
    private static func fileName(_ source: ProjectMigrationSource) -> String {
        switch source {
        case .connections: "studio-connections.json"
        case .usbMap: "launch-control-xl.json"
        case .pendingDraft: "assistant-pending-studio-draft.json"
        }
    }

    /// The bytes of one file, its refusal, or nil when it is absent.
    private static func gather<FS: StagingFileSystem>(
        _ source: ProjectMigrationSource, rootVolume: Int, limit: Int, _ store: inout FS
    ) -> Result<Data, LegacySourceRefusal>? {
        let name = fileName(source)
        do {
            guard let first = try store.status(at: name) else { return nil }
            guard first.kind == .regularFile else { return .failure(.io(.notRegularFile)) }
            guard first.linkCount == 1 else { return .failure(.io(.hardLinked)) }
            guard first.volume == rootVolume else { return .failure(.io(.otherVolume)) }
            guard first.byteCount <= limit else {
                return .failure(.migration(ProjectMigrationRefusal(source: source, kind: .oversized)))
            }
            let data = try store.read(at: name, offset: 0, count: limit + 1)
            guard let second = try store.status(at: name), second == first, second.byteCount == data.count else {
                return .failure(.io(.changed))
            }
            return .success(data)
        } catch .notFound, .changed {
            // The regular file it was a moment ago is gone, became a link or was swapped.
            return .failure(.io(.changed))
        } catch {
            return .failure(.io(.failed(error)))
        }
    }

    private static func outcome<Value: Sendable & Equatable>(
        _ gathered: Result<Data, LegacySourceRefusal>?, _ split: Result<Value, ProjectMigrationRefusal>?
    ) -> LegacySourceOutcome<Value> {
        switch (gathered, split) {
        case (nil, _): .missing
        case (.failure(let refusal)?, _): .refused(refusal)
        case (.success?, .success(let value)?): .adopted(value)
        case (.success?, .failure(let refusal)?): .refused(.migration(refusal))
        // Unreachable: the split answers every source it was given. Fail safe: a file that was read is never missing.
        case (.success?, nil): .refused(.io(.failed(.ioError)))
        }
    }

    /// Why the directory could not be opened: nil when it does not exist (told apart with one `lstat`).
    private static func rootRefusal(_ error: StagingRefusal, directory: URL) -> LegacySourceRefusal? {
        switch error {
        case .destinationRefused, .ioFailed(step: _, fault: .notFound, cleanup: _):
            var info = stat()
            let code = directory.withUnsafeFileSystemRepresentation { path -> Int32 in
                guard let path else { return EINVAL }
                return lstat(path, &info) == 0 ? 0 : errno
            }
            if code == ENOENT { return nil }
            return .io(code == 0 ? .directoryRefused : .failed(DiskStagingFileSystem.fault(errno: code)))
        case .packageIO(.destinationParentRefused):
            return .io(.directoryRefused)
        case .ioFailed(step: _, let fault, cleanup: _):
            return .io(.failed(fault))
        default:
            return .io(.failed(.ioError))
        }
    }
}
