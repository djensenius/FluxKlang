import Foundation

protocol PendingStudioPatchPersisting: Sendable {
    func load() async -> StudioPatchDraft?
    func save(_ draft: StudioPatchDraft?) async
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

    func load() async -> StudioPatchDraft? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(StudioPatchDraft.self, from: data)
    }

    func save(_ draft: StudioPatchDraft?) async {
        guard let draft else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        guard let data = try? JSONEncoder().encode(draft) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }
}
