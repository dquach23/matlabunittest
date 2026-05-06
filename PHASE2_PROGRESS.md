# Phase 2 progress (in-flight)

This file documents the in-flight Phase 2 work as of 2026-05-04. Code changes
are applied but **not yet verified** by a MATLAB run — the access dialog
timed out repeatedly while the user was away. Resume with the verification
run before continuing.

## What's done

### 2.1 — Headline split through `report.html` and `autotestGUI` (CODE COMPLETE, UNVERIFIED)

`+autotest/ReportRenderer.m`:

- `collectViewModel` now reads `summary.GeneratedTotal/Passed/Failed/Incomplete`
  and `summary.UserStubTotal` when present, falling back to the legacy
  combined fields. The banner struct gains `StubText`, `GeneratedTotal`,
  `GeneratedPassed`, `GeneratedFailed`, `GeneratedIncomplete`,
  `UserStubTotal` so downstream writers can render the split.
- The HTML banner now reads "X of Y generated tests passed (F failed,
  I incomplete)" plus a separate `banner-info` sub-banner for the user
  stubs awaiting implementation.
- HTML summary cards changed: was `Total / Passed / Failed / Incomplete /
  Duration`, now `Generated / Passed / Failed / Incomplete / User stubs /
  Duration`. The `User stubs` card uses a new `card-info` class — if the
  existing CSS doesn't define it, it'll fall back to default card styling
  (the card renders, just without a custom color). Worth checking after
  the verification run; if it looks unstyled, add a rule in
  `htmlStyles()` for `.card-info`.
- Markdown header line: `Generated tests: %d total, %d passed, ...` plus
  a conditional `User-written test stubs awaiting implementation: %d`.
- `plainTextSummary` got the same generated/user-stub split.

`autotestGUI.m`:

- `showSummaryDialog` body sprintf reads `s.GeneratedTotal/Passed/Failed/
  Incomplete/UserStubTotal` (with `isfield` fallback), shows them as
  separate rows including `User stubs: %d (awaiting implementation)`.
- `headlineText` now reads "All %d generated tests passed" or
  "%d failed, %d incomplete (of %d generated)".

### 2.2 — Mirror opaque-skip into randomized property layer (CODE COMPLETE, UNVERIFIED)

`+autotest/TestWriter.m::appendPropertyTestsForFcn`:

- After the `if isempty(fcn.Inputs), return; end` guard, runs
  `typesFromArguments` and walks the inputs checking each via
  `InputSampler.isOpaqueType`. If every positional input is opaque (DOM
  nodes, dictionary, containers.Map, etc.), emits a single
  `testSkipped_random_<name>` `assumeFail`-based Incomplete placeholder
  and returns early.
- Existing randomized loop is unchanged for non-opaque inputs.

### 2.3 — Suppress synthetic smokes when realistic case + name-driven literal exists (CODE COMPLETE, UNVERIFIED)

`+autotest/TestWriter.m::appendFunctionMethods`:

- After the `for s = 1:numel(smart)` loop, before the synthetic-smokes
  loop, computes `skipSynthetic`: true iff `smart` is non-empty AND the
  FixtureProvider's `literalForArg` returns something different from
  `InputSampler.scalarFor(typed{k})` for at least one input. The
  synthetic `for s = 1:numel(smokes)` loop is now gated on
  `~skipSynthetic`.
- Net effect: for functions where the name-driven heuristic resolved
  (e.g. `message` → `'hello'`), only the realistic smoke test is emitted
  — the `_scalar/_vector/_matrix` variants that pass `1` and crash on
  `cellstr(1)` are gone.

### 2.5 — Surface real-signal CellRefUtils failures (PARTIAL)

The `testRandomized_isCellInRange` failure is already noted in
`<target>\_autotest\exports\triage.md` from Phase 1. Add to the next
handoff: `removal_redaction_tool/Classes/CellRefUtils.m::isCellInRange`
silently returns `false` for malformed range inputs that should throw.
Compare the validation pattern in `parseCellRange`. **Outside the
autogen tool's scope** — do this in the project under test, not here.

## What's deferred / blocked

