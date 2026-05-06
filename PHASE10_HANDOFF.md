# Phase 10 handoff — matlabunittest

Read this if you're picking up after Phase 9 work on 2026-05-06.

## TL;DR

Phase 9 turned out to be a **misdiagnosis correction**, not a regression
fix.  The Phase 7 spec assumed `tRedactionToolGUI` was failing on
`testCallback_sheetStatusChanged`; the Phase 6 baseline XML actually
shows the failure was always `testAppHasUIFigure`.

Phase 9 made two changes:

1. **Generic autogen fix** (`+autotest/TestWriter.m`): the
   `testAppHasUIFigure` assertion now checks property TYPES (any property
   whose value `isa('matlab.ui.Figure')`) instead of hardcoded property
   NAMES (`'UIFigure'` / `'Figure'`).  This is portable: any App
   Designer app benefits, regardless of how the user named their figure
   component (e.g. `ReportRedactionToolUIFigure` in this project).
2. **`known_real_signal.txt`** extended with 4 new entries (3
   writeRedactedWordsToReport variants + 1 RenameXML_default).
   Existing Phase 7 entries preserved.

Verification status: **NOT yet executed** in this session.  The agent
hit a coordinate-mode/screenshot interaction issue with the user's
MATLAB windows where the screenshots kept showing desktop and
keystrokes didn't reach MATLAB.  See "Verification recipe" below for
the one-line user-driven path.

## Phase 7 misdiagnosis: details

Phase 7's known_real_signal entry for
`tRedactionToolGUI.testCallback_sheetStatusChanged` was wrong.  The
Phase 6 baseline (`results_phase6_v2.xml` line 5) shows
`testAppHasUIFigure` was the only failure in tRedactionToolGUI; line 22
shows `testCallback_sheetStatusChanged` was passing.  So the Phase 7
entry caused a passing test to be reclassified as Incomplete (37 passed
→ 36 passed + 1 incomplete) while leaving the actual failure
(`testAppHasUIFigure`) untouched.

The misdirected entry is **left in place** per the user's
"Append (don't replace)" instruction; it's a no-op once the underlying
CellRefUtils issue is project-side fixed.  Future cleanup can drop it.

## Phase 9 autogen fix — what was emitted

Before (TestWriter.m lines 436-440):
```matlab
function testAppHasUIFigure(testCase)
    testCase.verifyTrue( ...
        any(strcmp(properties(testCase.App), 'UIFigure')) || ...
        any(strcmp(properties(testCase.App), 'Figure')));
end
```

After (TestWriter.m lines 436-455):
```matlab
function testAppHasUIFigure(testCase)
    % Phase 9: check by TYPE (any property holding a uifigure
    % handle) rather than by hardcoded NAME -- App Designer apps
    % frequently rename the figure component (e.g.
    % ReportRedactionToolUIFigure) so a name-only check is brittle.
    pp = properties(testCase.App);
    found = false;
    for k = 1:numel(pp)
        try
            v = testCase.App.(pp{k});
            if isscalar(v) && isa(v, 'matlab.ui.Figure')
                found = true;
                break;
            end
        catch
        end
    end
    testCase.verifyTrue(found, ...
        'App has no property holding a matlab.ui.Figure handle');
end
```

This is fully portable to any other MATLAB project containing an
App Designer app.

## File integrity (Phase 9)

| File | Lines | Bytes | CRLF | bare-LF | NUL | Tail |
|---|---:|---:|---:|---:|---:|---|
| `+autotest/TestWriter.m` | 1264 | 66,084 | 1264 | 0 | 0 | `end / end / end\r\n` ✓ |
| `_autotest/known_real_signal.txt` | 19 | n/a | n/a | n/a | n/a | 8 entries (4 P7 + 4 P9) ✓ |

Tested via the byte-level Python recipe in
`/tmp/phase9_fix_testAppHasUIFigure_zealous-determined-hypatia.py`.

