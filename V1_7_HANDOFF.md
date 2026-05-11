# v1.7 handoff -- matlabunittest

Read this if you're picking up after the v1.6 work on 2026-05-11.

## TL;DR of v1.7

**v1.7 = explicit classification picker + heavy docx visual refinement
(cover redesign, real static TOC, horizontal callouts, KPI strip,
section dividers, page header, drop-cap H1 numerals, badge baseline
alignment).**  Autogen mechanism unchanged from v1.5; deliverable
changes live in the report stack (`+autotest/+report/**`).

## What shipped

### Classification picker (the user-controlled marking source-of-truth)

`Classification` is now an explicit, validated enum.  Pass via
`ReportOptions.Classification`; defaults to UNCLASSIFIED.

```matlab
% Default (UNCLASSIFIED).
info = autotest.runWorkflow(folder);

% Explicit higher tier.
info = autotest.runWorkflow(folder, 'ReportOptions', ...
    struct('Classification', 'SECRET'));

% Standalone re-emit at a different tier.
info = autotest.generateReport(folder, 'Classification', 'TOP SECRET//SCI');
```

Allowed values (case-insensitive, normalised on entry):

| Level                 | Portion code | Banner colour treatment        |
|-----------------------|--------------|--------------------------------|
| `UNCLASSIFIED`        | `(U)`        | plain text (DoDM 5200.01 V2)   |
| `UNCLASSIFIED//FOUO`  | `(U//FOUO)`  | plain text                     |
| `CONFIDENTIAL`        | `(C)`        | CAPCO blue   `#0033A0`         |
| `SECRET`              | `(S)`        | CAPCO red    `#C8102E`         |
| `TOP SECRET`          | `(TS)`       | CAPCO orange `#FF8C00`         |
| `TOP SECRET//SCI`     | `(TS//SCI)`  | CAPCO yellow `#FCE300` (black text) |

Any other value errors fail-loud at the workflow boundary
(`autotest:report:BadClassification`) with the full allowed list
printed.  The validated, normalised value also lands in summary.txt:

```
autotest run summary
====================
Classification:   SECRET
Timestamp:        20260511-111913
...
```

Single source of truth lives in `+autotest/+report/Style.m::
allowedClassifications()`.  Add new levels there ONLY; the marking
helpers (`portionCode`, `classificationFill`,
`classificationBannerText`, `isUnclassified`) all key off these
strings.

### Docx visual refinements

1. **Cover-page redesign.**  Optional charcoal monogram top-left
   (from `ProjectPrefix`, e.g. "RR" for removal_redaction_tool).
   Title at 56pt bold Calibri charcoal; full-width 2pt muted-gold
   rule directly under the title; subtitle in Georgia italic 16pt
   slate.  Metadata table: hairline grey top + bottom borders +
   interior horizontals only, slate uppercase right-aligned keys,
   charcoal left-aligned values, even cell padding.  Distribution
   Statement D box wrapped in a 1.5pt deep-red border
   (`Style.FailEmphasis`) instead of v1.4's heavy black.

2. **Real static numbered TOC with dotted leaders.**  Drops the
   field-code TOC for docx in favour of an explicit numbered list
   with right-aligned em-dash placeholders and dotted-leader tab
   fill between label and page number.  Word populates real page
   numbers on first open (or via right-click "Update Field" on the
   field-code TOC).  Light alternating-row shading on rows for
   legibility.

3. **Horizontal callout strip.**  Section 1's four exec-summary
   callouts (tests generated / passed / failed / pass rate) now sit
   side-by-side in a single 4-cell parent table at content width
   -- layout parity with the HTML inline-block treatment.  Each
   callout: 22pt accent-coloured value, 8pt slate uppercase caption,
   thick left accent border on light-grey fill.

4. **Section dividers.**  Lightweight centred three-dot accent
   ornament (`• • •` in muted gold) between major sections.
   Visually lighter than a horizontal rule; helps the eye chunk
   without screaming "page break."

