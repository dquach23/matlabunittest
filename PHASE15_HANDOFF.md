# Phase 15 handoff -- matlabunittest

Read this if you're picking up after the Phase 14 work on 2026-05-06.

## TL;DR

**Phase 14 = constructor-graph fixture (unzipped Excel) plus typed
table/cell fixture provider.  Failed still 0 on both targets;
Pass count unchanged at 934 on removal_redaction_tool and 95 on
matlabunittest/examples.**

The autogen now handles, **generically across any MATLAB project**:

- Classes whose constructor takes a path-like staging directory AND
  the project supplies a primary `.xlsx` fixture.  Phase 14 unzips
  that workbook into a temp directory at TestMethodSetup time and
  hands the path to the constructor, so any zero-arg sibling
  populator (`loadAllDOMs`, `buildLookupMaps`, etc.) detected by
  Phase 11's StateInitializer actually populates the instance state
  instead of silently no-opping inside the prelude's try/catch.
  ExcelProcessor is the canonical example: its constructor now
  receives a real unzipped Excel directory and its DomCache /
  SheetMap / RIdToTarget dictionaries are live for downstream tests.
- Methods whose `arguments` block declares an arg as `table` or
  `cell` get a small synthetic table or 2-D cell-of-cells matrix
  rather than the InputSampler defaults (`1` and `{1}`).  Gated on
  `argInfo.IsExplicit`, so the heuristic is dormant when no
  `arguments` block is present (the bulk of MATLAB classdef methods
  in the wild) -- callers who type their args explicitly opt in.

| | Phase 12 | Phase 13 | **Phase 14** |
|---|---:|---:|---:|
| Failed (removal_redaction_tool) | 0 | 0 | **0** |
| Passed (removal_redaction_tool) | 857 | 934 | **934** |
| Generated tests (removal_redaction_tool) | 911 | 976 | **976** |
| Incomplete (generated, removal_redaction_tool) | 54 | 42 | **42** |
| known_real_signal entries needed | 5 | 5 | **5** |
| Failed (matlabunittest/examples) | 0 | 0 | **0** |
| Passed (matlabunittest/examples) | 95 | 95 | **95** |

## Per-source breakdown (removal_redaction_tool)

| Source | Phase 13 | Phase 14 | delta |
|---|---|---|---|
| RedactionToolGUI.mlapp  | 37/38 |  37/38  |  unchanged |
| Classes/CellRefUtils.m  | 64/66 |  64/66  |  unchanged |
| Classes/ConsoleLogger.m | 54/54 |  54/54  |  unchanged |
| Classes/ExcelProcessor.m | 226/252 | 226/252 | unchanged |
| Classes/ExcelRemover.m  | 219/222 | 219/222 | unchanged |
| Classes/ExcelXmlCleaner.m | 109/115 | 109/115 | unchanged |
| Classes/ReportWriter.m  | 86/87 |  86/87  | unchanged |
| Classes/TableMetadata.m | 81/83 |  81/83  | unchanged |
| Classes/TextRedactor.m  | 58/59 |  58/59  | unchanged |

The Pass count did not move on this target.  That's expected and is
worth understanding before the next phase: ExcelProcessor's
constructor now genuinely receives a real unzipped Excel directory
(verified by inspecting the regenerated `tExcelProcessor.m` --
constructInstance now reads `ExcelProcessor(autotest.InputSampler.tempUnzippedExcel(testCase, '...toolTester.xlsx'))`),
and the prelude's `loadAllDOMs()` / `buildLookupMaps()` calls now
populate `DomCache`, `SheetMap`, and `RIdToTarget` for real.  But
every smoke / randomized / edge test on this stateful class is
already wrapped in a Phase 11 `try / assumeFail` so any throw from
`removeSheet('Sheet')` (synthetic input that doesn't match the real
sheet names in `toolTester.xlsx`) becomes Incomplete rather than
Failed.  The architectural improvement is real; flipping those
Incomplete back to Pass requires either (a) a smarter synthetic
input layer that knows about the actual sheet names in the live
fixture or (b) dropping the `try / assumeFail` wrap when a real
fixture is verified to have populated state -- both deferred to
Phase 15+.

Candidate 3 (table / cell fixtures) is dormant on this target: no
method in `removal_redaction_tool` declares an `arguments` block
typing an input as `table` or `cell` (8 `arguments` blocks total
across `Classes/CellRefUtils.m` and `Classes/TableMetadata.m`,
none of them use `table` or `cell`).

## Phase 14 implementation

### Candidate 1: unzipped-Excel staging fixture

#### `+autotest/InputSampler.m` -- two new public Static methods

