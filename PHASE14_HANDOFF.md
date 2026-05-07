# Phase 14 handoff -- matlabunittest

Read this if you're picking up after the Phase 13 work on 2026-05-06.

## TL;DR

**Phase 13 = multi-arg state-init detection + name-driven literal
heuristics: 857 -> 934 Pass (+77) on removal_redaction_tool with
Failed still 0, Incomplete 54 -> 42 (-22%).**

The autogen now handles, **generically across any MATLAB project**:

- Multi-arg state-init methods (e.g. `addTable(name, sheet, location)`,
  `setColumnNames(name, columns)`).  When a stateful classdef exposes
  multi-arg state-mutator methods whose every argument resolves cleanly
  via FixtureProvider (or InputSampler.scalarFor as a typed fallback),
  the methods are wired into the TestMethodSetup prelude with their
  arguments synthesised.  This unblocks the whole downstream test
  ladder (smoke / edge / randomized) for classes whose state has to
  be primed via setter calls rather than a zero-arg `init()`.
- Composite stringy arg names: arg names ending in `titleText`,
  `headerText`, `subtitle`, `tablename`, `columnname`, `columnnames`,
  `cellLocation`, `padchar`, `fillchar`.  FixtureProvider used to
  match only on exact lowercase tokens; Phase 13 extended the
  matcher with `endsWith` for these specific suffixes so a
  `createCenteredHeader(titleText, padChar)` call gets a real string
  + char pair instead of `(1, 1)`.

| | Phase 11 | Phase 12 | **Phase 13** |
|---|---:|---:|---:|
| Failed (removal_redaction_tool) | 0 | 0 | **0** |
| Passed (removal_redaction_tool) | 746 | 857 | **934** |
| Generated tests (removal_redaction_tool) | 842 | 911 | **976** |
| Incomplete (generated, removal_redaction_tool) | 96 | 54 | **42** |
| known_real_signal entries needed | 5 | 5 | **5** |
| Failed (matlabunittest/examples) | 0 | 0 | **0** |
| Passed (matlabunittest/examples) | 95 | 95 | **95** |

## Per-source breakdown (removal_redaction_tool)

| Source | Phase 12 | Phase 13 | delta |
|---|---|---|---|
| RedactionToolGUI.mlapp  | 37/38 |  37/38  |  unchanged |
| Classes/CellRefUtils.m  | 64/66 |  64/66  |  unchanged |
| Classes/ConsoleLogger.m | 54/54 |  54/54  |  unchanged |
| Classes/ExcelProcessor.m | 226/252 | 226/252 | unchanged |
| Classes/ExcelRemover.m  | 219/222 | 219/222 | unchanged |
| Classes/ExcelXmlCleaner.m | 109/115 | 109/115 | unchanged |
| Classes/ReportWriter.m  | 85/89 |  86/87  | +1 Pass, -2 total |
| Classes/TableMetadata.m | 5/16  |  **81/83**  | **+76 Pass, +67 total** |
| Classes/TextRedactor.m  | 58/59 |  58/59  | unchanged |

The TableMetadata jump is candidate 2 (multi-arg state-init).  The
+1 on ReportWriter is the createCenteredHeader smoke now resolving
its titleText / padChar args.  The -2 total on ReportWriter is the
old `testSkipped_<name>` placeholder being replaced by a real smoke
that runs and passes.

ExcelProcessor / ExcelRemover / ExcelXmlCleaner did not move because
their remaining Incompletes are dominated by `containers.Map` /
`sheetMap` / `targetToRId` opaque-typed inputs that the FixtureProvider
cannot synthesise generically.  Future phase candidate.

## Phase 13 implementation

### Candidate 2: multi-arg state-init detection

#### `+autotest/StateInitializer.m` -- two new public Static methods

