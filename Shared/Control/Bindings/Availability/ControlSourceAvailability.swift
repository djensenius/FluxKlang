/// Which bindings have their controller listed as live. A pure join of each binding's source id (read with
/// `ControlFeedbackMIDI1SourceParser`) and a set of origins the caller says are live. It reads no registry, device or
/// endpoint, keeps no state, never changes a pickup state and refuses no single binding. Only `ControlInputBank`
/// uses it, to read `maximumLiveOrigins`; nothing calls `project` yet.
/// `project(bindings:liveOrigins:)` is declared in `ControlSourceAvailabilityReport.swift`, beside the types it builds.
enum ControlSourceAvailability {
    static let maximumBindings = ControlBindingLimit.maximumBindings
    static let maximumLiveOrigins = 128
}
