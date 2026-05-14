function info = autotestGUI(varargin)
%AUTOTESTGUI  Interactive entry point for the autotest workflow.
%
%   AUTOTESTGUI() prompts for a project folder, then for a Classification
%   level + whether to build the system-test report, then generates and
%   runs tests for every .m and .mlapp source it finds.  Results land in
%   <chosenFolder>/_autotest/.
%
%   AUTOTESTGUI(FOLDER) skips the folder picker and runs against FOLDER.
%   The Classification dialog still appears unless 'Classification' is
%   supplied as a name-value parameter.
%
%   AUTOTESTGUI(..., 'Classification', LEVEL) skips the classification
%   dialog and uses LEVEL.  Valid values: 'UNCLASSIFIED', 'CONFIDENTIAL',
%   'SECRET', 'TOP SECRET', 'FOUO'.  Anything else is passed through and
%   falls back to the charcoal banner in generateSystemTestReport.
%
%   AUTOTESTGUI(..., 'GenerateReport', TF) skips the report-toggle
%   dialog and forces the build on (TRUE) or off (FALSE).  When FALSE,
%   the Classification picker is skipped too (classification is only
%   used by the report builder).
%
%   AUTOTESTGUI(..., 'Prompt', TF) when FALSE forces a fully programmatic
%   run with no dialogs at all -- equivalent to passing both
%   'Classification' and 'GenerateReport' explicitly.  Default TRUE.
%
%   INFO = AUTOTESTGUI(...) returns the same struct as AUTOTEST.RUNWORKFLOW.
%
%   Persistence: last-used folder, classification, and report toggle are
%   remembered via getpref/setpref under the 'autotest' group, keys
%   'LastFolder', 'LastClassification', 'LastGenerateReport'.
%
%   See also: AUTOTEST.RUNWORKFLOW, AUTOTEST.GENERATESYSTEMTESTREPORT,
%             GENERATETESTS.

    here = fileparts(mfilename('fullpath'));
    if ~isempty(here) && exist(fullfile(here, '+autotest'), 'dir')
        addpath(here);
    end

    % ── Argument parsing ────────────────────────────────────────────────
    folderArg = '';
    if ~isempty(varargin) && ~ischar(varargin{1}) && ~isstring(varargin{1})
        % First arg is not a path -- assume it's the start of name-value pairs.
        nvStart = 1;
    elseif ~isempty(varargin)
        folderArg = char(varargin{1});
        nvStart = 2;
    else
        nvStart = 1;
    end

    p = inputParser();
    p.addParameter('Classification', '', @(x) ischar(x) || isstring(x));
    p.addParameter('GenerateReport', [], @(x) isempty(x) || islogical(x));
    p.addParameter('Prompt', true, @islogical);
    p.parse(varargin{nvStart:end});
    r = p.Results;

    explicitClassification = ~isempty(char(r.Classification));
    explicitGenerate       = ~isempty(r.GenerateReport);

    % ── Folder pick ─────────────────────────────────────────────────────
    if ~isempty(folderArg)
        folder = folderArg;
    else
        folder = pickFolder();
        if isempty(folder)
            fprintf('autotestGUI cancelled.\n');
            info = [];
            return
        end
    end
    setpref('autotest', 'LastFolder', folder);

    % ── Classification + report-toggle pick ─────────────────────────────
    % Decide whether to show the dialog.  We skip it when the caller
    % supplied BOTH knobs explicitly or when 'Prompt' is false.
    needPrompt = r.Prompt && ~(explicitClassification && explicitGenerate);
    if needPrompt && ~hasDisplay()
        warning('autotest:NoDisplay', ...
            ['autotestGUI cannot show its Classification dialog (no display). ' ...
             'Falling back to remembered settings.']);
        needPrompt = false;
    end

    [classification, genReport, cancelled] = resolveRunOptions( ...
        r, explicitClassification, explicitGenerate, needPrompt);
    if cancelled
        fprintf('autotestGUI cancelled.\n');
        info = [];
        return
    end

    setpref('autotest', 'LastClassification', classification);
    setpref('autotest', 'LastGenerateReport', genReport);

    % ── Run ─────────────────────────────────────────────────────────────
    if genReport
        info = autotest.runWorkflow(folder, ...
            'GenerateReport', true, ...
            'ReportOptions', struct('Classification', classification));
    else
        info = autotest.runWorkflow(folder);
    end

    showSummaryDialog(info, classification, genReport);
end

% =============================================================================
% Helpers
% =============================================================================

function folder = pickFolder()
    if ispref('autotest', 'LastFolder')
        startDir = getpref('autotest', 'LastFolder');
        if ~isfolder(startDir)
            startDir = pwd;
        end
    else
        startDir = pwd;
    end
    selected = uigetdir(startDir, 'Select project folder to test');
    if isequal(selected, 0)
        folder = '';
    else
        folder = selected;
    end
end

