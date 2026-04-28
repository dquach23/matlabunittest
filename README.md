# matlabunittest

Auto-generate `matlab.unittest.TestCase` files from `.m` and `.mlapp`
sources. The generator parses the source into a structural model, then emits
a test class with smoke tests, edge-case tests, property-based tests, doc
example tests, and (for App Designer apps) callback tests.

This is **scaffolding plus invariants**, not "tests that know your spec."
A regenerator can guarantee that every public function/method/property is
exercised, that obvious edge cases (`[]`, `NaN`, `Inf`, `0`, `intmax`) are
covered, and that things don't throw — it can't infer expected values you
never wrote down.

## Quick start

Run `autotestGUI` from the MATLAB command window, pick your project folder
when the dialog appears, and find results under `<yourProject>/_autotest/`:

```matlab
autotestGUI
```

That single call:

1. Recursively finds every `.m` (function or classdef) and `.mlapp` source
   in the chosen folder, skipping anything that already looks like a test
   (`^t[A-Z]` / `^test[A-Z]`) and anything inside `_autotest/`.
2. Generates a `matlab.unittest.TestCase` for each source via
   `generateTests`, mirroring the source tree under `_autotest/generated/`.
3. Runs the suite with TAP and JUnit-XML plugins attached, capturing the
   whole run in a timestamped diary log.
4. Writes a human-readable summary, a JUnit `results.xml` for CI, and a
   `results.tap` for TAP-aware tools, then pops a small dialog with the
   pass/fail tallies and an "Open output folder" button.

The last-used folder is remembered between sessions
(`getpref('autotest','LastFolder')`).

For finer control use the underlying API directly:

```matlab
% From the repo root
generateTests('examples/sampleFunctions.m')   % writes tsampleFunctions.m next to the source
generateTests('examples/Calculator.m', 'OutputDir', 'tests')
runtests('tsampleFunctions')

% Or call the workflow without a GUI:
info = autotest.runWorkflow('/path/to/project');
disp(info.Summary)
```

The top-level entry points are [`autotestGUI`](autotestGUI.m) and
[`generateTests`](generateTests.m). The implementation lives under the
`+autotest` package.

## Output layout

`autotestGUI` (and `autotest.runWorkflow`) drop everything under
`<yourProject>/_autotest/`:

```
_autotest/
    generated/        auto-generated tXxx.m files (mirrors source tree)
    reports/
        summary.txt   passed/failed/skipped counts per source
        results.xml   JUnit-style XML (for CI tools)
        results.tap   TAP output
    logs/
        run-YYYYMMDD-HHMMSS.log   full diary of the run
        generation-errors.txt     per-file generation failures, if any
    exports/          reserved for additional artefacts
```

`_autotest/` is added to `.gitignore` automatically. Re-running the
workflow replaces `generated/` and overwrites `reports/`, but each run's
log is kept in `logs/` so you can compare runs.

## What gets generated

For a `.m` **function** file:

| Test | What it verifies |
| --- | --- |
| `testExists_<name>` | `which('<name>')` resolves on the path |
| `testSmoke_<name>_scalar` / `_vector` / `_matrix` | Calls the function with type-appropriate inputs (informed by `arguments` blocks) and verifies it does not throw and outputs are non-empty / not all-NaN |
| `testRandomized_<name>` | Runs 25 randomised input trials (a property-based check) and verifies invariants hold or only validation errors are raised |
| `testEdge_<name>_<arg>_empty` / `_nan` / `_inf` / `_zero` / `_neg` / `_large` / `_small` | Per-argument edge variants. Edge cases may legitimately throw or return a degenerate value (`NaN`, `Inf`, `[]`); the test accepts either |
| `testDocExample_<name>_<n>` | Each `Example:` block in help text becomes an executable test |

For a `.m` **classdef**:

- `TestMethodSetup` constructs the instance with default args, with handle-class cleanup wired up.
- Every public, non-Constant property gets a get/set round-trip test.
- Each public method (instance and `Static`) gets the same smoke / property / edge / doc-example treatment as a function.

For a **`.mlapp`** App Designer file:

- The archive is unzipped, the embedded source is extracted from `matlab/document.xml`, and the same classdef parser is re-used.
- Components are read from `appdesigner/appModel.xml`.
- `TestMethodSetup` launches the app and registers `delete(app)` teardown.
- A test is emitted for every method whose name matches a callback pattern (`*Callback`, `*PushedFcn`, `*ValueChanged`, `startupFcn`, ...). The callback is invoked with the resolved component as the source and a synthetic event struct.

## Options

```matla