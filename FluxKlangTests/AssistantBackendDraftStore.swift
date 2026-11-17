#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

actor AssistantBackendDraftStore: PendingStudioPatchPersisting {
    var draft: StudioPatchDraft?
    func load() -> PendingStudioPatchLoadOutcome { draft.map { .loaded($0) } ?? .absent }
    func save(_ draft: StudioPatchDraft?) -> PendingStudioPatchMutationOutcome {
        self.draft = draft
        return draft == nil ? .deleteCompleted : .writeCompleted
    }
}
