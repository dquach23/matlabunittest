classdef MlappFixtureProvider
    %MLAPPFIXTUREPROVIDER  Phase 3 helpers for App Designer callback tests.
    %
    %   Detects file-dialog usage in callback bodies (uigetfile /
    %   uiputfile / uigetdir) so the TestWriter can emit a stubbing
    %   wrapper around the callback invocation.  The wrapper installs
    %   shim .m files on a tempdir that shadow the built-in dialogs
    %   for the duration of the test, returning canned values so the
    %   callback doesn't block on a modal dialog.
    %
    %   This is a static-method class -- nothing instance-shaped --
    %   used at code-gen time by autotest.MlappParser (detection) and
    %   autotest.TestWriter (emission).

    properties (Constant)
        DialogFunctions = {'uigetfile', 'uiputfile', 'uigetdir'};
    end

    methods (Static)
        function dialogs = detectInBody(bodyText)
            %DETECTINBODY  Return the file-dialog functions referenced
            %   in BODYTEXT.  BODYTEXT is the raw char body of a single
            %   function (without classdef/method-block headers).  Line
            %   comments are masked before matching so that
            %   `% TODO uigetfile(...)` doesn't false-positive.
            dialogs = {};
            if isempty(bodyText), return; end
            cleaned = regexprep(bodyText, '%[^\r\n]*', '');
            names = autotest.MlappFixtureProvider.DialogFunctions;
            for k = 1:numel(names)
                pat = ['\<' names{k} '\s*\('];
                if ~isempty(regexp(cleaned, pat, 'once'))
                    dialogs{end+1} = names{k}; %#ok<AGROW>
                end
            end
        end

        function dialogs = detectForCallback(srcText, callbackName)
            %DETECTFORCALLBACK  Locate the callback function in SRCTEXT
            %   and return any file-dialog functions referenced in its
            %   body.  Returns {} when the callback isn't found or has
            %   no dialog references.  Handles the App Designer code
            %   layout (every callback is its own classdef method) by
            %   scanning from the matching `function ... <name>(...)`
            %   declaration up to the next `function ` line.
            dialogs = {};
            if isempty(srcText) || isempty(callbackName), return; end
            txt = regexprep(srcText, '\r\n?', '\n');
            sigPat = ['function\s+(?:\[?[^=]+?\]?\s*=\s*)?' ...
                regexptranslate('escape', char(callbackName)) ...
                '\s*\('];
            matchEnd = regexp(txt, sigPat, 'end', 'once');
            if isempty(matchEnd), return; end
            after = txt(matchEnd+1:end);
            nextSig = regexp(after, '(?m)^\s*function\b', 'start', 'once');
            if isempty(nextSig)
                body = after;
            else
                body = after(1:nextSig-1);
            end
            dialogs = autotest.MlappFixtureProvider.detectInBody(body);
        end

        function lines = stubInstallationLines(dialogs, indent)
            %STUBINSTALLATIONLINES  Return the MATLAB code lines that,
            %   when emitted into a test method body, install a tempdir
            %   shim for each dialog in DIALOGS.  INDENT is a leading
            %   whitespace prefix (e.g. 12 spaces) applied to each line.
            %   The returned cellstr is appended directly into the
            %   TestWriter buffer so the indentation matches the
            %   surrounding test method.
            if nargin < 2, indent = repmat(' ', 1, 12); end
            lines = {};
            if isempty(dialogs), return; end
            % We rely on a private helper installFileDialogStubs(testCase, dialogs)
            % which TestWriter.appendHelpers inlines into every test
            % class.  That keeps the generated tXxx.m self-contained.
            dialogList = '{';
            for k = 1:numel(dialogs)
                if k > 1, dialogList = [dialogList ', ']; end %#ok<AGROW>
                dialogList = [dialogList  dialogs{k} ]; %#ok<AGROW>
            end
            dialogList = [dialogList '}'];
            lines{end+1} = [indent '% --- Phase 3: file-dialog shim ---']; %#ok<AGROW>
            lines{end+1} = [indent 'testCase.installFileDialogStubs(' dialogList ');']; %#ok<AGROW>
        end
    end
end
