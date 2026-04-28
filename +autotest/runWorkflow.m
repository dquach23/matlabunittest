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
    reportsDir   = fullfile(outRoot, 'reports');
    logsDir      = fullfile(outRoot, 'logs');
    exportsDir   = fullfile(outRoot, 'exports');

    if isfolder(generatedDir)
        rmdir(generatedDir, 's');
    end
    mkdirIfMissing(generatedDir);
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
    addProjectPaths(folder, outRoot);

    % ── Generate tests ───────────────────────────────────────────────────
    genErrors = strings(0,1);
    for i = 1:numel(sources)
        s = sources(i);
        relSubdir = fileparts(s.RelPath);
        outDir = fullfile(generatedDir, relSubdir);
        mkdirIfMissing(outDir);
        try
            tFile = generateTests(s.Path, ...
                'OutputDir', outDir, ...
                'Verbose',   r.Verbose);
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

    addpath(generatedDir);

    % ── Run tests ────────────────────────────────────────────────────────
    [results, summary] = runGeneratedTests(generatedDir, reportsDir);

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
        'ReportsDir',    reportsDir, ...
        'LogsDir',       logsDir, ...
        'ExportsDir',    exportsDir, ...
        'Sources',       sources, ...
        'Results',       results, ...
        'Summary',       summary, ...
        'Timestamp',     timestamp, ...
        'LogFile',       logFile, ...
        'GenerationErrors', {cellstr(genErrors)});
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
    tf = ~isempty(regexp(name, '^t[A-Z]', 'once')) || ...
         ~isempty(regexp(name, '^test[A-Z]', 'once'));
end

function addProjectPaths(folder, outRoot)
    % Add every non-package, non-class subdirectory under FOLDER to the
    % MATLAB path, excluding anything inside outRoot.
    raw = strsplit(genpath(folder), pathsep);
    raw = raw(~cellfun(@isempty, raw));
    keep = false(size(raw));
    outNorm = normalisePath(outRoot);
    for i = 1:numel(raw)
        n = normalisePath(raw{i});
        if strcmp(n, outNorm) || startsWith(n, [outNorm filesep])
            continue
        end
        keep(i) = true;
    end
    keptDirs = raw(keep);
    if ~isempty(keptDirs)
        addpath(strjoin(keptDirs, pathsep));
    end
end

function [results, summary] = runGeneratedTests(generatedDir, reportsDir)
    import matlab.unittest.TestSuite
    import matlab.unittest.TestRunner
    import matlab.unittest.plugins.TAPPlugin
    import matlab.unittest.plugins.XMLPlugin
    import matlab.unittest.plugins.ToFile

    tapFile = fullfile(reportsDir, 'results.tap');
    xmlFile = fullfile(reportsDir, 'results.xml');

    % Clear stale reports from prior runs.
    for f = {tapFile, xmlFile}
        if isfile(f{1})
            delete(f{1});
        end
    end

    suite = TestSuite.fromFolder(generatedDir, 'IncludingSubfolders', true);
    if isempty(suite)
        results = matlab.unittest.TestResult.empty;
        summary = struct('Total', 0, 'Passed', 0, 'Failed', 0, ...
            'Incomplete', 0, 'DurationSeconds', 0);
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
    summary = struct( ...
        'Total',           numel(results), ...
        'Passed',          sum([results.Passed]), ...
        'Failed',          sum([results.Failed]), ...
        'Incomplete',      sum([results.Incomplete]), ...
        'DurationSeconds', sum([results.Duration]));
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