```matlab
function calls = candidateMethodCalls(model, fixtureProvider)
    % Returns ordered cell array of call expressions:
    %   'buildLookupMaps()'
    %   'addTable(''Table1'', 1, ''A1'')'
    % Zero-arg path delegates to the existing candidateMethods and
    % wraps each in '<name>()'.
    % Multi-arg path scans methods with prefix add/register/attach/
    % insert/put/set, requires no outputs, and uses tryResolveArgs
    % to FixtureProvider-resolve every argument.  All-or-nothing.
end

function resolved = tryResolveArgs(m, fixtureProvider)
    % Returns {} unless EVERY positional input resolves to a non-empty
    % literal via FixtureProvider.literalForArg, with InputSampler.
    % scalarFor() as a typed fallback.  varargin always returns {}.
end
```

The multi-arg path is gated on the FixtureProvider being non-empty
and the model.Methods list being non-empty.  The all-or-nothing
discipline mirrors smartFor (Phase 12 lesson: half-fixtured calls
into project code can hit non-terminating paths that try/catch
cannot unstick).

#### `+autotest/TestWriter.m` -- two call-site updates

1. `appendClassTests` TestMethodSetup prelude (was line 359 area):
   ```matlab
   stateInits = autotest.StateInitializer.candidateMethodCalls( ...
       obj.Model, stateInitProvider);
   for ii = 1:numel(stateInits)
       % emit:  testCase.Instance.<call expression>;
   end
   ```
   The previous call returned bare names and the emitter appended
   literal `()`; that no longer works for multi-arg call expressions.

2. `appendFunctionMethods` early-gate (was line 546 area):
   ```matlab
   if obj.Model.IsStateful && strcmp(kind, 'method') ...
           && ~isFopenOnly ...
           && isempty(autotest.StateInitializer.candidateMethodCalls( ...
               obj.Model, gateProvider))
       % emit testSkipped_<name> (unchanged)
   end
   ```
   Same logic, just now consults the richer candidate list so a class
   with multi-arg state-init drops the gate too.

### Candidate 4 (light): name-driven literal extensions

#### `+autotest/FixtureProvider.m` -- three additions

```matlab
% (1) extend stringy exact-name list with endsWith composites
|| endsWith(lname, 'titletext') || endsWith(lname, 'headertext') ...
|| endsWith(lname, 'subtitle')

% (2) new pad/fill char block
if stringyOrUnknown ...
        && (strcmp(lname, 'padchar') || endsWith(lname, 'padchar') ...
            || strcmp(lname, 'fillchar') || endsWith(lname, 'fillchar'))
    expr = '''*''';
    return;
end

% (3) extend cellref to celllocation
|| strcmp(lname, 'celllocation') || endsWith(lname, 'celllocation')

% (4) extend tablename / columnname to endsWith + add columnnames
|| endsWith(lname, 'tablename')
|| endsWith(lname, 'columnname') || strcmp(lname, 'columnnames') ...
|| endsWith(lname, 'columnnames')
```

These are name-only heuristics with default-string fallback values.
They never fire for arguments that have an explicit `arguments`
block declaring a non-stringy type (`stringyOrUnknown` gate).

### Candidate 5: CHANGELOG.md

Added at repo root.  See the file for the per-phase delta history.

### Files changed in Phase 13

| File | Lines (Phase 12 -> Phase 13) | Bytes (Phase 12 -> Phase 13) | CRLF | bare-LF | NUL |
|---|---:|---:|---:|---:|---:|
| `+autotest/StateInitializer.m` | 111 -> 256 (+145) | 5,363 -> 11,774 (+6,411) | 256 | 0 | 0 |
| `+autotest/TestWriter.m` | 1399 -> 1419 (+20) | 74,894 -> 76,118 (+1,224) | 1419 | 0 | 0 |
| `+autotest/FixtureProvider.m` | 407 -> 428 (+21) | 17,105 -> 18,496 (+1,391) | 428 | 0 | 0 |
| `CHANGELOG.md` | NEW | NEW | n/a | 0 | 0 |
| `PHASE14_HANDOFF.md` | NEW | NEW | n/a | 0 | 0 |

All edits applied via byte-level Python recipes in `/tmp/phase13_*.py`.
No project source touched.

## Verification (both targets, Failed = 0)

### removal_redaction_tool

