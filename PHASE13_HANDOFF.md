# Phase 13 handoff -- matlabunittest

Read this if you're picking up after the Phase 12 work on 2026-05-06.

## TL;DR

**Phase 12 = fopen-lifecycle gate bypass + DOM fixture provider:
746 -> 857 Pass (+111) on removal_redaction_tool with Failed still 0.**

The autogen now handles, **generically across any MATLAB project**:
- Classes whose constructor opens a file via `fopen()` AND has a
  destructor calling `fclose()` (Phase 6's "stateful FileID lifecycle"
  detection).  The early-gate testSkipped_<name> short-circuit is
  dropped for these -- the constructor itself establishes the live
  handle, so methods can run normally.  Phase 11's stateful-smoke
  try/assumeFail wrap converts any synthetic-input-mismatch throws to
  Incomplete.
- Static and instance methods that take XML DOM args (`*DOM`,
  `*Document`, `dom`, `doc`, `xmlDoc`, `xmlNode` by name; org.w3c.dom.*
  / matlab.io.xml.dom.* by type).  A new `tempDOM(testCase)` helper
  builds an empty in-memory DOM, FixtureProvider returns it for
  DOM-named args, and the randomized layer's anyOpaque skip exempts
  DOM args so randomized fuzz tests can run too.
- A "fixture-driven smoke" wrap in TestWriter: any smoke / randomized
  call whose generated MATLAB source contains `tempDOM(testCase)` or
  `tempFileID(testCase)` is wrapped in try/`assumeFail`.  Exceptions
  thrown by project-side code paths that depend on real-world fixtures
  (e.g. ExcelXmlCleaner.cleanWorkbook calling RenameXML which fileread()s
  a non-existent unzippedExcel folder) report as Incomplete rather
  than Failed.

| | Phase 10 | Phase 11 | **Phase 12** |
|---|---:|---:|---:|
| Failed (removal_redaction_tool) | 0 | 0 | **0** |
| Passed (removal_redaction_tool) | 542 | 746 | **857** |
| Generated tests (removal_redaction_tool) | 622 | 842 | **911** |
| Incomplete (generated, removal_redaction_tool) | 80 | 96 | **54** |
| known_real_signal entries needed | 5 | 5 | **5** |
| Failed (matlabunittest/examples) | 0 | 0 | **0** |
| Passed (matlabunittest/examples) | 74 | 95 | **95** |

## Per-source breakdown (removal_redaction_tool)

|Source | Phase 11 | Phase 12 | delta |
|---|---|---|---|
| RedactionToolGUI.mlapp  | 37/38 |  37/38  |  unchanged |
| Classes/CellRefUtils.m  | 64/66 |  64/66  |  unchanged |
| Classes/ConsoleLogger.m | 54/54 |  54/54  |  unchanged |
| Classes/ExcelProcessor.m | 216/252 | 226/252 | +10 Pass |
| Classes/ExcelRemover.m  | 212/222 | 219/222 | +7 Pass |
| Classes/ExcelXmlCleaner.m | 100/115 | 109/115 | +9 Pass |
| Classes/ReportWriter.m  | 4/20  | **85/89**  | **+81 Pass** |
| Classes/TableMetadata.m | 5/16  |  5/16   |  unchanged |
| Classes/TextRedactor.m  | 54/59 |  58/59  | +4 Pass |

The ReportWriter jump is candidate 1 (fopen bypass).  The others are
candidate 2 (DOM fixture via FixtureProvider).  TableMetadata is the
only stateful class still flat -- its state-init pattern is via
`addTable`/`setColumnNames` (require args), so Phase 11's zero-arg
StateInitializer doesn't pick them up; future phases would need a
multi-arg fixture-aware prelude.

## Phase 12 implementation

### Candidate 1: fopen-lifecycle gate bypass (TestWriter.m)

In `appendFunctionMethods`, the early-gate condition that emits
`testSkipped_<name>` for stateful instance methods was extended to
ALSO drop the gate when the StatefulReason is purely fopen-related
(mentions `'fopen()'` but not `'leaves'`).  Mixed-case classes (both
container-empty AND fopen-lifecycle) still need a state-init prelude
on the container side, so the StateInitializer.candidateMethods check
remains.

### Candidate 2: DOM fixture provider (multiple files)

#### `+autotest/InputSampler.m` -- four new static methods

