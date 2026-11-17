# Bounded CoreMIDI callback ingress

Part of #763 and #81, roadmap #48. Parent issues remain open. Source/pure-fixture and compile qualification only.

## Contract and deliberate overload change

The real read closure strongly captures a per-start `MIDICallbackIngress`. It attempts one strong atomic
compare-exchange before traversing borrowed packets. Overlap/reentry refuses the entire callback without waiting;
this is NOT the old `MIDIPacketDelivery` waiting-and-both-succeed contract (T16), which is retained unchanged.
Nothing asserts that Apple serializes callbacks or gives them a stable thread.

Each start preallocates 1,024 descriptors, 1 MiB bytes and 4,096 UInt16 lengths. A callback examines at most
1,024 entries, including empty entries, and copies at most 65,536 bytes. A 65,535-byte packet is preserved whole.
Contention, exhausted capacity and over-limit input drop the whole callback, never publish a prefix. Empty packets
are omitted, as before. Uncommitted scratch writes from a later refusal are inaccessible to the consumer.
The native cursor reads scalar fields from raw pointers and uses `MIDIPacketNext` for architecture alignment;
it never loads a fixed Swift packet/list value or materializes an Array.

## Publication and reclamation proof

1. Gate word: busy = 1, closed = 2. Acquire CAS 0 → 1 admits exactly one producer. Exit release-ANDs ~1;
   stop ORs 2, so neither a concurrent exit nor any later callback can reopen the session.
2. Producer A's ordinary cursor/storage writes precede its release. Producer B's successful acquire reads that
   release, transferring ALL producer state, including SPSCRing's ordinary `writeSlot` and refusal counter.
   This is the same release/acquire producer-role handover rationale documented in `FanInHandoff`, Ordering;
   it does not depend on Apple callback serialization. The unchanged ring's policy declares post-admission
   `.midiReceive`, maximum 1, `.verified`, never `.appOwned`. No kernel policy relaxation is needed.
3. Scratch bytes and lengths precede the ring's releasing tail store. The sole consumer's acquiring tail load
   makes both descriptor and payload readable. Descriptor pop releases only the ring slot, NOT payload capacity.
4. The producer's wrapping UInt64 committed byte, length and batch counts are compared with acquiring loads of
   consumer acknowledgements. All three include any popped-but-not-copied descriptor. The consumer releases each
   acknowledgement only after copying. Thus a producer observing reclamation cannot overwrite bytes still read.
   Distances never exceed their capacities; bounded distances use wrapping subtraction. Payload capacities are
   powers of two, so masking remains continuous across UInt64 wrap. The unchanged ring has independent slot cursors.
5. Busy/oversize/full refusals release-store gap=true. Immediately before nonempty publication the admitted
   producer acquire/release-exchanges it to false. Refusals before that exchange mark this descriptor; later ones
   remain for the next. Failed publication restores true. Empty callbacks never exchange the flag.
   Atomic/admission order, not physical arrival order, defines these boundaries.

## Consumer and lifetime

One main-actor driver task is created per input, before connecting. It drains at most 64 batches / 65,536 bytes
per turn; one popped descriptor can carry to the next turn without acknowledgement. Arrays are made only here.
The active 2 ms sleep is provisional, not a latency guarantee.

Inactive delivery suspends on a separate `MIDIConsumerWake`: an off-callback mutex protects active/finished flags
and at most one continuation, not a queue. Start takes/resumes that waiter; stop only deactivates the reusable task.
Cancellation/teardown finishes and releases the waiter. The task captures this wake state strongly and its owner
weakly; no strong owner spans either await. Repeated start/stop creates no new/cancelled driver tasks. Deinit finishes
the wake, cancels the one task and closes any session. Manual-turn and controlled waiter fixtures cover this path.

Source notifications only set the captured session's atomic dirty flag. Initial reconciliation remains synchronous;
later reconciliation precedes draining. The consumer rechecks session identity after reconciliation and every handler.
Stop closes admission and clears the active session, handler and pending descriptor before native disconnect/dispose.
Even reentrant stop prevents a subsequent handler invocation. Admitted old work can finish only into its own session.
Connection tokens, detach/rekey invalidation and controller generation guards are unchanged. An unknown-token batch
still applies its all-source gap reset before routing refuses it.

Strong callback/session ownership prevents use-after-free without treating dispose-return as callback quiescence.
There is no retired-session list. Platform retention may keep arbitrarily many old sessions alive, and the final
release may deallocate on a callback/platform thread: neither global memory bounds nor off-callback destruction
is qualified. Atomic machine progress, scheduler timing and realtime certification also remain unqualified.

## Evidence boundary

See `fault-latch-platform-callbacks.md` for the absence of an Apple self-serialization guarantee. SDK
`MIDIServices.h` documents variable-length packets and ARM alignment in `MIDIPacketNext`; no MIDI timestamp
conversion or protocol migration is added. Tests use synthetic borrowed buffers, not native CoreMIDI execution.
macOS/iOS adapter checks are compile-only. The inspected Swift callback/ingress bodies contain no heap-allocation
or ARC instructions, but the Objective-C block-entry thunks retain/release their closure context.
The entire native callback is not ARC-free.
Deterministic fixtures and mutants cannot prove weak-memory behavior;
the argument above requires independent review. Coordinator registration, audit and hosted CI remain separate gates.
