function info = runWorkflow(folder, varargin)
%AUTOTEST.RUNWORKFLOW  Discover sources, generate tests, and run them.
%
%   INFO = AUTOTEST.RUNWORKFLOW(FOLDER) scans FOLDER recursively, generates
%   tests for every supported source, runs the test suite, and writes the
%   organised output to FOLDER/_autotest/.  Returns a struct describing the
%   run.
%
%   INFO = AUTOTEST.RUNWORKFLOW(FOLDER, 'OutputRoot', PATH) overrides the
%   default <folder>/_autotest output location.
%
%   INFO = AUTOTEST.RUNWORKFLOW(..., 'Verbose', TRUE) enables generator
%   diagnostics.
%
%   The returned INFO struct contains:
%       .Folder           project folder that was scanned
%       .OutputRoot       absolute path of <folder>/_autotest
%       .GeneratedDir     where generated tXxx.m files live
%       .ReportsDir       summary.txt / results.xml / results.tap
%       .LogsDir          run-<timestamp>.log + generation-errors.txt
%       .ExportsDir       reserved for user artefacts
%       .Sources          struct array of discovered sources (Path,
%                         RelPath, Kind, Generated, GeneratedTest, Error)
%       .Results          matlab.unittest.TestResult array (empty when
%                         no tests were generated)
%       .Summary          struct: Total, Passed, Failed, Incomplete,
%                         DurationSeconds
%       .Timestamp        char, yyyymmdd-HHMMSS
%       .LogFile          full path to the diary log
%
%   See also: AUTOTESTGUI, GENERATETESTS.

    p = inputParser();
    p.addRequired('folder', @(x) (ischar(x) || isstring(x)) && ~isempty(char(x)));
    p.addParameter('OutputRoot', '', @(x) ischar(x) || isstring(x));
    p.addParameter('Verbose', false, @islogical);
    % Phase 15: auto-render the native system test report
    % (autotest.generateSystemTestReport) immediately after the JUnit
    % summary is emitted.  Default OFF to preserve existing callers.
    p.addParameter('GenerateReport', false, @islogical);
    p.addParameter('ReportOptions',  struct(), @isstruct);
    p.parse(folder, varargin{:});
    r = p.Results;

    folder = absolutePath(char(r.folder));
    if ~isfolder(folder)
        error('autotest:FolderNotFound', 'Folder does not exist: %s', folder);
    end

    if isempty(char(r.OutputRoot))
        outRoot = fullfile(folder, '_autotest');
    else
        outRoot = absolutePath(char(r.OutputRoot));
    end

    timestamp = char(datetime('now', 'Format', 'yyyyMMdd-HHmmss'));

    % ── Output layout ────────────────────────────────────────────────────
    generatedDir = fullfile(outRoot, 'generated');
    userTestsDir = fullfile(outRoot, 'user_tests');
    reportsDir   = fullfile(outRoot, 'reports');
    logsDir      = fullfile(outRoot, 'logs');
    exportsDir   = fullfile(outRoot, 'exports');

    % Wipe ONLY the auto-generated tree.  user_tests/ is sticky so the
    % hand-written user stubs persist across re-runs.
    if isfolder(generatedDir)
        rmdir(generatedDir, 's');
    end
    mkdirIfMissing(generatedDir);
    mkdirIfMissing(userTestsDir);
    mkdirIfMissing(reportsDir);
    mkdirIfMissing(logsDir);
    mkdirIfMissing(exportsDir);

    logFile = fullfile(logsDir, sprintf('run-%s.log', timestamp));
    diary(logFile);
    diaryCleanup = onCleanup(@() diary('off')); %#ok<NASGU>

    fprintf('===== autotest workflow =====\n');
    fprintf('Started:        %s\n', char(datetime('now')));
    fprintf('Project folder: %s\n', folder);
    fprintf('Output root:    %s\n', outRoot);

    % ── Discover sources ─────────────────────────────────────────────────
    sources = discoverSources(folder, outRoot);
    nM     = sum(strcmp({sources.Kind}, '.m'));
    nMlapp = sum(strcmp({sources.Kind}, '.mlapp'));
    fprintf('Found %d .m sources, %d .mlapp files. Generating tests...\n', ...
        nM, nMlapp);

    if isempty(sources)
        warning('autotest:NoSources', ...
            'No .m or .mlapp sources discovered under %s.', folder);
    end

    % ── Manage MATLAB path so generated tests can find their sources ────
    pathSnap = path();
    pathCleanup = onCleanup(@() path(pathSnap)); %#ok<NASGU>
    % Snapshot the figures that already exist so we can mop up any GUI
    % windows the test run launches but fails to close.  Without this,
    % running tests against an .mlapp can leave dozens of stranded windows
    % on the desktop.
    preFigs = findall(groot, 'Type', 'figure');
    figCleanup = onCleanup(@() closeLeakedFigures(preFigs)); %#ok<NASGU>
    addProjectPaths(folder, outRoot);

    % ── Build a project-wide FixtureProvider ─────────────────────────────
    % Scans ONCE for usable fixtures (toolTester.xlsx, sample images, keep
    % / dirty list workbooks, etc.) so each generator pass can ask "is
    % there a realistic literal I should pass for this argument?" instead
    % of falling back to synthetic 1/[]/NaN.
    provider = autotest.FixtureProvider(folder);
    if provider.hasFixtures()
        fprintf('Fixture index: %d xlsx, %d images, %d text, %d mat\n', ...
            numel(provider.ExcelFiles), numel(provider.ImageFiles), ...
            numel(provider.TextFiles), numel(provider.MatFiles));
        if ~isempty(provider.PrimaryExcel)
            relExcel = strrep(provider.PrimaryExcel, [folder filesep], '');
            fprintf('  primary excel:    %s\n', relExcel);
        end
        if ~isempty(provider.PrimaryKeepList)
            fprintf('  keep list:        %s\n', ...
                strrep(provider.PrimaryKeepList, [folder filesep], ''));
        end
        if ~isempty(provider.PrimaryDirtyList)
            fprintf('  dirty list:       %s\n', ...
                strrep(provider.PrimaryDirtyList, [folder filesep], ''));
        end
    end

    % ── Generate tests ───────────────────────────────────────────────────
    genErrors = strings(0,1);
    for i = 1:numel(sources)
        s = sources(i);
        relSubdir = fileparts(s.RelPath);
        outDir    = fullfile(generatedDir,  relSubdir);
        stubDir   = fullfile(userTestsDir,  relSubdir);
        mkdirIfMissing(outDir);
        mkdirIfMissing(stubDir);
        try
            tFile = generateTests(s.Path, ...
                'OutputDir',       outDir, ...
                'UserStubDir',     stubDir, ...
                'FixtureProvider', provider, ...
                'TargetFolder',    folder, ...
                'Verbose',         r.Verbose);
            sources(i).Generated     = true;
            sources(i).GeneratedTest = tFile;
            fprintf('  [ok] %s -> %s\n', s.RelPath, ...
                strrep(tFile, [outRoot filesep], ''));
        catch ME
            sources(i).Generated = false;
            sources(i).Error     = ME.message;
            msg = sprintf('%s: %s', s.RelPath, ME.message);
            genErrors(end+1,1) = string(msg); %#ok<AGROW>
            fprintf(2, '  [skip] %s: %s\n', s.RelPath, ME.message);
        end
    end

    if ~isempty(genErrors)
        errFile = fullfile(logsDir, 'generation-errors.txt');
        writeLines(errFile, genErrors);
        fprintf('Wrote %d generation error(s) to %s\n', ...
            numel(genErrors), errFile);
    end

    addpath(genpath(generatedDir));
    addpath(genpath(userTestsDir));

    % ── Run tests ────────────────────────────────────────────────────────
    [results, summary] = runGeneratedTests({generatedDir, userTestsDir}, reportsDir);

    % ── Write summary report ─────────────────────────────────────────────
    summaryFile = fullfile(reportsDir, 'summary.txt');
    writeSummary(summaryFile, folder, outRoot, timestamp, sources, ...
        results, summary, genErrors);

    fprintf('===== run complete =====\n');
    fprintf('Total: %d  Passed: %d  Failed: %d  Incomplete: %d  Duration: %.2fs\n', ...
        summary.Total, summary.Passed, summary.Failed, ...
        summary.Incomplete, summary.DurationSeconds);
    fprintf('See %s for details.\n', summaryFile);

    info = struct( ...
        'Folder',        folder, ...
        'OutputRoot',    outRoot, ...
        'GeneratedDir',  generatedDir, ...
        'UserTestsDir',  userTestsDir, ...
        'ReportsDir',    reportsDir, ...
        'LogsDir',       logsDir, ...
        'ExportsDir',    exportsDir, ...
        'Sources',       sources, ...
        'Results',       results, ...
        'Summary',       summary, ...
        'Timestamp',     timestamp, ...
        'LogFile',       logFile, ...
        'GenerationErrors', {cellstr(genErrors)});

    % v1.4: legacy autotest.ReportRenderer (HTML + Markdown + best-effort
    % PDF) was retired.  The native system-test-report generator below
    % (autotest.generateSystemTestReport, opted in via 'GenerateReport')
    % supersedes it -- single .docx deliverable + audit sidecar + every
    % chart and table the legacy report carried plus the v1.4 polish.

    % ── Phase 15: native MATLAB system-test-report generator ─────────────
    % When 'GenerateReport' is true, build a full Word-format system test
    % report under <reportsDir> via autotest.generateSystemTestReport.
    % The function selects between mlreportgen.dom (when licensed) and a
    % hand-rolled OOXML emitter (built-ins only); see report_backend.log.
    if r.GenerateReport
        try
            ropts = r.ReportOptions;
            cellArgs = {};
            if isstruct(ropts)
                f = fieldnames(ropts);
                for k = 1:numel(f)
                    cellArgs{end+1} = f{k}; %#ok<AGROW>
                    cellArgs{end+1} = ropts.(f{k}); %#ok<AGROW>
                end
            end
            reportInfo = autotest.generateSystemTestReport(folder, cellArgs{:});
            info.ReportDocxPath = reportInfo.DocxPath;
            info.ReportPdfPath  = reportInfo.PdfPath;
            info.ReportBackend  = reportInfo.BackendDisplay;
            % v1.3 Part B item 3: surface the audit sidecar path so
            % callers can `disp(info.AuditSidecar)` after a workflow
            % run.  ReportBuilder.build already writes the sidecar;
            % this is just the wiring fix.
            if isfield(reportInfo, 'AuditSidecar')
                info.AuditSidecar = reportInfo.AuditSidecar;
            else
                info.AuditSidecar = '';
            end
            fprintf('Wrote %s (backend: %s)\n', reportInfo.DocxPath, reportInfo.BackendDisplay);
            if ~isempty(reportInfo.PdfPath)
                fprintf('Wrote %s\n', reportInfo.PdfPath);
            end
            if ~isempty(info.AuditSidecar)
                fprintf('Wrote %s\n', info.AuditSidecar);
            end
        catch ME
            warning('autotest:GenerateReport', ...
                'Native report generation failed: %s', ME.message);
        end
    end
