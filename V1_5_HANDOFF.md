# v1.5 handoff -- matlabunittest

Read this if you're picking up after the v1.4 work on 2026-05-10.

## Naming convention

Cycles track the DocVersion field that ships in each generated system
test report's metadata table.  v1.4 bumped DocVersion 1.3 -> 1.4.
Pre-1.3 history is preserved in PHASE<N>_HANDOFF.md.  When v1.5 ships,
name the next handoff `V1_6_HANDOFF.md`.  Public-API breaks bump to
v2.0; the next brief becomes `V2_0_HANDOFF.md` / `V2_1_HANDOFF.md`.

## TL;DR of v1.4

**v1.4 = customer-facing report polish + repo hygiene; no autogen
mechanism changes; goal-line preserved at v1.3 numbers.**

What shipped:
- Pie chart in Section 4 (pass / fail / incomplete) and horizontal
  bar chart in Section 5 (pass rate per source) -- both rendered to
  150-DPI PNGs via `figure -> pie/barh -> print('-dpng')`, embedded
  inline through a new `OoxmlBackend.addImage` path that registers
  PNG content type, mints image relationship Ids, and stages files
  into `word/media/`.
- Cover-page typography refresh: 48pt charcoal bold title, 18pt
  slate italic subtitle, 1pt muted-gold accent rule between the
  metadata table and the Distribution Statement D box.  Locked
  v1.4 palette documented in `Style.m`.
- Appendix B diagnostic samples now render as monospace + light-grey
  fill via a new `OoxmlBackend.addCodeBlock` method (Consolas with
  Cascadia / Courier fallback, `#F7FAFC` shading).
- CAPCO classification banner at top and bottom of every page,
  including the cover.  Per-level colour map locked in
  `Style.classificationFill`: UNCLASSIFIED -> `#007A33`,
  CONFIDENTIAL -> `#0033A0`, SECRET -> `#C8102E`,
  TOP SECRET -> `#FF8C00`, FOUO -> `#000000`, fallback -> `#1F2937`.