```
Total tests:      1085
  passed:         934
  failed:         0
  incomplete:     151           (109 user-stub + 42 generated)
Duration:         57.39 s

Per-source: all sources 0 failed.
  ReportWriter.m     (passed 86/87,  failed 0)    <-- Phase 12: 85/89
  TableMetadata.m    (passed 81/83,  failed 0)    <-- Phase 12:  5/16  (!)
```

### matlabunittest/examples (synthetic portability test)

```
Total tests:      114
  passed:         95
  failed:         0
  incomplete:     19            (all user-stub; 0 generated incomplete)
Duration:         5.41 s
```

Unchanged from Phase 12 -- the new heuristics never fire on the
example sources (no setter-style state-init, no titleText / padChar
args).  Confirms the changes are dormant when the patterns aren't
present in a project.

## What this approach intentionally does NOT do

* **No `data` heuristic in FixtureProvider.**  TableMetadata's
  `setTableData(name, data)` and similar generic-name args remain
  unresolved.  `data` could be a table, struct, char array, double
  matrix, or any number of opaque types in practice; defaulting to
  any single shape would silently corrupt downstream tests in some
  unrelated project.  The 2 residual TableMetadata Incompletes
  (`testSmoke_setTableData_realistic`, `testRandomized_setTableData`)
  are accepted.
* **No constructor-fixture for `containers.Map` / `sheetMap`.**
  The 26 ExcelProcessor and 3 ExcelRemover Incompletes that depend
  on a fully-populated sheet metadata map require a multi-step
  fixture builder (load real .xlsx, parse via ExcelProcessor itself,
  hand result back into the test).  Bootstrapping this generically
  is out of scope; left for a future phase that handles
  "constructor-graph" fixtures.
* **No DOM-substitute-in-smokeFor (still).**  Phase 12's lesson on
  half-fixtured smokes hanging the test runner held; smartFor +
  FixtureProvider continues to be the sole DOM-substitution path.

## Phase 14 candidates (all generic, no project-specific work)

Ranked by impact on Failed/Incomplete on arbitrary projects:

1. **`containers.Map` constructor-graph fixture.**  When a class's
   constructor takes a Map / dictionary and a sibling method exists
   that POPULATES it from a path-like input, run the populator at
   prelude time to synthesise a live Map.  Effort: high.  Reduction:
   could unblock the 26 ExcelProcessor Incompletes if the project
   under test follows that pattern.

2. **Doc-example parser hardening.**  Multi-line examples with
   variable bindings still confuse the extractor (carry-over from
   Phase 12).  Effort: medium.  Reduction: project-dependent.

3. **`table` / `cell-of-cells` fixture provider.**  Methods that take
   `table` or `cell-of-cells` typed `cell`/`table` get either
   `{1, 2, 3}` (cell) or empty (table).  Real fixtures here would
   unblock spreadsheet utility classes broadly.  Effort: medium.

4. **DOM-substitute-in-smokeFor with safety check.**  Re-attempt the
   per-arg DOM substitution in smokeFor, but ONLY when ALL the
   non-DOM args also resolve via FixtureProvider (full-fixture
   path) -- else skip the smoke entirely instead of going
   half-fixtured.  Effort: low.

5. **Add `data` to FixtureProvider with a SizeHint guard.**  Only
   fire when the typed `arguments` block declares a specific type
   (string -> "abc", double -> 1, table -> table()).  Effort: low.
   Risk: limited, given the explicit-type gate.

## Pitfalls (carried forward)

- **Edit-tool truncation on TestWriter.m / FixtureProvider.m**
  (Phases 7+8+10+11+13): always use byte-level Python recipe via
  bash for non-trivial edits.  Verify `wc -l`, CRLF count, bare-LF
  count, lone-CR count, and NUL bytes after every patch.  Phase 13
  hit this on FixtureProvider.m -- the Edit tool truncated the tail
  of the file even though the diff looked fine; restored from git
  show + LF->CRLF, then re-applied via Python.
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
  non-terminating paths that try/catch cannot unstick.

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
