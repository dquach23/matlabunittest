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

```matlab
% From the repo root
generateTests('examples/sampleFunctions.m')   % writes tsampleFunctions.m next to the source
generateTests('examples/Calculator.m', 'OutputDir', 'tests')
runtests('tsampleFunctions')
```

The top-level entry point is [`generateTests`](generateTests.m). The
implementation lives under the `+autotest` package.

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

```matlab
generateTests('Calc.m', ...
    'OutputDir',         'tests', ...   % where to write
    'TestClassName',     'tCalc', ...   % override class name (default: 't' + source name)
    'Overwrite',         true, ...
    'PropertyTests',     true, ...      % randomised invariants
    'EdgeCaseTests',     true, ...
    'DocExampleTests',   true, ...
    'AppCallbackTests',  true, ...      % .mlapp only
    'Verbose',           false);
```

## Layout

```
+autotest/
  TestGenerator.m   % orchestrator
  MFileParser.m     % parses .m
  MlappParser.m     % unzips & parses .mlapp
  SourceModel.m     % intermediate model
  InputSampler.m    % generates input expressions
  TestWriter.m      % emits the test class
generateTests.m     % top-level entry point
examples/
  sampleFunctions.m
  Calculator.m
  SimpleApp.mlapp   % minimal App Designer fixture
tests/
  tParser.m         % parser/generator self-tests (function + classdef)
  tMlappParser.m    % parser/generator self-tests (App Designer)
  runSelfTests.m    % runner
```

## Self-tests

```matlab
addpath(pwd);
runtests('tests')
% or:
tests/runSelfTests
```

## Caveats

- The parser is regex-based with light state tracking. It handles
  well-formed code (function files, classdefs, `arguments` blocks, line
  continuations, line/block comments, and most string-literal cases) but
  is not a full MATLAB grammar.
- Generated tests cover *behaviour-doesn't-blow-up*, not behaviour
  correctness. Add specific `verifyEqual` calls by hand to assert real
  contracts, then re-run `generateTests` with a different
  `'TestClassName'` to keep handwritten tests separate from generated
  ones.
- For `.mlapp` apps, callback invocation simulates an event struct and
  passes the resolved component as the source; if your callback derefs
  uncommon event fields, expect to flesh out the synthetic event.
- Property-based tests use `rand` and seed `rng