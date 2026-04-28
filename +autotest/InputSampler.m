classdef InputSampler
    %INPUTSAMPLER  Builds literal MATLAB expressions for use as test inputs.
    %
    %   The sampler emits two kinds of cases:
    %       - "smoke" cases: small, well-formed sample inputs intended to
    %         drive the function under test without throwing.
    %       - "edge" cases: empties, NaNs, Infs, zeros, very large values
    %         and negative values that exercise common boundary failures.
    %
    %   For functions with an `arguments` block, the sampler reads the
    %   declared types/sizes/validators and refines its samples accordingly.
    %
    %   Each sample is returned as a struct with fields:
    %       Label  - short human-readable label for the test name
    %       Expr   - a MATLAB expression string that evaluates to the value
    %       Kind   - 'smoke' | 'edge' | 'invalid'

    methods (Static)
        function cases = smokeFor(inputs, argBlocks)
            cases = autotest.InputSampler.emptyCase();
            if isempty(inputs)
                cases(1) = autotest.InputSampler.makeCase('default','','smoke');
                cases(1).Args = {};
                return;
            end
            typed = autotest.InputSampler.typesFromArguments(inputs, argBlocks);
            sets = { ...
                {'scalar',   @(t) autotest.InputSampler.scalarFor(t)}, ...
                {'vector',   @(t) autotest.InputSampler.vectorFor(t)}, ...
                {'matrix',   @(t) autotest.InputSampler.matrixFor(t)}, ...
                };
            for s = 1:numel(sets)
                label = sets{s}{1};
                builder = sets{s}{2};
                args = cell(1, numel(inputs));
                ok = true;
                for k = 1:numel(inputs)
                    if strcmp(inputs{k}, 'varargin')
                        args{k} = '';  % stop here
                        args = args(1:k-1);
                        break;
                    end
                    args{k} = builder(typed{k});
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
            cases = autotest.InputSampler.emptyCase();
            if isempty(inputs), return; end
            typed = autotest.InputSampler.typesFromArguments(inputs, argBlocks);
            % Build per-position edge variants while keeping other inputs at
            % their nominal scalar smoke value.
            nominal = cellfun(@autotest.InputSampler.scalarFor, typed, ...
                'UniformOutput', false);
            for k = 1:numel(inputs)
                if strcmp(inputs{k}, 'varargin'), break; end
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

    methods (Static)  % Type inference + per-type generators
        function typed = typesFromArguments(inputs, argBlocks)
            typed = repmat({struct('Type','double','SizeHint','any','Validators',{{}})}, ...
                1, numel(inputs));
            if isempty(argBlocks), return; end

            % Each block is a cell array of raw row strings.  Rows are
            % "name (size) Type {validators} = default".
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
                    expr = '1';  % most permissive default
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
                    edges = autotest.InputSampler.appendEdge(edges, 'unicode', '''café''');
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
  