The `known_real_signal.txt` lives on OneDrive (not bash-accessible)
— Edit-tool was used; CRLF preservation is implicit.  If byte-level
verification matters, run from MATLAB:

```matlab
b = fread(fopen('C:\Users\Duy\OneDrive\Documents\MATLAB\removal_redaction_tool\_autotest\known_real_signal.txt', 'rb'));
fprintf('bytes=%d, CRLF=%d, bare-LF=%d, NUL=%d\n', numel(b), ...
    sum(b(1:end-1)==13 & b(2:end)==10), ...
    sum(b==10) - sum(b(1:end-1)==13 & b(2:end)==10), ...
    sum(b==0));
```

## Verification recipe

```matlab
% Either run the helper script:
run('C:\Users\Duy\Projects\matlabunittest\verify_phase9.m')

% Or paste the equivalent inline:
close all force; delete(findall(0,'Type','figure')); clear classes;
run('C:\Users\Duy\OneDrive\Documents\MATLAB\removal_redaction_tool\run_autotest.m')
disp(fileread('C:\Users\Duy\OneDrive\Documents\MATLAB\removal_redaction_tool\_autotest\reports\summary.txt'))
```

Expected:
- `Total Failed: 0` or `1`
- `Sources scanned: 9`
- `tRedactionToolGUI: 38/38 passed` (testAppHasUIFigure now passing)
- `tTextRedactor: 0 failed` (3 writeRedactedWordsToReport tests skipped)
- `tExcelXmlCleaner: 0 failed` (RenameXML_default skipped)

If something unexpected appears, see the per-class breakdown in
`<target>/_autotest/exports/triage.md`.

## Phase 10 plan — generic fileID-arg auto-synthesis

**Constraint reminder from user:** "this application being able to use
on other projects in the future" — every change must improve generic
portability without touching the project-under-test.

### The problem

Three of the four Phase 9 known_real_signal entries are for
`writeRedactedWordsToReport(text, fileID)`-style functions where the
autogen sampler emits `rand(1, randi(5))` for the `fileID` arg.
`fprintf` then throws because that's not a real file handle.

### The fix (recommended)

Add **fileID-aware input synthesis** to `+autotest/InputSampler.m`
and/or `+autotest/FixtureProvider.m`:

1. Detect args whose name matches `^(fid|fileID|fileId|handleId|fhandle)$`
   (case-insensitive) — the conventional MATLAB names for file
   descriptors.
2. For those args, instead of `rand()` or other numeric synthesis,
   emit a `tempname()`-based fopen call wrapped in `addTeardown`:
   ```matlab
   tmpPath = [tempname() '.txt'];
   fid = fopen(tmpPath, 'w');
   testCase.addTeardown(@() autotest.TestWriter.cleanupFid(fid, tmpPath));
   ```
3. The cleanup helper closes the FID (if still valid) and deletes the
   temp file.

After this, the 3 writeRedactedWordsToReport entries can be **removed**
from `known_real_signal.txt` because the autogen tests will pass on
their own.  The 1 RenameXML entry stays (Phase 8 noted it's not
actionable from autogen side without deeper static analysis).

### Side benefit: portability

Any other project the user runs autotest against, that has functions
accepting fileID/fid args, will benefit automatically — no
project-specific opt-out needed.

### Files to touch

- `+autotest/InputSampler.m::sampleForType` — add a name-based
  override before falling through to numeric.
- `+autotest/InputSampler.m::randomArgsExpr` — same name-based
  detection, emitting the same fileID expression.
- `+autotest/FixtureProvider.m::literalForArg` — also gain the
  same name-based override (so smartFor / realistic ctor paths
  also hit it).
- `+autotest/TestWriter.m` — add a `cleanupFid(fid, tmpPath)`
  static helper for teardown reuse (or inline the cleanup).

### What this does NOT cover (left as Phase 11 candidates)

- **String-array support detection.**  Phase 7's Option 4 already
  handles the simple case (skip vector/matrix smokes when arg is
  stringy).  A more nuanced approach would inspect the function
  body for string-handling patterns (e.g. `regexp`, `replace`,
  `split`) and only emit string smokes that are likely to succeed.
