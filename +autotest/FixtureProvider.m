classdef FixtureProvider < handle
    %FIXTUREPROVIDER  Maps function arguments to realistic test inputs.

    properties (SetAccess = immutable)
        Root            (1,:) char
    end

    properties (SetAccess = private)
        ExcelFiles      (1,:) string = string.empty
        KeepListFiles   (1,:) string = string.empty
        DirtyListFiles  (1,:) string = string.empty
        ImageFiles      (1,:) string = string.empty
        TextFiles       (1,:) string = string.empty
        MatFiles        (1,:) string = string.empty
        MlappFiles      (1,:) string = string.empty
        PrimaryExcel    (1,:) char = ''
        PrimaryKeepList (1,:) char = ''
        PrimaryDirtyList(1,:) char = ''
        PrimaryImage    (1,:) char = ''
    end

    methods
        function obj = FixtureProvider(root)
            arguments
                root (1,:) char
            end
            obj.Root = root;
            if ~isempty(root) && isfolder(root)
                obj.scan();
            end
        end

        function tf = hasFixtures(obj)
            tf = ~isempty(obj.ExcelFiles) || ~isempty(obj.ImageFiles) ...
                || ~isempty(obj.TextFiles) || ~isempty(obj.MatFiles);
        end

        function expr = literalForArg(obj, argName, argInfo, helpText)
            arguments
                obj
                argName    (1,:) char
                argInfo    struct = struct('Type','double','SizeHint','any','Validators',{{}})
                helpText   (1,:) char = ''
            end
            expr = '';
            if isempty(argName)
                return;
            end
            lname = lower(argName);
            ltype = '';
            if isfield(argInfo, 'Type'), ltype = lower(strtrim(argInfo.Type)); end
            sizeHint = '';
            if isfield(argInfo, 'SizeHint'), sizeHint = argInfo.SizeHint; end

            % Treat default-double and empty-string as "no type info"
            % so name-driven heuristics still fire when no `arguments`
            % block is present (most MATLAB classdef ctors).
            unknownType = isempty(ltype) || strcmp(ltype, 'double');
            stringy     = obj.isCharScalar(ltype, sizeHint) ...
                          || strcmp(ltype, 'string');
            stringyOrUnknown = stringy || unknownType;

            ex = obj.literalFromExample(argName, helpText);
            if ~isempty(ex)
                expr = ex;
                return;
            end

            % --- Phase 10: fileID-named args -> real fopen-backed handle ---
            % Generic across projects: detection is purely name-based.
            % The expression evaluates inside a TestCase method where
            % `testCase` is in scope.  See InputSampler.tempFileID for
            % the actual fopen + addTeardown implementation.
            if autotest.InputSampler.isFileIDName(argName)
                expr = autotest.InputSampler.fileIDExpr();
                return;
            end

            % --- Phase 12: DOM-named/typed args -> in-memory DOM ----
            % Generic across projects: name match (`*DOM`, `*Document`,
            % `dom`, `doc`, `xmlDoc`, `xmlNode`) plus type match for
            % org.w3c.dom.* / matlab.io.xml.dom.*.  The expression
            % evaluates inside a TestCase method where `testCase` is
            % in scope.  See InputSampler.tempDOM for the actual
            % javax.xml.parsers builder call.
            if autotest.InputSampler.isDOMName(argName) ...
                    || autotest.InputSampler.isDOMType(argInfo)
                expr = autotest.InputSampler.domExpr();
                return;
            end

            % --- Phase 14 (candidate 3): typed table / cell fixtures -----
            % When an `arguments` block declares an arg as `table` or
            % `cell`, build a small synthetic value of that shape.
            % Default InputSampler.scalarFor returns `1` (table) or
            % `{1}` (cell), neither of which matches what spreadsheet
            % utility code expects.  Gated on argInfo.IsExplicit so
            % this is dormant when no `arguments` block is present.
            if isfield(argInfo, 'IsExplicit') && argInfo.IsExplicit
                if strcmp(ltype, 'table')
                    expr = 'table([1;2;3], ["a";"b";"c"], ''VariableNames'', {''N'', ''S''})';
                    return;
                end
                if strcmp(ltype, 'cell')
                    % cell-of-cells matrix (2x2) suits MATLAB
                    % conventions for spreadsheet-style data better
                    % than the {1, 2, 3} vector InputSampler.vectorFor
                    % would emit.
                    expr = '{1, ''a''; 2, ''b''}';
                    return;
                end
            end

            % --- Phase 16 (candidate 4): mustBeMember validator pull --------
            % When the `arguments` block declares
            %     argName ... {mustBeMember(argName, ["a","b","c"])}
            % InputSampler.typesFromArguments captures the allowed list as
            % argInfo.MustBeMember.  Use the FIRST allowed value as the
            % literal so the smoke is guaranteed to satisfy validation
            % (no synthesis, no risk of an "expected member" failure on
            % the first call into the project).  Generic across MATLAB
            % projects.  Inserted AFTER the typed table/cell branch and
            % BEFORE the Phase 15 cand-5 data/value/payload branch so
            % an `arguments` row that has BOTH an explicit type AND
            % mustBeMember validators picks the validator-driven value.
            if isfield(argInfo, 'MustBeMember') && ~isempty(argInfo.MustBeMember)
                first = argInfo.MustBeMember{1};
                if ischar(first) || isstring(first)
                    s = char(first);
                    % Pick the literal flavour by declared type:
                    % string -> "..."  (double-quoted)
                    % otherwise (char / unspecified) -> '...'
                    if strcmp(ltype, 'string')
                        expr = ['"' strrep(s, '"', '""') '"'];
                    else
                        expr = ['''' strrep(s, '''', '''''') ''''];
                    end
                    return;
                elseif isnumeric(first) && isscalar(first) && isfinite(first)
                    if floor(first) == first && abs(first) < 1e12
                        expr = sprintf('%d', first);
                    else
                        expr = sprintf('%g', first);
                    end
                    return;
                end
            end

            % --- Phase 15 (candidate 5): typed `data`/`value`/`payload` -----
            % When an `arguments` block declares one of these names with an
            % explicit type AND a recognised SizeHint, return a type+shape-
            % appropriate fixture.  Gated on argInfo.IsExplicit so the
            % heuristic is dormant when no `arguments` block is present
            % (a `data` arg with no declared type is too ambiguous; the
            % existing default-fallthrough is correct).  Generic across
            % MATLAB projects.
            if isfield(argInfo, 'IsExplicit') && argInfo.IsExplicit ...
                    && (strcmp(lname, 'data') || strcmp(lname, 'value') ...
                        || strcmp(lname, 'payload'))
                sh = '';
                if isfield(argInfo, 'SizeHint'), sh = argInfo.SizeHint; end
                switch ltype
                    case 'string'
                        expr = '"abc"';
                        return;
                    case 'char'
                        expr = '''abc''';
                        return;
                    case {'double', 'single', 'numeric'}
                        switch sh
                            case 'scalar', expr = '1';
                            case 'vector', expr = '[1 2 3]';
                            case 'matrix', expr = 'magic(3)';
                            otherwise,     expr = '1';
                        end
                        return;
                    case 'logical'
                        expr = 'true';
                        return;
                    case 'table'
                        expr = 'table([1;2;3], ["a";"b";"c"], ''VariableNames'', {''N'', ''S''})';
                        return;
                    case 'cell'
                        expr = '{1, ''a''; 2, ''b''}';
                        return;
                    case 'struct'
                        expr = 'struct(''value'', 1)';
                        return;
                end
            end

            % --- Stringy name-only heuristics (message/text/title/...) ----
            % Phase 13: extend the exact-name list with common composite
            % suffixes (titleText, headerText, subtitle) so callers like
            % createCenteredHeader(titleText, padChar) resolve cleanly.
            if stringyOrUnknown ...
                    && (strcmp(lname, 'message') || strcmp(lname, 'msg') ...
                        || strcmp(lname, 'text')    || strcmp(lname, 'title') ...
                        || strcmp(lname, 'caption') || strcmp(lname, 'label') ...
                        || strcmp(lname, 'header')  || strcmp(lname, 'string') ...
                        || strcmp(lname, 'str')     || strcmp(lname, 'word') ...
                        || endsWith(lname, 'titletext') || endsWith(lname, 'headertext') ...
                        || endsWith(lname, 'subtitle'))
                expr = '''hello''';
                return;
            end

            % Phase 13: pad/fill character args (createCenteredHeader's
            % padChar, drawSeparator's fillChar, etc.).  A printable ASCII
            % glyph is the only safe synthetic value; '*' is the
            % conventional choice for separators in plain-text reports.
            if stringyOrUnknown ...
                    && (strcmp(lname, 'padchar') || endsWith(lname, 'padchar') ...
                        || strcmp(lname, 'fillchar') || endsWith(lname, 'fillchar'))
                expr = '''*''';
                return;
            end

            % --- Phase 12: XML tag / element / attribute names -> 'a'
            % These appear alongside DOM args in XML-manipulating
            % functions (removeElements(dom, tagName), getAttribute(
            % node, attrName)).  A short ASCII identifier is the
            % safest synthetic value for Java DOM APIs that expect a
            % String.  `'a'` is the same shape MATLAB's scalarFor
            % returns for a typed `char` arg, so callers that DO have
            % an `arguments` block declaring `char` are unaffected.
            if stringyOrUnknown ...
                    && (endsWith(lname, 'tagname') || endsWith(lname, 'elementname') ...
                        || endsWith(lname, 'attrname') || endsWith(lname, 'attributename') ...
                        || endsWith(lname, 'nodename') || endsWith(lname, 'partname'))
                expr = '''a''';
                return;
            end

            % --- App Designer / GUI handles ---
            if contains(lname, 'textarea')
                expr = 'uitextarea(uifigure(''Visible'', ''off''))';
                return;
            end
            if contains(lname, 'uifigure') || strcmp(lname, 'figure') ...
                    || strcmp(lname, 'fig') || strcmp(lname, 'parent')
                expr = 'uifigure(''Visible'', ''off'')';
                return;
            end

            if stringyOrUnknown ...
                    && (strcmp(lname, 'cellref') || endsWith(lname, 'cellref') ...
                        || strcmp(lname, 'celllocation') || endsWith(lname, 'celllocation'))
                expr = '''A1''';
                return;
            end

            if stringyOrUnknown && contains(lname, 'range')
                expr = '''A1:F10''';
                return;
            end

            if stringyOrUnknown ...
                    && (contains(lname, 'pattern') || contains(lname, 'regex'))
                expr = '''[A-Z][A-Z]\d{4}[A-Z][A-Z]''';
                return;
            end

            if stringyOrUnknown ...
                    && (contains(lname, 'classif') || contains(lname, 'taglabel'))
                expr = '''FOR OFFICIAL USE ONLY''';
                return;
            end

            if stringyOrUnknown
                if contains(lname, 'sheet') && contains(lname, 'name')
                    expr = '''Sheet''';
                    return;
                end
                % Phase 13: extend tablename / columnname to also match
                % composite names (existingTableName, primaryColumnName,
                % columnNames plural).
                if strcmp(lname, 'tablename') || endsWith(lname, 'tablename')
                    expr = '''Table1''';
                    return;
                end
                if strcmp(lname, 'columnname') || endsWith(lname, 'columnname') ...
                        || strcmp(lname, 'columnnames') || endsWith(lname, 'columnnames')
                    expr = '''Comments''';
                    return;
                end
            end

            if (strcmp(ltype, 'string') || unknownType) ...
                    && (contains(lname, 'keep') || contains(lname, 'approv') ...
                        || contains(lname, 'whitelist'))
                expr = '["AB1234CD" "EF5678GH"]';
                return;
            end
            if (strcmp(ltype, 'string') || unknownType) ...
                    && (contains(lname, 'dirty') || contains(lname, 'deny') ...
                        || contains(lname, 'blacklist') || contains(lname, 'reject'))
                expr = '["Wrangler" "Golf"]';
                return;
            end

            if stringyOrUnknown ...
                    && (contains(lname, 'reportpath') ...
                        || contains(lname, 'reportfile') ...
                        || contains(lname, 'outputpath') ...
                        || contains(lname, 'outputfile') ...
                        || contains(lname, 'logpath') ...
                        || contains(lname, 'logfile') ...
                        || strcmp(lname, 'filepath'))
                expr = 'tempname()';
                return;
            end

            % --- Phase 14 (candidate 1): unzipped-Excel staging fixture -
            % When an arg looks like an unzip / staging directory AND
            % the project supplies a primary .xlsx fixture, return an
            % expression that unzips that workbook into a temp dir at
            % test time.  This is the constructor-graph fixture: a
            % class whose constructor takes a path-like dir AND has a
            % zero-arg sibling populator (loadAllDOMs/buildLookupMaps)
            % that fills internal Map/dictionary state from files on
            % disk.  Without a real populated dir, the populator's
            % try/catch silently swallows the read failure and maps
            % stay empty, cascading into Incomplete on every method
            % that touches them.
            % Dormant on projects with no .xlsx files (PrimaryExcel
            % empty); falls through to the bare tempname() path below.
            if stringyOrUnknown ...
                    && ~isempty(obj.PrimaryExcel) ...
                    && (contains(lname, 'unzip') ...
                        || contains(lname, 'stagingdir'))
                expr = sprintf( ...
                    'autotest.InputSampler.tempUnzippedExcel(testCase, %s)', ...
                    obj.charLiteral(obj.PrimaryExcel));
                return;
            end

            if stringyOrUnknown ...
                    && (contains(lname, 'unzip') ...
                        || contains(lname, 'stagingdir') ...
                        || contains(lname, 'tempdir') ...
                        || strcmp(lname, 'workdir'))
                expr = 'tempname()';
                return;
            end

            if stringyOrUnknown ...
                    && ~isempty(obj.PrimaryExcel) ...
                    && (contains(lname, 'xls') || contains(lname, 'excel') ...
                        || contains(lname, 'workbook') || endsWith(lname, 'file') ...
                        || endsWith(lname, 'path') || strcmp(lname, 'inputfile') ...
                        || strcmp(lname, 'filename'))
                expr = obj.charLiteral(obj.PrimaryExcel);
                return;
            end

            if any(strcmp(ltype, {'double','single','numeric',''})) ...
                    && (contains(lname, 'col') || contains(lname, 'row') ...
                        || contains(lname, 'index') || contains(lname, 'sheetnumber'))
                expr = '1';
                return;
            end

            if strcmp(ltype, 'logical') ...
                    && (contains(lname, 'remove') || contains(lname, 'enable') ...
                        || contains(lname, 'flag'))
                expr = 'true';
                return;
            end

            expr = '';
        end

        function expr = literalForProperty(obj, propName, propType)
            arguments
                obj
                propName (1,:) char
                propType (1,:) char = ''
            end
            expr = '';
            lname = lower(propName);
            ltype = lower(strtrim(propType));
            ltype = regexprep(ltype, '\([^)]*\)', '');
            ltype = strtrim(ltype);
            tokens = strsplit(ltype);
            base = '';
            if ~isempty(tokens), base = tokens{1}; end

            if any(strcmp(base, {'string', 'char'}))
                if contains(lname, 'pattern') || contains(lname, 'regex')
                    expr = '"[A-Z][A-Z]\d{4}[A-Z][A-Z]"';
                    if strcmp(base, 'char'), expr = '''[A-Z][A-Z]\d{4}[A-Z][A-Z]'''; end
                    return;
                end
                if contains(lname, 'classif')
                    expr = '"FOR OFFICIAL USE ONLY"';
                    if strcmp(base, 'char'), expr = '''FOR OFFICIAL USE ONLY'''; end
                    return;
                end
                if contains(lname, 'replac')
                    expr = '""';
                    if strcmp(base, 'char'), expr = ''''''; end
                    return;
                end
            end

            if strcmp(base, 'string')
                if contains(lname, 'keep') || contains(lname, 'approv')
                    expr = '["AB1234CD" "EF5678GH"]';
                    return;
                end
                if contains(lname, 'dirty') || contains(lname, 'deny') ...
                        || contains(lname, 'reject')
                    expr = '["Wrangler" "Golf"]';
                    return;
                end
            end
        end

        function p = primaryExcel(obj),     p = obj.PrimaryExcel;     end
        function p = primaryKeepList(obj),  p = obj.PrimaryKeepList;  end
        function p = primaryDirtyList(obj), p = obj.PrimaryDirtyList; end
        function p = primaryImage(obj),     p = obj.PrimaryImage;     end
    end

    methods (Access = private)
        function scan(obj)
            list = dir(fullfile(obj.Root, '**', '*'));
            for i = 1:numel(list)
                d = list(i);
                if d.isdir, continue; end
                full = fullfile(d.folder, d.name);
                if obj.shouldSkip(d.folder)
                    continue;
                end
                [~, base, ext] = fileparts(d.name);
                lext = lower(ext);
                lbase = lower(base);
                switch lext
                    case '.xlsx'
                        obj.ExcelFiles(end+1) = string(full); %#ok<AGROW>
                        if contains(lbase, 'approv') || contains(lbase, 'keep') ...
                                || contains(lbase, 'whitelist')
                            obj.KeepListFiles(end+1) = string(full); %#ok<AGROW>
                        end
                        if contains(lbase, 'dirty') || contains(lbase, 'deny') ...
                                || contains(lbase, 'reject') || contains(lbase, 'blacklist')
                            obj.DirtyListFiles(end+1) = string(full); %#ok<AGROW>
                        end
                    case {'.png','.jpg','.jpeg','.bmp','.gif','.tif','.tiff'}
                        obj.ImageFiles(end+1) = string(full); %#ok<AGROW>
                    case {'.txt','.csv','.log'}
                        obj.TextFiles(end+1) = string(full); %#ok<AGROW>
                    case '.mat'
                        obj.MatFiles(end+1) = string(full); %#ok<AGROW>
                    case '.mlapp'
                        obj.MlappFiles(end+1) = string(full); %#ok<AGROW>
                end
            end

            obj.PrimaryExcel = obj.choosePrimary(obj.ExcelFiles, ...
                {'tooltester','sample','demo','example','test'}, ...
                {'approv','keep','dirty','deny','reject','whitelist','blacklist'});
            obj.PrimaryKeepList  = obj.choosePrimary(obj.KeepListFiles, {}, {});
            obj.PrimaryDirtyList = obj.choosePrimary(obj.DirtyListFiles, {}, {});
            obj.PrimaryImage     = obj.choosePrimary(obj.ImageFiles, ...
                {'sample','example','test'}, {});
        end

        function tf = shouldSkip(obj, folderPath)
            ignored = {'.git', '.svn', '.hg', '.idea', '.vscode', ...
                       'node_modules', '_autotest'};
            rel = strrep(folderPath, obj.Root, '');
            parts = strsplit(rel, filesep);
            parts(cellfun(@isempty, parts)) = [];
            tf = any(ismember(parts, ignored));
        end
    end

    methods (Static, Access = private)
        function tf = isCharScalar(ltype, sizeHint)
            tf = strcmp(ltype, 'char') ...
                || (strcmp(ltype, '') && strcmp(sizeHint, 'scalar')) ...
                || strcmp(ltype, 'string');
        end

        function tf = looksLikePath(lname, ltype)
            tf = (strcmp(ltype, 'char') || strcmp(ltype, 'string')) ...
                && (contains(lname, 'file') || contains(lname, 'path') ...
                    || contains(lname, 'xlsx') || contains(lname, 'excel') ...
                    || contains(lname, 'workbook'));
        end

        function s = charLiteral(p)
            s = ['''' strrep(p, '''', '''''') ''''];
        end

        function pick = choosePrimary(list, prefer, exclude)
            pick = '';
            if isempty(list), return; end
            keep = true(size(list));
            for i = 1:numel(list)
                lo = lower(char(list(i)));
                for k = 1:numel(exclude)
                    if contains(lo, exclude{k})
                        keep(i) = false; break;
                    end
                end
            end
            filtered = list(keep);
            if isempty(filtered)
                filtered = list;
            end
            for k = 1:numel(prefer)
                for i = 1:numel(filtered)
                    if contains(lower(char(filtered(i))), prefer{k})
                        pick = char(filtered(i));
                        return;
                    end
                end
            end
            pick = char(filtered(1));
        end

        function expr = literalFromExample(argName, helpText)
            expr = '';
            if isempty(helpText), return; end
            lines = strsplit(helpText, newline, 'CollapseDelimiters', false);
            argLow = lower(argName);
            for i = 1:numel(lines)
                ln = lines{i};
                lnLow = lower(ln);
                if ~contains(lnLow, argLow), continue; end
                tok = regexp(ln, '''([^'']+)''', 'tokens', 'once');
                if ~isempty(tok)
                    expr = ['''' strrep(tok{1}, '''', '''''') ''''];
                    return;
                end
                tok = regexp(ln, '"([^"]+)"', 'tokens', 'once');
                if ~isempty(tok)
                    expr = ['"' tok{1} '"'];
                    return;
                end
                tok = regexp(ln, '\b(-?\d+(?:\.\d+)?)\b', 'tokens', 'once');
                if ~isempty(tok)
                    expr = tok{1};
                    return;
                end
            end
        end
    end
end
