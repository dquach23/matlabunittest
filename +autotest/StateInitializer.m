classdef StateInitializer
    %STATEINITIALIZER  Generic name-driven state-init prelude for stateful classes.
    %
    %   Many MATLAB classes split construction into two stages: a thin
    %   constructor that just stashes config, plus a separately-named
    %   zero-argument method (`buildLookupMaps`, `loadAllDOMs`, `scan`,
    %   `init`, `initialize`, `setup`, etc.) that has to run before any
    %   business-logic method works.  When the constructor leaves
    %   container state empty (Phase 2.4 detection), every instance
    %   method on the class is gated to `testSkipped_<name>` because the
    %   autogenerator can't safely call them on an uninitialized object.
    %
    %   This helper looks at the parsed SourceModel for a classdef and
    %   returns the ordered list of zero-arg public non-static methods
    %   whose names look like state-init candidates.  TestWriter calls
    %   them inside TestMethodSetup, after constructing testCase.Instance,
    %   each wrapped in its own try/catch so that one failing init does
    %   not block the rest.  When this list is non-empty, TestWriter also
    %   drops the early-gate skip on stateful instance methods so the
    %   normal smoke / edge / randomized layers can run against the now-
    %   populated state.
    %
    %   The list is intentionally name-driven and project-agnostic: any
    %   MATLAB project that follows the common ``build*/load*/init*``
    %   convention benefits without per-project configuration.

    methods (Static)
        function names = candidateMethods(model)
            %CANDIDATEMETHODS  Zero-arg state-init candidate names for MODEL.
            %
            %   names = autotest.StateInitializer.candidateMethods(model)
            %
            %   Returns a cell array of method names ordered by the
            %   conventional dependency direction: load -> scan -> prepare
            %   -> populate -> build -> init -> initialize -> setup ->
            %   configure -> compile.  Within each prefix bucket, methods
            %   keep their declaration order from the source file.
            names = {};
            if isempty(model)
                return;
            end
            if ~isa(model, 'autotest.SourceModel')
                return;
            end
            if ~strcmp(model.Kind, 'classdef')
                return;
            end
            if isempty(model.Methods)
                return;
            end

            % Ordered by dependency direction: data-loading runs before
            % derived-structure building.  init/initialize/setup are
            % general-purpose buckets that come last.  See class help.
            patterns = { ...
                'load', 'scan', 'prepare', 'populate', 'build', ...
                'init', 'initialize', 'setup', 'configure', 'compile'};

            % Names that LOOK init-flavored but aren't safe to call
            % blindly: destructors, paired teardown methods, and known
            % "produce output" verbs that happen to begin with one of
            % the prefixes (e.g. ``loadFile`` is filtered earlier by the
            % zero-arg gate; ``setupTeardown`` would be a setup that we
            % don't want to call -- include it here if encountered).
            negativeExact = {'delete', 'close', 'cleanup', 'destroy', ...
                             'finalize', 'tearDown', 'teardown'};

            buckets = cell(1, numel(patterns));
            for k = 1:numel(buckets)
                buckets{k} = {};
            end

            for i = 1:numel(model.Methods)
                m = model.Methods(i);
                if ~isfield(m, 'Name') || isempty(m.Name), continue; end
                if ~m.IsPublic, continue; end
                if m.IsStatic, continue; end
                % Skip the constructor -- its own emission already runs.
                if strcmp(m.Name, model.ClassName), continue; end
                if any(strcmp(m.Name, negativeExact)), continue; end
                % Zero-arg only.  fcn.Inputs has the receiver already
                % stripped by MFileParser.parseMethodsBlock, so an empty
                % cell here means truly no positional arguments.
                if ~isempty(m.Inputs), continue; end
                % If the method declares outputs, it's most likely a
                % query (getFoo, hasBar) or a build-and-return helper
                % whose return value the caller relies on -- not a
                % state-mutating init.  Skip.
                if ~isempty(m.Outputs), continue; end

                lname = lower(m.Name);
                bucketIdx = 0;
                for p = 1:numel(patterns)
                    pat = patterns{p};
                    if strncmp(lname, pat, numel(pat))
                        bucketIdx = p;
                        break;
                    end
                end
                if bucketIdx == 0, continue; end
                buckets{bucketIdx}{end+1} = m.Name; %#ok<AGROW>
            end

            % Concatenate buckets in dependency order.
            for k = 1:numel(buckets)
                if isempty(buckets{k}), continue; end
                names = [names, buckets{k}]; %#ok<AGROW>
            end
        end

        function calls = candidateMethodCalls(model, fixtureProvider)
            %CANDIDATEMETHODCALLS  Full call expressions for the state-init prelude.
            %
            %   calls = autotest.StateInitializer.candidateMethodCalls(model, fixtureProvider)
            %
            %   Returns a cell array of CALL EXPRESSION strings such as
            %       'buildLookupMaps()'                       -- zero-arg state-init
            %       'addTable(''Table1'', 1, ''A1'')'         -- multi-arg, all args resolved
            %
            %   Phase 11 returned only the names of zero-arg state-init
            %   methods.  Phase 13 keeps that list (formatted as 'name()'
            %   strings) and ALSO scans for multi-arg state-init candidates
            %   whose arguments can be entirely resolved by FIXTUREPROVIDER
            %   (FixtureProvider.literalForArg + InputSampler.scalarFor as a
            %   typed fallback).  Multi-arg candidates are included only when
            %   EVERY argument resolves to a non-empty literal -- the same
            %   all-or-nothing discipline used by smartFor (Phase 12 lesson:
            %   half-fixtured calls into project code can hit non-terminating
            %   paths that try/catch cannot unstick).
            %
            %   Multi-arg prefixes recognised: 'add', 'register', 'attach',
            %   'insert', 'put', 'set'.  Methods with output arguments are
            %   excluded (queries, not state mutators); so are methods on the
            %   destructor / teardown negativeExact list.  Generic across any
            %   MATLAB project that uses these conventional verbs.
            arguments
                model
                fixtureProvider = []
            end

            calls = {};
            if isempty(model)
                return;
            end
            if ~isa(model, 'autotest.SourceModel')
                return;
            end
            if ~strcmp(model.Kind, 'classdef')
                return;
            end

            % Zero-arg candidates first.  These are always safe and never
            % require a fixture provider; they reuse the established
            % candidateMethods detection.
            zeroArg = autotest.StateInitializer.candidateMethods(model);
            for i = 1:numel(zeroArg)
                calls{end+1} = [zeroArg{i} '()']; %#ok<AGROW>
            end

            % Multi-arg path needs a real FixtureProvider.  Without one we
            % stop here -- existing zero-arg behaviour is preserved.
            if isempty(fixtureProvider) ...
                    || ~isa(fixtureProvider, 'autotest.FixtureProvider')
                return;
            end
            if isempty(model.Methods)
                return;
            end

            multiPrefixes = {'add', 'register', 'attach', 'insert', 'put', 'set'};
            negativeExact = {'delete', 'close', 'cleanup', 'destroy', ...
                             'finalize', 'tearDown', 'teardown'};

            for i = 1:numel(model.Methods)
                m = model.Methods(i);
                if ~isfield(m, 'Name') || isempty(m.Name), continue; end
                if ~m.IsPublic, continue; end
                if m.IsStatic, continue; end
                if strcmp(m.Name, model.ClassName), continue; end
                if any(strcmp(m.Name, negativeExact)), continue; end
                % Skip zero-arg (already covered above).
                if isempty(m.Inputs), continue; end
                % State mutators do not return values.
                if ~isempty(m.Outputs), continue; end

                lname = lower(m.Name);
                matched = false;
                for p = 1:numel(multiPrefixes)
                    pat = multiPrefixes{p};
                    if strncmp(lname, pat, numel(pat))
                        matched = true;
                        break;
                    end
                end
                if ~matched, continue; end

                resolved = autotest.StateInitializer.tryResolveArgs( ...
                    m, fixtureProvider);
                if isempty(resolved), continue; end

                callStr = sprintf('%s(%s)', m.Name, strjoin(resolved, ', '));
                calls{end+1} = callStr; %#ok<AGROW>
            end
        end

        function resolved = tryResolveArgs(m, fixtureProvider)
            %TRYRESOLVEARGS  All-or-nothing FixtureProvider resolution.
            %
            %   Returns a cell array of literal expressions (one per input)
            %   if EVERY positional input resolves; otherwise returns {}.
            %   varargin is treated as unresolvable -- the prelude must not
            %   guess at variadic state-init signatures.
            resolved = {};
            inputs = m.Inputs;
            if isempty(inputs)
                return;
            end
            try
                typed = autotest.InputSampler.typesFromArguments( ...
                    inputs, m.ArgumentBlocks);
            catch
                return;
            end
            out = cell(1, numel(inputs));
            for k = 1:numel(inputs)
                argName = inputs{k};
                if strcmp(argName, 'varargin'), return; end
                argInfo = typed{k};
                expr = '';
                try
                    expr = fixtureProvider.literalForArg( ...
                        argName, argInfo, '');
                catch
                    return;
                end
                if isempty(expr)
                    % Fallback: typed scalarFor when the FixtureProvider
                    % had nothing name-driven for this arg.  scalarFor only
                    % yields a plausible literal when the type is known
                    % (string/char/numeric/logical/etc) -- otherwise we
                    % bail and the entire candidate is dropped.
                    try
                        expr = autotest.InputSampler.scalarFor(argInfo);
                    catch
                        return;
                    end
                end
                if isempty(expr)
                    return;
                end
                out{k} = expr;
            end
            resolved = out;
        end

        function expr = liveContainerExpr(propName, propType)
            %LIVECONTAINEREXPR  Build a live-container smoke arg expression.
            %
            %   Phase 16 (candidate 1): emits `testCase.Instance.<propName>`
            %   so the smoke uses the ENTIRE container property at runtime,
            %   not a key into it.  Symmetric to liveKeyExpr but for the
            %   case where a method's positional arg is the WHOLE
            %   containers.Map / dictionary / table / struct that lives on
            %   a sibling property of the same class -- e.g.
            %       function rebuildSheet(obj, sheetMap)
            %   with `properties; SheetMap; end` on the same class.
            %
            %   PROPNAME is the class property name (case-sensitive as
            %   declared in the source file).  PROPTYPE is accepted for
            %   parity with liveKeyExpr; not consulted at emission time
            %   (the property's runtime shape carries the type).
            %
            %   Generic across MATLAB projects: detection at the call
            %   site (TestWriter.applyContainerSubstitution) is purely
            %   shape-and-name-based.
            arguments
                propName (1,:) char
                propType (1,:) char = '' %#ok<INUSA>
            end
            expr = sprintf('testCase.Instance.%s', propName);
        end

        function expr = liveValueExpr(propName, propType, fallback)
            %LIVEVALUEEXPR  Build a live-value smoke arg expression.
            %
            %   Phase 16 (candidate 2): emits a call expression
            %       autotest.InputSampler.firstValueOr( ...
            %           testCase.Instance.<propName>, <fallback>)
            %   that the generated TestMethodSetup will resolve at
            %   runtime.  When the prelude has populated the named
            %   property (table / struct / cell), firstValueOr returns
            %   the first VALUE entry; when it has not, it returns the
            %   FALLBACK literal verbatim, so the smoke degrades
            %   gracefully without throwing inside the prelude's
            %   try/catch.
            %
            %   Symmetric to liveKeyExpr but for value-shaped args
            %   (tableData, rowValue, recordPayload, etc.) where the
            %   caller wants a SAMPLE entry rather than a KEY.
            %
            %   Generic across MATLAB projects: detection at runtime is
            %   purely shape-based, no project-specific knowledge.
            arguments
                propName (1,:) char
                propType (1,:) char = '' %#ok<INUSA>
                fallback (1,:) char = ''''''
            end
            if isempty(fallback)
                fallback = '''''';
            end
            expr = sprintf( ...
                'autotest.InputSampler.firstValueOr(testCase.Instance.%s, %s)', ...
                propName, fallback);
        end

        function expr = liveKeyExpr(propName, propType, fallback)
            %LIVEKEYEXPR  Build a live-key smoke arg expression.
            %
            %   Phase 15 (candidate 1): emits a call expression
            %       autotest.InputSampler.firstKeyOr( ...
            %           testCase.Instance.<propName>, <fallback>)
            %   that the generated TestMethodSetup will resolve at
            %   runtime.  When the prelude has populated the named
            %   property (containers.Map / dictionary / struct / cell
            %   / table), firstKeyOr returns the first key/index;
            %   when it has not, firstKeyOr returns the FALLBACK
            %   literal verbatim, so the smoke degrades gracefully
            %   without throwing inside the prelude's try/catch.
            %
            %   PROPNAME is the class property name (case-sensitive
            %   as declared in the source file).  PROPTYPE is
            %   accepted for parity with other emitters but is not
            %   currently consulted -- firstKeyOr does its own
            %   shape detection at runtime.  FALLBACK is the
            %   synthetic literal expression to use when the property
            %   is empty or unrecognised.
            %
            %   Generic across MATLAB projects: detection at runtime
            %   is purely shape-based, no project-specific knowledge.
            arguments
                propName  (1,:) char
                propType  (1,:) char = '' %#ok<INUSA>
                fallback  (1,:) char = ''''''
            end
            if isempty(fallback)
                fallback = '''''';
            end
            expr = sprintf( ...
                'autotest.InputSampler.firstKeyOr(testCase.Instance.%s, %s)', ...
                propName, fallback);
        end
    end
end
