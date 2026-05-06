# Phase 2 handoff — matlabunittest

Read this first if you're picking up where Phase 1 left off.

## Working directories

| What | Path |
|---|---|
| Tool source (this repo) | `C:\Users\Duy\Projects\matlabunittest` |
| Test target project | `C:\Users\Duy\OneDrive\Documents\MATLAB\removal_redaction_tool` |
| Generated output (per run) | `<target>\_autotest\` |
| Reports (refreshed each run) | `<target>\_autotest\reports\report.{html,md,pdf}` + `summary.txt`, `results.{xml,tap}` |
| Triage doc (latest verdicts) | `<target>\_autotest\exports\triage.md` |
| Run launcher | `<target>\run_autotest.m` |
| Run status (overwritten each run) | `<target>\run_autotest_status.txt` |

The earlier `PHASE1_HANDOFF.md` documents the architecture and parser fragility; that context still applies. Read it for the parser/writer/runner split before editing.

## Phase 1 result

Last verified run on the redaction tool, after Phase 1.1–1.5:

```
Generated tests: 1125  passed: 970  failed: 136  incomplete: 153
User stub tests: 109   (all Incomplete by design)
Total tests:     1234  passed: 970  failed: 136  incomplete: 262
Duration:        57.7 s
```

Per-source breakdown (from `_autotest\reports\summary.txt`):

```
[gen] RedactionToolGUI.mlapp   (passed 36/38, failed  2)
[gen] Classes\CellRefUtils.m   (passed 72/75, failed  3)
[gen] Classes\ConsoleLogger.m  (passed 86/94, failed  8)
[gen] Classes\ExcelProcessor.m (passed 219/278, failed 54)
[gen] Classes\ExcelRemover.m   (passed 212/222, failed  5)
[gen] Classes\ExcelXmlCleaner.m(passed 100/115, failed  8)
[gen] Classes\ReportWriter.m   (passed 95/110, failed 15)
[gen] Classes\TableMetadata.m  (passed 73/101, failed 28)
[gen] Classes\TextRedactor.m   (passed 76/91, failed 13)
```

Baseline before Phase 1 was `1251 / 493 / 80 / 756`. Passes nearly doubled (493 → 970). Failures went up (80 → 136) because constructors now succeed and methods that were previously stuck at "constructor threw" can now be exercised — many of those reveal genuine "this method needs state from a real workbook" expectations. The triage at `_autotest\exports\triage.md` classifies each remaining failure as **generator overreach** (writer/sampler bug, fix in this repo) vs **real signal** (the test is right; the project under test or a hand-written `user_tests/u<Name>.m` should respond).

## What was shipped in Phase 1

- **`+autotest/FixtureProvider.m`** — relaxed type strictness (treat the default-`double` placeholder as "no type info" so name-driven heuristics still fire), added heuristics for:
  - `textArea` / `uifigure` / `parent` → `uitextarea(uifigure('Visible','off'))` / `uifigure('Visible','off')`
  - `message` / `msg` / `text` / `title` / `caption` / `label` / `header` / `string` / `str` / `word` → `'hello'`
  - `unzipDir` / `stagingDir` / `tempDir` / `workdir` → `tempname()`
  - `reportPath` / `reportFile` / `outputPath` / `outputFile` / `logPath` / `logFile` / `filePath` → `tempname()` (matched **before** the xlsx-fixture path heuristic so a writer's output doesn't accidentally get the read-only `toolTester.xlsx`)
  - existing heuristics (`cellref`, `pattern`, `classif`, sheet/table/column names, keep/dirty lists, xlsx fixtures) preserved.
- **`+autotest/InputSampler.m`** — added `isOpaqueType(t, argName)` that recognises:
  - exact type tokens: `containers.Map`, `dictionary`, `matlab.io.xml.dom.*`, `org.w3c.dom.*`, `org.apache.xerces.*`, `matlab.io.matfile`
  - prefixes: `org.w3c.dom.`, `matlab.io.xml.`, `org.apache.`, `java.`, `matlab.ui.`
  - name-suffix when the declared type is the default-`double`: `*DOM`, `*Node`, `*Element`
  - name-contains: `sharedstrings`, `cellsbyrow`, `colwidths`, `lookupmap`, `rid_to_target`, `lookupmaps`, `tablemetadata`
  - **Important:** `smokeFor` early-returns empty when any positional input is opaque. `edgeFor` does NOT — edge tests `try/catch` the call and pass on either return-value or thrown-error, so opaque args don't break edges (they just throw, which is fine).
- **`+autotest/TestWriter.m`** —
  - `appendClassTests` now resolves the constructor signature via `InputSampler.smartFor(ctor.Inputs, ctor.ArgumentBlocks, helpText, provider)` and uses the resolved arg list as the body of `constructInstance`. Falls back to a no-arg call when smart returns empty.
  - `appendFunctionMethods` emits a single `testSkipped_<name>` Incomplete marker (via `assumeFail('… smoke skipped: opaque-typed input')`) when both the smart layer and the synthetic smokeFor came up empty AND inputs is non-empty. The function still appears in the report — it just shows as Incomplete with a clear reason rather than missing entirely.
  - Smoke branch in `appendCallTest` dropped `verifyNotEmpty(out, ...)`. Returning `[]` for a realistic input is a valid "nothing to do" outcome (e.g. `redactSharedStrings` with no matches); `assertReasonable` still rejects all-NaN numeric output, which is the actual suspicious signal.
- **`+autotest/runWorkflow.m`** — `runGeneratedTests` now filters results by name prefix (`u<Name>/userTest_*` → user stub, everything else → generated) and returns a summary struct with `GeneratedTotal/Passed/Failed/Incomplete` and `UserStubTotal/Incomplete` in addition to the legacy combined counts. `writeSummary` renders a "Generated tests" block and a "User stub tests" block above the legacy "Total tests" line.

## Definition of Done — Phase 1 status

| Criterion | Status |
|---|---|
| All four ctor-blocked classes show non-zero Passed | **✅** ConsoleLogger 86, ExcelProcessor 219, ReportWriter 95, TextRedactor 76 (up from 0 across the board) |
| Total Failed below 20 | **❌** Currently 136. Triage doc lays out the path to <30 (the two remaining writer suppressions plus moving state-dependent ExcelProcessor failures to "skipped"). |
| Headline split: generated vs user-stub | **✅ in `summary.txt`** — `Generated tests: 1125 / 970 / 136 / 153` and `User stub tests: 109 (all Incomplete by design)` are separate sections. **`report.html`/`report.md`/`autotestGUI` summary dialog still show the old combined headline** — `ReportRenderer.m` and `autotestGUI.m` weren't updated yet. Phase 2 task. |
| No regressions on tCellRefUtils / tRedactionToolGUI | **✅** tCellRefUtils 72/75 (baseline 71/74; +1 from the new realistic case), tRedactionToolGUI 36/38 unchanged, zero stranded figures (verified via the `closeLeakedFigures` cleanup hook). |

## Phase 2 work plan

### 2.1 Plumb the headline split through `report.html` / `autotestGUI`

**Goal:** finish what Phase 1.5 started — `summary.txt` shows the split, but the HTML report and the GUI dialog still read the legacy combined fields.

**Where:**
- `+autotest/ReportRenderer.m` — the renderer reads `info.Summary.Total/Passed/Failed/Incomplete`. Update the headline render to prefer `Generated*` fields when present, and add a "user-written test stubs awaiting implementation" badge using `UserStubTotal`.
- `autotestGUI.m` — the summary dialog at the end of `runWorkflow` does the same. Same fix.

The new fields are already in the summary struct (`runGeneratedTests` populates them); just rebind the renderer.

**Verify:** open `_autotest/reports/report.html` after a run; the header should read like "Status: 970 of 1125 generated tests passed (136 failed, 153 incomplete). 109 user-written test stubs await implementation." instead of the old combined "1234 / 970 / 136 / 262".

### 2.2 Mirror the opaque-skip into the randomized property layer

**Goal:** drop ~60 failures by suppressing `testRandomized_<name>` for methods whose every input is opaque-typed. Right now `appendPropertyTestsForFcn` is unconditional; it generates `for trial = 1:25; out = method(rand(1, randi(5))); end` for methods that take DOM nodes, which always throws.

**Where:**
- `+autotest/TestWriter.m`, function `appendPropertyTestsForFcn`. Mirror the smart/smoke pre-check: if every positional input is opaque (use `InputSampler.isOpaqueType` + `InputSampler.typesFromArguments`), skip emission entirely, OR emit a single `testSkipped_random_<name>` Incomplete placeholder for parity with the smoke skip.
- The randomized layer doesn't currently consult the `FixtureProvider`, so even resolving the constructor doesn't help here.

**Verify:** ExcelRemover failures should drop from 5 → 0; ExcelXmlCleaner from 8 → 0; ExcelProcessor from 54 → ~30 (only the state-dependent ones remain); TableMetadata from 28 → ~10.

### 2.3 Skip synthetic smokes when a 'realistic' case exists

**Goal:** stop emitting `testSmoke_<fn>_scalar/vector/matrix` when the FixtureProvider resolved a realistic case AND any input is name-routable to a string literal. The synthetic variants pass `1` for `message` and crash on `cellstr(1)`; the realistic variant passes `'hello'` and works.

**Where:**
- `+autotest/TestWriter.m`, `appendFunctionMethods`. After the `smart` loop, if `~isempty(smart)` and any input name matched the FixtureProvider's "stringy" heuristic, skip the `for s = 1:numel(smokes)` loop. Either pass a flag from FixtureProvider indicating "I matched a name-only heuristic" or detect the override by re-running `provider.literalForArg` on each input and seeing whether the resolved literal differs from `scalarFor(typed{k})`.

**Verify:** ConsoleLogger fails drop from 8 → ~3 (only `testRandomized_info`/`testRandomized_output` remain — those need 2.2). ReportWriter fails drop from 15 → ~5.

### 2.4 Move state-dependent failures to Incomplete

**Goal:** `ExcelProcessor` has ~50 methods that legitimately fail when called on a freshly-constructed instance whose `unzipDir` is `tempname()` (no real workbook to read). These aren't generator bugs — they're "you can't call this without `loadAllDOMs()` first." Mark them as Incomplete with a clear reason rather than Failed so the headline reflects what's actually broken vs what's "not yet wired."

**Options (pick one):**
1. **Tag the class as "stateful"** in the model (`SourceModel.IsStateful = true` when the constructor stores state but doesn't populate it, e.g. when the ctor calls `dictionary()` or `struct()` with no args). Then in `appendFunctionMethods` for instance methods of stateful classes, if the smart layer didn't resolve, emit `testSkipped_*` instead of synthetic smokes.
2. **Extend `isOpaqueType` to recognize stateful-class instance methods** — when the class's properties include `dictionary` / `containers.Map` and the ctor body assigns empty versions of them, treat any method on it as smoke-skip.
3. **Move responsibility to user_tests/** — emit a TODO comment in the auto-generated `tExcelProcessor.m` pointing to `uExcelProcessor.m` for state-dependent flows, and accept the failures as documentation of "needs user assertion." This is closest to the original tool philosophy ("scaffolding plus invariants, not tests that know your spec").

Option 3 with a clearer marker is probably the right call — but discuss with the user first.

### 2.5 Address the two real-signal failures in `tCellRefUtils`

**Goal:** `testRandomized_isCellInRange` fails consistently. The triage doc flags this as "real signal — the function should throw cleanly on invalid range inputs but instead silently returns `false` for some malformed inputs." Outside the autogen tool's scope, but worth surfacing in the next handoff.

**Where:** `removal_redaction_tool/Classes/CellRefUtils.m`, method `isCellInRange`. Compare to `parseCellRange` for the right validation pattern.

## Pitfalls discovered in Phase 1

- **File-tool truncation.** The `Edit` and `Write` tools repeatedly truncated files at the same byte count as the pre-edit version, leaving the tail filled with NULL bytes or chopped mid-line. The Read tool sometimes showed the truncated view, sometimes the cached pre-truncation view, depending on whether the file system cache had refreshed. **Defensive recipe:** after every `Edit`/`Write` on a file in `+autotest/`, run `wc -l -c` and `tail -3` via bash. If the byte count is suspiciously identical to pre-edit OR `tail` shows mid-line truncation, restore by writing the full file via bash heredoc to `/tmp/` and `cp` it into place. The `lf2crlf.py` helper at `/sessions/.../mnt/outputs/lf2crlf.py` (or recreate from PHASE1_HANDOFF.md) restores CRLF.
- **CRLF line endings still mandatory** — see PHASE1_HANDOFF.md.
- **`clear classes` between runs** — see PHASE1_HANDOFF.md. Already in the `run_autotest.m` invocation pattern.
- **MATLAB R2025b focus drops** — `open_application` brings the existing window forward but the desktop shell sometimes regrabs focus before the next click. Use `computer_batch` for click-then-type sequences so the focus check fires once. **Don't** spawn new MATLAB instances; bring the existing one forward.
- **The two methods (Static) blocks in TestWriter.m** — the file structure is `methods (Access = private) … end / methods (Static) … end`. When you regenerate the file via heredoc, count `end`s carefully: each function needs one, each `methods` block needs one, the classdef needs one. A missing `end` in the middle produces "Illegal use of reserved keyword 'methods'" pointing at the `methods (Static)` line.

## How to verify your starting state

Run these in order on session start:

1. Read `CLAUDE.md`, `PHASE1_HANDOFF.md`, this file, and `<target>/_autotest/exports/triage.md`.
2. Verify file integrity for the files Phase 1 touched. Expected sizes (approximate):

   ```
   FixtureProvider.m  ~15 KB / ~370 lines
   InputSampler.m     ~14 KB / ~320 lines
   TestWriter.m       ~46 KB / ~915 lines
   runWorkflow.m      ~22 KB / ~540 lines
   ReportRenderer.m   ~52 KB (unchanged from Phase 1 start)
   autotestGUI.m       ~5 KB (unchanged from Phase 1 start)
   ```

   Any file dramatically smaller is truncated and needs restoration.
3. Open `<target>\_autotest\reports\report.html` and `<target>\_autotest\reports\summary.txt` to see the last run's state. If stale, run the launcher to get a fresh baseline before editing.
4. For Phase 2 changes, use this iteration loop in MATLAB:

   ```matlab
   close all force; delete(findall(0,'Type','figure')); clear classes;
   run('C:\Users\Duy\OneDrive\Documents\MATLAB\removal_redaction_tool\run_autotest.m')
   ```

   Status appears in `<target>\run_autotest_status.txt` (poll via Read) and reports in `<target>\_autotest\reports\`.

## Definition of done for Phase 2

- Total `Failed` count is below 30 (down from 136). The triage doc's "generator overreach" verdicts (~85 failures across 2.2 + 2.3) should resolve cleanly; the ~50 state-dependent ExcelProcessor failures should move to Incomplete via 2.4.
- `report.html` and `autotestGUI` summary dialog show the generated-only headline with the user-stub badge separately.
- Triage doc updated with new verdicts after the run.
- No regressions: `tCellRefUtils` still passes 72/75, `tRedactionToolGUI` still passes 36/38, the workflow still leaves zero figures stranded after exit.
