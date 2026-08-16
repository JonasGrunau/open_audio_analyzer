# 00 — Scope

**Audit date:** 2026-08-15
**Subject:** Bel — free/open-source loudness and spectrum analyser (`open_music_analyzer`)
**Framework:** Dieter Rams' ten principles

## What was audited

**Whole app, all surfaces.** Specifically:

| Surface | Paths |
|---|---|
| Canvas and modules | `lib/src/canvas/`, `lib/src/modules/` (12 module kinds) |
| Shared UI primitives | `packages/bel_ui/lib/src/` (tokens, panel, module_frame, readout, scale) |
| Panels | `lib/src/panels/` (settings, presets, calibration editor, report, shortcuts) |
| App chrome | `lib/src/app/bel_app.dart`, `shortcuts.dart` |
| Remote display | `lib/src/remote/` |
| Domain vocabulary | `packages/bel_core/lib/src/` (metric, skin, layout, report) |
| Product copy | `README.md` |

**Excluded:** `engine/` C DSP internals (no user-facing surface), `cli/` (separate
interaction model, no visual design), `plugin/` (headless by definition).

## Primary user and task

**Both, weighted to monitoring.** Bel is a live meter first and a delivery
checker second. Scoring treats the canvas as a monitoring instrument — glanceable,
continuous, trustworthy at a distance — and the file-analysis flow as the
secondary path to a pass/fail delivery verdict.

## Constraints

- Flutter desktop/tablet; no web target, so web-specific weight metrics
  (JS bytes, network requests, TTI) do not apply and were replaced with the
  Flutter equivalents recorded in `01-evidence.md` §4.
- Palette is user-supplied at runtime (skins are JSON). Contrast was therefore
  measured against **both shipped skins**, not one.
- Licensing split constrains architecture, not design.

## Reference design

`process.audio` **Decibel** — Bel is a stated reimplementation of its ideas.
Relevant to principle #1 only.

## Method deviations (stated for honesty)

1. **No subagent fan-out.** This session is configured not to spawn subagents, so
   the orchestrator gathered all evidence directly. The contract that matters is
   unchanged: every finding in `01-evidence.md` carries a `file:line` citation,
   and nothing was scored without one.
2. **Source-only visual evidence**, by user instruction. Spacing, type, colour
   and state facts are read from source and computed, not screenshotted. Facts
   that could only be confirmed by running the app are marked **INFERRED**.
   Contrast ratios are *computed*, not inferred — they are exact.
3. **Working-tree state, not the session-start snapshot.** A second agent is
   working Phase 8 in this same tree; `HEAD` moved from `ef195a0` to `351b866`
   during the audit. All citations are against the working tree as read on
   2026-08-15. Line numbers may drift as that agent commits.
