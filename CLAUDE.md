# matlabunittest — project guide for Claude

## What this project is

A MATLAB tool that scans a user-selected MATLAB project directory and
auto-generates `matlab.unittest.TestCase` classes for every `.m`
(function or classdef) and `.mlapp` (App Designer) source it finds.

The tool is **scaffolding plus invariants**, not "tests that know your
spec." It can guarantee every public function / method / property is
exercised, that obvious edge cases are covered, and that things don't
throw — it cannot infer expected values you never wrote down.

## Entry points

- `autotestGUI[(folder)]` — interactive entry point. Pops a folder
  picker (or accepts a path), then runs the workflow against it.
  Remembers the last folder via `getpref('autotest','LastFolder')`.
- `generateTests(sourcePath, ...)` — generate a single test class for
  one source file. Used by the workflow internally.
- `autotest.runWorkflow(folder, ...)` — programmatic equivalent of
  `autotestGUI`, no dialogs.

## Output layout (under `<projectFolder>/_autotest/`)

```
_autotest/
    generated/        auto-generated tXxx.m files (mirrors source tree)
                      WIPED on every run — DO NOT EDIT
    user_tests/       hand-edit-friendly uXxx.m stubs (mirrors source tree)
                      STICKY — created once per source, never overwritten
    reports/
        summary.txt   pass/fail counts per source
        results.xml   JUnit XML (CI)
        results.tap   TAP output
    logs/
        run-YYYYMMDD-HHMMSS.log   full diary of the run
        generation-errors.txt     per-file generation failures, if any
    exports/          reserved for additional artefacts
```

Each run wipes `generated/` and overwrites `reports/`, but keeps
historical entries in `logs/` AND preserves everything in
`user_tests/` so the user can iteratively add real assertions
without losing them on regeneration. `_autotest/` is auto-added to
`.gitignore`.

The two test trees serve different purposes:

