//
//  PeerRetryPolicy.swift
//  FluxKlang
//
//  Which commands may be retried after the remote lost certainty about them (#97). The classes are total
//  and closed: the classification is an exhaustive `switch` with no `default`, so a new `CommandOperation`
//  case does not compile until it is classified. Only the two parameter writers may be offered again, and
//  only as a FRESH intent (a new command ID, built by the caller) after `PeerIntentRevalidator` accepted
//  them against the current session. Nothing is ever replayed or relabelled. Triggers, transport, structural
//  changes, safety commands and drafts never retry.
//

enum PeerRetryClass: Hashable, Sendable {
    /// The command is dropped, never offered again.
    case never
    /// A fresh intent may replace it, only after revalidation against the current session and state.
    case freshIntentOnly
}

enum PeerRetryPolicy {
    static func classify(_ operation: CommandOperation) -> PeerRetryClass {
        switch operation {
        case .set, .ramp:
            .freshIntentOnly
        case .bind, .recall, .trigger, .start, .stop, .locate, .panic, .safeMute, .propose, .editDraft:
            .never
        }
    }
}
