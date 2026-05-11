function info = generateReport(projectPath, varargin)
%AUTOTEST.GENERATEREPORT  v1.6 -- regenerate the report from existing test artefacts.
%
%   info = autotest.generateReport(PROJECTPATH, 'Name', value, ...)
%
%   Reads the most recent test artefacts under
%   <PROJECTPATH>/_autotest/reports/ (summary.txt, results.xml,
%   known_real_signal.txt) and re-emits ONLY the report stage --
%   no source rescan, no test regeneration, no test re-run.  Use this
%   when:
%     * You've hand-edited user_tests/u<Name>.m and re-run via
%       `runtests` outside the autogen workflow, and want a refreshed
%       deliverable from the new results.xml.
%     * You want to flip a ReportOptions field (Classification,
%       DistributionDate, DocVersion) without paying the full
%       autotest cycle's cost.
%     * You're driving the report from CI after a test stage that
%       already produced the JUnit artefacts.
%
%   Inputs:
%     PROJECTPATH - the project folder; <PROJECTPATH>/_autotest/reports/
%                   must already contain summary.txt + results.xml.
%
%   Name-value parameters (forwarded to
%   autotest.generateSystemTestReport; defaults in brackets):
%     'DisplayName'             [<basename of PROJECTPATH, prettified>]
%     'Owner'                   ['Project Owner -- <DisplayName>']
%     'DocVersion'              ['1.6']
%     'ProjectPrefix'           [2-letter prefix from <DisplayName>]
%     'DistributionReason'      ['Administrative or Operational Use']
%     'DistributionDate'        [<Month YYYY of today>]
%     'DistributionController'  ['the Project Owner']
%     'OutputDir'               [<PROJECTPATH>/_autotest/reports]
%     'OutputBaseName'          [<basename of PROJECTPATH>]
%     'PdfBackend'              ['auto' | 'rptgen' | 'libreoffice' | 'none']
%     'Classification'          ['UNCLASSIFIED']
%     'GenerateHtml'            [true]
%     'ReportOptions'           struct of any of the above -- forwarded
%                               fields override defaults.  Lets callers
%                               share an options struct with
%                               autotest.runWorkflow.
%
%   Returns:
%     INFO  struct with fields:
%       .ReportHtmlPath  - HTML deliverable path ('' if not produced)
%       .ReportDocxPath  - Docx deliverable path ('' if docx step
%                          failed best-effort)
%       .ReportPdfPath   - Pdf deliverable path ('' if no PDF tier)
%       .ReportBackend   - selected backend display name
%       .AuditSidecar    - audit sidecar path
%
%   When no recent results exist under the project's _autotest/reports/
%   directory, ERRORS with a clear actionable message rather than
%   producing a hollow report.  This is the right failure mode for
%   the "I re-ran my tests, now refresh the report" workflow.
%
%   See also: autotest.runWorkflow, autotest.generateSystemTestReport.

    if ~(ischar(projectPath) || isstring(projectPath))
        error('autotest:generateReport:Path', ...
            'PROJECTPATH must be a char or string scalar.');
    end
    projectPath = char(projectPath);
    if ~isfolder(projectPath)
        error('autotest:generateReport:NoProject', ...
            'Project folder does not exist: %s', projectPath);
    end

    % Pre-flight: confirm the workflow has actually run at least once
    % under this project so the report stage has something to read.
    reportsDir = fullfile(projectPath, '_autotest', 'reports');
    summaryTxt = fullfile(reportsDir, 'summary.txt');
    resultsXml = fullfile(reportsDir, 'results.xml');
    if ~isfile(summaryTxt) || ~isfile(resultsXml)
        error('autotest:generateReport:NoResults', ...
            ['No test results found under %s.\n' ...
             '  Expected: summary.txt + results.xml after a previous run.\n' ...
             '  Fix: run `autotest.runWorkflow(''%s'')` first, OR run\n' ...
             '       the generated tests via `runtests` to refresh the\n' ...
             '       JUnit XML before re-invoking autotest.generateReport.'], ...
            reportsDir, projectPath);
    end

    % Accept either flat name-value pairs OR a 'ReportOptions' struct
    % (so callers can share an options block with runWorkflow).
    p = inputParser();
    p.KeepUnmatched = true;
    p.addParameter('ReportOptions', struct(), @isstruct);
    p.parse(varargin{:});

    cellArgs = {};
    if ~isempty(fieldnames(p.Unmatched))
        f = fieldnames(p.Unmatched);
        for k = 1:numel(f)
            cellArgs{end+1} = f{k}; %#ok<AGROW>
            cellArgs{end+1} = p.Unmatched.(f{k}); %#ok<AGROW>
        end
    end
    ropts = p.Results.ReportOptions;
    if isstruct(ropts) && ~isempty(fieldnames(ropts))
        f = fieldnames(ropts);
        for k = 1:numel(f)
            cellArgs{end+1} = f{k}; %#ok<AGROW>
            cellArgs{end+1} = ropts.(f{k}); %#ok<AGROW>
        end
    end

    reportInfo = autotest.generateSystemTestReport(projectPath, cellArgs{:});

    info = struct( ...
        'ReportHtmlPath', '', ...
        'ReportDocxPath', '', ...
        'ReportPdfPath',  '', ...
        'ReportBackend',  '', ...
        'AuditSidecar',   '');
    if isfield(reportInfo, 'HtmlPath')
        info.ReportHtmlPath = reportInfo.HtmlPath;
    end
    if isfield(reportInfo, 'DocxPath')
        info.ReportDocxPath = reportInfo.DocxPath;
    end
    if isfield(reportInfo, 'PdfPath')
        info.ReportPdfPath = reportInfo.PdfPath;
    end
    if isfield(reportInfo, 'BackendDisplay')
        info.ReportBackend = reportInfo.BackendDisplay;
    end
    if isfield(reportInfo, 'AuditSidecar')
        info.AuditSidecar = reportInfo.AuditSidecar;
    end

    if ~isempty(info.ReportHtmlPath)
        fprintf('Wrote %s\n', info.ReportHtmlPath);
    end
    if ~isempty(info.ReportDocxPath)
        fprintf('Wrote %s (backend: %s)\n', info.ReportDocxPath, info.ReportBackend);
    end
    if ~isempty(info.ReportPdfPath)
        fprintf('Wrote %s\n', info.ReportPdfPath);
    end
    if ~isempty(info.AuditSidecar)
        fprintf('Wrote %s\n', info.AuditSidecar);
    end
end
