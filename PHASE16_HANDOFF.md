# Phase 16 handoff -- matlabunittest

Read this if you're picking up after the Phase 15 work on 2026-05-07.

## TL;DR

**Phase 15 = three new generic autogen mechanisms (live-state-aware
smoke inputs, full-fixture DOM smokes with safety check, typed
data/value/payload fixtures) + a native MATLAB system-test-report
generator that replaces the previous external Node.js + LibreOffice
pipeline.  Failed must remain 0 on both targets when the master
driver `_phase15_run_all.m` is executed (verification still pending
per the "Verification not yet run" note below).**

The autogen now handles, **generically across any MATLAB project**:

- Methods whose key-shaped argument (suffix `name` / `id` / `key`)
  partial-matches a class container property (e.g. `sheetName` <->
  `SheetMap`, `tableName` <-> `Tables`).  At smoke time the synthetic
  literal is replaced with `autotest.InputSampler.firstKeyOr(
  testCase.Instance.<prop>, <fallback>)` so the call uses a real key
  from live state when the prelude succeeded, and falls back cleanly
  to the synthetic literal when state was empty / unrecognised.
  The Phase 11 `try / assumeFail` wrap is dropped on this path so a
  successful live-key smoke reports as Pass instead of Incomplete.
- Methods that take a DOM-typed/named arg AND every non-DOM arg
  resolves via `FixtureProvider.literalForArg`: an additional
  `testSmoke_<fn>_domFullFixture` smoke is emitted that uses
  `tempDOM(testCase)` for the DOM arg and the fixture literals for
  every other arg, with an `% Phase 15 cand-4 Args = {...}` leading
  comment so the post-mortem in `results.xml` can attribute the test
  back to candidate 4.  The pre-pass is all-or-nothing: any non-DOM
  arg falling through to `InputSampler.scalarFor` aborts emission
  rather than going half-fixtured (Phase 12 documented half-fixture
  smokes as hang-prone).
- Methods with an `arguments` block declaring a `data` / `value` /
  `payload` arg with an explicit type AND a recognised SizeHint:
  `FixtureProvider.literalForArg` returns a type+shape-appropriate
  fixture (string -> "abc", char -> 'abc', double scalar -> 1, vector
  -> [1 2 3], matrix -> magic(3), logical -> true, table -> 3-row
  synthetic table, cell -> 2x2 cell-of-cells, struct ->
  struct('value', 1)).  Gated on `argInfo.IsExplicit` so the
  heuristic is dormant when no `arguments` block is present (a `data`
  arg with no declared type is too ambiguous).

In addition, **Phase 15 ships a self-contained MATLAB system test
report generator** (`autotest.generateSystemTestReport(folder, ...)`)
that produces `<OutputDir>/<basename>_TestReport.docx` and a matching
`.pdf`.  No Node.js, no Python, no agent-side assembly: the whole
pipeline is MATLAB code under `+autotest/+report/`.  The generator
selects between two backends and logs the choice to
`<OutputDir>/report_backend.log`:

| Tier | Backend | Requirements | PDF tier |
|---|---|---|---|
| 1 | `RptgenBackend` (`+autotest/+report/+backends/RptgenBackend.m`) | `mlreportgen.dom.Document` AND `license('test','MATLAB_Report_Gen')` | `mlreportgen.utils.docToPDF` |
| 2 | `OoxmlBackend`  (`+autotest/+report/+backends/OoxmlBackend.m`)  | builtin `zip()` only                                       | LibreOffice headless (when path set in `getpref('autotest','LibreOfficePath')`) |

When neither tier is available, `BackendDetector.probe()` errors with
a clear "could not produce a Word doc on this MATLAB install"
message that lists what was probed.  Fail-loud, not silent.

The new public surface is integrated with `autotest.runWorkflow`:

```matlab
info = autotest.runWorkflow(folder, 'GenerateReport', true, ...
    'ReportOptions', struct('DisplayName', 'My Project', ...));
```

`GenerateReport` defaults to `false` so existing callers are
unaffected.

