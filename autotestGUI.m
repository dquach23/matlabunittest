function info = autotestGUI(varargin)
%AUTOTESTGUI  Interactive entry point for the autotest workflow.
%
%   AUTOTESTGUI() prompts for a project folder, then generates and runs
%   tests for every .m and .mlapp source it finds.  Results land in
%   <chosenFolder>/_autotest/.
%
%   AUTOTESTGUI(FOLDER) skips the folder picker and runs against FOLDER.
%
%   INFO = AUTOTESTGUI(...) returns the same struct as AUTOTEST.RUNWORKFLOW.
%
%   Persistence: the last-used folder is remembered via getpref/setpref
%   under the 'autotest' group, key 'LastFolder'.
%
%   See also: AUTOTEST.RUNWORKFLOW, GENERATETESTS.

    here = fileparts(mfilename('fullpath'));
    if ~isempty(here) && exist(fullfile(here, '+autotest'), 'dir')
        addpath(here);
    end

    if nargin >= 1 && ~isempty(varargin{1})
        folder = char(varargin{1});
    else
        folder = pickFolder();
        if isempty(folder)
            fprintf('autotestGUI cancelled.\n');
            info = [];
            return
        end
    end

    setpref('autotest', 'LastFolder', folder);

    info = autotest.runWorkflow(folder);

    showSummaryDialog(info);
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

function showSummaryDialog(info)
    if isempty(info)
        return
    end

    msg = sprintf([ ...
        'autotest run complete\n\n' ...
        'Project: %s\n\n' ...
        'Sources: %d (generated %d)\n' ...
        'Total tests:    %d\n' ...
        '  passed:       %d\n' ...
        '  failed:       %d\n' ...
        '  incomplete:   %d\n' ...
        'Duration:       %.2f s\n\n' ...
        'Output: %s'], ...
        info.Folder, ...
        numel(info.Sources), sum([info.Sources.Generated]), ...
        info.Summary.Total, info.Summary.Passed, ...
        info.Summary.Failed, info.Summary.Incomplete, ...
        info.Summary.DurationSeconds, ...
        info.OutputRoot);

    if ~hasDisplay()
        fprintf('%s\n', msg);
        return
    end

    try
        fig = uifigure('Name', 'autotest results', ...
            'Position', [100 100 460 320], ...
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

        openBtn = uibutton(gl, ...
            'Text', 'Open output folder', ...
            'ButtonPushedFcn', @(~,~) openOutputFolder(info.OutputRoot));
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
    if info.Summary.Failed == 0 && info.Summary.Incomplete == 0 && info.Summary.Total > 0
        txt = sprintf('All %d tests passed', info.Summary.Total);
    elseif info.Summary.Total == 0
        txt = 'No tests were generated';
    else
        txt = sprintf('%d failed, %d incomplete', ...
            info.Summary.Failed, info.Summary.Incomplete);
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