- **DOM/COM/Excel-handle args** — args expecting Java/COM objects
  fall back to opaque-skip already.  Could be improved with
  fixture-based DOM construction.
- **ExcelXmlCleaner.RenameXML** — the Phase 6 stringy-override
  path-of-least-resistance bug.  Worth a deeper investigation but
  is project-shape dependent.

## Validation strategy for Phase 10

After implementing, two verification gates:

1. **Local target:** rerun on `removal_redaction_tool`.  Expected:
   `Total Failed: 0`, no writeRedactedWordsToReport entries needed.
2. **Portability check:** generate a tiny synthetic MATLAB project
   in `<matlabunittest>/examples/` containing a function that
   accepts a `fid` arg and writes to it.  Confirm the autogen test
   passes without any project-specific opt-out.  This catches the
   "works on the demo target only" trap.

If a second real project is available, run on it as a stretch
validation step.

## Pitfalls already known

- **MATLAB regex line-continuation bug** (Phase 6 documented) — use
  `contains` over `regexp` when literal `\.` spans string-concat
  continuations.
- **Edit-tool truncation** — don't trust the Edit tool on TestWriter.m
  (~1.2k lines).  Use the byte-level Python recipe via bash with a
  unique `/tmp/phase<N>_*_<session>.py` name.
- **Screenshot/coordinate masking by exe basename** — the
  request_access call resolves by displayName, but the screenshot
  mask checks the running exe's path.  When `MATLAB R2025b` (the
  launcher at `bin/matlab.exe`) is granted, but the actual running
  process is `bin/win64/matlab.exe`, screenshots mask the window.
  Pass `matlab.exe` (basename) in addition.  Verified during this
  session — after granting the basename, MATLAB's allowlist updates
  but my keystrokes still didn't reach the focused window in this
  particular session, suggesting an additional issue (foreground-app
  detection OR a stale post-grant state).  User reports MATLAB
  windows are visible to them, so the pure-keystroke + summary.txt
  poll path may work in a fresh session.

## Next steps

1. **User runs `verify_phase9.m`** to confirm Phase 9 numbers (Failed
   should drop from 5 to 0 or 1).
2. **Agent implements Phase 10** (fileID-aware input synthesis) per
   plan above.
3. **Re-run on removal_redaction_tool** and confirm Failed = 0 with
   the 3 writeRedactedWordsToReport known_real_signal entries
   removed.
4. **Optional:** synthesize a tiny portable test project to
   confirm the fix works generically.

## Quick command reference

```matlab
% Phase 9 verify (one-liner)
run('C:\Users\Duy\Projects\matlabunittest\verify_phase9.m')

% Probe the new testAppHasUIFigure code
type C:\Users\Duy\OneDrive\Documents\MATLAB\removal_redaction_tool\_autotest\generated\tRedactionToolGUI.m

% Confirm KnownRealSignal honors all 8 entries
for entry = ["tCellRefUtils.testEdge_isCellInRange_cellRef_empty", ...
             "tCellRefUtils.testRandomized_isCellInRange", ...
             "tRedactionToolGUI.testCallback_sheetStatusChanged", ...
             "tTextRedactor.testEdge_cleanupPunctuation_text_empty", ...
             "tTextRedactor.testSmoke_writeRedactedWordsToReport_vector", ...
             "tTextRedactor.testSmoke_writeRedactedWordsToReport_matrix", ...
             "tTextRedactor.testRandomized_writeRedactedWordsToReport", ...
             "tExcelXmlCleaner.testSmoke_RenameXML_default"]
    parts = split(entry, '.');
    r = autotest.KnownRealSignal.match( ...
        'C:\Users\Duy\OneDrive\Documents\MATLAB\removal_redaction_tool', ...
        char(parts(1)), char(parts(2)));
    fprintf('%s -> [%s]\n', entry, r);
end
```