end

% =============================================================================
% Local helpers
% =============================================================================

function sources = discoverSources(folder, outRoot)
    sources = repmat(struct( ...
        'Path', '', 'RelPath', '', 'Kind', '', ...
        'Generated', false, 'GeneratedTest', '', 'Error', ''), ...
        0, 1);

    list = dir(fullfile(folder, '**', '*'));
    for i = 1:numel(list)
        d = list(i);
        if d.isdir
            continue
        end
        full = fullfile(d.folder, d.name);
        % Skip anything inside the autotest output root.
        if startsWith(normalisePath(full), [normalisePath(outRoot) filesep])
            continue
        end
        % Skip anything inside a VCS / IDE / dependency folder.  We use the
        % folder of the dirent rather than the file basename so we catch
        % files several levels deep inside (e.g. .git/hooks/foo.sample).
        if isInsideIgnoredFolder(d.folder, folder)
            continue
        end
        [~, name, ext] = fileparts(d.name);
        ext = lower(ext);
        if ~ismember(ext, {'.m', '.mlapp'})
            continue
        end
        % Skip files that look like test files already.
        if isLikelyTestFile(name)
            continue
        end
        % Skip files inside test fixture / "tests" subtrees if they look
        % like test classes themselves (handled by isLikelyTestFile above).
        rel = relativePath(full, folder);
        sources(end+1,1) = struct( ...
            'Path',          full, ...
            'RelPath',       rel, ...
            'Kind',          ext, ...
            'Generated',     false, ...
            'GeneratedTest', '', ...
            'Error',         ''); %#ok<AGROW>
    end
