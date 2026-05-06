# Phase 5 handoff — matlabunittest

Read this if you're picking up after the Phase 3 work on 2026-05-05.
Pick a Phase 5+ direction at the bottom before starting any new work.

## TL;DR

- Phase 3 (Option 1 + Option 2 + a small detectStateful loosening for
  TableMetadata) is **applied, verified, and clean** on
  `removal_redaction_tool`.
- Total Failed: 51 → **25**.  The user's `< 30` target is **met**.
- ExcelRemover: 5 → **0** ✅ (Option 1 widening killed the residual
  randomized failures).
- ExcelXmlCleaner: 5 → **1** ✅ (one residual edge case; details below).
- TableMetadata: 16 → **0** ✅ (extended `detectStateful` to recognise
  *untyped* properties whose ctor RHS is `dictionary[*]` /
  `containers.Map[*]` / `struct[*]`).
- RedactionToolGUI: 36/38 → **37/38** (the 1 residual is
  `testCallback_sheetStatusChanged`, which crashes inside
  `CellRefUtils.isCellInRange` — real signal in the project under test,
  not a test-generation issue).
- ExcelProcessor: stays at **1** failure (Phase 2.4 baseline preserved).
- ReportWriter: **11** failures, unchanged — still depends on `FileID`
  from `fopen()`, which Phase 2.4/Phase 3 detection deliberately doesn't
  catch.  Top candidate for Phase 6 work.
- TextRedactor: **8** failures, unchanged — DOM-arg + regex-arg methods
  that need a different fixture story (next-tier work).
- Stranded figures: **0** ✅.

See `<target>/_autotest/exports/triage.md` for the per-source breakdown.

## What was implemented

### Option 1 — `isOpaqueType` widening (+ randomized any-opaque gate)

1. **`+autotest/InputSampler.m::isOpaqueType`** — extended the
   case-insensitive endsWith list to cover Excel / XML DOM / App
   Designer noun families and added an exact-match list for
   plural-container argument names (only fires when the declared type
   is empty / `double`, so a typed `Tables (1,1) string` arg wouldn't
   match):
   - Suffix added: `dom`, `doms`, `node`, `element`, `xmldoc`, `sheet`,
     `sheets`, `worksheet`, `workbook`, `doc`.
   - Exact-match added: `tables`, `data`, `relationships`, `ridmap`,
     `sheetmap`, `cache`, `lookup`, `map`, `maps`.
2. **`+autotest/TestWriter.m::appendPropertyTestsForFcn`** — flipped
   the randomized opaque gate from "ALL inputs opaque" to "ANY input
   opaque".  The Phase 2.2 all-opaque rule left tests live where one
   arg was a string (e.g. `tableName`) and another was a DOM/dictionary
   — `rand(1, randi(5))` only needs to hit the latter to crash.  The
   anyOpaque gate emits the existing `testSkipped_random_<name>`
   placeholder with the existing reason text.

### Option 2 — `.mlapp` file-dialog callback shimming

3. **`+autotest/MlappFixtureProvider.m`** *(new)* — static-method class
   with two responsibilities:
   - `detectInBody(bodyText)` / `detectForCallback(srcText, name)`
     scan a callback's body for references to `uigetfile` /
     `uiputfile` / `uigetdir` (line comments masked, then `\<name\(`).
   - `DialogFunctions` constant lists the three dialog names and is
     used as the default fallback list.
4. **`+autotest/SourceModel.m`** — added `UsesFileDialog` (logical) and
   `DialogFunctions` (cell) fields to both `emptyCallback()` (the
   `{}`-ed type-shape struct) and `makeCallback()` (the
   default-populated factory).  Backwards-compatible — existing readers
   either ignore the fields or `isfield`-gate.
5. **`+autotest/MlappParser.m::parse`** — after building
   `model.Callbacks`, scan `srcM` (the unzipped classdef text) once
   per callback via `MlappFixtureProvider.detectForCallback` and tag
   each callback with the dialogs it calls.  `identifyCallbacks` is
   unchanged otherwise; the new fields stay at their defaults from
   `makeCallback` until parse() overwrites them.
