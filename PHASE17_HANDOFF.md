# Phase 17 handoff -- matlabunittest

Read this if you're picking up after the Phase 16 work on 2026-05-07.

## TL;DR

**Phase 16 = five new generic autogen mechanisms (container-typed
sibling substitution, live-state-aware VALUE synthesis, drop-stateful-
wrap-when-clean gate, mustBeMember validator pulls, doc-example
parser hardening) + an "official-grade" extension to the native
MATLAB report generator (page-number footer, two-section sectPr,
LibreOffice UNO macro for TOC refresh, RptgenBackend `_docs` cleanup,
cluster-grained DefectRegister, Appendix B fidelity raise, NEW
Appendix E Audit Trail backed by a sha256 sidecar).**

Verification of both targets is **blocked on a MathWorks Software
Deactivation Required dialog** that appeared during the Phase 16
session and was left untouched per safety policy (license deactivation
is a destructive change requiring user action, not Claude's).  When
the operator dismisses that dialog (X in top-right, NOT Deactivate),
re-run the master driver to capture the goal-line numbers and emit
the deliverables:

```matlab
cd 'C:\Users\Duy\Projects\matlabunittest'
% Examples portability smoke first.
close all force; delete(findall(0,'Type','figure')); clear classes;
addpath('C:\Users\Duy\Projects\matlabunittest');
info = autotest.runWorkflow( ...
    'C:\Users\Duy\Projects\matlabunittest\examples', ...
    'GenerateReport', true);
disp(info.Summary)
% Then the project goal-line.
close all force; delete(findall(0,'Type','figure')); clear classes;
info = autotest.runWorkflow( ...
    'C:\Users\Duy\OneDrive\Documents\MATLAB\removal_redaction_tool', ...
    'GenerateReport', true, ...
    'ReportOptions', struct( ...
        'DisplayName',            'Removal/Redaction Tool', ...
        'Owner',                  'Project Owner -- Removal/Redaction Tool', ...
        'DocVersion',             '1.1', ...
        'ProjectPrefix',          'RR', ...
        'DistributionReason',     'Administrative or Operational Use', ...
        'DistributionDate',       'May 2026', ...
        'DistributionController', 'the Project Owner'));
disp(info.Summary)
fprintf('Doc:           %s\n', info.ReportDocxPath);
fprintf('PDF:           %s\n', info.ReportPdfPath);
fprintf('Audit Sidecar: %s\n', info.AuditSidecar);
fprintf('Backend:       %s\n', info.ReportBackend);
```

Both must report `failed: 0`.  PROJECT must additionally report
`passed: >=927` (>=95% of 976 generated).

## Phase 16 implementation -- Part A autogen candidates

### Candidate 1 -- container-typed sibling substitution

When a method's positional arg is shape-typed (`containers.Map` /
`dictionary` / `table` / `struct`) AND a public class property of
that same shape matches by name (case-insensitive, plural-aware),
the synthetic literal is replaced with `testCase.Instance.<propName>`
so the smoke operates against the live container.

Implementation:

- `+autotest/StateInitializer.m::liveContainerExpr(propName, propType)`
- `+autotest/TestWriter.m::applyContainerSubstitution(smartCase, fcn, kind)`
- `+autotest/TestWriter.m::matchArgToContainerProperty(argName, argType, props)`

Wired into `appendFunctionMethods` after the Phase 15 candidate-1
loop.  Sets `smartCase.DropStatefulWrap = true` when any substitution
happened, so the caller drops Phase 11's try/assumeFail wrap.

Generic across MATLAB projects -- pure shape + name similarity,
no project-specific knowledge.

**Targeted remediation**: the RR-005 / RR-007 cascade (opaque-typed
Map / dictionary positional args on stateful classes).  Methods
whose Map / dictionary arg comes from a sibling property rather
than from the constructor-staged fixture should now flip from
Incomplete to Pass once the prelude verifiably populates state.

### Candidate 2 -- live-state-aware VALUE synthesis

Symmetric to Phase 15 candidate 1 on the value side.  When a method's
declared arg type is `table` / `struct` / `cell` AND the class has
a property of that shape, draw a sample VALUE from the populated
property via `firstValueOr` instead of synthesising from
FixtureProvider's typed defaults.

Implementation:

- `+autotest/InputSampler.m::firstValueOr(container, fallback)` -- runtime helper
- `+autotest/StateInitializer.m::liveValueExpr(propName, propType, fallback)` -- emit
- `+autotest/TestWriter.m::applyLiveKeySubstitution` -- extended with a value path
- `+autotest/TestWriter.m::matchArgToValueProperty(argName, argType, props)` -- helper