function [classification, genReport, cancelled] = resolveRunOptions( ...
        r, explicitClassification, explicitGenerate, needPrompt)
    %RESOLVERUNOPTIONS  Combine explicit args, last-used prefs, and the
    %   optional dialog into the (classification, genReport) pair we
    %   hand to runWorkflow.  Pure logic; no side effects beyond the
    %   dialog itself.
    cancelled = false;

    % Defaults from prefs (NOT auto-applied to skip the dialog; just the
    % initial values shown).
    if ispref('autotest', 'LastClassification')
        defaultClass = char(getpref('autotest', 'LastClassification'));
    else
        defaultClass = 'UNCLASSIFIED';
    end
    if ispref('autotest', 'LastGenerateReport')
        defaultGenerate = logical(getpref('autotest', 'LastGenerateReport'));
    else
        defaultGenerate = false;
    end

    % Explicit args win unconditionally.
    if explicitClassification
        classification = char(r.Classification);
    else
        classification = defaultClass;
    end
    if explicitGenerate
        genReport = logical(r.GenerateReport);
    else
        genReport = defaultGenerate;
    end

    if ~needPrompt
        return
    end

    % Show the dialog seeded with the chosen defaults.
    [picked, ok] = showRunOptionsDialog(classification, genReport);
    if ~ok
        cancelled = true;
        return
    end
    classification = picked.Classification;
    genReport      = picked.GenerateReport;
end

function [out, ok] = showRunOptionsDialog(initClass, initGenerate)
    %SHOWRUNOPTIONSDIALOG  Modal uifigure for Classification + report toggle.
    %   Returns OUT struct with fields Classification + GenerateReport,
    %   and OK = true on confirm, false on cancel/close.
    levels = {'UNCLASSIFIED', 'CONFIDENTIAL', 'SECRET', 'TOP SECRET', 'FOUO'};
    if ~ismember(initClass, levels)
        % Preserve user-supplied non-standard value by prepending it.
        levels = [{initClass}, levels];
    end

    out = struct('Classification', initClass, 'GenerateReport', initGenerate);
    ok  = false;
    confirmed = false;
    pickedClass    = initClass;        % captured by the OK callback
    pickedGenerate = logical(initGenerate);

    fig = uifigure('Name', 'autotest run options', ...
        'Position', [300 300 420 220], ...
        'Resize', 'off', ...
        'WindowStyle', 'modal');
    % Treat the window close (X) the same as Cancel so we resume cleanly
    % instead of leaving uiwait hung.
    fig.CloseRequestFcn = @(~,~) onCancel();
    cleaner = onCleanup(@() safeClose(fig)); %#ok<NASGU>

    gl = uigridlayout(fig, [4 2]);
    gl.RowHeight   = {'fit', 'fit', 'fit', 'fit'};
    gl.ColumnWidth = {'fit', '1x'};
    gl.Padding     = [16 16 16 16];
    gl.RowSpacing  = 12;

    titleLbl = uilabel(gl, ...
        'Text', 'Run options', ...
        'FontSize', 16, 'FontWeight', 'bold');
    titleLbl.Layout.Row    = 1;
    titleLbl.Layout.Column = [1 2];

    classLbl = uilabel(gl, 'Text', 'Classification:');
    classLbl.Layout.Row    = 2;
    classLbl.Layout.Column = 1;
    classDD = uidropdown(gl, ...
        'Items', levels, ...
        'Value', initClass);
    classDD.Layout.Row    = 2;
    classDD.Layout.Column = 2;

    repLbl = uilabel(gl, 'Text', 'Generate report:');
    repLbl.Layout.Row    = 3;
    repLbl.Layout.Column = 1;
    repCB = uicheckbox(gl, ...
        'Text', '   build .docx / .pdf system-test report', ...
        'Value', logical(initGenerate));
    repCB.Layout.Row    = 3;
    repCB.Layout.Column = 2;

    btnPanel = uipanel(gl, 'BorderType', 'none');
    btnPanel.Layout.Row    = 4;
    btnPanel.Layout.Column = [1 2];
    btnGl = uigridlayout(btnPanel, [1 2]);
    btnGl.ColumnWidth = {'1x', '1x'};
    btnGl.Padding     = [0 0 0 0];
    btnGl.ColumnSpacing = 12;
    cancelBtn = uibutton(btnGl, ...
        'Text', 'Cancel', ...
        'ButtonPushedFcn', @(~,~) onCancel()); %#ok<NASGU>
    runBtn = uibutton(btnGl, ...
        'Text', 'Run', ...
        'FontWeight', 'bold', ...
        'ButtonPushedFcn', @(~,~) onConfirm()); %#ok<NASGU>

    % Block until the user dismisses.  uiwait returns when the figure is
    % deleted or resumed.
    uiwait(fig);

    if confirmed
        out.Classification = pickedClass;
        out.GenerateReport = pickedGenerate;
        ok = true;
    end

    function onConfirm()
        % Read widget values BEFORE destroying the figure -- once the
        % uifigure is deleted, classDD/repCB throw "Invalid or deleted
        % object" on .Value access.
        try
            pickedClass    = char(classDD.Value);
            pickedGenerate = logical(repCB.Value);
        catch
            % Widgets vanished out from under us; keep the seeded
            % defaults rather than crashing the workflow.
        end
        confirmed = true;
        uiresume(fig);
        delete(fig);
    end

    function onCancel()
        confirmed = false;
        uiresume(fig);
        if isgraphics(fig)
            delete(fig);
        end
    end
