# HIR-253 Gate 1: Raycast editability probe

This experiment checks the first decision gate for HIR-253: whether Raycast exposes a programmatically distinguishable outcome for editable vs. non-editable selected text.

## Safety boundary

Run this only on disposable, non-confidential, plain-text fixtures. The command pastes the exact selected string back into the current selection. Although the visible text should remain the same on an editable plain-text fixture, a paste can still affect rich-text formatting, so do not use formatted or production content.

The command never logs selected text, clipboard content, or replacement content. It logs only stage outcomes and a safe error type.

## Run

```bash
cd experiments/raycast-selected-text
npm install
npm run dev
```

Confirm that Raycast loads this checkout as a development extension, then invoke **Probe Editability Signal** from Raycast.

## Gate 1 procedure

Use paired controlled surfaces, starting with Slack and Meru where both are readily available:

1. **Editable surface**: enter a disposable plain-text fixture in the composer, select a substring, then run the command.
2. **Non-editable surface**: select text in a message body or other read-only selectable surface, then run the command.
3. Record the HUD/console outcome for each surface:
   - `selection: resolved | rejected`
   - `paste: resolved | rejected | not attempted`
4. Also record whether any visible mutation occurred. Do not copy the fixture text into the result record.

Expected structured log examples:

```json
{"probe":"editability","selection":"resolved","paste":"resolved"}
{"probe":"editability","selection":"resolved","paste":"rejected","errorType":"Error"}
```

## Decision rule

- If editable and non-editable surfaces produce the same programmatic outcome, or the only difference is visible to a human but not observable by the extension, Gate 1 is **FAIL** and the HIR-253 decision is `RAYCAST_NOT_SUFFICIENT`. Stop; do not proceed to the four-app replacement matrix.
- If a candidate discriminator exists, it must be repeatable, programmatically observable, and non-destructive on the non-editable case. Only then proceed to Gate 2/3 in the canonical HIR-253 Plan.

Current Raycast public API documentation does not document an explicit editability property: `getSelectedText()` reports selected-text acquisition, and `Clipboard.paste()` returns `Promise<void>` for the paste operation. Therefore this runtime probe is specifically testing whether a reliable observable failure distinction exists in practice.
