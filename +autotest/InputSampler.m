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

        function dirPath = tempUnzippedExcel(testCase, sourceXlsx)
            %TEMPUNZIPPEDEXCEL  Unzip an .xlsx into a tempdir; auto-cleans.
            %
            %   Phase 14 (candidate 1): backs the unzipped-Excel
            %   staging fixture.  When a class constructor takes an
            %   unzip / staging dir AND the project supplies a
            %   primary .xlsx, this helper provides a real populated
            %   directory at test time so downstream populator
            %   methods (loadAllDOMs / buildLookupMaps) actually
            %   populate the instance state instead of silently
            %   no-opping inside the prelude's try/catch.
            %
            %   Returns the path of the unzipped directory.  A
            %   teardown is registered to remove the temp dir when
            %   the test method ends.  If the source file is
            %   missing or unreadable, returns a bare tempname()
            %   (matches existing fallback behaviour) so the
            %   prelude's try/catch still short-circuits cleanly.
            if nargin < 2 || isempty(sourceXlsx) ...
                    || ~exist(sourceXlsx, 'file')
                dirPath = tempname();
                return;
            end
            dirPath = tempname();
            try
                unzip(sourceXlsx, dirPath);
            catch
                % Source isn't a real Zip-format file (or unreadable).
                % Make sure dirPath at least exists so callers do not
                % crash on isfolder() checks downstream.
                try
                    if ~isfolder(dirPath), mkdir(dirPath); end
                catch
                end
                return;
            end
            testCase.addTeardown(@() autotest.InputSampler.cleanupTempDir(dirPath));
        end

        function cleanupTempDir(dirPath)
            %CLEANUPTEMPDIR  Best-effort recursive removal of a tempdir.
            %   Phase 14 (candidate 1) teardown helper for tempUnzippedExcel.
            try
                if ~isempty(dirPath) && isfolder(dirPath)
                    rmdir(dirPath, 's');
                end
            catch
            end
        end

        function key = firstKeyOr(container, fallback)
            %FIRSTKEYOR  First key/index of a populated container, or FALLBACK.
            %
            %   Phase 15 (candidate 1): backs the live-state-aware smoke
            %   substitution.  When the prelude has populated a
            %   containers.Map / dictionary / struct / cell / table
            %   property, this returns a real key that exists in the live
            %   state, so smokes operate against actual data rather than a
            %   synthetic literal that the project's validation rejects.
            %
            %   When the container is empty or its shape is unrecognised,
            %   returns the FALLBACK literal verbatim (all-or-nothing
            %   safety: do NOT throw).  Generic across MATLAB projects:
            %   recognises only built-in container shapes.
            key = fallback;
            try
                if isa(container, 'containers.Map')
                    k = keys(container);
                    if ~isempty(k)
                        v = k{1};
                        if isstring(v), v = char(v); end
                        key = v;
                    end
                elseif isa(container, 'dictionary')
                    if numEntries(container) > 0
                        ks = keys(container);
                        if isstring(ks) && ~isempty(ks)
                            key = char(ks(1));
                        elseif iscell(ks) && ~isempty(ks)
                            v = ks{1};
                            if isstring(v), v = char(v); end
                            key = v;
                        elseif isnumeric(ks) && ~isempty(ks)
                            key = ks(1);
                        end
                    end
                elseif isstruct(container) && ~isempty(container)
                    f = fieldnames(container);
                    if ~isempty(f)
                        key = f{1};
                    end
                elseif iscell(container) && ~isempty(container)
                    v = container{1};
                    if ischar(v) || isstring(v)
                        key = char(v);
                    end
                elseif istable(container)
                    n = container.Properties.VariableNames;
                    if ~isempty(n)
                        key = n{1};
                    end
                end
            catch
                % Fall through to fallback.
            end
        end

        function val = firstValueOr(container, fallback)
            %FIRSTVALUEOR  First value of a populated container, or FALLBACK.
            %
            %   Phase 16 (candidate 2): backs the live-state-aware VALUE
            %   substitution.  Symmetric to firstKeyOr but returns the
            %   first VALUE entry of a populated containers.Map /
            %   dictionary / struct / cell / table, so smokes whose
            %   value-shaped arg matches a sibling container property
            %   operate against actual data rather than a synthetic
            %   literal that the project's validation rejects.
            %
            %   When the container is empty or its shape is unrecognised,
            %   returns the FALLBACK literal verbatim (all-or-nothing
            %   safety: do NOT throw).  Generic across MATLAB projects:
            %   recognises only built-in container shapes.
            val = fallback;
            try
                if isa(container, 'containers.Map')
                    if container.Count > 0
                        ks = keys(container);
                        val = container(ks{1});
                    end
                elseif isa(container, 'dictionary')
                    if numEntries(container) > 0
                        ks = keys(container);
                        if isstring(ks) && ~isempty(ks)
                            val = container(ks(1));
                        elseif iscell(ks) && ~isempty(ks)
                            val = container(ks{1});
                        elseif isnumeric(ks) && ~isempty(ks)
                            val = container(ks(1));
                        end
                    end
                elseif isstruct(container) && ~isempty(container)
                    f = fieldnames(container);
                    if ~isempty(f)
                        val = container.(f{1});
                    end
                elseif iscell(container) && ~isempty(container)
                    val = container{1};
                elseif istable(container) && height(container) > 0
                    val = container(1, :);
                end
            catch
                % Fall through to fallback.
            end
        end

        function tf = isDOMName(argName)
            %ISDOMNAME  True if argName looks like an XML DOM handle.
            %   Phase 12: name-based detection so functions taking a
            %   *DOM / *Document / dom arg get a real in-memory
            %   org.w3c.dom.Document in their smoke / edge / randomized
            %   tests rather than a numeric scalar (which Java rejects).
            %   Generic across projects: pure name match using the
            %   convention that DOM args are camelCased with a `DOM` /
            %   `Document` suffix.  Case-sensitive on the suffix to
            %   avoid false positives on lowercase identifiers like
            %   `random`, `freedom`, `wisdom`.
            tf = false;
            if isempty(argName), return; end
            a = strtrim(char(argName));
            % Exact match (lower-case or upper-case `dom`).
            if strcmp(a, 'dom') || strcmp(a, 'DOM') ...
                    || strcmp(a, 'doc') || strcmp(a, 'Doc') ...
                    || strcmp(a, 'document') || strcmp(a, 'Document') ...
                    || strcmp(a, 'xmlDoc') || strcmp(a, 'xmlDocument') ...
                    || strcmp(a, 'xmlNode')
                tf = true; return;
            end
            % Suffix match -- case-sensitive on the marker.
            if length(a) >= 4 && (endsWith(a, 'DOM') || endsWith(a, 'Document'))
                tf = true; return;
            end
        end

        function tf = isDOMType(t)
            %ISDOMTYPE  True if t is a typed DOM info struct/string.
            %   Recognises org.w3c.dom.* and matlab.io.xml.dom.* names.
            tf = false;
            if isempty(t), return; end
            if isstruct(t) && isfield(t, 'Type')
                ty = t.Type;
            else
                ty = t;
            end
            tyLow = lower(strtrim(char(ty)));
            if isempty(tyLow), return; end
            domExact = { ...
                'org.w3c.dom.document', 'org.w3c.dom.node', ...
                'org.w3c.dom.element', 'org.w3c.dom.nodelist', ...
                'org.apache.xerces.dom.documentimpl', ...
                'matlab.io.xml.dom.document', ...
                'matlab.io.xml.dom.node', 'matlab.io.xml.dom.element'};
            if any(strcmp(tyLow, domExact))
                tf = true; return;
            end
            domPrefix = {'org.w3c.dom.', 'matlab.io.xml.dom.'};
            for k = 1:numel(domPrefix)
                if startsWith(tyLow, domPrefix{k})
                    tf = true; return;
                end
            end
        end

        function expr = domExpr()
            %DOMEXPR  Canonical expression for a DOM smoke arg.
            %   Returns a call to tempDOM(testCase) which is a real
            %   in-memory org.w3c.dom.Document (one root element).
            %   testCase is always in scope inside any
            %   matlab.unittest.TestCase method (Phase 12).
            expr = 'autotest.InputSampler.tempDOM(testCase)';
        end

        function dom = tempDOM(testCase) %#ok<INUSD>
            %TEMPDOM  Build an empty in-memory DOM document.
            %   Phase 12: backs the DOM-aware input synthesis.
            %   The returned document has one `<root/>` element and
            %   is GC'd when the test method ends -- no teardown
            %   needed (in-memory only, no file handles or COM).
            %   testCase is accepted for signature parity with
            %   tempFileID and to leave room for future addTeardown.
            factory = javax.xml.parsers.DocumentBuilderFactory.newInstance();
            builder = factory.newDocumentBuilder();
            dom = builder.newDocument();
            root = dom.createElement('root');
            dom.appendChild(root);
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
                'Validators',{{}}, 'IsExplicit', false, ...
                'MustBeMember', {{}})}, 1, numel(inputs));
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
                            % Phase 16 cand-4: mustBeMember(arg, list) pull.
                            % The list is one of: string array literal
                            % ("a","b"), cellstr literal ('a','b'), or
                            % numeric array literal ([1 2 3]).  Symbol
                            % references (a const name) yield {} so the
                            % consumer falls through to the synthetic
                            % default.  Generic across MATLAB projects;
                            % no project-specific knowledge.
                            mbmList = autotest.InputSampler.parseMustBeMember(vl);
                            if ~isempty(mbmList)
                                info.MustBeMember = mbmList;
                            end
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

        function vals = parseMustBeMember(validatorsBraces)
            %PARSEMUSTBEMEMBER  Parse a mustBeMember validator's allowed list.
            %
            %   Phase 16 cand-4 helper.  Input is the raw `{...}` validator
            %   slot text (including braces) captured from an `arguments`
            %   block row.  Returns a cell array of bare allowed values
            %   (chars for string/cellstr literals, numerics for numeric
            %   arrays), OR an empty cell when:
            %     - no mustBeMember validator is present
            %     - the list is a symbol reference (a const name) that
            %       cannot be resolved at parse time
            %   Generic across MATLAB projects; no project-specific knowledge.
            vals = {};
            if isempty(validatorsBraces), return; end
            v = char(validatorsBraces);
            % Locate the mustBeMember(arg, LIST) call.  arg name not
            % consulted -- the validator already binds it positionally to
            % the arguments-block name.  Use a paren-balanced parse
            % rather than a single regex so nested constructs in LIST
            % don't trip up.
            idx = regexp(v, 'mustBeMember\s*\(', 'once');
            if isempty(idx), return; end
            % Walk to the open paren.
            openIdx = idx + find(v(idx:end) == '(', 1, 'first') - 1;
            if isempty(openIdx) || openIdx <= idx, return; end
            % Find the matching close paren.
            depth = 1;
            i = openIdx + 1;
            inSingle = false; inDouble = false;
            while i <= length(v) && depth > 0
                ch = v(i);
                if inDouble
                    if ch == '"', inDouble = false; end
                elseif inSingle
                    if ch == '''', inSingle = false; end
                else
                    switch ch
                        case '"', inDouble = true;
                        case '''', inSingle = true;
                        case '(', depth = depth + 1;
                        case ')', depth = depth - 1;
                    end
                end
                if depth == 0, break; end
                i = i + 1;
            end
            if depth ~= 0, return; end
            inner = strtrim(v(openIdx+1:i-1));
            % Skip the first arg (the variable name) up to the comma at
            % depth 0; what remains is the list expression.
            depth = 0;
            inSingle = false; inDouble = false;
            commaIdx = 0;
            for k = 1:length(inner)
                ch = inner(k);
                if inDouble
                    if ch == '"', inDouble = false; end
                elseif inSingle
                    if ch == '''', inSingle = false; end
                else
                    switch ch
                        case '"', inDouble = true;
                        case '''', inSingle = true;
                        case {'(','[','{'}, depth = depth + 1;
                        case {')',']','}'}, depth = depth - 1;
                        case ','
                            if depth == 0, commaIdx = k; break; end
                    end
                end
            end
            if commaIdx == 0, return; end
            listText = strtrim(inner(commaIdx+1:end));
            if isempty(listText), return; end
            vals = autotest.InputSampler.parseAllowedListLiteral(listText);
        end

        function vals = parseAllowedListLiteral(listText)
            %PARSEALLOWEDLISTLITERAL  Convert literal list text to a cell array.
            %
            %   Recognises three forms:
            %     ["a","b","c"]   string array  -> {'a','b','c'}
            %     {'a','b','c'}   cellstr        -> {'a','b','c'}
            %     [1 2 3]         numeric array  -> {1, 2, 3}
            %   Anything else returns {}.
            vals = {};
            t = strtrim(char(listText));
            if isempty(t), return; end
            % String / numeric array form: [...]
            if t(1) == '[' && t(end) == ']'
                inner = strtrim(t(2:end-1));
                if isempty(inner), return; end
                if any(inner == '"')
                    vals = autotest.InputSampler.scanQuoted(inner, '"');
                    return;
                end
                if any(inner == '''')
                    vals = autotest.InputSampler.scanQuoted(inner, '''');
                    return;
                end
                % Numeric: split on whitespace or comma.
                parts = regexp(inner, '[\s,]+', 'split');
                parts(cellfun(@isempty, parts)) = [];
                vals = cell(1, numel(parts));
                ok = true;
                for k = 1:numel(parts)
                    n = str2double(parts{k});
                    if isnan(n), ok = false; break; end
                    vals{k} = n;
                end
                if ~ok, vals = {}; end
                return;
            end
            % Cellstr form: {...}
            if t(1) == '{' && t(end) == '}'
                inner = strtrim(t(2:end-1));
                if isempty(inner), return; end
                if any(inner == '''')
                    vals = autotest.InputSampler.scanQuoted(inner, '''');
                    return;
                end
                if any(inner == '"')
                    vals = autotest.InputSampler.scanQuoted(inner, '"');
                    return;
                end
            end
            % Bare symbol reference: cannot resolve at parse time.
        end

        function vals = scanQuoted(inner, q)
            %SCANQUOTED  Extract every quoted run between Q delimiters.
            %   Q is one of '"' or ''''.  Doubled-quote escapes are
            %   collapsed (e.g. ''it''s'' -> 'it's').  Generic helper
            %   for parseAllowedListLiteral.
            vals = {};
            i = 1;
            n = length(inner);
            while i <= n
                if inner(i) ~= q
                    i = i + 1;
                    continue;
                end
                % Walk the quoted run, collapsing doubled quotes.
                buf = '';
                j = i + 1;
                while j <= n
                    if inner(j) == q
                        if j + 1 <= n && inner(j+1) == q
                            buf(end+1) = q; %#ok<AGROW>
                            j = j + 2;
                            continue;
                        end
                        break;
                    end
                    buf(end+1) = inner(j); %#ok<AGROW>
                    j = j + 1;
                end
                vals{end+1} = buf; %#ok<AGROW>
                i = j + 1;
            end
        end
    end
end