## Phase 15 Pass-count expectations

| | Phase 14 | **Phase 15** |
|---|---:|---:|
| Failed (removal_redaction_tool)               | 0  | 0 |
| Passed (removal_redaction_tool)               | 934 | TBD (see below) |
| Generated tests (removal_redaction_tool)      | 976 | TBD |
| Incomplete (generated, removal_redaction_tool) | 42 | TBD |
| Failed (matlabunittest/examples)              | 0  | 0 |
| Passed (matlabunittest/examples)              | 95 | unchanged target |

**Note: verification not yet run.** The Phase 15 master driver
`_phase15_run_all.m` was authored but not executed during the work
session because the operator was AFK and the MATLAB window was
masked from screenshots (matlab.exe basename not in the session
allowlist).  Run the driver from the MATLAB Command Window to
populate the missing numbers and produce both deliverables:

```matlab
cd 'C:\Users\Duy\Projects\matlabunittest'
run('_phase15_run_all.m')
```

The driver writes `_phase15_status.json` next to it with the
totals and report paths, and `_phase15_toolbox_audit.txt` capturing
`ver` output.

### Why the Pass count may not move on `removal_redaction_tool`

Candidate 1 (live-state-aware smoke inputs) targets the 26
ExcelProcessor + 3 ExcelRemover Incompletes from Phase 14.  But the
Phase 14 fixture is defeated by RR-004 (`ExcelProcessor`
constructor's `fullfile(pwd, abs_path)` prepending pwd to absolute
paths -- documented in the Phase 14 reference report's defect
register and reproduced below).  As long as RR-004 is unfixed in
the project under test, the constructor-graph fixture continues to
short-circuit inside the prelude's try/catch, and the live-key
substitution falls back to the synthetic literal.  This is the
expected and honest result.  **Do NOT add a workaround for RR-004 in
the autogen** -- that is a project-side bug that should be reported
and fixed, not papered over.

Candidates 4 and 5 are dormant on `removal_redaction_tool`:

- No method in the project declares a DOM-typed arg AND has every
  non-DOM arg resolved via FixtureProvider (the candidate-4
  pre-pass safety check).  ExcelProcessor's stateful methods are
  the closest case but their args don't include DOM.
