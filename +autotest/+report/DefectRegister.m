classdef DefectRegister
    %DEFECTREGISTER  Phase 15 -- categorise tests into per-defect entries.
    %
    %   defects = autotest.report.DefectRegister.build(data, prefix)
    %
    %   Inputs:
    %       DATA    -- struct returned by ResultsParser.parse(...).
    %       PREFIX  -- two-letter project prefix (e.g. 'RR') used to
    %                  number the emitted defect IDs.
    %
    %   Output: struct array with fields
    %       Id, Severity, Title, Location, Findings, AffectedTests,
    %       SeverityRationale, Status, Category.
    %
    %   The register differentiates three classes of finding:
    %     (a) real project defects     -- real-signal test failures /
    %                                     known_real_signal entries
    %     (b) autogen-side limitations -- opaque-typed input,
    %                                     synthetic-input mismatch
    %     (c) by-design placeholders   -- user-stub Incompletes
    %
    %   Severity ratings ('High' / 'Medium' / 'Low' / 'Informational')
    %   are defended in the SeverityRationale field for downstream
    %   prose emission.

    methods (Static)
        function defects = build(data, prefix)
            arguments
                data   struct
                prefix (1,:) char = 'XX'
            end
            defects = struct( ...
                'Id',{}, 'Severity',{}, 'Title',{}, 'Location',{}, ...
                'Findings',{}, 'AffectedTests',{}, ...
                'SeverityRationale',{}, 'Status',{}, 'Category',{}, ...
                'AffectedMethods',{});

            counter = 0;

            % --- 1. Known-real-signal entries (real project bugs). -------
            % Group entries by reason so multiple affected tests share one
            % defect ID.
            grouped = autotest.report.DefectRegister.groupByReason(data.KnownRealSignal);
            keys_ = fieldnames(grouped);
            for i = 1:numel(keys_)
                entry = grouped.(keys_{i});
                counter = counter + 1;
                title  = autotest.report.DefectRegister.titleFromReason(entry.Reason);
                affTxt = autotest.report.DefectRegister.formatAffectedTests(entry.Affected);
                rationale = autotest.report.DefectRegister.severityRationale( ...
                    'real-signal', entry.Reason);
                defects(end+1) = struct( ...
                    'Id',                sprintf('%s-%03d', prefix, counter), ...
                    'Severity',          autotest.report.DefectRegister.severityForReason(entry.Reason), ...
                    'Title',             title, ...
                    'Location',          autotest.report.DefectRegister.locationFromReason(entry.Reason), ...
                    'Findings',          autotest.report.DefectRegister.findingsFromReason(entry.Reason), ...
                    'AffectedTests',     affTxt, ...
                    'SeverityRationale', rationale, ...
                    'Status',            ['Acknowledged on the project''s ' ...
                                          '_autotest/known_real_signal.txt accepted-debt ' ...
                                          'list. Not a regression in this cycle.'], ...
                    'Category',          'real-signal', ...
                    'AffectedMethods',   {{entry.Affected.Method}}); %#ok<AGROW>
            end

            % --- 2. Stateful-input-mismatch (Incomplete) ----------------
            % Phase 16 (Part B item 5): cluster-grained entries.  Each
            % distinct failure cluster within a class gets its own
            % defect ID instead of collapsing into one per-class entry.
            % Clusters are formed by the diagnostic message signature
            % (first ~60 chars stripped of method-specific prefix), so
            % a class with two distinct underlying root causes appears
            % as two defects -- much higher-fidelity remediation
            % targets for the project owner.
            statefulClusters = autotest.report.DefectRegister.groupStatefulByCluster(data.Tests);
            classes_ = fieldnames(statefulClusters);
            for i = 1:numel(classes_)
                clsName = autotest.report.DefectRegister.demangleStruct(classes_{i});
                clusters = statefulClusters.(classes_{i});
                clusterKeys = fieldnames(clusters);
                for ci = 1:numel(clusterKeys)
                    clusterEntries = clusters.(clusterKeys{ci});
                    if isempty(clusterEntries), continue; end
                    counter = counter + 1;
                    methodsInCluster = {clusterEntries.Method};
                    affTxt = autotest.report.DefectRegister.briefAffectedList( ...
                        clsName, methodsInCluster);
                    sample = autotest.report.DefectRegister.mostCommonMessage( ...
                        clusterEntries);
                    sampleQuote = sample;
                    if length(sampleQuote) > 200
                        sampleQuote = [sampleQuote(1:197) '...'];
                    end
                    titleSuffix = autotest.report.DefectRegister.titleSuffixFromMessage( ...
                        sample);
                    if isempty(titleSuffix)
                        titleSuffix = sprintf('cluster %d', ci);
                    end
                    title = sprintf('Stateful-input mismatch on %s -- %s', ...
                        clsName, titleSuffix);
                    findings = sprintf( ...
                        ['Cluster of %d test method(s) on this class report ' ...
                         'Incomplete with a shared diagnostic signature.  Most ' ...
                         'common diagnostic (verbatim, truncated to 200 chars): ' ...
                         '"%s".  Phase 15 candidate 1 (live-state-aware smoke) ' ...
                         'and Phase 16 candidate 1 (container-typed sibling ' ...
                         'substitution) are the generic remediations on the ' ...
                         'autogen side; project-side, the underlying fixture ' ...
                         'wiring (constructor argument shape, populator method ' ...
                         'name) may also need adjustment.'], ...
                        numel(clusterEntries), sampleQuote);
                    mitigation = autotest.report.DefectRegister.userStubMitigation( ...
                        clsName, methodsInCluster);
                    defects(end+1) = struct( ...
                        'Id',                sprintf('%s-%03d', prefix, counter), ...
                        'Severity',          'Medium', ...
                        'Title',             title, ...
                        'Location',          sprintf('Class %s; cluster of %d method(s).', clsName, numel(clusterEntries)), ...
                        'Findings',          findings, ...
                        'AffectedTests',     affTxt, ...
                        'SeverityRationale', ['Medium because the underlying class is ' ...
                            'exercised by real callers in the project and the cluster ' ...
                            'obscures regression visibility on every method that shares ' ...
                            'the diagnostic signature.  When the cluster root cause is ' ...
                            'addressed, every method in the cluster flips from Incomplete ' ...
                            'to Pass on the next cycle.'], ...
                        'Status',            mitigation, ...
                        'Category',          'stateful-input-mismatch', ...
                        'AffectedMethods',   {methodsInCluster}); %#ok<AGROW>
                end
            end

            % --- 3. Opaque-typed-input cascade (autogen-side limitation) -
            opaqueCount = autotest.report.DefectRegister.countOpaque(data.Tests);
            if opaqueCount > 0
                counter = counter + 1;
                defects(end+1) = struct( ...
                    'Id',                sprintf('%s-%03d', prefix, counter), ...
                    'Severity',          'Low', ...
                    'Title',             sprintf('Autogen limitation: %d opaque-typed-input Incompletes', opaqueCount), ...
                    'Location',          'Distributed across stateful classes with containers.Map / dictionary / DOM-typed positional args.', ...
                    'Findings',          ['Test methods report Incomplete with the ' ...
                        'diagnostic ''opaque-typed input''.  These are arguments declared ' ...
                        'as containers.Map, dictionary, or DOM nodes that the ' ...
                        'autogenerator cannot synthesize from cold.  Phase 12 added ' ...
                        'an in-memory DOM fixture; Phase 14 added an unzipped-Excel ' ...
                        'staging fixture; Phase 15 (candidate 4) added a DOM ' ...
                        'full-fixture smoke gated on the safety check.  Methods whose ' ...
                        'signature still requires a containers.Map / dictionary ' ...
                        'positional argument remain Incomplete.'], ...
                    'AffectedTests',     'See Appendix A inventory; methods with name testSkipped_*.', ...
                    'SeverityRationale', ['Low.  These are autogen-side limitations ' ...
                        'rather than project defects.  Each affected test has a paired ' ...
                        'user-stub in _autotest/user_tests/u<Class>.m::userTest_<method> ' ...
                        'where a domain expert can fill in the real fixture.'], ...
                    'Status',            'Tracked but not a project bug. Resolution path is via the user-stub layer.', ...
                    'Category',          'opaque-typed-input', ...
                    'AffectedMethods',   {{}}); %#ok<AGROW>
            end

            % --- 4. User-stub placeholders (informational) --------------
            stubCount = data.Summary.UserTotal;
            if stubCount > 0
                counter = counter + 1;
                defects(end+1) = struct( ...
                    'Id',                sprintf('%s-%03d', prefix, counter), ...
                    'Severity',          'Informational', ...
                    'Title',             sprintf('User-stub placeholders: %d Incomplete by design', stubCount), ...
                    'Location',          '_autotest/user_tests/u<Class>.m for every class in the system.', ...
                    'Findings',          ['The matlabunittest workflow seeds each public ' ...
                        'function, method, property, and callback with a hand-edit-' ...
                        'friendly userTest_<name> stub starting with ' ...
                        'assumeFail(''TODO: ...'').  Until the user fills these in, they ' ...
                        'report as Incomplete.'], ...
                    'AffectedTests',     'Every user_tests/u<Class>.m file.', ...
                    'SeverityRationale', ['Informational.  The user-stub tree is the ' ...
                        'project owner''s channel for adding domain assertions that ' ...
                        'the scaffolding tier cannot infer.  Filling them in is ' ...
                        'recommended (see Section 8) but no count of unfilled stubs ' ...
                        'constitutes a system failure.'], ...
                    'Status',            'Open. Convert by hand-editing user_tests/u<Class>.m.', ...
                    'Category',          'user-stub', ...
                    'AffectedMethods',   {{}}); %#ok<AGROW>
            end
        end

        % -------------------------------------------------------- helpers
        function grouped = groupByReason(krsEntries)
            grouped = struct();
            for i = 1:numel(krsEntries)
                e = krsEntries(i);
                key = autotest.report.DefectRegister.canonicalKey(e.Reason);
                if ~isfield(grouped, key)
                    grouped.(key) = struct( ...
                        'Reason',   e.Reason, ...
                        'Affected', struct('Class',{},'Method',{}));
                end
                grouped.(key).Affected(end+1) = struct( ...
                    'Class', e.Class, 'Method', e.Method);
            end
        end

        function k = canonicalKey(reason)
            % Crude but stable: take the first 60 chars, stripping
            % parentheticals.
            r = char(reason);
            r = regexprep(r, '\([^)]*\)', '');
            r = regexprep(r, '[^A-Za-z0-9]+', '_');
            r = lower(r);
            if isempty(r), r = 'unknown'; end
            if length(r) > 60, r = r(1:60); end
            % MATLAB struct field names must start with a letter.
            if ~isempty(r) && ~isletter(r(1))
                r = ['x' r];
            end
            k = matlab.lang.makeValidName(r);
        end

        function title = titleFromReason(reason)
            tok = regexp(reason, '([A-Za-z][A-Za-z0-9]*\.[A-Za-z][A-Za-z0-9]*\s+line\s+\d+)', 'tokens', 'once');
            if ~isempty(tok)
                title = sprintf('%s -- real-signal failure', tok{1});
                return;
            end
            % Fallback: first 80 chars of reason.
            r = char(reason);
            if length(r) > 80, r = [r(1:77) '...']; end
            title = r;
        end

        function loc = locationFromReason(reason)
            tok = regexp(reason, '([A-Za-z][A-Za-z0-9]*\.m\s+line\s+\d+)', 'tokens', 'once');
            if ~isempty(tok), loc = tok{1}; return; end
            tok = regexp(reason, '([A-Za-z][A-Za-z0-9]*\.[A-Za-z][A-Za-z0-9]*)', 'tokens', 'once');
            if ~isempty(tok), loc = tok{1}; return; end
            loc = '(see Findings)';
        end

        function findings = findingsFromReason(reason)
            findings = ['Generated tests against this surface report ' ...
                'Incomplete (rather than Failed) because the test '   ...
                'is listed in the project''s _autotest/known_real_signal.txt ' ...
                'accepted-debt manifest with the reason: '];
            findings = [findings '"' char(reason) '". '];
            findings = [findings 'The bug is acknowledged real-signal; ' ...
                'this report tracks it as a defect to remind the project ' ...
                'owner that the test is suppressed and would re-flag the ' ...
                'moment the underlying behaviour changes.'];
        end

        function aff = formatAffectedTests(affected)
            if isempty(affected), aff = '(none)'; return; end
            n = min(8, numel(affected));
            parts = cell(1, n);
            for i = 1:n
                parts{i} = sprintf('%s.%s', affected(i).Class, affected(i).Method);
            end
            aff = strjoin(parts, ', ');
            if numel(affected) > n
                aff = sprintf('%s, +%d more.', aff, numel(affected) - n);
            else
                aff = [aff '.'];
            end
        end

        function sev = severityForReason(reason)
            r = lower(char(reason));
            if contains(r, 'cascade') || contains(r, 'callback') ...
                    || contains(r, 'gui') || contains(r, 'app designer') ...
                    || contains(r, 'sheetstatuschanged')
                sev = 'High';
                return;
            end
            if contains(r, 'phase-6') || contains(r, 'regression') ...
                    || contains(r, 'phase 6')
                sev = 'Low';
                return;
            end
            if contains(r, 'edge') || contains(r, 'empty') ...
                    || contains(r, 'cleanup')
                sev = 'Medium';
                return;
            end
            sev = 'Medium';
        end

        function r = severityRationale(category, reason) %#ok<INUSL>
            r = char(reason);
            if isempty(r)
                r = 'Severity reflects user-visible impact (see Findings).';
                return;
            end
            r = ['Severity reflects the user-visible impact of the ' ...
                'underlying behaviour, defended above in Findings.  ' ...
                'Triage entry kept on the project''s accepted-debt list.'];
        end

        function grouped = groupStateful(tests)
            grouped = struct();
            for i = 1:numel(tests)
                t = tests(i);
                if ~strcmp(t.Status, 'incomplete'), continue; end
                m = char(t.Message);
                if ~contains(lower(m), 'stateful class')
                    continue;
                end
                key = matlab.lang.makeValidName(t.Class);
                if ~isfield(grouped, key)
                    grouped.(key) = {};
                end
                grouped.(key){end+1} = t.Method;
            end
        end

        function n = countOpaque(tests)
            n = 0;
            for i = 1:numel(tests)
                t = tests(i);
                if strcmp(t.Status, 'incomplete') && contains(lower(t.Message), 'opaque-typed')
                    n = n + 1;
                end
            end
        end

        function aff = briefAffectedList(cls, methods_)
            n = min(6, numel(methods_));
            parts = cell(1, n);
            for i = 1:n
                parts{i} = sprintf('%s.%s', cls, methods_{i});
            end
            aff = strjoin(parts, ', ');
            if numel(methods_) > n
                aff = sprintf('%s, +%d more.', aff, numel(methods_) - n);
            else
                aff = [aff '.'];
            end
        end

        function grouped = groupStatefulByCluster(tests)
            %GROUPSTATEFULBYCLUSTER  Phase 16 Part B item 5.
            %   Cluster Incomplete tests by class AND message signature.
            %   Returns a nested struct:
            %     grouped.(clsKey).(sigKey) = struct array {Method, Message}
            grouped = struct();
            for i = 1:numel(tests)
                t = tests(i);
                if ~strcmp(t.Status, 'incomplete'), continue; end
                msg = char(t.Message);
                if ~contains(lower(msg), 'stateful class')
                    continue;
                end
                clsKey = matlab.lang.makeValidName(t.Class);
                sig = autotest.report.DefectRegister.clusterSignature(msg);
                sigKey = matlab.lang.makeValidName(['c_' sig]);
                if length(sigKey) > 50, sigKey = sigKey(1:50); end
                if ~isfield(grouped, clsKey)
                    grouped.(clsKey) = struct();
                end
                if ~isfield(grouped.(clsKey), sigKey)
                    grouped.(clsKey).(sigKey) = struct('Method', {}, 'Message', {});
                end
                grouped.(clsKey).(sigKey)(end+1) = struct( ...
                    'Method', t.Method, 'Message', msg); %#ok<AGROW>
            end
        end

        function sig = clusterSignature(msg)
            %CLUSTERSIGNATURE  Extract a stable cluster key from a diagnostic.
            %   The wrapped message format is:
            %     "<method> smoke threw (stateful class, prelude
            %     best-effort): <real-error>"
            %   We strip the wrapper preface, normalise quoted literals
            %   and numbers to placeholders, and lowercase the first 60
            %   chars of the result.  Tests with the same underlying
            %   root error cluster together; method-name churn does not
            %   force a new cluster.
            sig = 'unknown';
            if isempty(msg), return; end
            m = char(msg);
            idx = strfind(m, 'best-effort): ');
            if ~isempty(idx)
                m = m(idx(1)+length('best-effort): '):end);
            end
            m = regexprep(m, '''[^'']*''', 'X');
            m = regexprep(m, '"[^"]*"', 'X');
            m = regexprep(m, '\d+', 'N');
            m = regexprep(m, '\s+', ' ');
            m = lower(strtrim(m));
            if isempty(m), m = 'unknown'; return; end
            if length(m) > 60, m = m(1:60); end
            sig = m;
        end

        function clsName = demangleStruct(safeClassName)
            %DEMANGLESTRUCT  Round-trip from a struct field key to the class name.
            %   matlab.lang.makeValidName is largely identity for typical
            %   class names (tExcelProcessor etc.); this is a stub for
            %   future fidelity if a class name happens to need escaping.
            clsName = safeClassName;
        end

        function msg = mostCommonMessage(clusterEntries)
            %MOSTCOMMONMESSAGE  Phase 16 Part B item 5.
            %   Return the message that appears most often in the cluster.
            %   Ties broken by appearance order.
            msg = '';
            if isempty(clusterEntries), return; end
            msgs = {clusterEntries.Message};
            counts = zeros(1, numel(msgs));
            for i = 1:numel(msgs)
                counts(i) = sum(strcmp(msgs, msgs{i}));
            end
            [~, idx] = max(counts);
            msg = char(msgs{idx});
        end

        function suffix = titleSuffixFromMessage(message)
            %TITLESUFFIXFROMMESSAGE  Pull a short cluster discriminator.
            suffix = '';
            if isempty(message), return; end
            m = char(message);
            tok = regexp(m, '(MATLAB:[A-Za-z][\w:]*)', 'tokens', 'once');
            if ~isempty(tok)
                s = tok{1};
                parts = regexp(s, ':', 'split');
                suffix = parts{end};
                return;
            end
            idx = strfind(m, 'best-effort): ');
            rest = m;
            if ~isempty(idx)
                rest = m(idx(1)+length('best-effort): '):end);
            end
            rest = strtrim(rest);
            if isempty(rest), return; end
            words = regexp(rest, '\s+', 'split');
            n = min(4, numel(words));
            suffix = strjoin(words(1:n), ' ');
            if length(suffix) > 50, suffix = [suffix(1:47) '...']; end
        end

        function txt = userStubMitigation(clsName, methods_)
            %USERSTUBMITIGATION  Phase 16 Part B item 5.
            %   Explicit RR-NNN -> Mitigation Path mapping.  Points the
            %   project owner at the user-stub file path for each
            %   affected method.
            if isempty(methods_)
                txt = 'Open. No methods recorded for this cluster.';
                return;
            end
            base = regexprep(clsName, '^t', '', 'once');
            relPath = ['_autotest/user_tests/u' base '.m'];
            n = min(6, numel(methods_));
            parts = cell(1, n);
            for i = 1:n
                parts{i} = sprintf('%s::userTest_%s', relPath, methods_{i});
            end
            extra = '';
            if numel(methods_) > n
                extra = sprintf(' of %d', numel(methods_));
            end
            txt = sprintf( ...
                ['Open.  Mitigation Path: edit %s to replace assumeFail ' ...
                 'with real verify*/assert* assertions.  Affected stubs ' ...
                 '(first %d shown%s): %s.'], ...
                relPath, n, extra, strjoin(parts, '; '));
        end
    end
end