end

function tf = isLikelyTestFile(name)
    % Phase 7 (Option 3): also exclude run_*.m launcher scripts
    % (e.g. run_autotest.m) -- they're entry points, not testable
    % surfaces, and generating a trivial existence-only test class for
    % them adds noise to the per-source breakdown.
    tf = ~isempty(regexp(name, '^t[A-Z]', 'once')) || ...
         ~isempty(regexp(name, '^test[A-Z]', 'once')) || ...
         ~isempty(regexp(name, '^run_[A-Za-z]', 'once'));
end

function tf = isInsideIgnoredFolder(folderOfFile, projectRoot)
    % Check whether any path component (relative to PROJECTROOT) matches a
    % name that we know we never want to scan.  Keeping the check on path
    % components -- not substrings -- avoids accidentally hiding a folder
    % whose name happens to contain ".git" or "node_modules".
    ignored = {'.git', '.svn', '.hg', '.idea', '.vscode', ...
               'node_modules', '_autotest'};
    rel = relativePath(folderOfFile, projectRoot);
    if isempty(rel)
        tf = false;
        return
    end
    parts = strsplit(rel, filesep);
    parts(cellfun(@isempty, parts)) = [];
    tf = any(ismember(parts, ignored));
end

function addProjectPaths(folder, outRoot)
    % Add every non-package, non-class subdirectory under FOLDER to the
    % MATLAB path, excluding anything inside outRoot or inside a known VCS /
    % IDE folder.  Failures here are non-fatal (we warn and continue): the
    % generated tests fall back to per-test addpath of the source file's
    % own directory in TestMethodSetup, so a missing project-wide addpath
    % only affects cross-folder dependencies.
    try
        raw = strsplit(genpath(folder), pathsep);
    catch ME
        warning('autotest:addProjectPaths', ...
            'genpath failed for %s: %s', folder, ME.message);
        return
    end
    raw = raw(~cellfun(@isempty, raw));
    keep = false(size(raw));
    outNorm = normalisePath(outRoot);
    ignored = {'.git', '.svn', '.hg', '.idea', '.vscode', ...
               'node_modules', '_autotest'};
    for i = 1:numel(raw)
        n = normalisePath(raw{i});
        if strcmp(n, outNorm) || startsWith(n, [outNorm filesep])
            continue
        end
        if any(cellfun(@(seg) ~isempty(strfind([filesep n filesep], ...
                [filesep seg filesep])), ignored))
            continue
        end
        keep(i) = true;
    end
    keptDirs = raw(keep);
    if ~isempty(keptDirs)
        addpath(strjoin(keptDirs, pathsep));
    end