The key path runs first; if no key match, the value path is tried.
Key-shaped args (suffix `name`/`id`/`key`) still get the key
expression; value-shaped args of `table` / `struct` / `cell` type
get the value expression.

### Candidate 3 -- drop the stateful wrap when prelude succeeded

Phase 11's try/assumeFail wrap converts every throw on a stateful-
class smoke to Incomplete.  After Phase 15 cand 1 / cand 4 / Phase
16 cand 1, many of those smokes should report Pass or Failed
honestly.  Generic gate:

- (a) every smartCase arg resolved cleanly (smartFor's all-or-nothing
  resolution; reaching the gate means provider.literalForArg
  returned non-empty for every input -- no fallback to scalarFor),
- (b) the model has at least one state-init candidate detected by
  `StateInitializer.candidateMethodCalls`,
- (c) the FixtureProvider has at least one primary fixture
  (PrimaryExcel / PrimaryImage / PrimaryKeepList).

Implementation:

- `+autotest/TestWriter.m::markDropStatefulWrapIfClean(smartCase, fcn, kind)`
- `+autotest/TestWriter.m::fixtureProviderHasPrimary(provider)`

Wired into `appendFunctionMethods` after the cand-1 loop, before
the appendCallTest emission loop.

### Candidate 4 -- mustBeMember validator pulls

When an `arguments` block declares `mustBeMember(arg, list)` with
a literal list, pull the first allowed value as the smoke literal.

Implementation:

- `+autotest/InputSampler.m::typesFromArguments` -- extended to
  populate `info.MustBeMember`
- `+autotest/InputSampler.m::parseMustBeMember/parseAllowedListLiteral/scanQuoted`
  -- paren-balanced parser, recognises string array (`["a","b"]`),
  cellstr (`{'a','b'}`), and numeric array (`[1 2 3]`) list forms;
  symbol references return empty so the consumer cleanly falls back
- `+autotest/FixtureProvider.m::literalForArg` -- new branch
  consuming `argInfo.MustBeMember`, inserted AFTER the Phase 14
  typed table/cell branch and BEFORE the Phase 15 cand-5 data /
  value / payload branch