### 2.4 — State-dependent failures to Incomplete (DEFERRED, NEEDS USER INPUT)

The handoff explicitly says "discuss with the user first." My
recommendation: **Option 1 (SourceModel.IsStateful tag)** is the only
option that actually moves the ~50 ExcelProcessor failures to Incomplete
and gets the headline below DoD's `Failed < 30`. Option 3 (TODO comments
pointing at `user_tests/u<Name>.m`) is closer to the original tool
philosophy but doesn't change counts.

**Implementation sketch for Option 1:**

In `+autotest/MFileParser.m`, after parsing a classdef, set
`model.IsStateful = true` when:

1. The classdef has any property typed `dictionary`, `containers.Map`,
   or `struct`/`cell` with no default value, AND
2. The constructor body **assigns** those properties to empty/default
   values (`dictionary()`, `containers.Map()`, `struct()`, `{}`) rather
   than to populated ones.

In `+autotest/TestWriter.m::appendFunctionMethods`, when
`obj.Model.IsStateful && ~isStaticMethod && isempty(smart)`, emit
`testSkipped_<name>` (matching the existing 2.2 pattern) instead of the
synthetic smokes.

Both heuristics will mis-trigger occasionally; that's fine — the worst
case is a method gets reported as Incomplete when it could have been
auto-tested. Better than the current state (Failed when it could have
been Incomplete with a clear reason).

### Verification run (BLOCKED)

`request_access(["MATLAB R2025b"])` timed out three times in this
session. Once the dialog is approved, run:

```matlab
close all force; delete(findall(0,'Type','figure')); clear classes;
run('C:\Users\Duy\OneDrive\Documents\MATLAB\removal_redaction_tool\run_autotest.m')
```

Then poll `C:\Users\Duy\OneDrive\Documents\MATLAB\removal_redaction_tool\run_autotest_status.txt` for completion (~60s typical) and check:

- `_autotest\reports\summary.txt` — verify Generated/UserStub split
  numbers are sensible.
- `_autotest\reports\report.html` — verify the new banner reads
  "X of Y generated tests passed", the user-stub sub-banner appears,
  and the `User stubs` card renders.
- MATLAB Command Window — check for any MATLAB syntax/parse errors
  in `ReportRenderer.m`, `TestWriter.m`, or `autotestGUI.m` introduced
  by the byte-level Python edits.

Expected counts after 2.2 + 2.3 (without 2.4):

- Failed should drop from 136 to roughly **45–60** (the ~85 generator-
  overreach failures should clear; the ~50 state-dependent ExcelProcessor
  failures remain until 2.4 is decided).
- Total Incomplete should *go up* by roughly the same amount the
  randomized opaque-skip and synthetic-smoke-skip suppressed, since
  the new `testSkipped_*` placeholders count as Incomplete.

## File-tool truncation notes (for the next agent)

The Edit and Write tools silently truncated files multiple times during
this session — same byte count as pre-edit, but content shifted and
last several dozen lines lost. Two recoveries were needed:

1. `+autotest/ReportRenderer.m` — rebuilt the missing tail (formatDuration
   body, iif, getf, truncate, safeDelete, writeFile, fileUri, closing
   ends). The `fileUri` helper had to be reconstructed from scratch since
   no prior version was available; review the implementation at the
   bottom of the file for correctness.
2. `autotestGUI.m` — rebuilt the missing `openOutputFolder` body and
   `hasDisplay` function.

**Always verify after editing files in `+autotest/`:**

```bash
f=/sessions/.../mnt/matlabunittest/+autotest/<file>.m
wc -l -c "$f"
tail -3 "$f"          # must be `        end` / `    end` / `end`
tr -cd '\000' < "$f" | wc -c   # must be 0
file "$f"             # must report CRLF
```

The byte-level Python recipe (read raw, normalize CRLF→LF for matching,
substitute, normalize LF→CRLF, write raw) was reliable across all four
2.1/2.2/2.3 edits. Prefer that over Edit/Write for any non-trivial
change to `+autotest/` or `autotestGUI.m`.

The `lf2crlf.py` helper at `/sessions/.../mnt/outputs/lf2crlf.py` was
recreated this session.