- No method declares `data` / `value` / `payload` in an `arguments`
  block (candidate 5's IsExplicit gate).

Both candidates should still pass the portability run on
`matlabunittest/examples` (i.e. examples results unchanged).

## Phase 15 implementation -- candidate 1 (live-state-aware smoke)

### `+autotest/InputSampler.m::firstKeyOr(container, fallback)` (new public Static)

Returns the first key/index of a populated container, or `fallback`
when empty / unrecognised.  Switch/case-handles:

- `containers.Map` -- `keys(container){1}`
- `dictionary`     -- `keys(container)(1)` with isstring/iscell/isnumeric branches
- `struct`         -- `fieldnames(container){1}`
- `cell`           -- `container{1}` if char/string, else fallback
- `table`          -- `container.Properties.VariableNames{1}`

All-or-nothing safety: any throw / unrecognised shape returns
fallback.  Generic across MATLAB projects -- recognises only
built-in container shapes.

### `+autotest/StateInitializer.m::liveKeyExpr(propName, propType, fallback)` (new public Static)

Emits a call expression
`autotest.InputSampler.firstKeyOr(testCase.Instance.<propName>, <fallback>)`
that the generated TestMethodSetup will resolve at runtime.

`propType` is accepted for parity with other emitters but is not
currently consulted -- `firstKeyOr` does its own shape detection at
runtime.

### `+autotest/TestWriter.m::applyLiveKeySubstitution(smartCase, fcn, kind)` (new private)

For each smart-case Args entry whose corresponding input is
key-shaped (suffix name / id / key) AND partial-matches a class
container property by name (`startsWith(lprop, base)` with `base` =
arg minus suffix, AND `endsWith(lprop, container_suffix)` for
suffix in `{map, cache, list, set, dict, tables, s}` -- or a direct
equality match), the synthetic literal is replaced with the live-key
expression.

Marks the case with `DropStatefulWrap = true` when any substitution
happened, so `appendCallTest` drops the Phase 11 `try / assumeFail`
wrap.

### `+autotest/TestWriter.m::matchArgToProperty(argName, props)` (new private helper)

Implements the partial-match algorithm described above.  Restricted
to **public** properties.  Direct equality match (`lprop == base`)
also counts -- catches direct args like `tables` <-> `Tables`.

## Phase 15 implementation -- candidate 4 (DOM full-fixture smoke)

### `+autotest/TestWriter.m::tryDomFullFixtureSmoke(fcn, provider)` (new private)

Pre-pass over the args:

- If at least one arg is DOM-typed/named, use `tempDOM(testCase)` for it.
- If every non-DOM arg has a non-empty `FixtureProvider.literalForArg`
  result, use the fixture literal.
- If any non-DOM arg returns empty, **abort** (do not emit the smoke).

Returns a smoke case with `Label = 'domFullFixture'` and
`AnnotateArgs = true`.

`appendCallTest` honours `AnnotateArgs` by emitting a
`% Phase 15 cand-4 Args = {<argList>}` comment as the first line of
the test method body, so the post-mortem in `results.xml` can
attribute the test back to candidate 4.

## Phase 15 implementation -- candidate 5 (typed data/value/payload)

### `+autotest/FixtureProvider.m` -- new gated branch

Inserted AFTER the Phase 14 typed table/cell branch and BEFORE the
stringy heuristics:

```matlab
if isfield(argInfo, 'IsExplicit') && argInfo.IsExplicit ...
        && (strcmp(lname, 'data') || strcmp(lname, 'value') ...
            || strcmp(lname, 'payload'))
    sh = '';
    if isfield(argInfo, 'SizeHint'), sh = argInfo.SizeHint; end
    switch ltype
        case 'string', expr = '"abc"'; return;
        case 'char',   expr = '''abc'''; return;
        case {'double','single','numeric'}
            switch sh
                case 'scalar', expr = '1';
                case 'vector', expr = '[1 2 3]';
                case 'matrix', expr = 'magic(3)';
                otherwise,     expr = '1';
            end
            return;
        case 'logical', expr = 'true'; return;
        case 'table',   expr = 'table(...)'; return;   % details in source
        case 'cell',    expr = '{1, ''a''; 2, ''b''}'; return;
        case 'struct',  expr = 'struct(''value'', 1)'; return;
    end
end
```

Gated on `argInfo.IsExplicit`.  When `IsExplicit` is false the
existing default fallthrough applies (a `data` arg with no declared
type is too ambiguous).

## Phase 15 implementation -- native MATLAB report generator

### Module layout (under `+autotest/+report/`)

```
ReportBuilder.m           -- top-level orchestrator
ResultsParser.m           -- reads summary.txt + results.xml + known_real_signal.txt
SourceInventory.m         -- walks PROJECT_PATH for .m / .mlapp; pulls H1 verbatim
DefectRegister.m          -- categorises Incompletes; emits PROJECT_PREFIX-NNN IDs
SectionBuilder.m          -- Sections 1..9 + Appendices A..D
CoverPage.m               -- title block + metadata table + bordered Distribution Statement D
BackendDetector.m         -- license / toolbox sniff + selection
Style.m                   -- shared font / size / colour / spacing constants
+backends/
    RptgenBackend.m       -- mlreportgen.dom path
    OoxmlBackend.m        -- hand-rolled OOXML + builtin zip
```

Plus:

```
+autotest/generateSystemTestReport.m   -- public API
```

### Backend selection (BackendDetector.probe)

Probes in order, returns the first that works:

1. `RptgenBackend`  -- `license('test','MATLAB_Report_Gen')` AND `~isempty(which('mlreportgen.dom.Document'))`
2. `OoxmlBackend`   -- `zip` builtin available

No third tier exists; `BackendDetector.probe()` errors with a clear
"could not produce a Word doc on this MATLAB install" message that
lists what was probed.  Logged to `<OutputDir>/report_backend.log`.

### OOXML emitter notes

The fallback `OoxmlBackend` builds each constituent XML file as a
char vector via composeable helpers and packs with builtin `zip()`:

- `[Content_Types].xml`
- `_rels/.rels`
- `word/document.xml`
- `word/_rels/document.xml.rels`
- `word/styles.xml`
- `word/settings.xml`  (with `<w:updateFields w:val="true"/>` so Word refreshes the TOC on first open)

Headers, footers, and complex per-section page-numbering are
intentionally omitted -- the backend prioritises structural parity
with the Phase 14 reference (cover page, TOC, sections 1..9,
appendices A..D) over typographic fidelity.  RptgenBackend is the
preferred path when available.

The TOC field is emitted as the standard `w:fldChar begin / instrText
TOC \\o "1-3" / fldChar end` triple.  Word populates page numbers on
first open; LibreOffice's headless `--convert-to pdf` may need a
manual update pass via UNO (documented for future Phase 16+ work).

### PDF tier (`'PdfBackend'` name-value)

| Mode          | Tier order |
|---|---|
| `'auto'` (default) | rptgen -> libreoffice -> warn-and-skip |
| `'rptgen'`         | rptgen only (errors if missing) |
| `'libreoffice'`    | LibreOffice only (errors if missing) |
| `'none'`           | skip PDF entirely |

LibreOffice path resolution: `getpref('autotest','LibreOfficePath','')`
followed by an autodetect over the standard install paths
(`C:\Program Files\LibreOffice\program\soffice.exe`,
`/Applications/LibreOffice.app/Contents/MacOS/soffice`,
`/usr/bin/soffice`, `/usr/bin/libreoffice`).  Missing path falls
through to the next tier rather than blocking interactively.

### Integration with runWorkflow

```matlab
info = autotest.runWorkflow(folder, ...
    'GenerateReport', true, ...
    'ReportOptions', struct('DisplayName', 'My Project'));
```

`GenerateReport` defaults to `false` to preserve all existing
callers.  When true, after the existing
`reports/{summary.txt,results.xml,results.tap}` are emitted, the
workflow calls `autotest.generateSystemTestReport(folder, opts)`
and adds the generated `.docx` (+ `.pdf` when available) to the
reports directory.

`info.ReportDocxPath`, `info.ReportPdfPath`, and `info.ReportBackend`
are added to the returned info struct.

## Files changed in Phase 15

| File | Lines (Phase 14 -> Phase 15) | Bytes (Phase 14 -> Phase 15) | CRLF | bare-LF | NUL |
|---|---:|---:|---:|---:|---:|
| `+autotest/InputSampler.m`        | 629 -> 686  | 29,520 -> 32,090  | 686  | 0 | 0 |
| `+autotest/StateInitializer.m`    | 256 -> 293  | 11,774 -> 13,634  | 293  | 0 | 0 |
| `+autotest/FixtureProvider.m`     | 474 -> 517  | 21,026 -> 23,092  | 517  | 0 | 0 |
| `+autotest/TestWriter.m`          | 1419 -> 1613 | 76,118 -> 85,818  | 1613 | 0 | 0 |
| `+autotest/runWorkflow.m`         | 549 -> 580  | (CRLF preserved)  | 509  | 0 | 0 |
| `+autotest/generateSystemTestReport.m` | NEW   | 3,346             | 68   | 0 | 0 |
| `+autotest/+report/ReportBuilder.m`     | NEW | 11,812            | 279  | 0 | 0 |
| `+autotest/+report/ResultsParser.m`     | NEW | 9,687             | 193  | 0 | 0 |
| `+autotest/+report/SourceInventory.m`   | NEW | 10,428            | 263  | 0 | 0 |
| `+autotest/+report/DefectRegister.m`    | NEW | 15,813            | 303  | 0 | 0 |
| `+autotest/+report/SectionBuilder.m`    | NEW | 40,106            | 666  | 0 | 0 |
| `+autotest/+report/CoverPage.m`         | NEW | 1,467             | 37   | 0 | 0 |
| `+autotest/+report/BackendDetector.m`   | NEW | 4,564             | 100  | 0 | 0 |
| `+autotest/+report/Style.m`             | NEW | 1,602             | 42   | 0 | 0 |
| `+autotest/+report/+backends/RptgenBackend.m` | NEW | 8,837       | 251  | 0 | 0 |
| `+autotest/+report/+backends/OoxmlBackend.m`  | NEW | 24,709      | 515  | 0 | 0 |
| `_phase15_run_all.m`              | NEW   | 7,445             | 176  | 0 | 0 |
| `_phase15_ver.m`                  | NEW   | 2,462             | LF*  | -- | 0 |
| `CHANGELOG.md`                    | updated | n/a              | n/a  | 0 | 0 |
| `PHASE16_HANDOFF.md`              | NEW   | n/a               | n/a  | 0 | 0 |

(* `_phase15_ver.m` was the early ad-hoc driver before the master
`_phase15_run_all.m` superseded it; line endings were not converted.
The master driver supersedes it; either is safe to keep.)

All edits to existing source applied via byte-level Python recipes
under `_phase15_patches/`.  No project source touched.  CRLF /
bare-LF / lone-CR / NUL counts verified clean after every patch.

## Verification (Phase 16: still pending)

```matlab
cd 'C:\Users\Duy\Projects\matlabunittest'
run('_phase15_run_all.m')
```

The driver runs both targets with `GenerateReport=true` and writes
`_phase15_status.json` with totals.  Open it from the sandbox to
verify: `failed = 0` on both targets AND `DocxPath` non-empty for
each.

Manual checks recommended after the .docx is produced:

- Open `<PROJECT_PATH>/_autotest/reports/removal_redaction_tool_TestReport.docx`
  in Word; confirm the cover page renders (metadata table populated,
  Distribution Statement D in a bordered box) and the TOC shows
  populated page numbers (Word should refresh on first open via
  `<w:updateFields w:val="true"/>`).
- Open the matching `.pdf` (if produced) and confirm the same.
- Confirm `report_backend.log` records which backend was chosen.
- Confirm the methodology note (Appendix C) mentions Phase 15
  candidates 1 / 4 / 5.

## What this approach intentionally does NOT do

* **No workaround for RR-004 in the autogen.**  The
  `ExcelProcessor` constructor's `fullfile(pwd, abs_path)` issue is
  a project-side bug.  Phase 15 candidate 1 is a generic mechanism;
  it would benefit any project that pairs a stateful class with a
  populator method and key-shaped public API, but it cannot work
  around an absolute-path concatenation bug in the constructor.
  The honest answer remains: fix line 36 of
  `Classes/ExcelProcessor.m` (use `matlab.io.absolutePath`, or branch
  on `startsWith(unzipDir, drive_letter_pattern)`).  See defect
  RR-004 in any prior cycle's defect register for the precise text.
* **No ContainerType-aware smoke args.**  Candidate 1 covers the
  KEY position (sheetName -> SheetMap key).  The VALUE position
  (e.g., `addTable(tableName, tableValue)` where `tableValue` is a
  table struct) still falls through to FixtureProvider.literalForArg
  with name-driven heuristics.  Future phase: detect "arg is a table
  / struct AND class has a property of that shape" and synthesize a
  representative value from the live property.  Out of scope for
  Phase 15.
* **No header / footer / page-number rendering in OoxmlBackend.**
  Tracked above; out of scope.  RptgenBackend produces full footer
  with page numbers via mlreportgen.dom defaults.

## Pitfalls (carried forward)

- **Edit-tool truncation on TestWriter.m / FixtureProvider.m**
  (Phases 7+8+10+11+13+14): always use byte-level Python recipe via
  bash for non-trivial edits.  Phase 15 patches are kept under
  `_phase15_patches/` for reproducibility.
- **Sandbox vs. Windows git index** (Phase 11+): use MATLAB
  `system('git ...')` for ALL git operations on the matlabunittest
  repo.  The Linux sandbox's `git status` shows wildly inaccurate
  output and any commit / push attempts fail with index-lock errors.
- **MATLAB regex line-continuation bug** (Phase 6): use `contains`
  over `regexp` when literal `\.` spans string-concat continuations.
- **Screenshot mask by exe basename** (Phase 9): grant `MATLAB
  R2025b` AND `matlab.exe` (basename) so the running window is
  visible in screenshots.  Phase 15 work was performed without the
  basename grant -- the verification step blocked while the operator
  was AFK.  Add the basename to the session allowlist before the next
  Phase that needs to drive MATLAB interactively.
- **Half-fixtured smokes can hang the test runner** (Phase 12).
  Phase 15 candidate 4's pre-pass is intentionally all-or-nothing:
  any non-DOM arg falling through to InputSampler.scalarFor aborts
  the smoke rather than going half-fixtured.  Do NOT relax this
  guard.
- **MATLAB sprintf vs. Windows path backslashes**: Phase 14
  documented this; carries forward unchanged.
- **mlreportgen.dom emits a per-document _docs intermediate**
  (carried forward from operational notes).  RptgenBackend doesn't
  explicitly clean this up at present; if `_autotest/reports/` is
  cluttered after a few runs, add a `rmdir(_docs, 's')` to the
  RptgenBackend constructor.  Out of scope for Phase 15.
- **OoxmlBackend cannot overwrite a `.docx` open in Word.**
  ReportBuilder attempts `delete(docxPath)` first; if that fails it
  renames the file out of the way with a `.locked-HHMMSS.bak`
  suffix.  Operators should close Word before re-running.

## Phase 16 candidates (suggested, all generic)

1. **ContainerType-aware smoke VALUE synthesis.**  Mirror Phase 15
   candidate 1 on the value side.  Effort: medium.
2. **mlreportgen.dom `_docs` cleanup.**  RptgenBackend post-close
   teardown.  Effort: trivial.
3. **OoxmlBackend page-number footer.**  Add a `word/footer1.xml`
   with `<w:fldSimple w:instr="PAGE"/>` and the corresponding
   relationship; reference from `<w:sectPr>`.  Effort: low.
4. **Multi-language locale support in DistributionStatement D.**
   Currently English-only; localise via inputParser parameter.
   Effort: low.

## Verification one-liners (recap)

```matlab
% End-to-end Phase 15 driver (writes _phase15_status.json)
cd 'C:\Users\Duy\Projects\matlabunittest'
run('_phase15_run_all.m')

% Manual: PROJECT run with native report
close all force; delete(findall(0,'Type','figure')); clear classes;
addpath('C:\Users\Duy\Projects\matlabunittest');
info = autotest.runWorkflow( ...
    'C:\Users\Duy\OneDrive\Documents\MATLAB\removal_redaction_tool', ...
    'GenerateReport', true, ...
    'ReportOptions', struct( ...
        'DisplayName',            'Removal/Redaction Tool', ...
        'Owner',                  'Project Owner -- Removal/Redaction Tool', ...
        'ProjectPrefix',          'RR', ...
        'DistributionReason',     'Administrative or Operational Use', ...
        'DistributionDate',       'May 2026', ...
        'DistributionController', 'the Project Owner'));
disp(info.Summary)
fprintf('Doc:    %s\n', info.ReportDocxPath);
fprintf('PDF:    %s\n', info.ReportPdfPath);
fprintf('Backend: %s\n', info.ReportBackend);

% Manual: matlabunittest examples (portability test)
close all force; delete(findall(0,'Type','figure')); clear classes;
info = autotest.runWorkflow( ...
    'C:\Users\Duy\Projects\matlabunittest\examples', ...
    'GenerateReport', true);
disp(info.Summary)
```

Both must report `failed: 0` AND produce a `.docx` (and ideally
`.pdf`) in `<projectFolder>/_autotest/reports/`.