Generic across MATLAB projects.  Dormant on
`removal_redaction_tool` (no `mustBeMember` validators in the
project's classes); high-leverage on any project with strict input
validation.

### Candidate 5 -- doc-example parser hardening

`MFileParser.collectExampleBlock` rewritten to tolerate multi-line
bodies with internal blank lines.  Termination conditions:

1. Recognised heading (`See also:`, `Inputs:`, `Outputs:`,
   `Notes:`, `Arguments:`, `Returns:`, `Description:`, `Syntax:`).
2. Two consecutive blank lines.
3. Single blank followed by an unindented non-heading.

Indented (2+ spaces) lines remain continuation regardless of
intervening single blanks.

`+autotest/TestWriter.m::appendDocExampleTest` extended: when the
extracted text contains an `=` assignment, route through
`runIsolatedExample` (inlined helper, `clearvars`-then-`eval` in
its own local frame) so workspace state cannot leak between
example invocations even on test runners that reuse workers.

## Phase 16 implementation -- Part B native report generator

### Item 1 -- OoxmlBackend page-number footer

`OoxmlBackend.close` now writes `word/footer1.xml` and
`word/_rels/footer1.xml.rels` in addition to the existing parts.
`contentTypesXml` registers the footer; `docRelsXml` adds the
`rIdFooter` relationship.

Footer body: centred 9pt Calibri "Page X of Y" using
`<w:fldSimple>` PAGE / NUMPAGES fields.  Word refreshes both
fields on first open via the existing `<w:updateFields w:val="true"/>`
in settings.xml.

`Style.FooterFontSize = 18` (half-points) added.

### Item 2 -- two-section sectPr

`OoxmlBackend.addCoverPage` now ends with `coverSectionBreak()`
(a section-break paragraph carrying the cover-page sectPr with
`titlePg=true` and no footer reference) instead of `addPageBreak()`.
The final `<w:sectPr>` at the end of `<w:body>` -- which applies
to the LAST section, i.e. the main body -- carries the
`<w:footerReference w:type="default" r:id="rIdFooter"/>`.

`xmlns:r` added to the document element so `r:id` resolves.

`RptgenBackend` mirrors via a centred Page X of Y footer attached
to `PageFooters(1)` in the constructor.  Best-effort -- rptgen
footer API varies between R-versions; failure is non-fatal.

### Item 3 -- LibreOffice UNO macro for TOC refresh

NEW class `+autotest/+report/PdfBackend_LibreOffice.m`.  Wraps the
LibreOffice tier with a StarBasic macro that walks
`oDoc.DocumentIndexes` and updates each one before
`storeToURL writer_pdf_Export`.

Two-tier strategy:

1. Provision a fresh user profile via `-env:UserInstallation=...`
   with the macro library pre-installed, then invoke
   `macro:///Standard.AutoTOC.RefreshAndExport(<inUrl>,<outUrl>)`.
2. On any failure, fall back to bare `--convert-to pdf` (yields a
   .pdf with an unpopulated TOC page-number column; better than
   no PDF).

Dormant on installations with MATLAB Report Generator -- those
go through `RptgenBackend.renderPdf` (mlreportgen.utils.docToPDF).
This tier is the portability fallback for installations without
Report Generator.

### Item 4 -- RptgenBackend `_docs` cleanup

`RptgenBackend.close` now best-effort `rmdir(_docs, 's')` to
remove the per-document `_docs` intermediate that mlreportgen.dom
emits next to the .docx.  Repeat runs leave `_autotest/reports/`
tidy.

### Item 5 -- DefectRegister cluster-grained entries

`DefectRegister.build` refactored to emit a separate defect entry
per distinct failure cluster within a class, instead of collapsing
all of `tExcelProcessor`'s stateful-input-mismatches into one
entry.

Cluster signature: first 60 chars of the diagnostic message, with
quoted literals and numbers normalised to placeholders, lowercased.
Tests with the same underlying root error cluster together;
method-name churn does not force a new cluster.

Findings field cites the most common diagnostic verbatim
(truncated to 200 chars).  Status field maps RR-NNN to user-stub
file paths via `userStubMitigation`.

Helpers added: `groupStatefulByCluster`, `clusterSignature`,
`mostCommonMessage`, `titleSuffixFromMessage`, `userStubMitigation`,
`demangleStruct`.

### Item 6 -- Appendix B fidelity

`SectionBuilder.diagnosticSamples` cap raised from 3 to 6 samples
per defect.  When the defect carries `AffectedMethods` (set by the
stateful-cluster path), prefers samples from those exact methods
(cluster-precise filtering).  Belt-and-braces guarantees every
Section-6 DEFECTID gets at least one sample in Appendix B even
when the per-cluster filter returns zero.

Per-message truncation stays at 1500 chars.

### Item 7 -- Appendix E (Audit Trail)

NEW.  Lists matlabunittest commit hash, tree-clean status,
test-cycle timestamp, Phase 16 verification status, Pass / Fail /
Incomplete counts, chosen backend, PDF tier, and a reference to
the audit sidecar (`<basename>_TestReport_audit.txt`) published
next to the deliverables.

The sidecar is generated AFTER both the .docx and the .pdf are
written (a file's sha256 cannot be embedded inside itself).
Sidecar contents:

- matlabunittest commit hash + tree-clean status
- Test-cycle timestamp + report build time
- Phase 16 verification status
- Generated tests passed / failed / incomplete
- Selected report backend + PDF tier
- sha256 of the .docx
- sha256 of the .pdf
- Verify-on-receipt instructions

Implementation:

- `+autotest/+report/SectionBuilder.m::appendixE(backend, ctx)`
- `+autotest/+report/ReportBuilder.m::collectAudit/gitProvenance/writeAuditSidecar/sha256OfFile/formatChecksum`

Provenance via `system('git rev-parse HEAD')` and
`git status --porcelain` from the matlabunittest repo path
(resolved from `mfilename('fullpath')`, no `pwd` dependency).

`info.AuditSidecar` added to the returned info struct.

## Phase 17 candidates (suggested, all generic)

1. **`mustBeNonempty` / `mustBeFinite` / `mustBeReal` validator pulls.**
   Phase 16 cand 4 covered `mustBeMember`; the other common single-
   constraint validators are similar low-effort wins on projects
   with strict input validation.
2. **Two-pass body emission for embedded sha256.**  Currently the
   .docx's own sha256 is in the sidecar (Appendix E references it).
   A two-pass build could emit a placeholder, compute the body
   hash, post-process the document.xml to substitute -- the
   .docx's sha256 then matches what's printed inside it.  Effort:
   medium (post-zip XML edit + re-zip).
3. **Mirror two-section sectPr in RptgenBackend.**  Phase 16 added
   the page-number footer to RptgenBackend but did NOT split the
   document into cover + main sections.  The cover therefore shows
   "Page 1 of N" alongside the Distribution Statement D box.  Use
   `mlreportgen.dom.DOCXSection` or `DOCXPageLayout` overrides to
   get parity with OoxmlBackend.
4. **Constructor-graph fallback when stateful smokes still
   Incomplete.**  When candidate 1 / 3 don't flip a smoke (e.g.
   the project's RR-004-class bugs are still unfixed), emit a
   "fixture-driven smoke" that explicitly builds the populator
   from the constructor-staged fixture.  Trickier than cand 1 --
   requires a mini call-graph for the constructor body.
5. **`MlappParser` example-block parity.**  Phase 16 cand 5 hardened
   `MFileParser.collectExampleBlock`; the .mlapp parser reuses
   it indirectly via the embedded classdef.  Verify the path actually
   benefits on a project with App Designer help-text examples.

## Pitfalls (carried forward)

- **MathWorks deactivation dialog mid-cycle**: if `Deactivate
  MATLAB R2025b` is launched (from the Start menu, by accident or
  otherwise), it spawns a "Software Deactivation Required" window
  that blocks MATLAB.  **Close it via the X**, not the Deactivate
  button.  Phase 16 was blocked on this.
- **Edit-tool truncation on TestWriter.m / FixtureProvider.m**
  (Phases 7+8+10+11+13+14+15): always use byte-level Python recipe
  via bash for non-trivial edits when running in a sandbox; in
  the user's MATLAB-only environment, prefer surgical
  `Edit`/`replace`-style operations and verify file integrity by
  loading the package.
- **Sandbox vs. Windows git index** (Phase 11+): use MATLAB
  `system('git ...')` for ALL git operations on the matlabunittest
  repo.  The Linux sandbox's `git status` shows wildly inaccurate
  output and any commit / push attempts fail with index-lock errors.
- **MATLAB regex line-continuation bug** (Phase 6): use `contains`
  over `regexp` when literal `\.` spans string-concat continuations.
- **Screenshot mask by exe basename** (Phase 9 / 15 / 16): grant
  `MATLAB R2025b` AND `matlab.exe` AND `matlabwindow.exe` so the
  running window is visible in screenshots.
- **Half-fixtured smokes can hang the test runner** (Phase 12).
  Phase 15 candidate 4's pre-pass and Phase 16 candidate 1's
  short-circuit-on-empty are intentionally all-or-nothing.  Do
  NOT relax these guards.
- **mlreportgen.dom emits a per-document `_docs` intermediate.**
  Phase 16 item 4 adds best-effort cleanup; if Word still has
  handles open, the rmdir silently fails and the directory
  persists harmlessly.
- **OoxmlBackend cannot overwrite a .docx open in Word.**
  ReportBuilder attempts `delete(docxPath)` first; if that fails
  it renames the file out of the way with a `.locked-HHMMSS.bak`
  suffix.  Operators should close Word before re-running.
- **AffectedMethods field MUST be present on every defect entry.**
  The `defects = struct(...)` initialiser declares the schema; if
  any code path emits a defect without `AffectedMethods`, the
  array assembly fails with a "subscripted assignment between
  dissimilar structures" error.  The Phase 16 init declares the
  field once; cluster-grained entries populate it; informational
  entries pass `{{}}`.

## Verification one-liners (recap)

```matlab
% After dismissing the MathWorks deactivation dialog:
cd 'C:\Users\Duy\Projects\matlabunittest'

% PROJECT goal-line.
close all force; delete(findall(0,'Type','figure')); clear classes;
addpath('C:\Users\Duy\Projects\matlabunittest');
info = autotest.runWorkflow( ...
    'C:\Users\Duy\OneDrive\Documents\MATLAB\removal_redaction_tool', ...
    'GenerateReport', true, ...
    'ReportOptions', struct( ...
        'DisplayName',            'Removal/Redaction Tool', ...
        'Owner',                  'Project Owner -- Removal/Redaction Tool', ...
        'DocVersion',             '1.1', ...
        'ProjectPrefix',          'RR', ...
        'DistributionReason',     'Administrative or Operational Use', ...
        'DistributionDate',       'May 2026', ...
        'DistributionController', 'the Project Owner'));
disp(info.Summary)
fprintf('Doc:           %s\n', info.ReportDocxPath);
fprintf('PDF:           %s\n', info.ReportPdfPath);
fprintf('Audit Sidecar: %s\n', info.AuditSidecar);

% Examples portability check.
close all force; delete(findall(0,'Type','figure')); clear classes;
info = autotest.runWorkflow( ...
    'C:\Users\Duy\Projects\matlabunittest\examples', ...
    'GenerateReport', true);
disp(info.Summary)
```

Goal-line:

- removal_redaction_tool: `failed: 0`, `passed: >=927` (>=95% of 976 generated).
- matlabunittest/examples: `failed: 0`, `passed: 95`.
