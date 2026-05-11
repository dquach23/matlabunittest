function v1_4_cleanup_and_verify()
%V1_4_CLEANUP_AND_VERIFY  v1.4 single-shot driver script.
%
%   Executes the v1.4 cycle's runtime steps in order:
%     1. Close any Word instance holding the prior report .docx open.
%     2. Delete v1.4-dropped scratch + legacy files (Phase A.1/A.2).
%     3. git add the previously-untracked +autotest/+report/* package
%        files so the repo's tracked tree matches the actual package.
%     4. Run the examples workflow (portability gate).
%     5. Run the removal_redaction_tool workflow (goal-line gate).
%     6. Print everything back so the operator can see the numbers
%        before committing.
%
%   This is a v1.4-cycle helper.  It writes the verification outcome
%   to v1_4_run_summary.txt next to itself so a follow-on inspection
%   can read the numbers without scrolling the diary.
%
%   IMPORTANT: this script does NOT call `clear classes` -- it would
%   wipe the function's own workspace mid-run.  If you've recently
%   edited the +autotest package and have stale class definitions
%   cached, run these two lines at the MATLAB Command Window BEFORE
%   invoking the script:
%
%       clear classes
%       cd 'C:\Users\Duy\Projects\matlabunittest'
%
%   then call `v1_4_cleanup_and_verify` as usual.

repoRoot = fileparts(mfilename('fullpath'));
fprintf('=================================================================\n');
fprintf('matlabunittest v1.4 -- cleanup + verify\n');
fprintf('Repo root: %s\n', repoRoot);
fprintf('=================================================================\n\n');

%% Step 1: kill stale Word.
fprintf('[1/6] Closing any Word instance...\n');
try
    [s,~] = system('taskkill /F /IM WINWORD.EXE 2>NUL');
    if s == 0
        fprintf('       Closed.\n');
    else
        fprintf('       (no Word instance was running -- ok)\n');
    end
catch
    fprintf('       (taskkill failed -- continuing)\n');
end
% Brief pause so file handles are released.
pause(1);

%% Step 2: delete v1.4-dropped scratch + legacy files.
fprintf('\n[2/6] Deleting v1.4-dropped scratch + legacy files...\n');
toDelete = { ...
    fullfile(repoRoot, '_phase15_run_all.m'); ...
    fullfile(repoRoot, '_phase15_ver.m'); ...
    fullfile(repoRoot, 'debug_phase6.m'); ...
    fullfile(repoRoot, 'phase17_residual_map.m'); ...
    fullfile(repoRoot, 'report_phase6_v2.html'); ...
    fullfile(repoRoot, 'results_phase6_v2.xml'); ...
    fullfile(repoRoot, 'summary_phase6_v2.txt'); ...
    fullfile(repoRoot, 'triage_phase6.md'); ...
    fullfile(repoRoot, 'verify_phase9.m'); ...
    fullfile(repoRoot, '+autotest', 'ReportRenderer.m'); ...
    fullfile(repoRoot, '+autotest', '+report', 'CoverPage.m'); ...
};
for i = 1:numel(toDelete)
    p = toDelete{i};
    if isfile(p)
        try, delete(p); fprintf('       deleted: %s\n', relPath(p, repoRoot));
        catch ME, fprintf('       FAILED to delete %s: %s\n', relPath(p, repoRoot), ME.message);
        end
    else
        fprintf('       (not present, skip): %s\n', relPath(p, repoRoot));
    end
end
toDeleteDirs = { ...
    fullfile(repoRoot, '_phase14_report'); ...
    fullfile(repoRoot, '_phase15_patches'); ...
};
for i = 1:numel(toDeleteDirs)
    d = toDeleteDirs{i};
    if isfolder(d)
        try, rmdir(d, 's'); fprintf('       deleted dir: %s\n', relPath(d, repoRoot));
        catch ME, fprintf('       FAILED to delete dir %s: %s\n', relPath(d, repoRoot), ME.message);
        end
    else
        fprintf('       (not present, skip dir): %s\n', relPath(d, repoRoot));
    end
end

%% Step 3: git status before, then git add untracked package files.
fprintf('\n[3/6] git: stage v1.4 changes + previously-untracked package files...\n');
origDir = pwd;
cleanup = onCleanup(@() cd(origDir)); %#ok<NASGU>
cd(repoRoot);
[~, statusOut] = system('git status --porcelain');
fprintf('       git status (before stage):\n');
disp(indent(statusOut));
% Stage the +autotest/ tree and the .gitignore.  This catches the
% previously-untracked +autotest/+report/* files (BackendDetector,
% DefectRegister, PdfBackend_LibreOffice, ResultsParser,
% SourceInventory, Style, +backends/OoxmlBackend, +backends/RptgenBackend,
% etc.) that the v1.3 cycle never tracked.  -A makes deletes show too.
[~, ~] = system('git add -A "+autotest/" .gitignore "+autotest/generateSystemTestReport.m"');
[~, ~] = system('git add -A "v1_4_cleanup_and_verify.m"');
[~, ~] = system('git add -A');  % belt-and-braces -- catch root-level scratch deletes
[~, statusOut2] = system('git status --porcelain');
fprintf('       git status (after stage):\n');
disp(indent(statusOut2));

%% Step 4: examples portability gate.
fprintf('\n[4/6] Running examples workflow (portability gate)...\n');
% NB: deliberately NO 'clear classes' here -- it would wipe this
% function's own workspace mid-run (repoRoot, info_ex, etc.).  See
% the help block at the top of this file for the operator-side
% workaround if stale class definitions need to be cleared first.
close all force;
delete(findall(0,'Type','figure'));
addpath(repoRoot);
exFolder = fullfile(repoRoot, 'examples');
info_ex = struct();
exErr = '';
try
    info_ex = autotest.runWorkflow(exFolder, 'GenerateReport', true);
    fprintf('       examples summary:\n');
    disp(info_ex.Summary);
catch ME
    exErr = ME.message;
    fprintf('       EXAMPLES RUN FAILED: %s\n', ME.message);
end

%% Step 5: removal_redaction_tool goal-line.
fprintf('\n[5/6] Running removal_redaction_tool workflow (goal-line gate)...\n');
rrFolder = 'C:\Users\Duy\OneDrive\Documents\MATLAB\removal_redaction_tool';
close all force;
delete(findall(0,'Type','figure'));
% Same as Step 4: no 'clear classes' between runs.
addpath(repoRoot);
info_rr = struct();
rrErr = '';
try
    info_rr = autotest.runWorkflow(rrFolder, ...
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
    fprintf('       removal_redaction_tool summary:\n');
    disp(info_rr.Summary);
    if isfield(info_rr, 'ReportDocxPath')
        fprintf('       Doc:     %s\n', info_rr.ReportDocxPath);
    end
    if isfield(info_rr, 'AuditSidecar')
        fprintf('       Sidecar: %s\n', info_rr.AuditSidecar);
    end
    if isfield(info_rr, 'ReportBackend')
        fprintf('       Backend: %s\n', info_rr.ReportBackend);
    end
catch ME
    rrErr = ME.message;
    fprintf('       RR RUN FAILED: %s\n', ME.message);
end

%% Step 6: write summary file.
fprintf('\n[6/6] Writing v1_4_run_summary.txt next to this script...\n');
% Make sure pwd and path are set up for the final `git status`.
cd(repoRoot);
sumPath = fullfile(repoRoot, 'v1_4_run_summary.txt');
fid = fopen(sumPath, 'w');
if fid >= 3
    cleanupSum = onCleanup(@() fclose(fid)); %#ok<NASGU>
    fprintf(fid, 'matlabunittest v1.4 -- cleanup + verify summary\n');
    fprintf(fid, 'Generated: %s\n\n', char(datetime('now', 'Format','yyyy-MM-dd HH:mm:ss')));
    fprintf(fid, '== examples ==\n');
    if isempty(exErr) && isfield(info_ex, 'Summary')
        fprintf(fid, 'Total: %d  Passed: %d  Failed: %d  Incomplete: %d\n', ...
            info_ex.Summary.Total, info_ex.Summary.Passed, ...
            info_ex.Summary.Failed, info_ex.Summary.Incomplete);
    else
        fprintf(fid, 'FAILED: %s\n', exErr);
    end
    fprintf(fid, '\n== removal_redaction_tool ==\n');
    if isempty(rrErr) && isfield(info_rr, 'Summary')
        s = info_rr.Summary;
        fprintf(fid, 'Total: %d  Passed: %d  Failed: %d  Incomplete: %d\n', ...
            s.Total, s.Passed, s.Failed, s.Incomplete);
        if isfield(s, 'GeneratedTotal')
            fprintf(fid, 'Generated: %d  Passed: %d  Failed: %d  Incomplete: %d\n', ...
                s.GeneratedTotal, s.GeneratedPassed, s.GeneratedFailed, s.GeneratedIncomplete);
            if s.GeneratedTotal > 0
                fprintf(fid, 'Generated pass rate: %.2f%%\n', ...
                    100 * s.GeneratedPassed / s.GeneratedTotal);
            end
        end
        if isfield(info_rr, 'ReportDocxPath')
            fprintf(fid, 'Docx:    %s\n', info_rr.ReportDocxPath);
        end
        if isfield(info_rr, 'AuditSidecar')
            fprintf(fid, 'Sidecar: %s\n', info_rr.AuditSidecar);
        end
        if isfield(info_rr, 'ReportBackend')
            fprintf(fid, 'Backend: %s\n', info_rr.ReportBackend);
        end
    else
        fprintf(fid, 'FAILED: %s\n', rrErr);
    end
    fprintf(fid, '\n== git status (final) ==\n');
    [~, statusOut3] = system('git status --short');
    fprintf(fid, '%s', statusOut3);
    fprintf(fid, '\n');
    fprintf('       wrote %s\n', sumPath);
else
    fprintf('       failed to open %s for writing\n', sumPath);
end

fprintf('\n=================================================================\n');
fprintf('v1.4 cleanup + verify done.\n');
fprintf('=================================================================\n');
end

function r = relPath(full, base)
    full = char(full); base = char(base);
    if startsWith(full, base)
        r = full(numel(base)+2:end);
    else
        r = full;
    end
end

function s = indent(t)
    if isempty(strtrim(t))
        s = '         (clean)';
        return;
    end
    lines = strsplit(strtrim(t), char(10));
    s = '';
    for i = 1:numel(lines)
        s = [s '         ' lines{i} char(10)]; %#ok<AGROW>
    end
end