5. **Page header.**  Running pages (everything past the cover) carry
   project name left + document version right in Calibri 9pt slate,
   under a thin grey rule, under the classification banner.  Cover
   keeps banner-only via a second header part bound to the cover
   section.  Implemented as two header parts (`header1.xml` banner-
   only, `header_main.xml` banner + project + version) with the
   main-section sectPr binding `rIdHeaderMain`.

6. **Status badge baseline alignment.**  v1.6 badges sometimes
   broke row height because their cell padding diverged from
   non-badge cells.  v1.7 matches top/bottom padding (80 DXA) and
   adds `<w:vAlign w:val="center"/>` so badges sit on the row
   baseline without bumping height.

7. **KPI strip below callouts.**  Full-width banded row with four
   centre-aligned metrics (total tests / pass rate / failures / run
   date), packed with hairline vertical dividers and a top + bottom
   accent rule.  Glanceable status banner that complements the
   callout cards above it.

8. **(Bonus) Drop-cap H1 numerals.**  Level-1 headings that begin
   with `<number>. ` (the section prose convention) render the
   numeral as a 36pt muted-gold display-weight drop cap, followed
   by the rest of the heading in standard 16pt Calibri charcoal
   bold.  Non-numbered H1s (e.g. "Failed Tests (9)") fall through
   to plain rendering.

## v1.7 LOCKED PALETTE (carries v1.4/v1.6, adds TS//SCI yellow)

Unchanged from v1.6 except the addition of CAPCO yellow:

| Use                                | Hex      | Name              |
|------------------------------------|----------|-------------------|
| TOP SECRET//SCI banner fill (v1.7) | `#FCE300`| CAPCO yellow      |

CAPCO yellow uses black banner text (every other classification uses
white) because yellow + white fails contrast.

## How callers select classification (the user-asked clarification)

The user controls the classification by passing `'Classification'`
inside `ReportOptions`:

```matlab
% runWorkflow ------------------------------------------------------
info = autotest.runWorkflow(folder, 'ReportOptions', ...
    struct('Classification', 'SECRET'));

% generateReport (standalone, since v1.6) --------------------------
info = autotest.generateReport(folder, 'Classification', 'TOP SECRET');

% generateReport via shared ReportOptions struct -------------------
opts = struct( ...
    'DisplayName',    'Removal/Redaction Tool', ...
    'Classification', 'CONFIDENTIAL', ...
    'DistributionDate','May 2026');
info = autotest.generateReport(folder, 'ReportOptions', opts);
```

Errors thrown at the boundary when the value is outside the allowed
set, with the full list printed in the error message.

## Files changed in v1.7

| File | Change |
|---|---|
| `+autotest/+report/Style.m`                  | + allowedClassifications / validateClassification / classificationBannerText helpers; portionCode + classificationFill + isUnclassified extended to handle U//FOUO and TS//SCI; TitleFontSize 96 -> 112 (56pt); SubtitleFontSize 36 -> 32 (16pt); + MonogramFontSize |
| `+autotest/+report/SectionBuilder.m`         | + maybeDivider; emit() calls divider() between major sections; cover() routes ProjectPrefix into Monogram field and calls setPageHeader; executiveSummary uses addCalloutRow + addKpiStrip when available |
| `+autotest/+report/ReportBuilder.m`          | applyDefaults validates Classification + bumps DocVersion default 1.6 -> 1.7; docx path uses addStaticTOC when available; canonical tocEntries list built from Section labels |
| `+autotest/+report/+backends/OoxmlBackend.m` | + PortionCode immutable property; + PageHeaderTitle/PageHeaderVersion mutable properties; + setPageHeader; + addCalloutRow (horizontal layout); + addKpiStrip; + addSectionDivider; + addStaticTOC (numbered with dotted leaders); + dropCapHeadingXml (H1 numbered drop cap); + monogramParagraph / titleAccentRule / coverMetadataTable / headerMainXml private helpers; addCoverPage redesign; distBoxXml deep-red border; cellXml [STATUS:] padding match + vAlign center; main sectPr binds rIdHeaderMain; contentTypesXml + docRelsXml emit header_main.xml binding; close() writes header_main.xml |
| `+autotest/runWorkflow.m`                    | validates Classification up front; passes normalised value to writeSummary; surfaces `Classification:` line at top of summary.txt |
| `+autotest/generateSystemTestReport.m`       | DocVersion default 1.6 -> 1.7 |
| `CHANGELOG.md`                               | v1.7 entry |
| `V1_7_HANDOFF.md`                            | this file |

