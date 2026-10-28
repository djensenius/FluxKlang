# Apple instrument actions — qualification record (2026-10-28)

Qualified source revision: `3b2b418bec34b16e2a2d1e741dd84e6a5a7ff981` on `feat/apple-intelligence-actions` (subsequent qualification-document edits do not change app code).

## Passed

- Integrated iOS app and test-target compilation.
- Full iOS unit suite: **367 tests in 48 suites**, passing on the final source revision.
- macOS arm64 app build.
- Full-repository strict SwiftLint and whitespace checks.
- Six reviewed-action UI scenarios on an owned iPhone simulator: candidate selection and suggested amount, stereo before/after and hardware-confirmation target, expired review, inert restored card, partial per-member result, and stable consumed review with cancellation/double-tap protection.
- Existing three UI acceptance scenarios and portrait/landscape composer scenario.
- Keyboard-visible primary navigation: passed in a final isolated simulator run (109.388 s).
- Independent reviews closed for Apple interpretation/chat/Siri, target resolution/graph invariants, review UI, and guarded mono/stereo execution.

## Real Apple model check

`SystemLanguageModel.default.availability` reported `available` on the development Mac. A standalone harness compiled the **unchanged production interpretation contract, Foundation Models adapter and output validator**, with external app/transport dependencies stubbed. It made real on-device model requests and did not connect to a WING.

Final observed results:

| Current request | Validated interpretation |
| --- | --- |
| `turn down the volume of my Astrolab` | proposal; target `Astrolab`; lower; amount omitted; no addition |
| `add my mother-32 and turn the volume to 50%` | proposal; target `mother-32`; set fader travel to 50%; add shortcut |
| `What does 50% volume mean?` | answer; no action plan |
| `Don't turn down my Astrolab` | answer; no action plan |
| Mother-32 request with 64 observations in the app-side input | same combined proposal; the model prompt intentionally omits observation rows |

An earlier guided schema compiled but threw `UnsupportedGuide` at runtime. The final implementation uses a runtime-qualified conditional generable schema, bounded current text, completed structured output, greedy sampling, deterministic non-action guards, and independent intent validation. Passing these examples is not a guarantee of correct interpretation of every paraphrase.

## Failure history and residual risks

- The first integrated unit run exposed incorrect new test identifiers (`channel-7` versus production `ch-7`); those fixtures/selectors were corrected without weakening outcome assertions.
- The first UI run exposed a confirmation button whose accessible target was only 34 pt; its minimum 44 pt hit region now belongs to the button label.
- One subsequent full unit run hit the pre-existing demo paced-apply verification test; final full-suite runs passed without changing that test or its verification timing.
- In a combined UI run, the existing keyboard-navigation test timed out waiting for an iOS simulator app-animation completion notification. The other ten selected UI scenarios passed. The same final-source navigation scenario passed in an isolated owned-simulator run. This simulator/idleness flake is not claimed to be eliminated.

## Not qualified here

- Siri voice invocation on a signed physical iPhone, or arbitrary global Siri utterance discovery. The new **Ask FluxKlang** App Intent stages the request in the composer; Send and explicit action confirmation remain required.
- Apple model behavior on a physical iPhone or across every supported language/device/model state.
- Physical WING peer formatting, reply timing, real stereo echoes, wireless packet loss, cable/instrument presence, or hardware outcome. Recording transports cover these execution invariants, but controlled operator-approved hardware qualification is still required.

No real WING changes, remote publication, release, or merge was performed.

Durable local logs and exported UI attachments: `$HOME/.local/state/FluxKlang/apple-actions-20261028/`. Xcode result bundles under the temporary DerivedData location may be automatically pruned; logs preserve the run summaries.