```matlab
function tf = isDOMName(argName)
    % '*DOM' / '*Document' / dom / doc / xmlDoc / xmlNode (case-sensitive
    % suffix to avoid false positives on `random`, `freedom`, `wisdom`).
end

function tf = isDOMType(t)
    % org.w3c.dom.* / matlab.io.xml.dom.* exact and prefix match.
end

function expr = domExpr()
    expr = 'autotest.InputSampler.tempDOM(testCase)';
end

function dom = tempDOM(testCase)
    factory = javax.xml.parsers.DocumentBuilderFactory.newInstance();
    builder = factory.newDocumentBuilder();
    dom = builder.newDocument();
    root = dom.createElement('root');
    dom.appendChild(root);
end
```

Note: an earlier attempt also wired DOM substitution into smokeFor /
edgeFor (per-arg override).  That caused tExcelRemover to hang the
test runner because methods like `removeColumn(tableDOM, 1, 1, 1, 1, 1, 1, 1)`
entered project-side code paths that don't terminate cleanly with
half-fixtured / half-synthetic args.  The smokeFor / edgeFor wiring
was reverted; DOM substitution now happens ONLY through the smartFor
path (FixtureProvider.literalForArg), which forces all-or-nothing
arg resolution.  See "What this approach intentionally does NOT do"
below.

#### `+autotest/FixtureProvider.m`

Added DOM substitution after the fileID block (before the stringy
name-only heuristics):

```matlab
if autotest.InputSampler.isDOMName(argName) ...
        || autotest.InputSampler.isDOMType(argInfo)
    expr = autotest.InputSampler.domExpr();
    return;
end
```

Plus a XML name handler for `tagName` / `elementName` / `attrName` /
`attributeName` / `nodeName` / `partName`:

```matlab
if stringyOrUnknown ...
        && (endsWith(lname, 'tagname') || endsWith(lname, 'elementname') ...)
    expr = '''a''';
    return;
end
```

#### `+autotest/TestWriter.m`

Two changes plus three Phase 12 follow-up wraps:

1. `randomArgsExpr` -- DOM-named/typed args get domExpr() instead of
   rand() / numeric.

2. `appendPropertyTestsForFcn` -- the anyOpaque skip exempts DOM args
   so DOM-only methods can run randomized.

3. `appendCallTest` non-edge branch -- the Phase 11 stateful-smoke wrap
   now also fires for fixture-driven smokes (callExpr contains
   `tempDOM(testCase)` or `tempFileID(testCase)`).

4. `appendPropertyTestsForFcn` randomized catch -- same fixture-driven
   wrap; non-validation throws on fixture-using random calls become
   `assumeFail` (Incomplete) instead of `rethrow` (Failed).

5. fopen-lifecycle gate condition (candidate 1, see above).

### Files changed in Phase 12

| File | Lines (Phase 11 -> Phase 12) | Bytes (Phase 11 -> Phase 12) | CRLF | bare-LF | NUL |
|---|---:|---:|---:|---:|---:|
| `+autotest/InputSampler.m` | 498 -> 579 (+81) | 23,409 -> 27,273 (+3,864) | 579 | 0 | 0 |
| `+autotest/TestWriter.m` | 1338 -> 1399 (+61) | 70,816 -> 74,894 (+4,078) | 1399 | 0 | 0 |
| `+autotest/FixtureProvider.m` | 378 -> 407 (+29) | 14,952 -> 17,105 (+2,153) | 407 | 0 | 0 |
| `PHASE13_HANDOFF.md` | NEW | NEW | n/a | 0 | 0 |

All edits applied via byte-level Python recipes in `/tmp/phase12_*.py`.
No project source touched.

## Verification (both targets, Failed = 0)

### removal_redaction_tool

```
Total tests:      1020
  passed:         857
  failed:         0
  incomplete:     163
Duration:         53.17 s

Per-source: all sources 0 failed.
  ExcelProcessor.m   (passed 226/252, failed 0)   <-- Phase 11: 216/252
  ExcelRemover.m     (passed 219/222, failed 0)   <-- Phase 11: 212/222
  ExcelXmlCleaner.m  (passed 109/115, failed 0)   <-- Phase 11: 100/115
  ReportWriter.m     (passed 85/89,  failed 0)    <-- Phase 11:   4/20  (!)
  TextRedactor.m     (passed 58/59,  failed 0)    <-- Phase 11:  54/59
```

### matlabunittest/examples (synthetic portability test)

```
Total tests:      114
  passed:         95
  failed:         0
  incomplete:     19
Duration:         6.50 s
```

Unchanged from Phase 11 -- expected, since examples/ has no
fopen-lifecycle classes and no DOM args.  Confirms the changes are
dormant when the patterns aren't present in a project.

## What this approach intentionally does NOT do