```matlab
function dirPath = tempUnzippedExcel(testCase, sourceXlsx)
    % Create a tempdir, unzip sourceXlsx into it, register the
    % cleanup teardown, return the dirPath.  Falls back to a bare
    % tempname() when the source file is missing or unreadable so
    % the prelude's try/catch path continues to short-circuit cleanly.
end

function cleanupTempDir(dirPath)
    % Best-effort recursive removal of a tempdir registered by
    % tempUnzippedExcel.
end
```

#### `+autotest/FixtureProvider.m` -- one new heuristic

In `literalForArg`, before the existing `tempname()` branch for
unzip / staging / tempdir / workdir args:

```matlab
if stringyOrUnknown ...
        && ~isempty(obj.PrimaryExcel) ...
        && (contains(lname, 'unzip') ...
            || contains(lname, 'stagingdir'))
    expr = sprintf( ...
        'autotest.InputSampler.tempUnzippedExcel(testCase, %s)', ...
        obj.charLiteral(obj.PrimaryExcel));
    return;
end
```

Detection is purely name-based and gated on `obj.PrimaryExcel` being
non-empty.  Projects with no `.xlsx` fall through to the bare
`tempname()` path used previously, so the heuristic is dormant on
non-Excel projects (verified on `matlabunittest/examples`).

### Candidate 3: typed table / cell fixtures

#### `+autotest/FixtureProvider.m` -- one new gated branch

In `literalForArg`, after the DOM block:

```matlab
if isfield(argInfo, 'IsExplicit') && argInfo.IsExplicit
    if strcmp(ltype, 'table')
        expr = 'table([1;2;3], ["a";"b";"c"], ''VariableNames'', {''N'', ''S''})';
        return;
    end
    if strcmp(ltype, 'cell')
        expr = '{1, ''a''; 2, ''b''}';
        return;
    end
end
```

Gated on `argInfo.IsExplicit` so the branch only fires when the
source declared the type via an `arguments` block.  Default-double
fall-through (every untyped arg) is unaffected.

### Files changed in Phase 14

| File | Lines (Phase 13 -> Phase 14) | Bytes (Phase 13 -> Phase 14) | CRLF | bare-LF | NUL |
|---|---:|---:|---:|---:|---:|
| `+autotest/FixtureProvider.m` | 428 -> 474 (+46) | 18,496 -> 21,026 (+2,530) | 474 | 0 | 0 |
| `+autotest/InputSampler.m` | 579 -> 629 (+50) | 27,273 -> 29,520 (+2,247) | 629 | 0 | 0 |
| `CHANGELOG.md` | updated | n/a | n/a | 0 | 0 |
| `PHASE15_HANDOFF.md` | NEW | NEW | n/a | 0 | 0 |

All edits applied via byte-level Python recipes in
`/tmp/phase14_*.py`.  No project source touched.  CRLF /
bare-LF / NUL counts verified clean after every patch.

## Verification (both targets, Failed = 0)

### removal_redaction_tool

```
Total tests:      1085
  passed:         934
  failed:         0
  incomplete:     151           (109 user-stub + 42 generated)
Duration:         66.32 s

Per-source: all sources 0 failed.
  ExcelProcessor.m   (passed 226/252, failed 0, fixture: real unzipped toolTester.xlsx)
```

### matlabunittest/examples (synthetic portability test)

```
Total tests:      114
  passed:         95
  failed:         0
  incomplete:     19            (all user-stub; 0 generated incomplete)
Duration:         5.42 s
```

Unchanged from Phase 13 -- examples has no `.xlsx` (so Candidate 1
falls through to `tempname()`) and no `table`/`cell` typed args
(so Candidate 3 never fires).  Confirms both new heuristics are
dormant when the patterns aren't present in a project.

## What this approach intentionally does NOT do

* **No drop of the stateful-smoke `try / assumeFail` wrap when a
  fixture-driven prelude is in play.**  Phase 14 plumbs in a real
  unzipped Excel directory, but Phase 11's wrap still catches any
  throw from synthetic `removeSheet('Sheet')` calls (the synthetic
  sheet name does not exist in the real workbook).  Dropping the
  wrap conditionally on "fixture verified to populate state" would
  flip those Incompletes to either Pass (if `removeSheet` happens
  to no-op on a non-existent name) or Failed (if it throws).  The
  honest answer requires a smarter synthetic-input layer that
  introspects the live state -- e.g. reading `keys(obj.SheetMap)`
  and feeding one of those names back into the smoke.  Out of
  scope for Phase 14.
