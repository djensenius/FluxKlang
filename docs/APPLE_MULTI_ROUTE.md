# Apple multi-route Studio requests

## Goal and acceptance example

A conversational routing request should be interpreted as a complete list of independent branches, not as the cross-product of every mentioned source, effect and destination.

Request:

> I want to use Osmose and Solar on mains, with Solar going through evil pet, and I'd like my OP-XY going out the desktop speakers.

Intended review:

```text
Osmose ----------------------> Mains
Solar ----> Evil Pet ---------> Mains
OP-XY -----------------------> configured Desktop/Desk Speakers
```

The Solar modifier refines Solar's mains path. It must not also create a raw Solar-to-mains branch, put Evil Pet on Osmose, send OP-XY to mains, or omit OP-XY. An ordinary “through” path means processed-only; an extra dry path needs an explicit request and must be shown in review.

## Understanding versus authority

Apple Foundation Models supplies completed, typed, **untrusted** branch intent from the current submission. It does not choose equipment IDs, connector numbers, OSC addresses or hardware writes. The prompt stays within the on-device budget and does not use conversation history or a full live-label inventory to fill missing topology.

Deterministic preparation then resolves every source, ordered effect chain and destination against the same app context. Unknown or ambiguous mentions, incomplete physical mappings, unclear referents, missing destinations, or unsupported mixed routing/fader actions must clarify the whole request. An accepted subset is not a successful interpretation.

A routing-owned request that is unavailable, malformed, incomplete or misclassified must not fall through to the older heuristic parser or a provider's flat draft tool and create a different draft. Ordinary Q&A and the existing reviewed instrument/fader actions remain separate.

## Names and physical mappings

- Source labels may identify existing saved equipment or a valid current-session live alias; names alone cannot create ports, cables or inventory entries.
- Effects require their configured physical devices and complete send/return mapping.
- Desktop/Desk Speakers aliases resolve only to a unique configured output group. Connector numbers come from configuration, never the language model or a hardcoded example.
- A modified speaker name must not accidentally match the generic word “speakers” and become mains.
- A changed destination mapping must be revalidated rather than silently accepting the old output pair under the same name.

## One review, separate Listen

All branches are prepared before the pending draft is changed. Rejected, cancelled or superseded preparation must leave any existing pending draft intact.

The existing Studio draft can represent the result using its primary route and `additionalRoutes`. Review and revalidation must retain every branch and every branch's physical validation. Custom destinations should show their actual output cable instructions. Append is the conservative default; replacement needs an explicit setup-level request, not the incidental word “only” in one branch.

Accepting a valid draft merges the complete semantic graph locally. It does not apply mixer settings, accept a fader action, or invoke Listen. **Listen remains the separate routing hardware-write action.** The natural-language Siri wiring entry point must use the same validated preparation path; Ask FluxKlang remains a composer handoff.

## Qualification checklist

- Real on-device Apple interpretation of the exact example, plus reordered clauses, shared destinations and source-specific modifiers.
- Exact three-branch topology and actual configured Desktop output pair through prepare → build → revalidate → local accept.
- No unintended effect sharing, Cartesian expansion, dry duplication or source omission.
- Unknown/duplicate gear, effects and output groups; missing effect sends/returns; stale aliases; changed configuration; ambiguous pronouns and effect order.
- Explicit serial, parallel and dry-plus-processed requests either represented faithfully or clarified atomically.
- Existing pending draft survives a rejected request. Cancellation or an old async response cannot publish a late draft.
- Apple unavailable/errors/invalid output cannot trigger heuristic/provider fallback mutation.
- Zero hardware SETs during interpretation, preparation, review and local acceptance; physical WING qualification remains a separate controlled operator task.

## Native qualification boundary (October 28, 2026)

Real on-device inference passed the exact example above and this shared-destination
variant through physical preparation, revalidation and local graph merge:

> Route Osmose and Solar to mains, with only Solar through evil pet, and route OP-XY to desktop speakers

The resulting graph had exactly three branches, four wires and the fixture's
configured Desk output pair. Separate final-action validation also passed
Astrolab-down and Mother-32-add-with-50%-fader-travel requests.

Latest routing inference captures were produced at `ffc72b4`; those exact typed
outputs also passed replay through the tightened validators at `4cab101`.
The Apple-actions branch passed both mono examples again at `4da308e`.
These are bounded, source-specific checks, not fresh inference at every later
integration commit.

Native paraphrase handling is **not fully qualified**. This reordered version
returned clarification rather than a draft:

> OP-XY going out the Desktop Speakers, with Solar going through Evil Pet, use Solar and Osmose on mains

Diagnostic output included a wrong Solar destination and omitted processing;
independent validation correctly rejected it. An additional prompt example did
not fix the reordered request and also caused the shared-destination check to
clarify, so that experiment was removed rather than weakening validation.
Use a clearer complete request or the Studio wiring form when clarification is
returned. Deterministic injected-intent tests do not establish native-model
reliability for every clause order, paraphrase, device or language.

Qualification used an on-device Mac model and isolated local fixtures, not a
physical iPhone, actual studio cabling or a live WING. No hardware writes or
physical audio behavior were qualified.
