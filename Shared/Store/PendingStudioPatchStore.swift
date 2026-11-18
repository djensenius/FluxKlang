import Darwin
import Foundation

protocol PendingStudioPatchPersisting: Sendable {
    func load() async -> PendingStudioPatchLoadOutcome
    func save(_ draft: StudioPatchDraft?) async -> PendingStudioPatchMutationOutcome
}

enum PendingStudioPatchLoadOutcome: Sendable, Equatable {
    case loaded(StudioPatchDraft)
    case absent
    case malformedOrUnsupported
    case readFailed(PendingStudioPatchIOFailure)
}

enum PendingStudioPatchMutationOutcome: Sendable, Equatable {
    case writeCompleted, deleteCompleted, alreadyAbsent
    case encodingFailed
    case directoryPreparationFailed(PendingStudioPatchIOFailure)
    case mutationFailedEffectUnconfirmed(PendingStudioPatchIOFailure)

    var completed: Bool {
        switch self {
        case .writeCompleted, .deleteCompleted, .alreadyAbsent: true
        case .encodingFailed, .directoryPreparationFailed, .mutationFailedEffectUnconfirmed: false
        }
    }
}

enum PendingStudioPatchIOFailure: Sendable, Equatable {
    case permissionDenied, notDirectory, isDirectory, outOfSpace, other
}

// Only bounded, allowlisted codes escape Foundation; never paths, payloads or error text.
enum PendingStudioPatchIOError: Equatable {
    case absent
    case failure(PendingStudioPatchIOFailure)

    static func classify(_ error: any Error) -> Self {
        var current = error as NSError
        for _ in 0..<4 {
            let result = classifyCode(current)
            if case .failure(let failure) = result, failure != .other { return result }
            guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError else { return result }
            current = underlying
        }
        // A deeper obstruction must never be hidden by an outer absence wrapper.
        return .failure(.other)
    }

    private static func classifyCode(_ error: NSError) -> Self {
        if error.domain == NSPOSIXErrorDomain {
            return classifyPOSIXCode(error.code)
        }
        guard error.domain == NSCocoaErrorDomain else { return .failure(.other) }
        switch error.code {
        case NSFileNoSuchFileError, NSFileReadNoSuchFileError: return .absent
        case NSFileReadNoPermissionError, NSFileWriteNoPermissionError: return .failure(.permissionDenied)
        case NSFileWriteOutOfSpaceError: return .failure(.outOfSpace)
        default: return .failure(.other)
        }
    }

    private static func classifyPOSIXCode(_ code: Int) -> Self {
        switch code {
        case Int(ENOENT): .absent
        case Int(ENOTDIR): .failure(.notDirectory)
        case Int(EISDIR): .failure(.isDirectory)
        case Int(EACCES), Int(EPERM): .failure(.permissionDenied)
        case Int(ENOSPC): .failure(.outOfSpace)
        default: .failure(.other)
        }
    }
}

actor PendingStudioPatchStore: PendingStudioPatchPersisting {
    private let fileURL: URL

    init(fileURL: URL? = nil, directory: URL = AppPersistence.directory) {
        if let fileURL {
            self.fileURL = fileURL
            return
        }
        self.fileURL = directory
            .appendingPathComponent("assistant-pending-studio-draft.json")
    }

    func load() async -> PendingStudioPatchLoadOutcome {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            switch PendingStudioPatchIOError.classify(error) {
            case .absent: return .absent
            case .failure(let failure): return .readFailed(failure)
            }
        }
        guard let draft = try? JSONDecoder().decode(StudioPatchDraft.self, from: data) else {
            return .malformedOrUnsupported
        }
        return .loaded(draft)
    }

    // Completion is API success, not fsync durability or current-file authority.
    func save(_ draft: StudioPatchDraft?) async -> PendingStudioPatchMutationOutcome {
        guard let draft else {
            return removeEntry()
        }
        guard let data = try? JSONEncoder().encode(draft) else { return .encodingFailed }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            return .directoryPreparationFailed(failure(error))
        }
        do {
            try data.write(to: fileURL, options: .atomic)
            return .writeCompleted
        } catch {
            return .mutationFailedEffectUnconfirmed(failure(error))
        }
    }

    private func removeEntry() -> PendingStudioPatchMutationOutcome {
        guard fileURL.isFileURL, !fileURL.path.contains("\0") else {
            return .mutationFailedEffectUnconfirmed(.other)
        }
        return fileURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return .mutationFailedEffectUnconfirmed(.other) }
            // One name, no application-level recursion; ancestors still resolve normally.
            guard Darwin.unlinkat(AT_FDCWD, path, 0) == 0 else {
                let code = errno
                if code == ENOENT { return .alreadyAbsent }
                return .mutationFailedEffectUnconfirmed(
                    failure(NSError(domain: NSPOSIXErrorDomain, code: Int(code))))
            }
            return .deleteCompleted
        }
    }

    private func failure(_ error: any Error) -> PendingStudioPatchIOFailure {
        switch PendingStudioPatchIOError.classify(error) {
        case .absent: .other
        case .failure(let failure): failure
        }
    }
}