* **No constructor-arg synthesis for methods that take a
  `containers.Map` / `dictionary` directly as an argument.**  The
  fixture provides a populated INSTANCE; if a method's signature
  includes `function out = foo(obj, sheetMap)`, the autogen still
  treats `sheetMap` as opaque-typed and skips at the smoke layer.
  Future phase: detect "arg is a Map, class has a populator" and
  pass `testCase.Instance.SheetMap` at smoke time.
* **No table / cell synthesis for methods without `arguments` blocks.**
  The Candidate 3 heuristic is gated on `argInfo.IsExplicit`.
  Methods that take a table or cell positionally without declaring
  the type still get the InputSampler default (`1` for unknown,
  `{1, 2, 3}` for cell vector).  Widening this risks corrupting
  downstream tests in unrelated projects (the same concern that
  blocked `data` in Phase 13).

## Phase 15 candidates (all generic, no project-specific work)

Ranked by impact on Failed/Incomplete on arbitrary projects:

1. **Live-state-aware smoke inputs.**  When the prelude has run
   and `testCase.Instance.SheetMap` (or any dictionary property)
   is non-empty, draw a key from it for the smoke instead of the
   synthetic literal.  Drops the Phase 11 try/assumeFail wrap on
   smokes that successfully introspect a populated property.
   Effort: medium.  Reduction: directly targets the 26
   ExcelProcessor + 3 ExcelRemover Incompletes.

2. **`containers.Map` / `dictionary` arg substitution from a sibling
   instance.**  When a method's positional arg is typed (or named)
   as a Map / dictionary AND the same class has a property of that
   shape, pass the property at call time.  Effort: medium.

3. **Doc-example parser hardening.**  Multi-line examples with
   variable bindings still confuse the extractor (carry-over from
   Phase 12).  Effort: medium.

4. **DOM-substitute-in-smokeFor with safety check.**  Re-attempt
   the per-arg DOM substitution in smokeFor, but ONLY when ALL the
   non-DOM args also resolve via FixtureProvider (full-fixture
   path) -- else skip the smoke entirely.  Effort: low.

5. **Add `data` to FixtureProvider with a SizeHint guard.**  Only
   fire when the typed `arguments` block declares a specific type
   (string -> "abc", double -> 1, table -> table()).  Effort: low.
   Risk: limited, given the explicit-type gate.

## Pitfalls (carried forward)

- **Edit-tool truncation on TestWriter.m / FixtureProvider.m**
  (Phases 7+8+10+11+13): always use byte-level Python recipe via
  bash for non-trivial edits.  Verify `wc -l`, CRLF count, bare-LF
  count, lone-CR count, and NUL bytes after every patch.
- **Sandbox vs. Windows git index** (Phase 11+): use MATLAB
  `system('git ...')` for ALL git operations on the matlabunittest
  repo.  The Linux sandbox's `git status` shows wildly inaccurate
  output and any commit / push attempts fail with index-lock errors.
- **MATLAB regex line-continuation bug** (Phase 6): use `contains`
  over `regexp` when literal `\.` spans string-concat continuations.
- **Screenshot mask by exe basename** (Phase 9): grant `MATLAB
  R2025b` AND `matlab.exe` (basename) so the running window is
  visible in screenshots.
- **Half-fixtured smokes can hang the test runner** (Phase 12 lesson).
  When wiring a new fixture into smokeFor / edgeFor, ensure ALL args
  are resolvable -- partial-fixture calls into project code can hit
  non-terminating paths that try/catch cannot unstick.  Phase 14's
  `tempUnzippedExcel` returns a single string at the constructor
  position, so this risk doesn't apply -- the constructor either
  succeeds or fails cleanly.
- **MATLAB sprintf vs. Windows path backslashes**: `obj.charLiteral`
  emits the path as a MATLAB char literal with single quotes,
  `sprintf('%s', literal)` then embeds it verbatim into the
  generated source.  Backslashes in Windows paths are NOT
  re-escaped because they appear in the substituted value, not the
  format string.  Verified: the regenerated `tExcelProcessor.m`
  contains the path literally with single backslashes.

## Verification one-liners

```matlab
% removal_redaction_tool
close all force; delete(findall(0,'Type','figure')); clear classes;
addpath('C:\Users\Duy\Projects\matlabunittest');
info = autotest.runWorkflow('C:\Users\Duy\OneDrive\Documents\MATLAB\removal_redaction_tool');
disp(info.Summary)

% matlabunittest examples (portability test)
close all force; delete(findall(0,'Type','figure')); clear classes;
addpath('C:\Users\Duy\Projects\matlabunittest');
info = autotest.runWorkflow('C:\Users\Duy\Projects\matlabunittest\examples');
disp(info.Summary)
```

Both should report `failed: 0`.
