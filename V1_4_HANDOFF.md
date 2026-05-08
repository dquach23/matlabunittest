# v1.4 handoff -- matlabunittest

Read this if you're picking up after the v1.3 work on 2026-05-08.

## Naming change (was "Phase N", now "vM.N")

Cycles previously called "Phase N" now track the DocVersion field that
ships in each generated system test report's metadata table.  v1.3
bumped DocVersion 1.1 -> 1.3.  Pre-1.3 history is preserved in
PHASE<N>_HANDOFF.md.  New cycles use V<MAJOR>_<MINOR>_HANDOFF.md.

When v1.4 ships, name the next handoff `V1_5_HANDOFF.md`; if the
cycle includes a public-API break (e.g., dropping a tier or changing
the autogen contract), bump to v2.0 and call the next brief
`V2_0_HANDOFF.md` / `V2_1_HANDOFF.md`.

## TL;DR of v1.3

**v1.3 = three new generic autogen mechanisms (validator pulls,
composite stringy-suffix parity, scalar-shaped randomization) +
self-attesting content checksum embedded in the .docx + audit
sidecar surfaced through runWorkflow.**

Verification:

- removal_redaction_tool: PASSED 571 / 583 generated (97.9%); FAILED 0;
  INCOMPLETE 12 (all `testSkipped_*` opt-outs in `known_real_signal.txt`;
  zero real autogen residuals -- down from 6 in Phase 16).
- matlabunittest/examples: 95 / 95 (100%); FAILED 0; INCOMPLETE 0.

Self-attesting content checksum verified end-to-end: extract embedded
hex -> reverse-substitute the sentinel inside `word/document.xml` ->
sha256 -> matches the embedded hex.

## Tier configuration on this machine (and the user's work machine)

| Component                  | This machine     | Work machine   | v1.3 status |
|----------------------------|------------------|----------------|-------------|
| MATLAB Report Generator    | unlicensed (-5.2)| unlicensed     | DROPPED items 1, 4 |
| LibreOffice                | not installed    | not installed  | unavailable |
| Word COM (`actxserver`)    | works            | likely blocked | not used   |

License error -5.2 is "feature not in license file", not deactivation.
Reactivation cannot fix it -- the toolbox is not in the user's
license entitlement.  v1.3 verification therefore ran on
`OoxmlBackend` and produced a `.docx` + audit sidecar but no PDF.

## Conditionally-blocked items (revive when a tier opens up)

These items were originally Phase 17 Part B items 1 and 4.  They are
RptgenBackend-specific and have nothing to do until the toolbox is
licensed.

1. **RptgenBackend two-section sectPr** -- mirror what
   `OoxmlBackend.coverSectionBreak()` does so the cover page doesn't
   show "Page 1 of N" alongside the Distribution Statement D box on
   the rptgen-emitted .docx.  Implementation note: use
   `mlreportgen.dom.DOCXSection` or `DOCXPageLayout.FirstPageHeader`/
   `FirstPageFooter` overrides.
2. **RptgenBackend PDF refresh on emit** -- verify
   `mlreportgen.utils.docToPDF` produces a .pdf with TOC page numbers
   populated automatically.  Likely true; needs running to confirm.

If the user installs LibreOffice instead of getting Report Generator,
the existing `+autotest/+report/PdfBackend_LibreOffice.m` tier
already has the UNO macro for TOC refresh -- it would just start
firing on its own; no autogen change needed.  Item 1 stays
RptgenBackend-only.

## v1.4 candidates (suggested, all generic)

1. **TestWriter.m line growth.**  TestWriter is now ~1900 lines and
   accumulates one helper per cycle.  v1.4 could refactor the
   stringy-name / fileID-name / DOM-name / scalar-shaped-name
   classifier methods into a single `+autotest/ArgClassifier.m`
   that returns a kind enum -- shrinks both TestWriter and
   InputSampler.typesFromArguments and makes the name heuristics
   easier to test in isolation.
2. **`mustBeNonzeroLengthText` / `mustBeFolder` / `mustBeFile`
   pulls.**  v1.3 covered `mustBeNonempty` / `mustBeFinite` /
   `mustBeReal` / `mustBePositive` / `mustBeText`.  The remaining
   single-constraint validators in the MATLAB stdlib are all worth
   pulling once a project on the user's docket actually uses them.
3. **`MlappParser` example-block parity verification on a
   real-world target.**  v1.3 cand 4 was dormant on
   `removal_redaction_tool` because RedactionToolGUI.mlapp has
   0/10 methods with Example: blocks.  Re-run cand 4 against any
   future .mlapp target that does have multi-line Example: bodies.
4. **Constructor-graph fallback for stateful smokes (was Phase 17
   cand 3).**  Skipped in v1.3 because the only Phase 16 residual
   it would have addressed was the cleanWorkbook/RenameXML cwd
   bug -- a project bug routed to known_real_signal.txt instead.
   Keep this card in the deck for any future project where the
   ctor itself fails and a fixture replay would help.