end

function [results, summary] = runGeneratedTests(testDirs, reportsDir)
    import matlab.unittest.TestSuite
    import matlab.unittest.TestRunner
    import matlab.unittest.plugins.TAPPlugin
    import matlab.unittest.plugins.XMLPlugin
    import matlab.unittest.plugins.ToFile

    if ischar(testDirs) || isstring(testDirs)
        testDirs = cellstr(testDirs);
    end

    tapFile = fullfile(reportsDir, 'results.tap');
    xmlFile = fullfile(reportsDir, 'results.xml');

    % Clear stale reports from prior runs.
    for f = {tapFile, xmlFile}
        if isfile(f{1})
            delete(f{1});
        end
    end

    % Build the suite by unioning every test directory we were given.
    % Empty per-dir suites are fine -- they just contribute nothing.
    suite = matlab.unittest.Test.empty;
    for i = 1:numel(testDirs)
        d = testDirs{i};
        if ~isfolder(d), inue; end
        try
            sub = TestSuite.fromFolder(d, 'IncludingSubfolders', true);
        catch ME
            warning('autotest:Suite', ...
                'Could not collect tests from %s: %s', d, ME.message);
            continue
        end
        suite = [suite, sub]; %#ok<AGROW>
    end
    if isempty(suite)
        results = matlab.unittest.TestResult.empty;
        summary = struct('Total', 0, 'Passed', 0, 'Failed', 0, ...
            'Incomplete', 0, 'DurationSeconds', 0, ...
            'GeneratedTotal', 0, 'GeneratedPassed', 0, ...
            'GeneratedFailed', 0, 'GeneratedIncomplete', 0, ...
            'UserStubTotal', 0, 'UserStubIncomplete', 0);
        return
    end

    runner = TestRunner.withTextOutput();
    try
        runner.addPlugin(TAPPlugin.producingOriginalFormat(ToFile(tapFile)));
    catch ME
        warning('autotest:TAPPlugin', 'TAP plugin failed: %s', ME.message);
    end
    try
        runner.addPlugin(XMLPlugin.producingJUnitFormat(xmlFile));
    catch ME
        warning('autotest:XMLPlugin', 'XML plugin failed: %s', ME.message);
    end

    results = runner.run(suite);
    % Phase 1.5: split user-stub Incompletes out of the headline.
    isUserStub = false(size(results));
    for i = 1:numel(results)
        nm = char(results(i).Name);
        slash = strfind(nm, '/');
        if isempty(slash), continue; end
        prefix = nm(1:slash(1)-1);
        if ~isempty(prefix) && prefix(1) == 'u'
            isUserStub(i) = true;
        end
    end
    gen = results(~isUserStub);
    usr = results(isUserStub);
    summary = struct( ...
        'Total',                numel(results), ...
        'Passed',               sum([results.Passed]), ...
        'Failed',               sum([results.Failed]), ...
        'Incomplete',           sum([results.Incomplete]), ...
        'DurationSeconds',      sum([results.Duration]), ...
        'GeneratedTotal',       numel(gen), ...
        'GeneratedPassed',      sum([gen.Passed]), ...
        'GeneratedFailed',      sum([gen.Failed]), ...
        'GeneratedIncomplete',  sum([gen.Incomplete]), ...
        'UserStubTotal',        numel(usr), ...
        'UserStubIncomplete',   sum([usr.Incomplete]));