- `generated/tXxx.m` — invariants ("doesn't throw," "doesn't return
  all-NaN," "edge cases either work or throw cleanly"). Provides
  coverage automatically; cannot encode "for X expect Y."
- `user_tests/uXxx.m` — placeholders for hand-written assertions.
  Each public function/method/property/callback gets one
  `userTest_<name>` stub starting with `assumeFail('TODO: ...')`,
  so the test reports as Incomplete until the user fills it in.

The runner discovers tests from both trees and merges results.

## Excluding known real-signal failures

When the autogenerator emits a test that fails because the project under
test has a genuine bug (one the user has chosen NOT to fix or fix later),
the failure adds noise to the report and obscures regressions in the
autogen tool itself.  Phase 7 added a per-target opt-out: list those
tests in `<projectFolder>/_autotest/known_real_signal.txt` and the
generator emits a `testSkipped_<testMethodName>` Incomplete carrying the
user's reason text instead of the failing test.

File format (`#` comments and blank lines are ignored):

```
<testClassName>.<testMethodName>: <reason text>
```

Example (`removal_redaction_tool/_autotest/known_real_signal.txt`):

```
tCellRefUtils.testEdge_isCellInRange_cellRef_empty: project bug (CellRefUtils.isCellInRange line 78 -- MATLAB:nonLogicalConditional)
tCellRefUtils.testRandomized_isCellInRange: project bug (CellRefUtils.isCellInRange line 78)
tRedactionToolGUI.testCallback_sheetStatusChanged: project bug (cascade through CellRefUtils.isCellInRange line 78)
```

`<testClassName>` is the generated class name (`t<SourceName>` for `.m`,
`t<AppName>` for `.mlapp`).  `<testMethodName>` is the method name
exactly as it appears in `report.html` (e.g.
`testEdge_isCellInRange_cellRef_empty`,
`testRandomized_isCellInRange`, `testCallback_sheetStatusChanged`,
`testConstructor_realistic`).

The lookup runs at every `testSmoke_` / `testEdge_` / `testRandomized_` /
`testCallback_` / `testConstructor_` emission point in
`+autotest/TestWriter.m`.  Implementation lives in
`+autotest/KnownRealSignal.m` (a static helper with one cached
`match(folder, class, method) -> reason` entry point).

The file is preserved across runs (it lives directly under `_autotest/`,
NOT under `generated/`, so it survives the per-run wipe).

## Architecture (under `+autotest/`)

```
autotestGUI.m            user-facing entry; folder picker + summary dialog
generateTests.m          single-file API; thin wrapper around TestGenerator
+autotest/
    runWorkflow.m        discover sources → generate → run → report
    TestGenerator.m      orchestrator: parser dispatch + writer
    MFileParser.m        .m parser (function | classdef)
    MlappParser.m        .mlapp parser (unzips, extracts CDATA classdef)
    SourceModel.m        parsed view (fields → consumed by writer)
    InputSampler.m       smoke / edge-case input synthesis
    TestWriter.m         emits the matlab.unittest.TestCase source
```

Data flow:

```
Source file ─▶ Parser ─▶ SourceModel ─▶ TestWriter ─▶ tXxx.m
                                  ▲
                          InputSampler (called by writer)
```

## How discovery works

`runWorkflow.discoverSources` runs `dir(folder/**/*)` and keeps any
`.m` or `.mlapp` file that:

- Is **not** inside `<folder>/_autotest/` (own output)
- Is **not** named like an existing test file: `^t[A-Z]` or
  `^test[A-Z]` (e.g. `tParser.m`, `testFooBar.m`)

Path setup: `addProjectPaths` adds every non-package, non-class
subdirectory of the project root (via `genpath`) so generated tests
can resolve their sources. `genpath` automatically skips folders
starting with `.` (so `.git` is fine) and `private`/`+pkg`/`@cls`.

## Per-source-kind test menu

| Kind | What gets emitted |
|---|---|
| `.m` function | existence test; smoke (scalar/vector/matrix); per-arg edge tests (`empty`/`nan`/`inf`/`zero`/`neg`/`large`/`small`); randomized property test; one test per `Example:` block in help text |
| `.m` classdef | constructor smoke test; get/set round-trip per public mutable property; per-method smoke + edge + randomized + doc-example (instance vs `Static`) |
| `.mlapp` | launch + teardown; verify `UIFigure`/`Figure` present; per-callback invocation with synthetic event struct using component tag from `appdesigner/appModel.xml` |

Each generated test class is self-contained (private helpers
inlined): `safeDelete`, `isValidationError`, `assertReasonable`,
`findByTag`, `runExample`. No runtime dependency on the `+autotest`
package.

## Known fragility (worth knowing before changes)

The parsers are regex-based and target well-formed MATLAB — they are
not a full MATLAB AST. Specifically:

- `MFileParser` joins `...` continuation lines first, then walks
  line-by-line with masked strings/comments and a depth counter for
  block keywords (`if`/`for`/`while`/`switch`/`try`/`parfor`/
  `arguments`/`function`/`properties`/`methods`/`events`/`enumeration`).
- The string-literal heuristic distinguishes `'` as string-opener vs
  transpose by looking at the previous non-space token.
- The classdef walker only branches at depth 1; nested control flow
  inside method bodies is jumped over via `findMatchingEnd`.
- `MlappParser` reuses `MFileParser` after extracting the embedded
  classdef from `matlab/document.xml`'s CDATA.

If a source uses an exotic construct that breaks parsing, the failure
is captured per-file in `_autotest/logs/generation-errors.txt` and the
workflow continues with the remaining sources.

## Working test target (real project)

The `removal_redaction_tool` project at
`C:\Users\Duy\OneDrive\Documents\MATLAB\removal_redaction_tool`
is the canonical real-world target. Layout:

```
removal_redaction_tool/
    RedactionToolGUI.mlapp     main App Designer app (~1.3k LOC embedded)
    Classes/
        CellRefUtils.m         classdef, all-Static utility
        ConsoleLogger.m        handle classdef, GUI log facade
        ExcelProcessor.m       handle classdef, orchestrator
        ExcelRemover.m         classdef, all-Static
        ExcelXmlCleaner.m      classdef, all-Static
        ReportWriter.m         handle classdef
        TableMetadata.m        handle classdef (uses `dictionary`)
        TextRedactor.m         handle classdef
    *.xlsx, *.png, *.txt       not parsed (correct: not .m/.mlapp)
```

A successful run should produce one `tXxx.m` per source: one for the
mlapp, eight under `_autotest/generated/Classes/`.

## Conventions for changes in this repo

- Preserve CRLF line endings on existing files (the project is
  Windows-edited; `git diff` will balloon into "every line changed"
  if you flip line endings).
- The four files `MFileParser.m`, `MlappParser.m`, `SourceModel.m`,
  `TestWriter.m` were truncated mid-source in the initial commits
  (e.g., `SourceModel.m` ended at `function c = makeComponent(tag, `).
  Re-truncating them by accident is the most likely regression — make
  sure every file ends with a closing `end` for the classdef and a
  trailing newline.
- Static helpers used at code-gen time (`TestWriter.iif`,
  `TestWriter.sampleForType`, `MlappParser.tryRmdir`) are referenced
  before they're defined in source order; if you remove them, search
  call sites first.

## Quick command reference

```matlab
% Run the full workflow with a picker
autotestGUI

% Run on a specific folder, skip the dialog
autotestGUI('C:\Users\Duy\OneDrive\Documents\MATLAB\removal_redaction_tool')

% Programmatic
info = autotest.runWorkflow('C:\path\to\project', 'Verbose', true);
disp(info.Summary)

% Single-file
generateTests('Classes/CellRefUtils.m', 'OutputDir', 'tests')
runtests('tCellRefUtils')
```
