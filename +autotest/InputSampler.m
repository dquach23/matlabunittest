classdef InputSampler
    %INPUTSAMPLER  Builds literal MATLAB expressions for use as test inputs.

    methods (Static)
        function cases = smartFor(inputs, argBlocks, helpText, provider)
            cases = autotest.InputSampler.emptyCase();
            if nargin < 4 || isempty(provider) || ~isa(provider, 'autotest.FixtureProvider')
                return;
            end
            if isempty(inputs)
                return;
            end
            typed = autotest.InputSampler.typesFromArguments(inputs, argBlocks);
            args = cell(1, numel(inputs));
            for k = 1:numel(inputs)
                if strcmp(inputs{k}, 'varargin')
                    args = args(1:k-1);
                    break;
                end
                expr = provider.literalForArg(inputs{k}, typed{k}, helpText);
                if isempty(expr)
                    return;
                end
                args{k} = expr;
            end
            c = autotest.InputSampler.makeCase('realistic', ...
                autotest.InputSampler.argsToCallStr(args), 'smoke');
            c.Args = args;
            cases(end+1) = c;
        end

        function cases = smokeFor(inputs, argBlocks)
            cases = autotest.InputSampler.emptyCase();
            if isempty(inputs)
                cases(1) = autotest.InputSampler.makeCase('default','','smoke');
                cases(1).Args = {};
                return;
            end
            typed = autotest.InputSampler.typesFromArguments(inputs, argBlocks);
            for k = 1:numel(inputs)
                if strcmp(inputs{k}, 'varargin'), break; end
                if autotest.InputSampler.isOpaqueType(typed{k}, inputs{k})
                    return;
                end
            end
            % Phase 7 (Option 4): when ANY input was name-overridden to
            % `string` (resolved Type='string' AND IsExplicit=false),
            % only emit the scalar smoke.  Vector/matrix smokes for
            % string args reliably crash project code that pipes a
            % stringy arg straight into regexp/fprintf/sprintf -- real
            % signal but not actionable from the autogen side.  An
            % explicitly typed `arguments`-block string still gets the
            % full ladder; the author has declared the contract.  See
            % PHASE7_HANDOFF.md for the alternative (parse-method-body)
            % approach if this conservative form causes regressions.
            stringyImplicit = false;
            for k = 1:numel(inputs)
                if strcmp(inputs{k}, 'varargin'), break; end
                info = typed{k};
                isExplicit = isfield(info, 'IsExplicit') && info.IsExplicit;
                if ~isExplicit && strcmpi(strtrim(char(info.Type)), 'string')
                    stringyImplicit = true;
                    break;
                end
            end
            % Phase 10: when ANY input is a fileID-named arg, force the
            % scalar smoke ONLY -- a "vector of fileIDs" is meaningless
            % and the fileID-aware override below will swap that arg
            % for a real fopen-backed handle anyway.  Generic across
            % projects: the detection is purely name-based.
            hasFileID = false;
            for k = 1:numel(inputs)
                if strcmp(inputs{k}, 'varargin'), break; end
                if autotest.InputSampler.isFileIDName(inputs{k})
                    hasFileID = true;
                    break;
                end
            end
            if stringyImplicit || hasFileID
                sets = { ...
                    {'scalar',   @(t) autotest.InputSampler.scalarFor(t)}, ...
                    };
            else
                sets = { ...
                    {'scalar',   @(t) autotest.InputSampler.scalarFor(t)}, ...
                    {'vector',   @(t) autotest.InputSampler.vectorFor(t)}, ...
                    {'matrix',   @(t) autotest.InputSampler.matrixFor(t)}, ...
                    };
            end
            for s = 1:numel(sets)
                label = sets{s}{1};
                builder = sets{s}{2};
                args = cell(1, numel(inputs));
                ok = true;
                for k = 1:numel(inputs)
                    if strcmp(inputs{k}, 'varargin')
                        args{k} = '';
                        args = args(1:k-1);
                        break;
                    end
                    args{k} = builder(typed{k});
                    % Phase 10: per-arg fileID override.  After the
                    % shape-based builder runs, if this arg is fileID-
                    % named, swap in a real fopen-backed handle expr.
                    if autotest.InputSampler.isFileIDName(inputs{k})
                        args{k} = autotest.InputSampler.fileIDExpr();
                    end
                    if isempty(args{k}), ok = false; break; end
                end
                if ok
                    c = autotest.InputSampler.makeCase(label, ...
                        autotest.InputSampler.argsToCallStr(args), 'smoke');
                    c.Args = args;
                    cases(end+1) = c; %#ok<AGROW>
                end
            end
        end

        function cases = edgeFor(inputs, argBlocks)
            % Edge tests catch exceptions and pass either way; opaque
            % args don't break edges, just smokes.  Keep edge coverage.
            cases = autotest.InputSampler.emptyCase();
            if isempty(inputs), return; end
            typed = autotest.InputSampler.typesFromArguments(inputs, argBlocks);
            nominal = cellfun(@autotest.InputSampler.scalarFor, typed, ...
                'UniformOutput', false);
            % Phase 10: substitute real fopen-backed handle for any
            % fileID-named nominal arg so the OTHER arg's edge variants
            % aren't shooting at fprintf with a dummy numeric.
            for k = 1:numel(inputs)
                if strcmp(inputs{k}, 'varargin'), break; end
                if autotest.InputSampler.isFileIDName(inputs{k})
                    nominal{k} = autotest.InputSampler.fileIDExpr();
                end
            end
            for k = 1:numel(inputs)
                if strcmp(inputs{k}, 'varargin'), break; end
                % Phase 10: skip emitting edge variants for fileID args.
                % Empty/NaN/Inf "fileIDs" are meaningless -- they always
                % crash fprintf and add noise to the report.
                if autotest.InputSampler.isFileIDName(inputs{k})
                    continue;
                end
                edges = autotest.InputSampler.edgesFor(typed{k});
                for e = 1:numel(edges)
                    args = nominal;
                    args{k} = edges(e).Expr;
                    label = sprintf('%s_%s', inputs{k}, edges(e).Label);
                    c = autotest.InputSampler.makeCase(label, ...
                        autotest.InputSampler.argsToCallStr(args), 'edge');
                    c.Args = args;
                    cases(end+1) = c; %#ok<AGROW>
                end
            end
        end

        function tf = isFileIDName(argName)
            %ISFILEIDNAME  True if argName looks like a file-handle param.
            %   Phase 10: name-based detection so functions taking a
            %   fid/fileID arg get a real fopen-backed handle in their
            %   smoke/edge/randomized tests rather than a numeric
            %   rand() sample (which throws inside fprintf etc.).
            %   Generic across projects: pure name match, no
            %   project-specific knowledge required.
            tf = false;
            if isempty(argName), return; end
            lname = lower(strtrim(char(argName)));
            exact = {'fid', 'fileid', 'filehandle', 'fhandle', ...
                     'outputfid', 'inputfid', 'logfid'};
            if any(strcmp(lname, exact))
                tf = true; return;
            end
            % Suffix match catches casing variants in the parser
            % (it lowercases the name) and patterns like `outFileID`.
            if endsWith(lname, 'fileid') || endsWith(lname, 'filehandle')
                tf = true; return;
            end
        end

        function expr = fileIDExpr()
            %FILEIDEXPR  Canonical expression for a fileID smoke arg.
            %   Returns a call to tempFileID(testCase) which is a real
            %   fopen-backed FID with auto-close + auto-delete via
            %   addTeardown.  testCase is always in scope inside any
            %   matlab.unittest.TestCase method (Phase 10).
            expr = 'autotest.InputSampler.tempFileID(testCase)';
        end

        function fid = tempFileID(testCase)
            %TEMPFILEID  Open a temp file and return its FID; auto-cleans.
            %   Used by Phase 10 fileID-aware input synthesis.  The
            %   teardown closes the FID and deletes the temp file when
            %   the test method finishes (pass or fail).
            tmpPath = [tempname() '.txt'];
            fid = fopen(tmpPath, 'w+');
            if fid < 3
                error('autotest:tempFileID:fopen', ...
                    'tempFileID could not open %s for writing', tmpPath);
            end
            testCase.addTeardown(@() autotest.InputSampler.cleanupFid(fid, tmpPath));
        end

        function cleanupFid(fid, tmpPath)
            %CLEANUPFID  Close FID and delete the backing file (best effort).
            try
                if ~isempty(fid) && isnumeric(fid) && fid >= 3
                    fclose(fid);
                end
            catch
            end
            try
                if ~isempty(tmpPath) && exist(tmpPath, 'file')
                    delete(tmpPath);
                end
            catch
            end
        end

        function tf = isOpaqueType(t, argName)
            if nargin < 2, argName = ''; end
            tf = false;
            if isstruct(t) && isfield(t, 'Type')
                ty = strtrim(char(t.Type));
            else
                ty = strtrim(char(t));
            end
            tyLow = lower(ty);
            opaqueExact = { ...
                'containers.map', 'dictionary', ...
                'matlab.io.matfile', 'matlab.io.xml.dom.document', ...
                'matlab.io.xml.dom.node', 'matlab.io.xml.dom.element', ...
                'org.w3c.dom.node', 'org.w3c.dom.document', ...
                'org.w3c.dom.element', 'org.w3c.dom.nodelist', ...
                'org.apache.xerces.dom.documentimpl'};
            if ~isempty(tyLow) && any(strcmp(tyLow, opaqueExact))
                tf = true; return;
            end
            opaquePrefix = { ...
                'org.w3c.dom.', 'matlab.io.xml.', 'org.apache.', ...
                'java.', 'matlab.ui.'};
            for k = 1:numel(opaquePrefix)
                if ~isempty(tyLow) && startsWith(tyLow, opaquePrefix{k})
                    tf = true; return;
                end
            end
            % Name-based fallback for default-double / no-info args.
            unknownType = isempty(tyLow) || strcmp(tyLow, 'double');
            if ~unknownType, return; end
            if isempty(argName), return; end
            lname = lower(argName);
            % Phase 3 (Option 1): widened endsWith list to cover Excel /
            % XML DOM / App Designer noun families.  Order matters only
            % for readability -- endsWith is independent per entry.
            opaqueNameSuffix = { ...
                'dom', 'doms', 'node', 'element', 'xmldoc', ...
                'sheet', 'sheets', 'worksheet', 'workbook', 'doc'};
            for k = 1:numel(opaqueNameSuffix)
                if endsWith(lname, opaqueNameSuffix{k})
                    tf = true; return;
                end
            end
            opaqueNameContains = {'sharedstrings', 'cellsbyrow', ...
                'colwidths', 'lookupmap', 'rid_to_target', 'rid2target', ...
                'lookupmaps', 'tablemetadata'};
            for k = 1:numel(opaqueNameContains)
                if contains(lname, opaqueNameContains{k})
                    tf = true; return;
                end
            end
            % Phase 3 (Option 1): plural-container shaped argument names.
            % Match only when the declared type is empty/double (already
            % gated above by `unknownType`); a typed `Tables (1,1) string`
            % wouldn't reach this branch.  These are the names that show
            % up in TableMetadata / ExcelXmlCleaner / ExcelRemover where
            % the underlying value is a dictionary / containers.Map / DOM
            % bag, but the source declared no type.
            opaqueNameExact = { ...
                'tables', 'data', 'relationships', ...
                'ridmap', 'sheetmap', 'cache', ...
                'lookup', 'map', 'maps'};
            for k = 1:numel(opaqueNameExact)
                if strcmp(lname, opaqueNameExact{k})
                    tf = true; return;
                end
            end
        end

        function expr = argsToCallStr(args)
            if isempty(args)
                expr = '';
            else
                expr = strjoin(args, ', ');
            end
        end

        function s = makeCase(label, callExpr, kind)
            s = struct('Label', label, 'Expr', callExpr, 'Kind', kind, 'Args', {{}});
        end

        function s = emptyCase()
            s = struct('Label', {}, 'Expr', {}, 'Kind', {}, 'Args', {});
        end
    end

    methods (Static)
        function typed = typesFromArguments(inputs, argBlocks)
            % Phase 6 (Option 3): track per-arg IsExplicit -- true when an
            % `arguments` block row matched, false when the default
            % (Type='double') was never overridden.  Used by the name-driven
            % string override below so callers who explicitly typed an arg
            % as `double` aren't silently re-typed as string.
            typed = repmat({struct('Type','double','SizeHint','any', ...
                'Validators',{{}}, 'IsExplicit', false)}, 1, numel(inputs));
            if ~isempty(argBlocks)
                for b = 1:numel(argBlocks)
                    rows = argBlocks{b};
                    for r = 1:numel(rows)
                        row = rows{r};
                        tok = regexp(row, ...
                            '^([A-Za-z]\w*)(?:\.[A-Za-z]\w*)?\s*(\([^)]*\))?\s*([A-Za-z][\w.]*)?\s*(\{[^}]*\})?', ...
                            'tokens', 'once');
                        if isempty(tok), continue; end
                        nm = tok{1};
                        sz = tok{2};
                        ty = tok{3};
                        vl = tok{4};
                        idx = find(strcmp(inputs, nm), 1);
                        if isempty(idx), continue; end
                        info = typed{idx};
                        info.IsExplicit = true;
                        if ~isempty(ty), info.Type = ty; end
                        if ~isempty(sz)
                            if ~isempty(regexp(sz, '\(\s*1\s*,\s*1\s*\)', 'once'))
                                info.SizeHint = 'scalar';
                            elseif ~isempty(regexp(sz, '\(\s*1\s*,\s*:\s*\)', 'once')) ...
                                    || ~isempty(regexp(sz, '\(\s*:\s*,\s*1\s*\)', 'once'))
                                info.SizeHint = 'vector';
                            else
                                info.SizeHint = 'matrix';
                            end
                        end
                        if ~isempty(vl)
                            info.Validators = strsplit(strtrim(vl(2:end-1)), ',');
                        end
                        typed{idx} = info;
                    end
                end
            end
            % Phase 6 (Option 3): name-driven string override.  When the
            % resolved type is empty/double AND the source NEVER explicitly
            % typed this arg in an `arguments` block, AND the arg name
            % strongly suggests a string (text/pattern/format/name/message/
            % msg/str/string/title/caption/header/label/word/originalText),
            % override Type='string'.  Stops edgeFor / randomArgsExpr from
            % feeding [] / NaN / rand() into a regexp / fprintf chain.
            % The set of stringy names mirrors FixtureProvider.literalForArg.
            stringyNames = { ...
                'text', 'originaltext', 'pattern', 'format', 'name', ...
                'message', 'msg', 'str', 'string', 'title', ...
                'caption', 'header', 'label', 'word'};
            for k = 1:numel(inputs)
                info = typed{k};
                if isfield(info, 'IsExplicit') && info.IsExplicit
                    continue;
                end
                lname = lower(strtrim(inputs{k}));
                if isempty(lname) || strcmp(lname, 'varargin'), continue; end
                tyLow = lower(strtrim(char(info.Type)));
                unknownType = isempty(tyLow) || strcmp(tyLow, 'double');
                if ~unknownType, continue; end
                if any(strcmp(lname, stringyNames))
                    info.Type = 'string';
                    typed{k} = info;
                end
            end
        end

        function expr = scalarFor(t)
            switch lower(t.Type)
                case {'double','single','numeric'}
                    expr = '1';
                case {'int8','int16','int32','int64'}
                    expr = sprintf('%s(1)', t.Type);
                case {'uint8','uint16','uint32','uint64'}
                    expr = sprintf('%s(1)', t.Type);
                case 'logical'
                    expr = 'true';
                case {'char'}
                    expr = '''a''';
                case {'string'}
                    expr = '"a"';
                case {'cell'}
                    expr = '{1}';
                case {'struct'}
                    expr = 'struct(''f'',1)';
                case {'datetime'}
                    expr = 'datetime(2024,1,1)';
                case {'duration'}
                    expr = 'seconds(1)';
                case {'categorical'}
                    expr = 'categorical("a")';
                case {'function_handle'}
                    expr = '@(x) x';
                otherwise
                    expr = '1';
            end
        end

        function expr = vectorFor(t)
            if isfield(t, 'SizeHint') && strcmp(t.SizeHint, 'scalar')
                expr = autotest.InputSampler.scalarFor(t);
                return;
            end
            base = autotest.InputSampler.scalarFor(t);
            switch lower(t.Type)
                case {'double','single','numeric'}
                    expr = '[1 2 3 4]';
                case {'int8','int16','int32','int64','uint8','uint16','uint32','uint64'}
                    expr = sprintf('%s([1 2 3 4])', t.Type);
                case 'logical'
                    expr = '[true false true false]';
                case 'char'
                    expr = '''abcd''';
                case 'string'
                    expr = '["a" "b" "c"]';
                case 'cell'
                    expr = '{1, 2, 3}';
                case 'datetime'
                    expr = 'datetime(2024,1,1) + days(0:3)';
                otherwise
                    expr = base;
            end
        end

        function expr = matrixFor(t)
            if isfield(t, 'SizeHint') && strcmp(t.SizeHint, 'scalar')
                expr = autotest.InputSampler.scalarFor(t);
                return;
            end
            if isfield(t, 'SizeHint') && strcmp(t.SizeHint, 'vector')
                expr = autotest.InputSampler.vectorFor(t);
                return;
            end
            switch lower(t.Type)
                case {'double','single','numeric'}
                    expr = 'magic(3)';
                case {'int8','int16','int32','int64','uint8','uint16','uint32','uint64'}
                    expr = sprintf('%s(magic(3))', t.Type);
                case 'logical'
                    expr = 'true(2,2)';
                case 'string'
                    expr = '["a" "b"; "c" "d"]';
                case 'cell'
                    expr = '{1 2; 3 4}';
                otherwise
                    expr = autotest.InputSampler.vectorFor(t);
            end
        end

        function edges = edgesFor(t)
            edges = struct('Label', {}, 'Expr', {});
            switch lower(t.Type)
                case {'double','single','numeric'}
                    edges = autotest.InputSampler.appendEdge(edges, 'empty',    '[]');
                    edges = autotest.InputSampler.appendEdge(edges, 'zero',     '0');
                    edges = autotest.InputSampler.appendEdge(edges, 'neg',      '-1');
                    edges = autotest.InputSampler.appendEdge(edges, 'nan',      'NaN');
                    edges = autotest.InputSampler.appendEdge(edges, 'inf',      'Inf');
                    edges = autotest.InputSampler.appendEdge(edges, 'large',    '1e9');
                    edges = autotest.InputSampler.appendEdge(edges, 'small',    'eps');
                case {'int8','int16','int32','int64','uint8','uint16','uint32','uint64'}
                    edges = autotest.InputSampler.appendEdge(edges, 'empty', sprintf('%s([])', t.Type));
                    edges = autotest.InputSampler.appendEdge(edges, 'zero',  sprintf('%s(0)', t.Type));
                    edges = autotest.InputSampler.appendEdge(edges, 'max',   sprintf('intmax(''%s'')', t.Type));
                    edges = autotest.InputSampler.appendEdge(edges, 'min',   sprintf('intmin(''%s'')', t.Type));
                case 'logical'
                    edges = autotest.InputSampler.appendEdge(edges, 'true',  'true');
                    edges = autotest.InputSampler.appendEdge(edges, 'false', 'false');
                    edges = autotest.InputSampler.appendEdge(edges, 'empty', 'logical([])');
                case 'char'
                    edges = autotest.InputSampler.appendEdge(edges, 'empty', '''''');
                    edges = autotest.InputSampler.appendEdge(edges, 'unicode', '''cafe''');
                case 'string'
                    edges = autotest.InputSampler.appendEdge(edges, 'empty', '""');
                    edges = autotest.InputSampler.appendEdge(edges, 'missing', 'string(missing)');
                case 'cell'
                    edges = autotest.InputSampler.appendEdge(edges, 'empty', '{}');
                otherwise
                    edges = autotest.InputSampler.appendEdge(edges, 'empty', '[]');
            end
        end

        function edges = appendEdge(edges, label, expr)
            edges(end+1).Label = label; %#ok<AGROW>
            edges(end).Expr = expr;
        end
    end
end