end

function writeSummary(file, folder, outRoot, timestamp, sources, results, summary, genErrors)
    lines = strings(0,1);
    lines(end+1,1) = "autotest run summary";
    lines(end+1,1) = "====================";
    lines(end+1,1) = sprintf("Timestamp:        %s", timestamp);
    lines(end+1,1) = sprintf("Project folder:   %s", folder);
    lines(end+1,1) = sprintf("Output root:      %s", outRoot);
    lines(end+1,1) = "";
    lines(end+1,1) = sprintf("Sources scanned:  %d", numel(sources));
    if ~isempty(sources)
        nGen = sum([sources.Generated]);
        lines(end+1,1) = sprintf("  generated:      %d", nGen);
        lines(end+1,1) = sprintf("  failed:         %d", numel(sources) - nGen);
    end
    lines(end+1,1) = "";
    if isfield(summary, 'GeneratedTotal')
        lines(end+1,1) = sprintf("Generated tests:  %d", summary.GeneratedTotal);
        lines(end+1,1) = sprintf("  passed:         %d", summary.GeneratedPassed);
        lines(end+1,1) = sprintf("  failed:         %d", summary.GeneratedFailed);
        lines(end+1,1) = sprintf("  incomplete:     %d", summary.GeneratedIncomplete);
        lines(end+1,1) = "";
        lines(end+1,1) = sprintf("User stub tests:  %d (all Incomplete by design --", ...
            summary.UserStubTotal);
        lines(end+1,1) = "                  fill in user_tests/u<Name>.m to enable)";
        lines(end+1,1) = "";
    end
    lines(end+1,1) = sprintf("Total tests:      %d", summary.Total);
    lines(end+1,1) = sprintf("  passed:         %d", summary.Passed);
    lines(end+1,1) = sprintf("  failed:         %d", summary.Failed);
    lines(end+1,1) = sprintf("  incomplete:     %d", summary.Incomplete);
    lines(end+1,1) = sprintf("Duration:         %.2f s", summary.DurationSeconds);
    lines(end+1,1) = "";
    lines(end+1,1) = "Per-source breakdown";
    lines(end+1,1) = "--------------------";
    for i = 1:numel(sources)
        s = sources(i);
        if s.Generated
            stats = perSourceStats(s, results);
            lines(end+1,1) = sprintf("  [%s] %s  (passed %d/%d, failed %d)", ...
                'gen', s.RelPath, stats.Passed, stats.Total, stats.Failed); %#ok<AGROW>
        else
            lines(end+1,1) = sprintf("  [err] %s  (%s)", ...
                s.RelPath, s.Error); %#ok<AGROW>
        end
    end
    if ~isempty(genErrors)
        lines(end+1,1) = "";
        lines(end+1,1) = "Generation errors";
        lines(end+1,1) = "-----------------";
        for i = 1:numel(genErrors)
            lines(end+1,1) = "  " + genErrors(i); %#ok<AGROW>
        end
    end
    writeLines(file, lines);
