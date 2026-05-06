# Phase 3 handoff — matlabunittest

Read this if you're picking up after the Phase 2 verification on 2026-05-05.

## TL;DR

- Phase 2.1 (HTML / GUI headline split), 2.2 (opaque-skip in randomized layer), 2.3 (skip synthetic smokes when realistic + stringy literal exists) are **applied, verified, and clean**.
- Headline went from `1125 / 970 / 136 / 153` (Phase 1) to `1041 / 936 / 78 / 103` (Phase 2). Total Failed dropped 43% (-58).
- One follow-up CSS fix landed this session: `.banner-info` and `.card-info` now have proper `--info`/`--info-bg` colors so the user-stub sub-banner and User stubs card render as styled blue rather than unstyled.
- DoD's `Failed < 30` is **not yet hit** — currently 78. Phase 2.4 is the only remaining lever and is gated on user choice between three options.
- No regressions: `tRedactionToolGUI` 36/38, `tCellRefUtils` 65/66 (the totals dropped because 2.3 suppressed noisy synthetic smokes; the *failure* count went 3 → 1), zero stranded figures.

See `<target>/_autotest/exports/triage.md` for the per-source breakdown.

## Phase 2.4 — needs user OK before implementing

The handoff explicitly says "discuss with user first." My recommendation, **subject to your sign-off**, is **Option 1 (SourceModel.IsStateful tag)**. It's the only option that actually moves the ~50 state-dependent ExcelProcessor failures to Incomplete and gets the headline below DoD's `Failed < 30`.

| Option | What it does | Failed delta | Pros | Cons |
|---|---|---|---|---|
| 1 — `SourceModel.IsStateful` tag | Parser flags classes whose ctor leaves required state empty; writer emits `testSkipped_*` for instance methods on stateful classes when smart-resolve fails. | -50 (target) | Deterministic, surfaces in the report as Incomplete with reason. | Heuristic — will mis-trigger sometimes; the worst case is "method gets reported Incomplete when it could have been auto-tested." |
| 2 — Extend `isOpaqueType` for stateful-class instance methods | When the class's properties include `dictionary` / `containers.Map` and the ctor assigns empties, treat any method on it as opaque-skip. | -50 | Smaller change, reuses an existing concept. | Mixes two concepts (opaque-typed argument vs stateful-class method) in one helper, which makes the helper harder to reason about later. |
| 3 — TODO comments pointing at `user_tests/` | Auto-generated `tExcelProcessor.m` has a comment at the top pointing the reader at `uExcelProcessor.m` for state-dependent flows; failures stay as Failed. | 0 | Closest to the original "scaffolding plus invariants" tool philosophy. | Doesn't move the headline; DoD `Failed < 30` stays unmet. |

**Implementation sketch for Option 1:**

In `+autotest/MFileParser.m`, after parsing a classdef, set `model.IsStateful = true` when:

1. The classdef has any property typed `dictionary`, `containers.Map`, or `struct`/`cell` with no default value, AND
2. The constructor body **assigns** those properties to empty/default values (`dictionary()`, `containers.Map()`, `struct()`, `{}`) rather than to populated ones.

In `+autotest/TestWriter.m::appendFunctionMethods`, when `obj.Model.IsStateful && ~isStaticMethod && isempty(smart)`, emit `testSkipped_<name>` (matching the existing 2.2 pattern) instead of the synthetic smokes.

**To proceed:** reply with "go with Option 1" (or 2/3) and I'll land it next session.

## What was applied this session (2026-05-05)

- Verified file integrity for `ReportRenderer.m` (1166 lines), `TestWriter.m` (972 lines), `autotestGUI.m` (183 lines). All CRLF, zero NULL bytes, proper `end`/`end`/`end` tail.
- Recreated `lf2crlf.py` helper (was missing in the new session).
- Ran `run_autotest.m` against `removal_redaction_tool` twice. Both runs completed cleanly in ~55–65 s with identical headline numbers.
- Patched `ReportRenderer.htmlStyles()` to add `--info: #1f6feb` and `--info-bg: #ddf4ff` to the `:root` block, plus `.banner-info { background: var(--info-bg); color: var(--info); }` and `.card-info .value { color: var(--info); }`. Verified the regenerated `report.html` has the rules and the file integrity is preserved (1168 lines, 55071 bytes, CRLF, 0 NULL bytes).
- Updated `<target>/_autotest/exports/triage.md` with the new per-source verdicts.

## Phase 3 — open question for you

Once 2.4 lands (assuming you OK Option 1), the next priority is up to you. Three reasonable directions:

1. **Push the failure count further down** with more `FixtureProvider` heuristics. The remaining ExcelRemover (5) / ExcelXmlCleaner (5) / TableMetadata (16) failures all stem from inputs that *should* be opaque-routed but the heuristic isn't matching them. Effort: medium. Payoff: another ~25 failures.
2. **`.mlapp` callback coverage improvements.** Currently 36/38 on `RedactionToolGUI`; the 2 fails are file-dialog flows the synthetic event struct can't satisfy. Could add a `MlappFixtureProvider` that recognizes file-dialog patterns and substitutes fake paths via `mockit`-style monkey-patching. Effort: high. Payoff: closes the last 2 mlapp fails plus prepares the writer for future apps.
3. **Tooling work** — coverage analysis (codeCoverage / unittest report integration), better user-stub generators (one stub per public symbol with type-aware skeleton assertions), CI hookup (GitHub Actions running `runtests` and parsing the JUnit XML). Effort: medium per item. Payoff: makes the tool useful in repos other than `removal_redaction_tool`.

Tell me which direction you want and I'll plan it next session.

## Pitfalls confirmed this session

- The first `request_access(["MATLAB R2025b"])` granted `c:\program files\matlab\r2025b\bin\matlab.exe` (the launcher), but the actual MATLAB GUI runs as `c:\program files\matlab\r2025b\bin\win64\matlab.exe` — that one wasn't in the allowlist and got masked in screenshots. Workaround: a second `request_access(["matlab.exe"])` matched the actual basename and brought it into scope. **For the next agent:** if MATLAB appears as "hidden process" in the screenshot note, request access by basename `matlab.exe` (resolves to `bin\win64\matlab.exe`).
- `mcp__computer-use__open_application` doesn't bring focus reliably from the desktop shell — clicking the desktop returns "frontmost shell" errors. Always issue `open_application` then `computer_batch` with click+type so the focus check fires once at batch start.
- The byte-level Python recipe (read raw, normalize CRLF→LF for matching, substitute, normalize LF→CRLF, write raw) was reliable for the small CSS patch this session. Keep using it for any non-trivial edit to `+autotest/` or `autotestGUI.m`.

## Quick command reference for next session

```matlab
close all force; delete(findall(0,'Type','figure')); clear classes;
run('C:\Users\Duy\OneDrive\Documents\MATLAB\removal_redaction_tool\run_autotest.m')
```

Status appears in `<target>\run_autotest_status.txt` (poll). Reports in `<target>\_autotest\reports\`. Triage in `<target>\_autotest\exports\triage.md`.
