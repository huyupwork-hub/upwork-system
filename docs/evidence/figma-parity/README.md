# Figma parity pass — render evidence

Screens that were actually looked at before the pass was called done, not a
list of what the tests assert.

## Mobile — `apps/mobile/tool/render/goldens/`

Sixteen screens rendered from the real widget trees at 390×844 @2x with the
SDK's Roboto and the Cupertino glyph font registered, so the text and icons are
the ones the app draws.

    cd apps/mobile
    flutter test --update-goldens tool/render/capture_test.dart

Not a CI gate: `flutter test` with no path runs `test/` only. A golden that
fails a build on an antialiasing difference teaches a team to delete goldens.

This is not on-device QA and does not stand in for it. Touch targets, keyboard
insets, scroll physics, platform fonts and real photo bytes are unverified for
this pass — the handset used for the offline slice was disconnected before it
started.

## Admin — `admin/`

Captured from `next dev` signed in as the published demo reviewer, via headless
Chrome. Live data, so these are a point-in-time snapshot rather than a
reproducible fixture — including the `SMOKE … do-not-keep` rows the hosted
smoke test writes into the demo project on every CI run.

| file | screen |
| --- | --- |
| `a1-signin.png` | sign-in |
| `a2-queue.png` | submitted queue, populated |
| `a3-no-matches.png` | search with no results |
| `a5-search-hit.png` | search with results |
| `a4-detail.png` | one inspection, with both dependency notes |

## What looking found that the tests did not

- `UnsyncedPill` used without its import — the mobile app did not compile.
- A fabricated `Template` value presented as a field of the record.
- `Requires a contractor2019s work-order integration` — a curly apostrophe that
  lost its backslash and shipped as four digits, under an assertion that only
  matched the prefix before it.
- Two controls doing one job each, twice: Sign Out, and add-a-finding.
- An error screen that was a bare `Exception: …`.
