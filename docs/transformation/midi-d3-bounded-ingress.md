# Bounded CoreMIDI callback ingress

Part of #763, #777 and #81, roadmap #48. Parent issues remain open. Source/pure-fixture and compile qualification only.

## Contract and deliberate overload change

The real read closure strongly captures a per-start `MIDICallbackIngress`. It attempts one strong atomic
compare-exchange before traversing borrowed packets. Overlap/reentry refuses the entire callback without waiting;
this is NOT the old `MIDIPacketDelivery` waiting-and-both-succeed contract (T16), which is retained unchanged.
Nothing asserts that Apple serializes callbacks or gives them a stable thread.

Each start preallocates 1,024 descriptors, 1 MiB bytes and 4,096 UInt16 lengths. A callback examines at most
1,024 entries, including empty entries, and copies at most 65,536 bytes. A legacy 65,535-byte packet is preserved whole.
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

## Opt-in MIDI 1.0 UMP input

The existing LCXL settings picker persists `inputBackend` in version-1 `launch-control-xl.json`. Legacy bytes
remain default, including missing/null/unknown-string selections; wrong types and required fields still fail
decoding. Experimental selection reaches `MIDIInputPortCreateWithProtocol(._1_0)` through the existing factory
and reusable input/consumer. Both APIs remain behind the production isolation/audit gate. Old byte-only input
implementations forward only legacy starts; unsupported experimental selection reports no sources.

The session format is immutable. Payload copying still uses the same descriptor/storage/gate proof above.
Only the consumer constructs owned UInt32 words, before releasing acknowledgements. `MIDIPacketBatch.payload`
distinguishes bytes from MIDI1 UMP; its compatibility `packets` accessor/setter is checked bytes-only.
The raw event cursor follows the SDK's four-byte-packed layout, using unaligned scalar loads and actual word
counts, not the words[64] template. At most 16,383 words (65,532 bytes) fit one packet; 65,532+4 bytes fit one
callback but 65,532+8 do not. Count/protocol validity is checked under admission, including after next(), so
even a later invalid header cannot publish copied scratch. There is no received allocation extent: valid
borrowed native memory is a platform precondition, not something these limits validate.

Each effective registry Source owns MP1 with its parser/performance state. Resolved sources are independent;
unresolved and registry-full routes share the existing legacy pair. Each event packet is framed whole before
decoding one UMP at a time into a value candidate. Typed malformed/wire/feed-size refusal publishes no outputs
and commits no candidate state; the LCXL caller then resets that effective pair. Nonfatal MP1 unsupported,
protocol, orphan and foreign-group skips retain their old semantics. System Reset follows the source profile,
interleaved before the next UMP. Logical SysEx spans callbacks, but a multiword UMP cannot span event packets.
The experimental splitter's 16,383-word bound survives all resets; MP1's default remains 4,096.

Backend/mode changes invalidate the generation and pending actions before old stop, restart before awaiting
persistence, and check each queued action's generation before reporting/dispatching it. Already-dispatched async
actions cannot be undone. Old callbacks/reports drop; unexpected payload formats reset all sources and drop.
Non-SysEx groups merge; simultaneous SysEx groups are not independent. Automatic protocol conversion does not
establish legacy receive-group equivalence, hardware behavior or MIDI2 fidelity: all remain unqualified.

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
Connection tokens and detach/rekey invalidation are retained. An unknown-token batch
still applies its all-source gap reset before routing refuses it.

Strong callback/session ownership prevents use-after-free without treating dispose-return as callback quiescence.
There is no retired-session list. Platform retention may keep arbitrarily many old sessions alive, and the final
release may deallocate on a callback/platform thread: neither global memory bounds nor off-callback destruction
is qualified. Atomic machine progress, scheduler timing and realtime certification also remain unqualified.

## Evidence boundary

See `fault-latch-platform-callbacks.md` for the absence of an Apple self-serialization guarantee. SDK
`MIDIServices.h` documents variable-length packets and ARM alignment in `MIDIPacketNext`; event structs at
448–528 and `MIDIEventPacketNext` at 2600–2605 establish the UMP cursor layout. No timestamp conversion is added.
Tests use synthetic borrowed buffers, not native CoreMIDI execution.
macOS/iOS adapter checks are compile-only. The inspected Swift callback/ingress bodies contain no heap-allocation
or ARC instructions, but the Objective-C block-entry thunks retain/release their closure context.
The entire native callback is not ARC-free.
Deterministic fixtures and mutants cannot prove weak-memory behavior;
the argument above requires independent review. Coordinator registration, audit and hosted CI remain separate gates.

The #777 worker's source-faithful selective mirror passed 191 tests in four suites in clean Debug and Release,
including the retained D3/LCXL/registry/MP1 regressions and 22 new test functions. The new adapter extensions cover
selection/persistence/awaits, raw ingress bounds and typed ownership, and source-paired transactions/lifetimes.
Ten focused mirror-only mutants failed, then canonical copies were restored and compared. macOS/iOS adapter
typechecks and optimized inspection of seven Swift callback/ingress/storage/ring bodies passed; no device callback
ran. SettingsContentView was source/lint reviewed only: its AppModel-dependent full compile remains a hosted gate.