* **No DOM substitution in smokeFor/edgeFor (per-arg override).**  The
  initial Phase 12 attempt wired tempDOM substitution directly into
  the smoke/edge synthetic-input path, mirroring the fileID handling.
  That caused the runtime to enter a hang on tExcelRemover -- methods
  like `removeColumn(tableDOM, 1, 1, 1, 1, 1, 1, 1)` resolve some args
  from fixtures (DOM) and the rest from synthetic scalars (1), then
  the project-side method does e.g. `for j = 1:length(...)` over
  unexpected types and never terminates cleanly.  Phase 11's
  try/assumeFail wrap doesn't help because try/catch can't catch
  infinite loops.  Solution: DOM substitution happens ONLY through
  smartFor + FixtureProvider, which is all-or-nothing -- if any arg
  can't be resolved by FixtureProvider, the whole smartFor case is
  dropped and the synthetic path runs unchanged (no DOM substitution).
  The skipSynthetic gate in `appendFunctionMethods` then suppresses
  the synthetic smoke when smartFor succeeds, so we never have a
  half-fixtured smoke.
* **No multi-arg state-init detection.**  Phase 11's StateInitializer
  finds zero-arg methods only.  TableMetadata requires
  `addTable(name, sheetNumber, cellLocation)` with three args to
  populate state; the autogen has no way to synthesize sensible
  values for those.  Future phase candidate.

## Phase 13 candidates (all generic, no project-specific work)

Ranked by impact on Failed/Incomplete on arbitrary projects:

1. **Doc-example parser hardening.**  Multi-line examples with variable
   bindings still confuse the extractor (pre-Phase-10 `examples/writeReport.m`
   repro).  Effort: medium.  Reduction: project-dependent.

2. **Multi-arg state-init detection (TableMetadata pattern).**  Most
   stateful classes have a setter-style state-init: `addX(name, value)`,
   `setY(value)`.  A FixtureProvider-driven prelude that calls these
   with synthesised args would unblock the 11 Incomplete on
   TableMetadata in removal_redaction_tool.  Effort: high.

3. **CSV / table fixture provider.**  Methods that take `table` or
   `cell-of-cells` matrices typed as `cell`/`table` get either
   `{1, 2, 3}` (cell) or empty (table).  Real fixtures here would
   unblock spreadsheet utility classes broadly.  Effort: medium.

4. **DOM-substitute-in-smokeFor with safety check.**  Re-attempt the
   per-arg DOM substitution in smokeFor, but ONLY when ALL the
   non-DOM args can also be resolved (full-fixture path) -- else
   skip the smoke entirely instead of going half-fixtured.  Same
   net effect as the current smartFor-only approach but works without
   needing FixtureProvider patterns for non-DOM args.  Effort: low.

5. **Auto-generated CHANGELOG.md.**  Cosmetic.  Effort: low.

## Pitfalls (carried forward)

- **MATLAB regex line-continuation bug** (Phase 6): use `contains` over
  `regexp` when literal `\.` spans string-concat continuations.
- **Edit-tool truncation on TestWriter.m** (Phases 7+8+10+11): always
  use byte-level Python recipe via bash for non-trivial edits.  Verify
  `wc -l` and CRLF / bare-LF / NUL counts after every patch.
- **Screenshot mask by exe basename** (Phase 9): grant `MATLAB R2025b`
  AND `matlab.exe` (basename) to ensure the running window is visible.
- **Sandbox vs. Windows git index** (Phase 11): the Linux sandbox's
  `git status` shows wildly inaccurate output.  Use MATLAB
  `system('git ...')` for ALL git operations.
- **Half-fixtured smokes can hang the test runner** (Phase 12 lesson
  above).  When wiring a new fixture into smokeFor/edgeFor, ensure
  ALL args are resolvable -- partial-fixture calls into project code
  can hit non-terminating paths that try/catch can't unstick.

## Verification one-liners

```matlab
% removal_redaction_tool
close all force; delete(findall(0,'Type','figure')); clear classes;
run('C:\Users\Duy\OneDrive\Documents\MATLAB\removal_redaction_tool\run_autotest.m')
disp(fileread('C:\Users\Duy\OneDrive\Documents\MATLAB\removal_redaction_tool\_autotest\reports\summary.txt'))

% matlabunittest examples (portability test)
close all force; delete(findall(0,'Type','figure')); clear classes;
addpath('C:\Users\Duy\Projects\matlabunittest');
info = autotest.runWorkflow('C:\Users\Duy\Projects\matlabunittest\examples');
disp(info.Summary)
```

Both should report `failed: 0`.