## Verification (run on this machine)

```matlab
close all force; delete(findall(0,'Type','figure')); clear classes;
addpath('C:\Users\Duy\Projects\matlabunittest');

% Full workflow, default UNCLASSIFIED.
info = autotest.runWorkflow( ...
    'C:\Users\Duy\OneDrive\Documents\MATLAB\removal_redaction_tool');

% Standalone, explicit classification (validates against the allowed set).
info2 = autotest.generateReport( ...
    'C:\Users\Duy\OneDrive\Documents\MATLAB\removal_redaction_tool', ...
    'Classification', 'SECRET');

% Bad input -- errors fail-loud with the allowed list.
try
    autotest.generateReport(folder, 'Classification', 'NOT_A_LEVEL');
catch ME
    fprintf(2, '%s\n', ME.message);
end
```

Goal-line on `removal_redaction_tool`:

- HTML + Docx both produced (best-effort independent paths since
  v1.5.1).
- Docx for SECRET classification shows: red CAPCO banner top + bottom;
  `(S)` portion markings on every body paragraph and heading (303
  marks confirmed); 56pt title; full-width gold rule under title; 4
  callouts side-by-side; KPI strip below; numbered TOC with dotted
  leaders; muted-gold drop cap on Section 1/2/.../10 H1 headings.
- summary.txt starts with `Classification: SECRET`.

## Pitfalls carried forward

Unchanged from v1.6:

- **MATLAB Report Generator unlicensed on both machines.**
  OoxmlBackend remains the only docx tier; HtmlBackend the only
  truly portable deliverable.
- **OoxmlBackend cannot overwrite a .docx open in Word.**  Close
  Word before running.
- **MATLAB `zip()` is non-deterministic.**  The self-attesting
  checksum hashes `word/document.xml` content, not the .docx
  wrapper, so verification is robust to zip metadata jitter.

## v1.7-introduced tech debt for v1.8 to revisit

- **Static TOC page numbers are em-dashes** until Word renders.
  Adding a `pages` field to `tocEntries` (filled by a post-render
  Word COM pass on machines that have Word) would close that gap.
  Out of scope for v1.7 because Word COM is blocked on the work
  machine.
- **Section dividers between numbered sections may stack against
  page breaks** in Appendices.  Current `emit()` flow inserts a
  divider between each major section but appendices use
  `addPageBreak` between themselves; no divider gets emitted
  there.  Could be unified into a single `endOfSection(backend)`
  helper that decides between divider / page break / nothing.
- **Drop-cap heading numeral detection is a regex** on the heading
  text.  Works because the section labels follow `"N. Title"`
  convention.  A more robust approach is to pass `level + index`
  explicitly into addHeading and have the backend compose the
  drop cap from those.
- **Monogram derives from ProjectPrefix.**  For projects with a
  bespoke logo, an `opts.MonogramOverride` ReportOption would let
  the caller drop in a longer text emblem without renaming the
  ProjectPrefix.

## After v1.7 verification passes

```bat
cd C:\Users\Duy\Projects\matlabunittest
git diff --stat HEAD
git commit -am "v1.7: classification picker + heavy docx visual refinement"
git push
```