end

function stats = perSourceStats(src, results)
    if isempty(results)
        stats = struct('Total', 0, 'Passed', 0, 'Failed', 0);
        return
    end
    [~, gName] = fileparts(src.GeneratedTest);
    names = {results.Name};
    mask = startsWith(names, [gName '/']) | strcmp(names, gName);
    if ~any(mask)
        stats = struct('Total', 0, 'Passed', 0, 'Failed', 0);
    else
        sub = results(mask);
        stats = struct( ...
            'Total',  numel(sub), ...
            'Passed', sum([sub.Passed]), ...
            'Failed', sum([sub.Failed]));
    end
end

function writeLines(file, lines)
    fid = fopen(file, 'w');
    if fid < 0
        error('autotest:WriteFailed', 'Cannot open %s for writing.', file);
    end
    cleanup = onCleanup(@() fclose(fid)); %#ok<NASGU>
    for i = 1:numel(lines)
        fprintf(fid, '%s\n', char(lines(i)));
    end
end

function mkdirIfMissing(d)
    if ~isfolder(d)
        mkdir(d);
    end
end

function closeLeakedFigures(preFigs)
    try
        postFigs = findall(groot, 'Type', 'figure');
        if isempty(postFigs)
            return
        end
        if isempty(preFigs)
            leaked = postFigs;
        else
            leaked = setdiff(postFigs, preFigs);
        end
        for k = 1:numel(leaked)
            try
                delete(leaked(k));
            catch
            end
        end
    catch
    end
end

function abs = absolutePath(p)
    if isempty(p)
        abs = '';
        return
    end
    f = java.io.File(p);
    if f.isAbsolute()
        abs = char(f.getCanonicalPath());
    else
        abs = char(java.io.File(fullfile(pwd, p)).getCanonicalPath());
    end
end

function n = normalisePath(p)
    n = char(p);
    if ~isempty(n) && (n(end) == filesep)
        n(end) = [];
    end
end

function rel = relativePath(target, base)
    target = normalisePath(absolutePath(target));
    base   = normalisePath(absolutePath(base));
    if strcmpi(target, base)
        rel = '';
    elseif startsWith(lower(target), [lower(base) filesep])
        rel = target(numel(base)+2:end);
    else
        rel = target;
    end
end