6. **`+autotest/TestWriter.m::appendCallbackTest`** — when
   `cb.UsesFileDialog`, emit a `testCase.installFileDialogStubs({...})`
   call before the try/catch around the callback invocation.  The
   catch block also softens for these callbacks: a downstream throw
   is acceptable (we can't synthesize a real file at the path the
   callback expects), but app-destruction is still fail.
7. **`+autotest/TestWriter.m::appendHelpers`** — inlined three new
   private helpers in every generated tXxx.m so the test class stays
   self-contained (no runtime `+autotest` dependency):
   - `installFileDialogStubs(testCase, dialogs)` — creates a
     `tempname()` directory, writes `uigetfile.m`/`uiputfile.m`/
     `uigetdir.m` shims that return canned values
     (`'synthetic.xlsx'`, `tempdir()`, `1` — or just `tempdir()` for
     `uigetdir`), addpath's the directory (default `-begin` so the
     shims shadow toolbox built-ins), and registers two teardowns:
     `removeFileDialogStubPath` (rmpath + rehash) and
     `removeFileDialogStubDir` (rmdir).  Teardown order is correct
     by construction — register-rmdir-first → register-rmpath-second
     → LIFO invokes rmpath first, then rmdir.
   - `removeFileDialogStubPath(stubDir)` — best-effort `rmpath` +
     `rehash path`, swallows errors.
   - `removeFileDialogStubDir(stubDir)` — best-effort `rmdir(d, 's')`,
     swallows errors.

### detectStateful loosening (TableMetadata fix)

8. **`+autotest/MFileParser.m::detectStateful`** — extended the
   ctor-empty-init detection to ALSO accept untyped properties when
   the ctor RHS is one of the explicit named-container constructors
   (`dictionary`, `dictionary()`, `dictionary("k", ...)`,
   `containers.Map`, `containers.Map()`, `struct`, `struct()`).  Raw
   `{}` / `[]` RHS still requires a declared `cell` / `struct` type —
   those forms are too generic to stand alone (could be any list /
   numeric matrix).  ExcelProcessor's typed-property branch is
   preserved unchanged, so its 1-failure baseline is untouched.
9. **`+autotest/MFileParser.m::isNamedContainerEmpty`** *(new helper)*
   — alongside `isContainerEmpty`; returns true only for the explicit
   named-container forms above.  Sibling to `isContainerEmpty` and
   used only by the loosened path in `detectStateful`.

## Why three changes, not just two

The user prompt asked for Option 1 + Option 2.  After each was applied
the actual run on `removal_redaction_tool` showed:

| Change | Total Failed |
|---|---:|
| Phase 2.4 baseline | 51 |
| Option 1 (isOpaqueType widening only) | 50 |
| Option 1 + any-opaque randomized gate | 41 |
| Option 1 + Option 2 + any-opaque gate | 41 |
| + detectStateful loosening (TableMetadata) | **25** |

