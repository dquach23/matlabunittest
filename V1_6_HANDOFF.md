# v1.6 handoff -- matlabunittest

Read this if you're picking up after the v1.5 / v1.5.1 work on 2026-05-11.

## TL;DR of v1.6

**v1.6 = official DoD markings + .docx polish + Failed Tests section
+ status badges + standalone regenerate-report command.**  The
autogen mechanism is unchanged from v1.5; the cycle's deliverable
changes all live inside the report stack
(`+autotest/+report/`, `+autotest/+report/+backends/`) plus a new
top-level `+autotest/generateReport.m` entry point.

What shipped:

1. **DoDI 5200.48 portion markings** -- every body paragraph and
   heading emitted by either backend now carries a parenthetical
   classification prefix `(U)`, `(C)`, `(S)`, `(TS)`, `(U//FOUO)`.
   Driven from the existing `Classification` ReportOption.
2. **DoDM 5200.01 V2 UNCLASSIFIED banner** -- UNCLASSIFIED docs now
   render the top + bottom banner as plain centred text (no
   coloured-fill block).  Higher classifications retain the v1.4
   CAPCO colour map.
3. **300-DPI charts + value labels** -- pie chart now burns percent
   labels onto each slice, hides labels for slices <5% to avoid
   crowding, and emits a separate right-side legend pane with
   coloured swatches + raw counts.  Bar chart prints right-of-bar
   `xx.x%   passed / total` value labels and a caption strip.  Both
   render at 300 DPI (was 150) and embed at full content width
   (9360 DXA, ~6.5") with proportional height.
4. **.docx typography refresh** -- body switched to Georgia 11pt
   justified with 1.5x line spacing; headings stay Calibri (sans)
   in charcoal for clear hierarchy.  Every level-1 heading gets a
   60%-width muted-gold accent rule directly below.  Tables now
   use hairline borders (top/bottom + interior horizontals only)
   with alternating-row shading on body rows (`#F7FAFC` on even
   rows).
5. **Executive-summary callout boxes** -- four big-number callout
   panels at the end of Section 1 (tests generated / passed /
   failed / pass rate).  Big accent-coloured value, small slate
   uppercase caption, left-bordered light-grey fill.
6. **Status badges** -- Pass / Fail / Incomplete / Skipped now
   render as coloured pill markers (green / red / amber / grey)
   anywhere the SectionBuilder writes a `[STATUS:<name>]`
   sentinel.  Currently applied in Appendix A's per-test table.
7. **Failed Tests section** -- new Section 6 between "Detailed
   Findings by Source File" (5) and "Defect Register" (now 7).
   One card per failed test: identifier, headline message,
   3-frame stack excerpt, and a plain-English explanation pattern-
   matched against `FailureExplainer.knownPatterns()` (6 starter
   entries covering MATLAB:dictionary:UnconfiguredLookupNotSupported,
   nonLogicalConditional, UndefinedFunction, validators, fileread,
   OutOfMemory).  Unrecognised errors render verbatim with a
   "Cause not classified -- investigate manually" hint.
8. **`autotest.generateReport(projectPath, ...)`** -- new top-level
   function that re-emits the report stage ONLY (HTML + Docx)
   from the existing `_autotest/reports/` artefacts.  Use it when
   you've re-run `runtests` manually after hand-editing
   `user_tests/u<Class>.m` and want a refreshed deliverable
   without paying the full autogen cycle's cost.  Errors with a
   clear "no test results found" message when called against a
   project that hasn't been through `runWorkflow` yet.
9. **DocVersion default bumped to 1.6**.

## v1.6 LOCKED PALETTE (carries v1.4 + adds badges)

The v1.4 palette is preserved verbatim:

| Use                                | Hex      | Name        |
|------------------------------------|----------|-------------|
| Headings, body text                | `#1F2937`| charcoal    |
| Metadata key cells, captions       | `#4B5563`| slate       |
| Rules, section markers, chart highlights | `#B45309`| muted gold  |
| Failed-count emphasis (sparingly)  | `#991B1B`| deep red    |
| Code-block fill (monospace)        | `#F7FAFC`| light grey  |
| Table headers (existing)           | `#E7E6E6`| light grey  |
| Metadata key cell shading (existing) | `#F2F2F2`| pale grey  |
| Alternating row shading (v1.6)     | `#F7FAFC`| light grey  |
| Callout fill (v1.6)                | `#F7FAFC`| light grey  |
| Callout left border (v1.6)         | `#B45309`| muted gold  |

v1.6 ADDS the badge palette:

| Status     | Fill       | Text       |
|------------|------------|------------|
| Pass       | `#D1FAE5`  | `#065F46`  |
| Fail       | `#FEE2E2`  | `#991B1B`  |
| Incomplete | `#FEF3C7`  | `#92400E`  |
| Skipped    | `#E5E7EB`  | `#374151`  |

## Files changed in v1.6

| File | Change |
|---|---|
| `+autotest/+report/Style.m`                  | + Badge*Fill / Badge*Text constants; + AltRowShading; + BodyFontNameSerif / HeadingFontName / CalloutFill / CalloutBorderColor; + statusBadge() / portionCode() / isUnclassified() helpers |
| `+autotest/+report/FailureExplainer.m`       | NEW (6-entry knownPatterns table; extractIdentifier / extractMessage / extractStack) |
| `+autotest/+report/SectionBuilder.m`         | + failedTests() (new Section 6); executiveSummary emits 4 callout boxes; Appendix A status column wrapped in `[STATUS:...]` sentinel; renderPieChart / renderBarChart bumped to 300 DPI + value labels + filled content width |
| `+autotest/+report/+backends/HtmlBackend.m`  | + addStatusBadge / addCalloutBox / addFailureCard; addTable detects `[STATUS:...]`; classificationBanner emits plain text for UNCLASSIFIED; CSS refresh (serif body, sans headings, alt-row shading, badge / callout / failure-card styles) |
| `+autotest/+report/+backends/OoxmlBackend.m` | + PortionCode property; + EmitPortionMarks switch; + applyPortionPrefix / headingAccentRule private helpers; + addStatusBadge / addCalloutBox / addFailureCard; cellXml detects `[STATUS:...]`; tableXml uses hairline borders + alt-row shading; classificationBannerXml emits plain text for UNCLASSIFIED; stylesXml + headingStyleXml refresh (Georgia body, Calibri headings, justified body, 1.5x line spacing) |
| `+autotest/+report/ReportBuilder.m`          | DocVersion default 1.0 -> 1.6 |
| `+autotest/generateSystemTestReport.m`       | DocVersion default 1.0 -> 1.6 |
| `+autotest/generateReport.m`                 | NEW (standalone re-emit; reuses `generateSystemTestReport`; errors fail-loud when no results.xml exists) |
| `CHANGELOG.md`                               | this entry |
| `V1_6_HANDOFF.md`                            | NEW |

## Tier configuration on this machine + work machine

Unchanged from v1.4/v1.5:

| Component                  | This machine     | Work machine   |
|----------------------------|------------------|----------------|
| MATLAB Report Generator    | unlicensed (-5.2)| unlicensed     |
| LibreOffice                | not installed    | not installed  |
| Word COM (`actxserver`)    | works            | likely blocked |

OoxmlBackend remains the only docx tier.  No PDF on either machine.

## Verification

```matlab
% Full workflow -- report defaults ON in v1.5; v1.6 carries that forward.
close all force; delete(findall(0,'Type','figure')); clear classes;
addpath('C:\Users\Duy\Projects\matlabunittest');
info = autotest.runWorkflow( ...
    'C:\Users\Duy\OneDrive\Documents\MATLAB\removal_redaction_tool');
disp(info.Summary);
fprintf('HTML: %s\nDocx: %s\n', info.ReportHtmlPath, info.ReportDocxPath);

% Standalone re-emit (v1.6 -- skips autogen + test run).
info2 = autotest.generateReport( ...
    'C:\Users\Duy\OneDrive\Documents\MATLAB\removal_redaction_tool', ...
    'DocVersion', '1.6-rerun');
disp(info2);
```

Goal-line on `removal_redaction_tool`:

- 967 total tests, 818 passed, 9 failed (all 9 are real project bugs
  cascading through `MATLAB:dictionary:UnconfiguredLookupNotSupported`
  on `ExcelProcessor`; opt-out via project's
  `_autotest/known_real_signal.txt` if desired).
- HTML carries: 967 `<span class="badge">` (one per row in Appendix A);
  4 `<aside class="callout">` (executive-summary metrics); 9
  `<article class="failure-card">` (one per failed test); plus the
  v1.4 palette colours, v1.5 SVG pie + bar charts, sha256 self-
  attestation.
- Docx carries: portion markings `(U)` on every body paragraph + heading;
  plain-text UNCLASSIFIED banner top + bottom; 300-DPI pie + bar charts
  embedded at content width; serif body + sans headings + gold rule
  under each H1; alt-row shading on data tables; status badges as
  shaded table cells in Appendix A; failure cards in the new Section 6.

## Pitfalls carried forward

- **MATLAB Report Generator deactivation client (Phase 16).**  If a
  "Software Deactivation Required" dialog appears mid-cycle, close
  it via the X, NEVER click Deactivate.
- **OoxmlBackend cannot overwrite a .docx open in Word.**  Close
  Word before running.
- **`pie()` patch / text indexing.**  v1.6's renderPieChart walks
  `pie`'s return alternating patch/text handles; defensively uses
  `isgraphics(h(k),'patch')` and `isgraphics(h(k),'text')` rather
  than relying on the alternating-index assumption.
- **MATLAB `zip()` is non-deterministic.**  Don't change
  `embedSelfChecksum` to hash the whole .docx; the existing
  document.xml-only hash is what makes the verification recipe
  robust.

## v1.6-introduced tech debt for v1.7 to revisit

- **FailureExplainer.knownPatterns is a static cellarray.**  Six
  entries is enough for the current Removal/Redaction Tool plus the
  common MATLAB errors; expand as new error families surface in
  generated test runs.  Consider extracting to a JSON file under
  `+autotest/+report/patterns/` if the table grows past ~20 rows so
  reviewers can read it without scrolling through a `.m`.
- **Portion markings on table cells.**  v1.6 prefixes paragraphs and
  headings.  DoDI 5200.48 also requires portion markings on
  individual table cells when they carry independent classified
  content; the autogen's tables are entirely metric counts and class
  names so this is dormant for UNCLASSIFIED runs, but a project
  targeting CUI or higher should revisit before shipping.
- **Callout boxes embed at fixed 2880 DXA width** (~2").  They don't
  arrange in a horizontal strip in .docx -- each callout sits on
  its own line.  HTML uses inline-block so the strip lays out
  correctly.  A v1.7 candidate is to wrap four callouts in a 4-cell
  parent table for .docx layout parity with HTML.
- **`autotest.generateReport` requires `summary.txt + results.xml`.**
  If a user runs `runtests` from MATLAB's command line and the
  XMLPlugin isn't attached, the .xml won't exist and generateReport
  errors fail-loud.  A v1.7 candidate is to auto-detect and
  reconstruct partial results from the in-memory
  `matlab.unittest.TestResult` array when the caller passes it.

## After v1.6 verification passes

```bat
cd C:\Users\Duy\Projects\matlabunittest
git diff --stat HEAD
git commit -am "v1.6: DoD markings + docx polish + Failed Tests section + standalone generateReport"
git push
```
