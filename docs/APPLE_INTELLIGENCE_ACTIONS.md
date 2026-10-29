# Apple Intelligence instrument actions

## Intended experience

FluxKlang uses Apple's Foundation Models framework for **in-app, on-device understanding** of the current submitted request. App Intents provides the entry point from Siri. These are complementary integrations: Foundation Models is not an API for invoking Siri's system conversation engine, and a shortcut does not guarantee that Siri will recognize every arbitrary utterance without naming FluxKlang.

Examples to qualify:

- “Turn down the volume of my Astrolab.” Resolve the current instrument/channel, then show an explicit suggested decrease when the amount was omitted. A suggested 3 dB change is an app policy shown in review, not a number attributed to the user.
- “Add my Mother-32 and turn the volume to 50%.” Review adding a shortcut to the existing WING channel and changing that channel's existing fader. **50% means normalized fader travel**, not half loudness or half amplitude. Under the current fader law, 50% is approximately −10 dB; 0% is off and 75% is 0 dB.

## Separation of responsibilities

1. A tool-free Foundation Models session produces completed, typed intent data, not executable commands. It receives the current submission and bounded, untrusted live-name context; conversation history does not authorize actions.
2. Deterministic app code validates evidence, resolves current WING targets, obtains fresh identity/source/level observations, and prepares an immutable review.
3. Similar names and multiple candidates require selection. A saved equipment name or channel number alone is not proof of an attached instrument.
4. An explicit, single-use confirmation is the execution boundary. Changed identity, baseline, environment, session, layout, expiry, or cancellation invalidates the reviewed meaning rather than silently rebasing the operation.
5. The final transport send remains narrowly allowlisted, revocable and expiring. Neither model tools, Siri handoff, retry, history restoration nor a streamed model response may confirm a hardware action.

Apple Intelligence may be disabled, unavailable on a device, unready, or unable to interpret a request. Explain that honestly and offer supported deterministic/manual interaction. Do not silently substitute a cloud provider for Apple command interpretation. The existing choice of Q&A provider is separate.

## What “add” means

A live-channel shortcut references an **already-existing WING channel**. It is not new saved Equipment, an audio port, a cable, a routing endpoint or a newly allocated bus. Adding, moving or removing it must not change compiled routing settings, Home connections, Temporary Moves or hardware routing. It has no routable ports; malformed imported edges involving a shortcut must fail closed.

Persisted shortcut identity is inert display evidence. Restoring or syncing it does not restore authorization, prove a connection, or permit silently controlling the same channel number on a different console/session.

## Stereo and partial outcomes

Only an explicitly reviewed, currently verified, non-overlapping saved pair may be treated as a stereo unit. Similar L/R labels alone are candidates, not proof of pair membership. Otherwise ask the user to select individual channels.

For supported pairs, review each member's before/after level. Relative dB changes apply the same dB delta to both sides. Absolute fader-travel settings preserve the existing normalized-position balance and reject out-of-range results rather than clamping or silently rebalancing.

Local shortcut addition and UDP fader writes are **not atomic**. A local-first operation can leave a valid shortcut if hardware sending or confirmation fails. If a pair is partially sent or a readback is missing, report the exact confirmed/unconfirmed members. Never automatically retry, roll back hardware, or claim that a failed UDP send proves no effect occurred.

Physical routing requests remain the separate Studio draft review and Listen workflow. A reviewed fader action must not call Listen implicitly.

## Validation and manual qualification

Automated tests should use injected interpreters and recording transports for intent validation, ambiguity, stale identity, baseline changes, single-use confirmation, final-send cancellation, partial stereo results, history/Siri replay, graph-codec compatibility and routing/compiler invariants. Passing mock tests does not establish real model or hardware behavior.

Before release, qualify on an eligible device with Apple Intelligence enabled:

- Both example utterances and variations in capitalization, punctuation and similar instrument names.
- Generic questions, negation, quotations and hypothetical requests produce no actionable hardware confirmation by accident.
- Siri handoff opens FluxKlang for review and performs no SET or routing acceptance.
- Disabled/unready Apple Intelligence has a truthful fallback, with no silent external command interpretation.
- Duplicate names, changed scribbles/source patches, reconnects and expired reviews require renewed review.
- Mono and explicit stereo units show meaningful before/after values and truthful partial/unconfirmed results.

Use a controlled WING setup and deliberate operator approval for hardware qualification; development tests must not discover or mutate a real console implicitly.

## Apple API reference

- [Generating Swift data structures with guided generation](https://developer.apple.com/documentation/foundationmodels/generating-swift-data-structures-with-guided-generation): `@Generable`, `@Guide`, and `LanguageModelSession.respond(to:generating:)`. Structured generation constrains output shape, not factual correctness or execution authorization.