- Repo hygiene: `.gitignore` was truncated mid-line at "# lo" (229
  bytes) and missed the `_autotest/` rule; v1.4 repaired and added
  the v1.4 patterns.  The previously-untracked `+autotest/+report/*`
  files (Phase 15 added them but never `git add`'d) are now tracked.
  Eleven scratch files / two scratch directories were deleted from
  the working tree (see CHANGELOG for the list).
- Consolidation: dropped legacy `+autotest/ReportRenderer.m` and
  merged `+autotest/+report/CoverPage.m` into `SectionBuilder.cover`.
  Net -2 file count under `+autotest/**` vs v1.3 HEAD.

## v1.4 LOCKED PALETTE (carry this forward, do not drift)

| Use                                | Hex      | Name        |
|------------------------------------|----------|-------------|
| Headings, body text                | `#1F2937`| charcoal    |
| Metadata key cells, captions       | `#4B5563`| slate       |
| Rules, section markers, chart highlights | `#B45309`| muted gold  |
| Failed-count emphasis (sparingly)  | `#991B1B`| deep red    |
| Code-block fill (monospace)        | `#F7FAFC`| light grey  |
| Table headers (existing)           | `#E7E6E6`| light grey  |
| Metadata key cell shading (existing) | `#F2F2F2`| pale grey  |
| Page background                    | default  | paper-white |

These are the *only* colours used in the report body.  No gradients.
Failed-count `#991B1B` shows up only on non-zero failed counts and on
the Distribution Statement D box border.  Document the palette again
in any v1.5+ handoff that touches the report stack so future cycles
cannot drift.

## CAPCO classification colour map (locked in v1.4)

| Level         | Hex      | Source            |
|---------------|----------|-------------------|
| UNCLASSIFIED  | `#007A33`| CAPCO green       |
| CONFIDENTIAL  | `#0033A0`| CAPCO blue        |
| SECRET        | `#C8102E`| CAPCO red         |
| TOP SECRET    | `#FF8C00`| CAPCO orange      |
| FOUO          | `#000000`| CAPCO black       |
| (fallback)    | `#1F2937`| charcoal          |

Banner text is white, bold, centred, 11pt Calibri.  Banner appears in
both `header1.xml` (top) and `footer1.xml` (bottom, beneath the
existing Page X of Y line).  Cover-page section's `sectPr` carries
both `headerReference` + `footerReference` so the banner shows on the
cover too (CAPCO requires it on every page).

## Tier configuration on this machine (and the user's work machine)

| Component                  | This machine     | Work machine   | v1.4 status |
|----------------------------|------------------|----------------|-------------|
| MATLAB Report Generator    | unlicensed (-5.2)| unlicensed     | unchanged from v1.3; OoxmlBackend remains the only backend |
| LibreOffice                | not installed    | not installed  | unchanged from v1.3; no PDF tier |
| Word COM (`actxserver`)    | works            | likely blocked | not used by v1.4 |

License error -5.2 is "feature not in license file"; reactivation
cannot fix it.  v1.4 verification therefore runs on `OoxmlBackend`
only and produces a `.docx` + audit sidecar; no PDF.

## v1.4 deferrals (revive in v1.5+)

Carried over from V1_4_HANDOFF, NOT shipped by v1.4:

1. **`+autotest/ArgClassifier.m` consolidation refactor** (the V1_4
   handoff's "default candidate").  v1.4 deferred it deliberately so
   the customer-facing report polish landed cleanly without putting
   the heuristics-driven test count on the operating table at the
   same time.  v1.5 should re-prioritise this:
   - Consolidate the scattered name/type heuristics in
     `InputSampler.typesFromArguments` and `TestWriter.randomArgsExpr`
     (plus the `isFileIDName`, `isDOMName`, `isDOMType`,
     scalar-shaped detection, stringy-suffix detection,
     validator-flag plumbing) into a single classifier that returns
     a kind enum (`fileid` / `dom` / `scalar_index` / `stringy` /
     `numeric` / `opaque` / `default`) plus a constraint struct.
   - Net effect: fewer files, simpler autogen contract, classifier
     can be unit-tested in isolation.
   - The refactor adds 1 file (`ArgClassifier.m`); pair it with one
     more deletion (e.g. merge `MlappFixtureProvider` into
     `FixtureProvider`) to keep the file-count delta non-positive.
2. **`mustBeNonzeroLengthText` / `mustBeFolder` / `mustBeFile`
   validator pulls.**  v1.3 covered the common single-constraint
   validators; the remainder are worth pulling once a project on
   the docket actually uses them.
3. **`MlappParser` example-block parity verification** on a real
   .mlapp target with multi-line `Example:` bodies.  Dormant on
   removal_redaction_tool because RedactionToolGUI.mlapp has 0/10
   methods with `Example:` blocks.
4. **Constructor-graph fallback for stateful smokes** (was Phase 17
   cand 3).  Skipped in v1.3 because the only Phase 16 residual it
   would address was already routed to `known_real_signal.txt`.
   Keep this card in the deck.
5. **Validator-driven smoke filtering.**  v1.3 cand 2 filters edges;
   smokes don't currently consult validators.  Worth a pass to
   confirm there's no project where a smoke literal trips
   `mustBeMember` at the boundary.

## v1.4-introduced tech debt for v1.5 to revisit

- **`OoxmlBackend.addImage` sizing is caller-controlled in DXA.**
  v1.4 callers pass fixed dimensions (5400x4500 for the pie, 8400 x
  variable for the bar).  If a future cycle adds a chart that
  doesn't fit US Letter content width (9360 DXA), the image will
  overflow the right margin.  Consider clamping inside `addImage`.
- **Chart PNG tempfiles aren't cleaned up.**  `renderPieChart` and
  `renderBarChart` use `tempname()` and never delete the file.
  Each MATLAB session leaks one PNG per chart per workflow run into
  `%TEMP%`.  Negligible in practice; tidy up if the dispenser ever
  becomes load-bearing.
- **The cover-page section's `sectPr` references the page-numbered
  footer.**  CAPCO required the banner on the cover, but the
  footer also carries Page X of Y -- so the cover page now shows
  "Page 1 of N" beneath the Distribution Statement D box.  v1.4
  accepted this trade-off (banner on cover > clean cover with no
  banner).  v1.5 could split the footer into two: a banner-only
  footer for the cover section and the existing banner+page-number
  footer for the main section.
- **`pie()` patch / text indexing.**  The chart code assumes pie's
  return is `[patch, text, patch, text, ...]` and walks odd
  indices.  This has been stable across MATLAB releases but is not
  documented.  Worth replacing with an explicit `isgraphics(h(k),
  'patch')` filter (already present, defensively).

## Pitfalls (carried forward from earlier cycles, plus v1.4 additions)

- **No PDF tier on this license configuration.**  The `.docx` is the
  sole deliverable.  Documented exhaustively in
  V1_4_HANDOFF; unchanged in v1.4.
- **MATLAB Report Generator deactivation client (Phase 16).**  If a
  "Software Deactivation Required" dialog appears mid-cycle, close
  it via the X, NEVER click Deactivate.
- **MATLAB regex line-continuation bug (Phase 6).**  Prefer `contains`
  over `regexp` when literal `\.` spans string-concat continuations.
- **Half-fixtured smokes can hang the test runner (Phase 12).**  v1.4
  did not relax Phase 16 cand 1's short-circuit-on-empty in
  `tryDomFullFixtureSmoke`.  Do not relax it in v1.5 either.
- **OoxmlBackend cannot overwrite a .docx open in Word.**  Carried
  over from v1.3 / Phase 17.  `v1_4_cleanup_and_verify.m` opens with
  `taskkill /F /IM WINWORD.EXE` for this reason; do the same in any
  v1.5 driver script.
- **MATLAB `zip()` is non-deterministic.**  Don't change
  `embedSelfChecksum` to hash the whole .docx; the existing
  document.xml-only hash is what makes the verification recipe
  robust.
- **Stringy-name retyping vs edge count.**  Carried from v1.3.  Don't
  gate on absolute pass-count; gate on pass rate and on `failed: 0`.
- **v1.4: image-relationship Ids must be unique across all sources.**
  `addImage` mints `rIdImg<N>` where N is `numel(ImageEntries) + 1`.
  If a future change adds another rel-emitting helper that ALSO
  uses the `rIdImg` prefix, change one of them.  The static rels
  `rId1`, `rId2`, `rIdHeader`, `rIdFooter` are reserved.

## Verification one-liners

```matlab
cd 'C:\Users\Duy\Projects\matlabunittest'

% v1.4 helper -- runs cleanup + both verification gates and writes
% v1_4_run_summary.txt next to itself.  Closes Word first (so the
% prior .docx isn't locked), deletes scratch, git-add's tracked
% package files, runs examples then RR.  ~3-5 minutes total.
v1_4_cleanup_and_verify

% Or run the gates manually:

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
        'DocVersion',             '1.4', ...
        'ProjectPrefix',          'RR', ...
        'DistributionReason',     'Administrative or Operational Use', ...
        'DistributionDate',       'May 2026', ...
        'DistributionController', 'the Project Owner', ...
        'Classification',         'UNCLASSIFIED'));
disp(info.Summary)
fprintf('Doc:     %s\n', info.ReportDocxPath);
fprintf('Sidecar: %s\n', info.AuditSidecar);
fprintf('Backend: %s\n', info.ReportBackend);
```

Goal-line:

- removal_redaction_tool: `failed: 0`, `passed >= 571` (97.9% of 583
  generated), generated `incomplete: <= 12` (all opt-outs in
  known_real_signal.txt; zero real autogen residuals).
- matlabunittest/examples: `failed: 0`, `passed: 95`,
  `incomplete: 0`.
- `info.ReportBackend = 'OoxmlBackend (hand-rolled OOXML + builtin zip)'`.
- `info.ReportPdfPath` is empty (no PDF tier available).
- `info.AuditSidecar` non-empty.
- The `.docx` opens cleanly in Word with the v1.4 polish visible:
  classification banner top + bottom in CAPCO green; refreshed cover
  typography (48pt charcoal title, 18pt slate italic subtitle, gold
  accent rule); pie chart in Section 4; bar chart in Section 5;
  monospace + light-grey Appendix B diagnostics.
- Self-attesting sha256 round-trip in Appendix E.5 still verifies.
- `git status --short` clean except for runtime outputs under
  `_autotest/` (gitignored as of v1.4).
- File count under `+autotest/**`: net -2 vs v1.3 HEAD.

## After v1.4 verification passes

```bat
cd C:\Users\Duy\Projects\matlabunittest
git diff --stat HEAD
git commit -am "v1.4: report polish (charts + cover refresh + Appendix B + CAPCO banner) + repo hygiene"
git push
```

(Run from MATLAB via `system(...)` if cmd.exe isn't convenient.
The `v1_4_cleanup_and_verify` script handles the staging but not
the commit -- intentional, so the operator inspects the diff before
shipping.)
