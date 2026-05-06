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
    end
end
