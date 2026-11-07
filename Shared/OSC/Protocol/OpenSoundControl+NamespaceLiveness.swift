//
//  OpenSoundControl+NamespaceLiveness.swift
//  FluxKlang
//
//  The compile-time-exhaustive live-only guard of the neutral OSC namespace
//  (#89, slice O2a). Adding a `CommandOperation` case breaks this build until
//  the case is classified here.
//

extension OpenSoundControl {
    /// Classifies every `CommandOperation` as reachable from the namespace (live) or not.
    /// It classifies by case, not by `controlClass`: `set` and `ramp` have no class of their own
    /// because the catalog descriptor supplies it, and `RouteTable` only routes live descriptors.
    enum NamespaceLiveness {
        static func isLive(_ operation: CommandOperation) -> Bool {
            switch operation {
            case .set, .ramp, .trigger, .start, .stop, .locate: true
            case .bind, .recall, .panic, .safeMute, .propose, .editDraft: false
            }
        }
    }
}
