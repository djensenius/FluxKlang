#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

actor AssistantBackendDraftStore: PendingStudioPatchPersisting {
    var draft: StudioPatchDraft?
    func load() -> StudioPatchDraft? { draft }
    func save(_ draft: StudioPatchDraft?) { self.draft = draft }
}
