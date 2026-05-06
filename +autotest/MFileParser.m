classdef MFileParser < handle
    %MFILEPARSER  Parse a .m file into an autotest.SourceModel.
    %
    %   The parser handles function files (single or with sub-functions),
    %   script files (skipped), and classdef files (parses properties,
    %   methods, arguments blocks, and help-text Examples).
    %
    %   It is regex-based with a few state-tracking passes for string
    %   literals, comments, line continuations, and block nesting.  It is
    %   not a full MATLAB parser; it targets well-formed source code.

    properties (SetAccess = immutable)
        SourcePath (1,:) char
    end

    methods
        function obj = MFileParser(sourcePath)
            obj.SourcePath = sourcePath;
        end

        function model = parse(obj)
            raw = obj.readFile();
            lines = obj.preprocess(raw);

            model = autotest.SourceModel();
            model.SourcePath = obj.SourcePath;
            [~, model.SourceName] = fileparts(obj.SourcePath);

            firstSig = obj.firstSignificantLine(lines);
            if startsWith(firstSig, 'classdef')
                obj.parseClassdef(lines, model);
                model.Kind = 'classdef';
            elseif startsWith(firstSig, 'function')
                obj.parseFunctions(lines, model);
                model.Kind = 'function';
            else
                model.Kind = 'script';
            end
        end
    end

    methods (Access = private)
        function txt = readFile(obj)
            fid = fopen(obj.SourcePath, 'r');
            if fid < 0
                error('autotest:OpenFailed', 'Cannot open %s', obj.SourcePath);
            end
            cleaner = onCleanup(@() fclose(fid));
            txt = fread(fid, '*char').';
            % Normalise line endings.
            txt = regexprep(txt, '\r\n?', '\n');
        end

        function lines = preprocess(~, txt)
            % Returns a struct array with fields:
            %   Code       - line with strings/comments masked for parsing
            %   HelpText   - original comment text if this was a help line
            %   IsComment  - logical
            %   Raw        - original line (joined for continuations)

            % Join line continuations: trailing ... means concat next line.
            txt = regexprep(txt, '\.\.\.[^\n]*\n', ' ');

            rawLines = strsplit(txt, '\n', 'CollapseDelimiters', false);
            n = numel(rawLines);
            lines = repmat(struct('Code','','HelpText','','IsComment',false,'Raw',''), 1, n);

            inBlockComment = false;
            for i = 1:n
                rawLine = rawLines{i};
                trimmed = strtrim(rawLine);
                lines(i).Raw = rawLine;

                if inBlockComment
                    if startsWith(trimmed, '%}')
                        inBlockComment = false;
                    end
                    lines(i).IsComment = true;
                    lines(i).HelpText = trimmed;
                    lines(i).Code = '';
                    continue;
                end

                if strcmp(trimmed, '%{')
                    inBlockComment = true;
                    lines(i).IsComment = true;
                    lines(i).HelpText = trimmed;
                    lines(i).Code = '';
                    continue;
                end

                [code, commentText, isFullComment] = autotest.MFileParser.splitCodeComment(rawLine);
                lines(i).Code      = code;
                lines(i).HelpText  = commentText;
                lines(i).IsComment = isFullComment;
            end
        end

        function ln = firstSignificantLine(~, lines)
            ln = '';
            for i = 1:numel(lines)
                t = strtrim(lines(i).Code);
                if ~isempty(t)
                    ln = t;
                    return;
                end
            end
        end

        function parseFunctions(obj, lines, model)
            n = numel(lines);
            i = 1;
            while i <= n
                t = strtrim(lines(i).Code);
                if startsWith(t, 'function')
                    [fcn, helpStartIdx, bodyStartIdx, bodyEndIdx] = ...
                        obj.parseFunctionAt(lines, i);
                    if ~isempty(fcn.Name)
                        % Help text is the contiguous comments immediately
                        % after the function line.
                        fcn.HelpText = obj.collectHelpText(lines, helpStartIdx);
                        fcn.Examples = autotest.MFileParser.extractExamples(fcn.HelpText);
                        fcn.ArgumentBlocks = obj.parseArgumentBlocks(lines, bodyStartIdx, bodyEndIdx);
                        model.Functions(end+1) = fcn; %#ok<AGROW>
                    end
                    i = bodyEndIdx + 1;
                else
                    i = i + 1;
                end
            end
        end

        function parseClassdef(obj, lines, model)
            n = numel(lines);

            % Find classdef line.
            cdIdx = 0;
            for i = 1:n
                t = strtrim(lines(i).Code);
                if startsWith(t, 'classdef')
                    cdIdx = i;
                    break;
                end
            end
            if cdIdx == 0
                return;
            end

            cdLine = strtrim(lines(cdIdx).Code);
            tok = regexp(cdLine, ...
                '^classdef\s*(\([^)]*\))?\s*([\w.]+)\s*<\s*([^\n%]+)', ...
                'tokens', 'once');
            if isempty(tok)
                tok = regexp(cdLine, ...
                    '^classdef\s*(\([^)]*\))?\s*([\w.]+)', ...
                    'tokens', 'once');
                if ~isempty(tok)
                    tok{3} = '';
                end
            end
            if ~isempty(tok)
                model.ClassName = strtrim(tok{2});
                if ~isempty(tok{3})
                    supers = strsplit(strtrim(tok{3}), '&');
                    model.SuperClasses = strtrim(supers);
                    model.IsHandle = any(strcmp(model.SuperClasses, 'handle')) || ...
                                     any(contains(model.SuperClasses, 'matlab.apps.AppBase'));
                end
            end

            % Walk blocks at depth 1 inside classdef.
            i = cdIdx + 1;
            depth = 1;
            while i <= n && depth >= 1
                t = strtrim(lines(i).Code);
                if isempty(t)
                    i = i + 1; continue;
                end

                if depth == 1 && startsWith(t, 'properties')
                    attrs = autotest.MFileParser.parseBlockAttributes(t, 'properties');
                    [propIdxEnd, props] = obj.parsePropertiesBlock(lines, i+1, attrs);
                    model.Properties = [model.Properties, props];
                    i = propIdxEnd + 1;
                    continue;
                elseif depth == 1 && startsWith(t, 'methods')
                    attrs = autotest.MFileParser.parseBlockAttributes(t, 'methods');
                    [mthIdxEnd, methods] = obj.parseMethodsBlock(lines, i+1, attrs, model.ClassName);
                    model.Methods = [model.Methods, methods];
                    i = mthIdxEnd + 1;
                    continue;
                elseif depth == 1 && (startsWith(t, 'events') || startsWith(t, 'enumeration'))
                    skipEnd = obj.findMatchingEnd(lines, i+1);
                    i = skipEnd + 1;
                    continue;
                elseif strcmp(t, 'end')
                    depth = depth - 1;
                    if depth == 0
                        break;
                    end
                end
                i = i + 1;
            end

            % Detect constructor; collect its inputs onto model.
            for k = 1:numel(model.Methods)
                if strcmp(model.Methods(k).Name, model.ClassName)
                    inp = model.Methods(k).Inputs;
                    % Strip leading 'obj' equivalent if present (constructor
                    % doesn't take obj, but defensive).
                    model.ConstructorArgs = inp;
                    break;
                end
            end

            % Phase 2.4: tag classes whose ctor leaves required container
            % state empty (dictionary, containers.Map, struct, cell).  The
            % TestWriter uses this to emit testSkipped_<name> placeholders
            % for instance methods on stateful classes when the
            % FixtureProvider doesn't resolve a realistic call -- moves
            % crashes-because-state-is-empty failures from Failed to
            % Incomplete with a reason.
            obj.detectStateful(lines, model);
        end

        function [endIdx, props] = parsePropertiesBlock(obj, lines, startIdx, attrs)
            n = numel(lines);
            depth = 1;
            i = startIdx;
            props = autotest.SourceModel.emptyProp();
            while i <= n && depth >= 1
                t = strtrim(lines(i).Code);
                if strcmp(t, 'end')
                    depth = depth - 1;
                    if depth == 0, break; end
                elseif startsWith(t, 'properties') || startsWith(t, 'methods') ...
                        || startsWith(t, 'function') || startsWith(t, 'arguments') ...
                        || startsWith(t, 'if') || startsWith(t, 'for') ...
                        || startsWith(t, 'while') || startsWith(t, 'switch') ...
                        || startsWith(t, 'try') || startsWith(t, 'parfor')
                    depth = depth + 1;
                elseif ~isempty(t)
                    p = autotest.MFileParser.parsePropertyLine(t);
                    if ~isempty(p.Name)
                        access = '';
                        if isfield(attrs, 'Access'), access = attrs.Access; end
                        if isempty(access), access = 'public'; end
                        p.Access = access;
                        % SetAccess defaults to whatever Access is, unless
                        % explicitly tightened (Constant => SetAccess=immutable).
                        setAccess = access;
                        if isfield(attrs, 'SetAccess') && ~islogical(attrs.SetAccess)
                            setAccess = attrs.SetAccess;
                        end
                        p.SetAccess = setAccess;
                        if isfield(attrs, 'Dependent') && attrs.Dependent
                            p.IsDependent = true;
                        end
                        if isfield(attrs, 'Constant') && attrs.Constant
                            p.IsConstant = true;
                            p.SetAccess = 'immutable';
                        end
                        props(end+1) = p; %#ok<AGROW>
                    end
                end
                i = i + 1;
            end
            endIdx = i;
        end

        function [endIdx, methods] = parseMethodsBlock(obj, lines, startIdx, attrs, className)
            n = numel(lines);
            depth = 1;
            i = startIdx;
            methods = autotest.SourceModel.emptyFcn();
            while i <= n && depth >= 1
                t = strtrim(lines(i).Code);
                if strcmp(t, 'end')
                    depth = depth - 1;
                    if depth == 0, break; end
                    i = i + 1; continue;
                end

                if depth == 1 && startsWith(t, 'function')
                    [fcn, helpStartIdx, bodyStartIdx, bodyEndIdx] = ...
                        obj.parseFunctionAt(lines, i);
                    if ~isempty(fcn.Name)
                        fcn.HelpText = obj.collectHelpText(lines, helpStartIdx);
                        fcn.Examples = autotest.MFileParser.extractExamples(fcn.HelpText);
                        fcn.ArgumentBlocks = obj.parseArgumentBlocks(lines, bodyStartIdx, bodyEndIdx);
                        if isfield(attrs, 'Static') && attrs.Static
                            fcn.IsStatic = true;
                        end
                        if isfield(attrs, 'Access')
                            fcn.IsPublic = strcmpi(attrs.Access, 'public');
                        end
                        % If non-static and first input is the class instance
                        % handle (any name), strip it from Inputs.
                        if ~fcn.IsStatic && ~strcmp(fcn.Name, className) ...
                                && ~isempty(fcn.Inputs)
                            fcn.Inputs = fcn.Inputs(2:end);
                        end
                        methods(end+1) = fcn; %#ok<AGROW>
                    end
                    i = bodyEndIdx + 1;
                    continue;
                end

                if startsWith(t, 'if') || startsWith(t, 'for') ...
                        || startsWith(t, 'while') || startsWith(t, 'switch') ...
                        || startsWith(t, 'try') || startsWith(t, 'parfor') ...
                        || startsWith(t, 'arguments')
                    depth = depth + 1;
                end
                i = i + 1;
            end
            endIdx = i;
        end

        function [fcn, helpStartIdx, bodyStartIdx, bodyEndIdx] = parseFunctionAt(obj, lines, idx)
            fcn = autotest.SourceModel.makeFcn('');
            % Concatenate code until parenthesis balanced (continuations
            % already joined in preprocess, but multi-line function decls
            % without ... still possible? unlikely; safe regex anyway).
            sigLine = strtrim(lines(idx).Code);

            % First attempt: signature with parentheses for inputs.
            tok = regexp(sigLine, ...
                '^function\s+(\[?[^=]+?\]?\s*=\s*)?([A-Za-z]\w*)\s*\(([^)]*)\)', ...
                'tokens', 'once');
            if isempty(tok)
                % Fallback: no input parentheses (e.g. "function foo").
                tok = regexp(sigLine, ...
                    '^function\s+(\[?[^=]+?\]?\s*=\s*)?([A-Za-z]\w*)\s*$', ...
                    'tokens', 'once');
                if isempty(tok)
                    helpStartIdx = idx + 1;
                    bodyStartIdx = idx + 1;
                    bodyEndIdx = obj.findMatchingEnd(lines, idx+1);
                    return;
                end
                tok{3} = '';
            end
            outRaw = strtrim(tok{1});
            outRaw = regexprep(outRaw, '\s*=\s*$', '');
            fcn.Name = strtrim(tok{2});
            inRaw = strtrim(tok{3});

            fcn.Outputs = autotest.MFileParser.splitArgs(outRaw);
            fcn.Inputs  = autotest.MFileParser.splitArgs(inRaw);
            fcn.HasVarargin  = any(strcmp(fcn.Inputs, 'varargin'));
            fcn.HasVarargout = any(strcmp(fcn.Outputs, 'varargout'));

            helpStartIdx = idx + 1;
            bodyStartIdx = idx + 1;
            bodyEndIdx = obj.findMatchingEnd(lines, idx + 1);
        end

        function endIdx = findMatchingEnd(~, lines, startIdx)
            % Walk from startIdx until a matching `end` is found at depth 0.
            % Treats block keywords as depth increments.  This is heuristic;
            % MATLAB allows omitting `end` at script function ends.
            n = numel(lines);
            depth = 1;
            for i = startIdx:n
                t = strtrim(lines(i).Code);
                if isempty(t), continue; end
                if startsWith(t, 'function') || startsWith(t, 'if') ...
                        || startsWith(t, 'for') || startsWith(t, 'while') ...
                        || startsWith(t, 'switch') || startsWith(t, 'try') ...
                        || startsWith(t, 'parfor') || startsWith(t, 'classdef') ...
                        || startsWith(t, 'properties') || startsWith(t, 'methods') ...
                        || startsWith(t, 'events') || startsWith(t, 'enumeration') ...
                        || startsWith(t, 'arguments') || startsWith(t, 'spmd')
                    depth = depth + 1;
                elseif strcmp(t, 'end') || startsWith(t, 'end ') ...
                        || startsWith(t, 'end;') || startsWith(t, 'end,')
                    depth = depth - 1;
                    if depth == 0
                        endIdx = i;
                        return;
                    end
                end
            end
            endIdx = n;
        end

        function help = collectHelpText(~, lines, startIdx)
            % Help text is the contiguous %... block immediately following
            % the function declaration (allow blank-line termination).
            n = numel(lines);
            buf = strings(0,1);
            for i = startIdx:n
                if lines(i).IsComment
                    raw = strtrim(lines(i).HelpText);
                    if startsWith(raw, '%')
                        raw = regexprep(raw, '^%+\s?', '');
                    end
                    buf(end+1,1) = string(raw); %#ok<AGROW>
                elseif isempty(strtrim(lines(i).Code))
                    if isempty(buf), continue; end
                    break;
                else
                    break;
                end
            end
            if isempty(buf)
                help = '';
            else
                help = char(strjoin(buf, newline));
            end
        end

        function blocks = parseArgumentBlocks(obj, lines, bodyStart, bodyEnd)
            % Find leading `arguments` block(s) inside a function body and
            % capture each line as raw text.  Used for richer input typing.
            blocks = {};
            i = bodyStart;
            while i <= bodyEnd
                t = strtrim(lines(i).Code);
                if isempty(t) || lines(i).IsComment
                    i = i + 1; continue;
                end
                if startsWith(t, 'arguments')
                    blockEnd = obj.findMatchingEnd(lines, i+1);
                    rows = strings(0,1);
                    for k = (i+1):(blockEnd-1)
                        c = strtrim(lines(k).Code);
                        if ~isempty(c)
                            rows(end+1,1) = string(c); %#ok<AGROW>
                        end
                    end
                    blocks{end+1} = cellstr(rows); %#ok<AGROW>
                    i = blockEnd + 1;
                else
                    break;  % arguments blocks must precede other code
                end
            end
        end

        function detectStateful(obj, lines, model)
            % Set model.IsStateful = true when the constructor body leaves
            % one or more container-typed properties (dictionary,
            % containers.Map, struct, cell) empty.  Builds a human-readable
            % StatefulReason listing the property names involved so the
            % TestWriter can splice it into the assumeFail message.
            % NOTE: This is called from parseClassdef BEFORE model.Kind is
            % set to 'classdef' (parse() sets it on return), so don't
            % gate on Kind here -- having a ClassName + Properties is the
            % real classdef indicator at this point.
            if isempty(model.ClassName) || isempty(model.Properties)
                return;
            end
            [ctorLineIdx, ctorOutName] = obj.findConstructorLine( ...
                lines, model.ClassName);
            if ctorLineIdx == 0 || isempty(ctorOutName)
                return;
            end
            bodyEndIdx = obj.findMatchingEnd(lines, ctorLineIdx + 1);

            propNames = {model.Properties.Name};
            leftEmpty = {};
            assignRe = ['^\s*' regexptranslate('escape', ctorOutName) ...
                '\.([A-Za-z]\w*)\s*=\s*(.+)$'];

            for i = (ctorLineIdx+1):(bodyEndIdx-1)
                t = strtrim(lines(i).Code);
                if isempty(t), continue; end
                % Strip trailing semicolon (and any whitespace after it).
                t = regexprep(t, ';\s*$', '');
                tok = regexp(t, assignRe, 'tokens', 'once');
                if isempty(tok), continue; end
                propName = tok{1};
                rhs = strtrim(tok{2});
                if ~ismember(propName, propNames), continue; end
                if ~autotest.MFileParser.isContainerEmpty(rhs), continue; end
                if ismember(propName, leftEmpty), continue; end
                % Phase 3 (Option 1 fallout): in addition to typed
                % container properties (Phase 2.4's strict criterion),
                % flag UNTYPED properties when the ctor RHS is a specific
                % named-container constructor (dictionary[*], containers.Map[*],
                % struct[*]).  This catches TableMetadata.Tables / .Data /
                % .Relationships -- properties declared `Tables` (no
                % type) and assigned `obj.Tables = dictionary;` in the
                % ctor, then read by every other method.  Raw `{}` / `[]`
                % RHS values are too generic to stand alone so we still
                % require a declared cell/struct type for those.  The
                % typed branch is preserved unchanged so ExcelProcessor's
                % current 1-failure baseline doesn't shift.
                rhsNamed = autotest.MFileParser.isNamedContainerEmpty(rhs);
                for p = 1:numel(model.Properties)
                    if ~strcmp(model.Properties(p).Name, propName), continue; end
                    def = strtrim(char(model.Properties(p).Default));
                    if ~isempty(def), break; end  % has default -> skip
                    declaredType = lower(strtrim(char(model.Properties(p).Type)));
                    declaredType = regexprep(declaredType, '^\([^)]*\)\s*', '');
                    declaredType = strtrim(declaredType);
                    typedMatch = any(strcmp(declaredType, ...
                        {'dictionary', 'containers.map', 'struct', 'cell'}));
                    untypedNamedMatch = isempty(declaredType) && rhsNamed;
                    if typedMatch || untypedNamedMatch
                        leftEmpty{end+1} = propName; %#ok<AGROW>
                    end
                    break;
                end
            end

            % Phase 6 (Option 1): also detect fopen()-style state-init.
            % The class manages a FileID lifecycle when:
            %   1. ctor body assigns `obj.X = fopen(...)`
            %   2. property X is declared (typed `double` or untyped)
            %      with no default value
            %   3. class is a handle (has `delete(obj)` destructor)
            %   4. some method body calls `fclose(<x>.X)` for at least
            %      one such property -- the fopen->fclose lifecycle
            %      signature.
            % This is the ReportWriter / TextRedactor pattern.  Without
            % the destructor + fclose check the property might just be
            % a transient handle, not a managed lifecycle.
            fopenProps = autotest.MFileParser.findFopenAssignmentsInCtor( ...
                lines, ctorLineIdx, ctorOutName, bodyEndIdx);
            fopenLifecycle = {};
            for fp = 1:numel(fopenProps)
                propName = fopenProps{fp};
                if ~ismember(propName, propNames), continue; end
                if ismember(propName, leftEmpty), continue; end
                for p = 1:numel(model.Properties)
                    if ~strcmp(model.Properties(p).Name, propName), continue; end
                    def = strtrim(char(model.Properties(p).Default));
                    if ~isempty(def), break; end
                    declaredType = lower(strtrim(char(model.Properties(p).Type)));
                    declaredType = regexprep(declaredType, '^\([^)]*\)\s*', '');
                    declaredType = strtrim(declaredType);
                    typedDouble  = strcmp(declaredType, 'double');
                    untypedAny   = isempty(declaredType);
                    if typedDouble || untypedAny
                        fopenLifecycle{end+1} = propName; %#ok<AGROW>
                    end
                    break;
                end
            end
            if ~isempty(fopenLifecycle)
                hf = autotest.MFileParser.hasFcloseInDestructor(lines, model.ClassName, fopenLifecycle);
                if hf
                    leftEmpty = [leftEmpty, fopenLifecycle];
                else
                    fopenLifecycle = {};
                end
            else
                fopenLifecycle = {};
            end

            if ~isempty(leftEmpty)
                model.IsStateful = true;
                if ~isempty(fopenLifecycle) && ~isequal(leftEmpty, fopenLifecycle)
                    % Mixed case: container-empty + fopen-lifecycle.
                    containerProps = setdiff(leftEmpty, fopenLifecycle, 'stable');
                    model.StatefulReason = sprintf( ...
                        ['stateful class -- ctor leaves %s empty; ' ...
                         'method requires populated state; ' ...
                         'ctor opens %s via fopen(); methods require live file handle'], ...
                        strjoin(containerProps, ', '), ...
                        strjoin(fopenLifecycle, ', '));
                elseif ~isempty(fopenLifecycle)
                    % Pure fopen-lifecycle case.
                    model.StatefulReason = sprintf( ...
                        ['stateful class -- ctor opens %s via fopen(); ' ...
                         'methods require live file handle'], ...
                        strjoin(fopenLifecycle, ', '));
                else
                    model.StatefulReason = sprintf( ...
                        ['stateful class -- ctor leaves %s empty; ' ...
                         'method requires populated state'], ...
                        strjoin(leftEmpty, ', '));
                end
            end
        end

        function [ctorLineIdx, ctorOutName] = findConstructorLine(~, lines, className)
            % Locate `function <out> = <ClassName>(...)` (or with bracketed
            % single output) anywhere in the file.  Returns the line index
            % and the captured output-variable name.
            ctorLineIdx = 0;
            ctorOutName = '';
            cls = regexptranslate('escape', className);
            re1 = ['^function\s+(\w+)\s*=\s*' cls '\s*\('];
            re2 = ['^function\s+\[\s*(\w+)\s*\]\s*=\s*' cls '\s*\('];
            for i = 1:numel(lines)
                t = strtrim(lines(i).Code);
                if isempty(t) || ~startsWith(t, 'function'), continue; end
                tok = regexp(t, re1, 'tokens', 'once');
                if isempty(tok)
                    tok = regexp(t, re2, 'tokens', 'once');
                end
                if ~isempty(tok)
                    ctorLineIdx = i;
                    ctorOutName = tok{1};
                    return;
                end
            end
        end
    end

    methods (Static, Access = private)
        function [code, commentText, isFullComment] = splitCodeComment(rawLine)
            % Walk the line tracking string state, return code prefix and
            % comment suffix.  MATLAB strings: 'literal' (transpose-aware,
            % heuristic) and "literal".  Block comment markers handled by
            % caller.
            n = length(rawLine);
            inSingle = false; inDouble = false;
            code = ''; commentText = ''; isFullComment = false;

            % Heuristic: a single-quote is a string opener if the previous
            % non-space token is an operator, comma, semicolon, paren, or
            % start-of-line; otherwise it's the transpose operator.
            prevSig = char(0);
            cutAt = -1;
            for k = 1:n
                ch = rawLine(k);
                if inDouble
                    if ch == '"', inDouble = false; end
                elseif inSingle
                    if ch == '''', inSingle = false; end
                else
                    if ch == '%'
                        cutAt = k;
                        break;
                    elseif ch == '"'
                        inDouble = true;
                    elseif ch == ''''
                        if isempty(prevSig) || any(prevSig == ['([{,;= +-*/^<>~&|:' char([0])])
                            inSingle = true;
                        end
                    end
                end
                if ~isspace(ch)
                    prevSig = ch;
                end
            end
            if cutAt < 0
                code = rawLine;
                return;
            end
            code = rawLine(1:cutAt-1);
            commentText = rawLine(cutAt:end);
            if isempty(strtrim(code))
                isFullComment = true;
            end
        end

        function args = splitArgs(raw)
            raw = strtrim(raw);
            if isempty(raw)
                args = {};
                return;
            end
            % Strip optional brackets around outputs.
            raw = regexprep(raw, '^\[(.*)\]$', '$1');
            parts = strsplit(raw, ',');
            args = strtrim(parts);
            args(cellfun(@isempty, args)) = [];
        end

        function attrs = parseBlockAttributes(line, kw)
            attrs = struct();
            tok = regexp(line, ['^' kw '\s*\(([^)]*)\)'], 'tokens', 'once');
            if isempty(tok), return; end
            entries = strsplit(tok{1}, ',');
            for k = 1:numel(entries)
                e = strtrim(entries{k});
                kv = regexp(e, '^(\w+)\s*=\s*([\w.{}'']+)$', 'tokens', 'once');
                if isempty(kv)
                    if ~isempty(e)
                        attrs.(e) = true;
                    end
                else
                    val = strrep(strrep(strtrim(kv{2}), '''', ''), '"', '');
                    attrs.(kv{1}) = val;
                end
            end
        end

        function p = parsePropertyLine(t)
            p = autotest.SourceModel.makeProp('');
            % Strip trailing semicolons.
            t = regexprep(t, ';\s*$', '');
            % Split off default value at first '='.
            eqIdx = autotest.MFileParser.findTopLevelEq(t);
            defaultVal = '';
            if eqIdx > 0
                defaultVal = strtrim(t(eqIdx+1:end));
                t = strtrim(t(1:eqIdx-1));
            end
            % Now t is "Name (sz) Type"
            tok = regexp(t, '^([A-Za-z]\w*)\s*(\([^)]*\))?\s*(.*)$', 'tokens', 'once');
            if isempty(tok), return; end
            p.Name = tok{1};
            p.Type = strtrim([tok{2} ' ' tok{3}]);
            p.Default = defaultVal;
        end

        function idx = findTopLevelEq(t)
            depth = 0; inSingle = false; inDouble = false;
            idx = 0; prevSig = char(0);
            for k = 1:length(t)
                ch = t(k);
                if inDouble
                    if ch == '"', inDouble = false; end
                elseif inSingle
                    if ch == '''', inSingle = false; end
                else
                    switch ch
                        case '"', inDouble = true;
                        case ''''
                            if isempty(prevSig) || any(prevSig == ['([{,;= +-*/^<>~&|:' char([0])])
                                inSingle = true;
                            end
                        case {'(','[','{'}, depth = depth + 1;
                        case {')',']','}'}, depth = depth - 1;
                        case '='
                            if depth == 0 && k < length(t) && t(k+1) ~= '='
                                if k > 1 && any(t(k-1) == '<>~=')
                                    % comparison: skip
                                else
                                    idx = k; return;
                                end
                            end
                    end
                end
                if ~isspace(ch), prevSig = ch; end
            end
        end

        function ex = extractExamples(helpText)
            ex = {};
            if isempty(helpText), return; end
            lines = strsplit(helpText, newline, 'CollapseDelimiters', false);
            i = 1;
            while i <= numel(lines)
                ln = strtrim(lines{i});
                if ~isempty(regexpi(ln, '^example[s]?\s*[:.]?\s*$', 'once')) ...
                        || ~isempty(regexpi(ln, '^example[s]?\s*:\s*(.*)$', 'once'))
                    [block, j] = autotest.MFileParser.collectExampleBlock(lines, i+1);
                    if ~isempty(block)
                        ex{end+1} = block; %#ok<AGROW>
                    end
                    i = j;
                else
                    i = i + 1;
                end
            end
        end

        function [block, nextIdx] = collectExampleBlock(lines, startIdx)
            buf = strings(0,1);
            i = startIdx;
            while i <= numel(lines)
                ln = lines{i};
                trimmed = strtrim(ln);
                if isempty(trimmed)
                    % Blank line after content terminates the block; a
                    % blank line before any content is just leading
                    % whitespace and should be skipped.
                    if ~isempty(buf), break; end
                    i = i + 1;
                    continue;
                end
                % A new help section header (See also:, Example:) ends the
                % block as well.
                if ~isempty(regexpi(trimmed, '^see also[:.]', 'once')) ...
                        || ~isempty(regexpi(trimmed, '^example[s]?\s*[:.]?\s*$', 'once'))
                    break;
                end
                buf(end+1,1) = string(trimmed); %#ok<AGROW>
                i = i + 1;
            end
            if isempty(buf)
                block = '';
            else
                block = char(strjoin(buf, newline));
            end
            nextIdx = i;
        end

        function tf = isNamedContainerEmpty(rhs)
            % Returns true when RHS is an explicit named-container
            % constructor (dictionary*, containers.Map*, struct*).
            % Used to extend Phase 2.4's stateful detection to UNTYPED
            % properties whose ctor RHS clearly identifies the intended
            % container kind.  Excludes raw `{}` and `[]` because those
            % are too generic to stand alone (they could be any list,
            % numeric matrix, etc.).
            rhs = strtrim(rhs);
            rhs = regexprep(rhs, ';\s*$', '');
            rhs = strtrim(rhs);
            tf = false;
            if isempty(rhs), return; end
            patterns = { ...
                '^dictionary\s*$', ...
                '^dictionary\s*\(\s*\)\s*$', ...
                '^dictionary\s*\(\s*"[^"]+"\s*,.*\)\s*$', ...
                '^containers\.Map\s*$', ...
                '^containers\.Map\s*\(\s*\)\s*$', ...
                '^struct\s*$', ...
                '^struct\s*\(\s*\)\s*$' };
            for k = 1:numel(patterns)
                if ~isempty(regexp(rhs, patterns{k}, 'once'))
                    tf = true;
                    return;
                end
            end
        end

        function tf = isContainerEmpty(rhs)
            % Returns true when RHS is one of the canonical "empty
            % container" forms.  Used by detectStateful to decide whether
            % a ctor assignment leaves a property in an empty state that
            % subsequent methods will need to populate.
            rhs = strtrim(rhs);
            rhs = regexprep(rhs, ';\s*$', '');
            rhs = strtrim(rhs);
            if isempty(rhs)
                tf = true; return;
            end
            patterns = { ...
                '^dictionary\s*$', ...
                '^dictionary\s*\(\s*\)\s*$', ...
                '^dictionary\s*\(\s*"[^"]+"\s*,.*\)\s*$', ...
                '^containers\.Map\s*$', ...
                '^containers\.Map\s*\(\s*\)\s*$', ...
                '^struct\s*$', ...
                '^struct\s*\(\s*\)\s*$', ...
                '^\{\s*\}\s*$', ...
                '^\[\s*\]\s*$' };
            tf = false;
            for k = 1:numel(patterns)
                if ~isempty(regexp(rhs, patterns{k}, 'once'))
                    tf = true;
                    return;
                end
            end
        end

        function props = findFopenAssignmentsInCtor(lines, ctorLineIdx, ctorOutName, bodyEndIdx)
            % Phase 6 (Option 1) helper.  Scan the constructor body for
            % `<ctorOutName>.X = fopen(...)` assignments and return the
            % set of property names X that appear on the LHS.  Sibling
            % to the assignment-walker in detectStateful; uses the same
            % LHS-shape regex but a separate fopen() RHS check.
            props = {};
            if ctorLineIdx == 0 || isempty(ctorOutName), return; end
            assignRe = ['^\s*' regexptranslate('escape', ctorOutName) ...
                '\.([A-Za-z]\w*)\s*=\s*(.+)$'];
            for i = (ctorLineIdx+1):(bodyEndIdx-1)
                t = strtrim(lines(i).Code);
                if isempty(t), continue; end
                t = regexprep(t, ';\s*$', '');
                tok = regexp(t, assignRe, 'tokens', 'once');
                if isempty(tok), continue; end
                rhs = strtrim(tok{2});
                if isempty(regexp(rhs, '^fopen\s*\(', 'once')), continue; end
                propName = tok{1};
                if ~ismember(propName, props)
                    props{end+1} = propName; %#ok<AGROW>
                end
            end
        end

        function tf = hasFcloseInDestructor(lines, className, propNames)
            % Phase 6 (Option 1) helper.  Returns true when:
            %   1. The class defines a `function delete(<obj>)` destructor.
            %   2. Some method in the class body calls `fclose(...)` on a
            %      property in propNames.
            % The second check is intentionally lenient: a delete() that
            % calls obj.close() which calls fclose(obj.FileID) is the
            % ReportWriter pattern, and walking the method-call graph from
            % delete() down through every helper would be brittle.  Requires
            % (a) a destructor exists AND (b) some line contains BOTH
            % "fclose(" AND ".<propName>".  This is a heuristic but matches
            % the intent: a stateful FileID lifecycle.  Uses substring
            % search rather than regex because MATLAB's regex engine has
            % quirks with backslash-dot patterns built via line continuation.
            tf = false;
            if isempty(className) || isempty(propNames), return; end
            hasDelete = false;
            for i = 1:numel(lines)
                t = strtrim(lines(i).Code);
                if isempty(t), continue; end
                if startsWith(t, 'function delete(') ...
                        || ~isempty(regexp(t, '^function\s+delete\s*\(', 'once'))
                    hasDelete = true;
                    break;
                end
            end
            if ~hasDelete, return; end
            for p = 1:numel(propNames)
                needle = ['.' propNames{p}];
                for i = 1:numel(lines)
                    t = lines(i).Code;
                    if isempty(t), continue; end
                    if contains(t, 'fclose(') && contains(t, needle)
                        tf = true;
                        return;
                    end
                end
            end
        end
    end
end