Option 1's name-list widening alone barely moved the needle (50 vs 51).
The big drop came from flipping the randomized layer's opaque gate from
"all" to "any", which the user spec hinted at in step 4 ("Optional
extension — have the randomized layer try the FixtureProvider first").
I implemented the simpler version — when ANY input is opaque, skip
randomized entirely — because it's strictly simpler and gets the same
result (rand-arg crashes a single DOM/dictionary input).

TableMetadata's 16 → 0 drop required loosening `detectStateful`.  This
was Deviation 2 from PHASE4_HANDOFF.md (Phase 2.4 deliberately required
typed properties to avoid over-flagging TableMetadata).  In Phase 3 the
user explicitly wanted TableMetadata flagged.  The new gate is
narrower than the original "any container-empty assignment" — it only
fires for explicit named-container constructors, NOT raw `{}`/`[]`,
which keeps the false-positive risk low.

## Files touched (verified clean)

| File | Lines | Bytes | CRLF | NULL |
|---|---:|---:|---:|---:|
| `+autotest/InputSampler.m` | 342 | 15,361 | all | 0 |
| `+autotest/TestWriter.m` | 1,107 | 57,981 | all | 0 |
| `+autotest/MlappParser.m` | 215 | 8,688 | all | 0 |
| `+autotest/MFileParser.m` | 783 | 33,866 | all | 0 |
| `+autotest/SourceModel.m` | 88 | 3,406 | all | 0 |
| `+autotest/MlappFixtureProvider.m` *(new)* | 88 | 4,390 | all | 0 |

All six end with the proper `end` / `end` / `end` tail.  All edits used
the byte-level Python recipe (read raw → CRLF→LF for matching → replace
→ LF→CRLF → write raw).

## Definition-of-Done status

- **Total Failed below 30** ✅ — actual count is **25**.
- **ExcelRemover failures: 5 → 0 or 1** ✅ — actual is **0**.
- **ExcelXmlCleaner failures: 5 → 0 or 1** ✅ — actual is **1**.
- **TableMetadata failures: 16 → ≤ 5** ✅ — actual is **0**.
- **RedactionToolGUI: 36/38 → 38/38** ⚠️ — actual is **37/38**.  The
  residual is `testCallback_sheetStatusChanged`, which crashes inside
  `CellRefUtils.isCellInRange` (`MATLAB:nonLogicalConditional` —
  the same real-signal bug that's been failing
  `tCellRefUtils/testRandomized_isCellInRange` since Phase 1).
  Fixing the project-under-test's `isCellInRange` would close both.
  No file-dialog callback fails remain — the dialog shims work.
- **ExcelProcessor: stays at 1 failure** ✅.
- **`tCellRefUtils`, `tConsoleLogger` unchanged** ✅.
- **Zero stranded figures** ✅.
- **report.html shows the new opaque-skip Incompletes / Phase 2.2
  reason text** ✅ — 14 mentions of "randomized skipped: opaque-typed
  input" (was ~6 in Phase 2.4); 31 mentions of "stateful class" (20
  ExcelProcessor + 11 TableMetadata).

## Pitfalls confirmed this session

- **The Phase 2.2 randomized gate was too narrow.**  `allOpaque` was a
  conservative read of the spec but empirically wrong: a single
  opaque arg crashes `rand(1, randi(5))`.  Flipping to `anyOpaque` was
  necessary to actually hit the < 30 target.  Burned ~15 minutes
  thinking the widening hadn't worked when in reality it was emitting
  the right `testSkipped_*` entries but the randomized layer was still
  emitting `testRandomized_*` crashes alongside them.
- **MATLAB JUnit XML uses `<error>` for thrown exceptions and
  `<failure>` for `verifyX` failures.**  The summary.txt's per-source
  "failed" count appears to mix both, but report.html and downstream
  parsers may distinguish.  When in doubt, use the bash recipe in this
  doc (`re.finditer + <testcase ...>...<failure|<error...</testcase>`).
- **JUnit XML's `name` attribute on `<testcase>` is the per-method
  test name (good).  Empty Error ID + `<failure>` element usually means
  a `verifyTrue`/`verifyClass` failure.**  The first regex pass treated
  these inconsistently; the recipe in the verification block is
  correct.
- **`detectStateful` deliberately uses two RHS predicates.**
  `isContainerEmpty` is the broad one (includes `{}` / `[]`) used for
  the typed branch.  `isNamedContainerEmpty` is the narrow one
  (`dictionary*` / `containers.Map*` / `struct*` only) used for the
  untyped branch.  Don't merge them — the typed branch needs to fire
  for typed cell properties initialised with `{}` (which is the
  ExcelProcessor case), but the untyped branch must not fire for
  generic `[]` (which would over-flag random numeric properties).

## Phase 6 — needs user OK before starting

The user prompt asked for likely candidates if Option 1 + Option 2
finished.  Three are most actionable now:

1. **Extend `detectStateful` for `fopen()`-style state-init**
   (PHASE4_HANDOFF.md option 4).  ReportWriter has 11 failures, all
   under `Error in ReportWriter (line 36)` (constructor) or
   `writeCustomLine` / `createCenteredHeader` (methods that need the
   `fopen()`'d FileID alive).  Detection rule: ctor body ends in an
   `obj.X = fopen(...)` assignment AND the property's declared type
   is `double` / unspecified.  Risk: more over-flagging.  Mitigation:
   *also* require that the class destructor (delete()) calls fclose
   on the same property, which is the `fopen() / fclose()` lifecycle
   signature.  **Effort:** medium.  **Failed reduction:** 8-11.
2. **Tooling work — coverage analysis + CI hookup.**  No failure-count
   reduction; meta value.  CI hookup would consume `results.xml` and
   gate PR merges on regression.  Coverage analysis would surface
   which methods of the project under test are *actually exercised*
   beyond just "doesn't throw."  **Effort:** medium per item.
   **Failed reduction:** 0.
3. **TextRedactor (8) deeper fix.**  The 8 failures split between
   `redactText` (4) and `writeRedactedWordsToReport` (3) and
   `cleanupPunctuation` (1).  The first group fails inside `regexp`
   because the input `originalText` arg is `[]` or numeric (edge
   tests).  The second group fails on a closed FileID.  Could be
   split: regexp-on-non-string is a real signal (the project's
   methods don't validate inputs), and the FileID issue is the same
   pattern as ReportWriter (item 1).  **Effort:** low (regexp arg
   validation is one-line in the project).  **Failed reduction:** 5+.

**My recommendation:** option 1.  It's the only single move that
hits another big chunk (ReportWriter's 11) and parallels the
TableMetadata loosening that worked this session — same
"detection-rule extension" pattern.

**To proceed:** reply with "go with option N" and I'll plan it next
session.  Don't start Phase 6 without your OK.

## Skill saved for future projects

The byte-level CRLF-preserving patch recipe used throughout these
phases (read raw → CRLF→LF for matching → substitute → LF→CRLF →
write raw) was packaged into `/tmp/patch_*.py` scripts per session.
Worth promoting to a reusable skill for future Windows-edited MATLAB
or any-language CRLF projects.  The pattern is: any time
`Edit`/`Write` could damage CRLFs by mismatching them with the actual
file bytes, pre-normalize to LF in memory, do the substitution against
LF text, re-CRLF-encode on write.  Stale `/tmp/patch_*.py` files from
prior sessions can have wrong-uid permissions — always use a unique
suffix per session (`_p3v3.py`, `_v2.py`, etc.).

## Quick command reference

```matlab
% Full workflow
close all force; delete(findall(0,'Type','figure')); clear classes;
run('C:\Users\Duy\OneDrive\Documents\MATLAB\removal_redaction_tool\run_autotest.m')

% Verify the new isNamedContainerEmpty branch on TableMetadata
clear classes;
m = autotest.MFileParser('C:\Users\Duy\OneDrive\Documents\MATLAB\removal_redaction_tool\Classes\TableMetadata.m').parse();
fprintf('IsStateful=%d Reason=[%s]\n', m.IsStateful, m.StatefulReason);
% Expected: IsStateful=1
%   Reason=[stateful class -- ctor leaves Tables, Data, Relationships empty;
%           method requires populated state]

% Verify file-dialog detection for an .mlapp callback
clear classes;
mlp = autotest.MlappParser('C:\Users\Duy\OneDrive\Documents\MATLAB\removal_redaction_tool\RedactionToolGUI.mlapp');
m = mlp.parse();
for k = 1:numel(m.Callbacks)
    if m.Callbacks(k).UsesFileDialog
        fprintf('  %s -> %s\n', m.Callbacks(k).Name, ...
            strjoin(m.Callbacks(k).DialogFunctions, ', '));
    end
end

% Inspect the new shim helpers in a generated test class
type('C:\Users\Duy\OneDrive\Documents\MATLAB\removal_redaction_tool\_autotest\generated\tRedactionToolGUI.m')

% Verify dropoff in report.html
fid = fopen('C:\Users\Duy\OneDrive\Documents\MATLAB\removal_redaction_tool\_autotest\reports\report.html','r');
html = fread(fid,'*char').'; fclose(fid);
fprintf('opaque-skip mentions: %d\n', numel(strfind(html, 'randomized skipped: opaque-typed input')));
fprintf('stateful mentions:    %d\n', numel(strfind(html, 'stateful class')));
```
