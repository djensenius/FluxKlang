import Foundation

extension LegacySidecarPlan {
    /// Composes this plan with an adopted result into a new verified package, reading the result and never
    /// building one: the project and graph documents and their paths come from the result, every `.opaqueState`
    /// member of the result is carried in the result's file order (sorted by UTF-8 bytes), and the plan files
    /// follow. Project and graph documents are re-encoded canonically by the assembler. Sizes and the entry count
    /// are checked by the assembler against `policy`, which may be stricter than the limits the plan was made
    /// under; its refusal is reported as `assembly`. An empty plan re-assembles the result's own documents and
    /// opaque members.
    func extending(
        _ result: LegacyAdoptionResult, policy: ProjectPackageManifestPolicy
    ) throws(LegacySidecarRefusal) -> ProjectPackageContents {
        let contents = result.contents
        let manifest = contents.manifest
        let graphs = zip(manifest.graphs, result.documents.graphs).map {
            (path: $0.member.path, document: $1)
        }
        let carried = contents.files.filter { file in
            if case .opaqueState = file.role { return true }
            return false
        }
        do {
            return try ProjectPackageContents.make(
                project: (manifest.project.member.path, result.documents.project), graphs: graphs,
                extraFiles: carried + files, policy: policy
            )
        } catch {
            throw .assembly(error)
        }
    }
}