end

function safeClose(fig)
    try
        if isgraphics(fig)
            delete(fig);
        end
    catch
    end
end

function showSummaryDialog(info, classification, genReport)
    if isempty(info)
        return
    end

    s = info.Summary;
    if isfield(s, 'GeneratedTotal')
        gTot = s.GeneratedTotal;  gPass = s.GeneratedPassed;
        gFail = s.GeneratedFailed; gInc = s.GeneratedIncomplete;
        uStub = s.UserStubTotal;
    else
        gTot = s.Total;  gPass = s.Passed;
        gFail = s.Failed; gInc = s.Incomplete;
        uStub = 0;
    end
    msg = sprintf([ ...
        'autotest run complete\n\n' ...
        'Project: %s\n' ...
        'Classification: %s\n' ...
        'Report:         %s\n\n' ...
        'Sources: %d (generated %d)\n' ...
        'Generated tests: %d\n' ...
        '  passed:        %d\n' ...
        '  failed:        %d\n' ...
        '  incomplete:    %d\n' ...
        'User stubs:      %d (awaiting implementation)\n' ...
        'Duration:        %.2f s\n\n' ...
        'Output: %s'], ...
        info.Folder, ...
        classification, ...
        ternary(genReport, 'enabled', 'skipped'), ...
        numel(info.Sources), sum([info.Sources.Generated]), ...
        gTot, gPass, gFail, gInc, uStub, ...
        info.Summary.DurationSeconds, ...
        info.OutputRoot);

    if ~hasDisplay()
        fprintf('%s\n', msg);
        return
    end

    try
        fig = uifigure('Name', 'autotest results', ...
            'Position', [100 100 460 360], ...
            'Resize', 'off');
        gl = uigridlayout(fig, [3 2]);
        gl.RowHeight   = {'fit', '1x', 'fit'};
        gl.ColumnWidth = {'1x', '1x'};

        title = uilabel(gl, ...
            'Text', headlineText(info), ...
            'FontSize', 16, ...
            'FontWeight', 'bold');
        title.Layout.Row    = 1;
        title.Layout.Column = [1 2];

        body = uitextarea(gl, ...
            'Value', strsplit(msg, newline), ...
            'Editable', 'off');
        body.Layout.Row    = 2;
        body.Layout.Column = [1 2];

        htmlPath = fullfile(info.ReportsDir, 'report.html');
        if isfile(htmlPath)
            openBtn = uibutton(gl, ...
                'Text', 'Open HTML report', ...
                'ButtonPushedFcn', @(~,~) openOutputFolder(htmlPath));
        else
            openBtn = uibutton(gl, ...
                'Text', 'Open output folder', ...
                'ButtonPushedFcn', @(~,~) openOutputFolder(info.OutputRoot));
        end
        openBtn.Layout.Row    = 3;
        openBtn.Layout.Column = 1;

        closeBtn = uibutton(gl, ...
            'Text', 'Close', ...
            'ButtonPushedFcn', @(~,~) close(fig));
        closeBtn.Layout.Row    = 3;
        closeBtn.Layout.Column = 2;
    catch ME
        warning('autotest:SummaryDialog', ...
            'Could not show summary dialog: %s', ME.message);
        fprintf('%s\n', msg);
    end
end

function txt = headlineText(info)
    s = info.Summary;
    if isfield(s, 'GeneratedTotal')
        gTot = s.GeneratedTotal;  gFail = s.GeneratedFailed;
        gInc = s.GeneratedIncomplete;
    else
        gTot = s.Total;  gFail = s.Failed; gInc = s.Incomplete;
    end
    if gFail == 0 && gInc == 0 && gTot > 0
        txt = sprintf('All %d generated tests passed', gTot);
    elseif gTot == 0
        txt = 'No tests were generated';
    else
        txt = sprintf('%d failed, %d incomplete (of %d generated)', ...
            gFail, gInc, gTot);
    end
end

function openOutputFolder(p)
    try
        if ispc
            winopen(p);
        elseif ismac
            system(['open "' p '"']);
        else
            system(['xdg-open "' p '" &']);
        end
    catch ME
        warning('autotest:OpenFolder', ...
            'Could not open %s: %s', p, ME.message);
    end
end

function tf = hasDisplay()
    if ispc || ismac
        tf = usejava('desktop') || feature('ShowFigureWindows');
    else
        tf = ~isempty(getenv('DISPLAY')) && (usejava('desktop') || feature('ShowFigureWindows'));
    end
end

function v = ternary(cond, a, b)
    if cond, v = a; else, v = b; end
end