5. **Validator-driven smoke filtering.**  v1.3 cand 2 filters
   *edges*; smokes don't currently consult validators (FixtureProvider
   already produces literals that pass most of them).  Worth a
   pass to confirm there's no project where a smoke literal trips
   `mustBeMember` at the boundary, but low priority.

## Pitfalls (carried forward from Phase 16, plus v1.3 additions)

- **No PDF tier on this license configuration.**  The .docx is the
  sole deliverable.  See "Tier configuration" above.  If a future
  cycle adds an alternative PDF tier (e.g., Word COM gated to
  home-only), make it explicit in `BackendDetector.PdfCandidates`
  so it's discoverable without code-reading.
- **MATLAB Report Generator deactivation client (Phase 16).**  If a
  "Software Deactivation Required" dialog appears mid-cycle, close
  it via the X, NEVER click Deactivate.  In this case the underlying
  state (no license entitlement) is unfixable from the deactivation
  client.
- **MATLAB regex line-continuation bug (Phase 6).**  Prefer `contains`
  over `regexp` when literal `\.` spans string-concat continuations.
- **Half-fixtured smokes can hang the test runner (Phase 12).**  v1.3
  did not relax Phase 16 cand 1's short-circuit-on-empty in
  `tryDomFullFixtureSmoke`.  Do not relax it in v1.4 either.
- **OoxmlBackend cannot overwrite a .docx open in Word.**  v1.3
  workflow run hit this -- Word had the previous report open and
  the rebuild's `delete()` + `movefile()` both failed.  ReportBuilder
  has a `.locked-HHMMSS.bak` rename fallback but it is best-effort.
  Operators should close Word before re-running the workflow, or
  use `system('taskkill /F /IM WINWORD.EXE')` from MATLAB if Word
  isn't responsive.
- **MATLAB `zip()` is non-deterministic.**  v1.3 originally tried to
  embed a sha256 over the entire .docx zip and discovered the
  re-zip produces different bytes (timestamps, part order).  The
  shipped design hashes `word/document.xml` directly instead -- the
  document content, not the zip wrapper -- so the verification recipe
  is robust.  If a future cycle changes embedSelfChecksum to hash the
  whole .docx, the recipe breaks.
- **Stringy-name retyping vs edge count.**  v1.3 cand 2 retypes
  `*Name` / `*Text` args from double to string when the source has
  no arguments block.  Side effect: edge count drops 5 per such arg
  (7 numeric edges -> 2 string edges).  This is a quality
  improvement -- the dropped edges crashed inside strlength/regexp
  chains -- but absolute test counts can shift by tens of tests
  cycle-over-cycle.  Don't gate on absolute pass-count; gate on
  pass rate and on `failed: 0`.

## Verification one-liners

```matlab
cd 'C:\Users\Duy\Projects\matlabunittest'

% Examples portability check.
close all force; delete(findall(0,'Type','figure')); clear classes;
addpath('C:\Users\Duy\Projects\matlabunittest');
info_ex = autotest.runWorkflow( ...
    'C:\Users\Duy\Projects\matlabunittest\examples', ...
    'GenerateReport', true);
disp(info_ex.Summary)

% Project goal-line.
close all force; delete(findall(0,'Type','figure')); clear classes;
info = autotest.runWorkflow( ...
    'C:\Users\Duy\OneDrive\Documents\MATLAB\removal_redaction_tool', ...
    'GenerateReport', true, ...
    'ReportOptions', struct( ...
        'DisplayName',            'Removal/Redaction Tool', ...
        'Owner',                  'Project Owner -- Removal/Redaction Tool', ...
        'DocVersion',             '1.3', ...
        'ProjectPrefix',          'RR', ...
        'DistributionReason',     'Administrative or Operational Use', ...
        'DistributionDate',       'May 2026', ...
        'DistributionController', 'the Project Owner'));
disp(info.Summary)
fprintf('Doc:           %s\n', info.ReportDocxPath);
fprintf('PDF:           %s\n', info.ReportPdfPath);
fprintf('Sidecar:       %s\n', info.AuditSidecar);
fprintf('Backend:       %s\n', info.ReportBackend);
```

Goal-line:

- removal_redaction_tool: `failed: 0`, `passed >= 571` (97.9% of 583
  generated), generated `incomplete: <= 12` (all opt-outs in
  known_real_signal.txt; zero real autogen residuals).
- matlabunittest/examples: `failed: 0`, `passed: 95`, `incomplete: 0`.
- `info.ReportBackend = 'OoxmlBackend (hand-rolled OOXML + builtin zip)'`.
- `info.ReportPdfPath` is empty (no PDF tier available on this license
  configuration -- expected, documented).
- `info.AuditSidecar` non-empty.
- The .docx contains an embedded sha256 in Appendix E.5 that round-trips
  via the verification recipe (substitute hex back to
  `__DOCX_SHA256_SLOT__` inside `word/document.xml`, sha256 the file,
  result equals the inline hex).
