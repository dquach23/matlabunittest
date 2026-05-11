classdef FailureExplainer
    %FAILUREEXPLAINER  v1.6 -- pattern-match a MATLAB error to a plain-English explanation.
    %
    %   [explanation, identifier, message, stack] = ...
    %       autotest.report.FailureExplainer.explain(test)
    %
    %   Input:
    %       TEST -- a Tests(i) struct from ResultsParser:
    %               {Class, Method, Status, DurationS, Message}.
    %               Message carries the JUnit failure / error CDATA.
    %
    %   Outputs:
    %       EXPLANATION -- a 1-2 sentence plain-English explanation of
    %                      the failure plus a 1-sentence "Likely fix:"
    %                      hint, or '' when the identifier doesn't match
    %                      a known pattern.
    %       IDENTIFIER  -- MATLAB error identifier extracted from the
    %                      diagnostic body, e.g.
    %                      'MATLAB:dictionary:UnconfiguredLookupNotSupported'.
    %       MESSAGE     -- the trimmed first-paragraph diagnostic.
    %       STACK       -- cellstr of stack frames (top to bottom),
    %                      truncated to ~3 entries and ~100 chars per
    %                      line; suitable for inline table rendering.
    %
    %   The known-pattern table is intentionally small and generic; we
    %   prefer "no explanation" over a confident-but-wrong one, and the
    %   appendix renders unrecognised errors with their identifier +
    %   message verbatim and a "Cause not classified" note.

    methods (Static)
        function [explanation, identifier, message, stack] = explain(test)
            arguments
                test struct
            end
            raw = '';
            if isfield(test, 'Message') && ~isempty(test.Message)
                raw = char(test.Message);
            end
            % --- Identifier extraction --------------------------------
            identifier = autotest.report.FailureExplainer.extractIdentifier(raw);
            % --- Headline message extraction -------------------------
            message = autotest.report.FailureExplainer.extractMessage(raw);
            % --- Stack excerpt ---------------------------------------
            stack = autotest.report.FailureExplainer.extractStack(raw);
            % --- Pattern-match against the known-error table ---------
            explanation = autotest.report.FailureExplainer.lookup( ...
                identifier, message);
        end

        function out = lookup(identifier, message)
            %LOOKUP  Known-pattern table.  Add entries as new error
            %   families are observed in autogen test runs.  Each entry
            %   pairs an identifier pattern (regex) with a 1-2 sentence
            %   explanation plus a "Likely fix:" hint.  Order matters:
            %   earlier entries win, so specific patterns must come
            %   before generic catchalls.
            ident = char(identifier);
            msg   = char(message);
            out = '';
            patterns = autotest.report.FailureExplainer.knownPatterns();
            for i = 1:size(patterns, 1)
                idRe   = patterns{i, 1};
                msgRe  = patterns{i, 2};
                text   = patterns{i, 3};
                idHit  = isempty(idRe)  || ~isempty(regexp(ident, idRe,  'once'));
                msgHit = isempty(msgRe) || ~isempty(regexp(msg,   msgRe, 'once', 'ignorecase'));
                if idHit && msgHit
                    out = text;
                    return;
                end
            end
        end

        function rows = knownPatterns()
            %KNOWNPATTERNS  v1.6 starter table: 6 families.
            %   {identifierRegex, messageRegex, plainEnglish}
            rows = { ...
                'MATLAB:dictionary:UnconfiguredLookupNotSupported', '', ...
                ['The test exercised a code path that calls isKey / lookup ' ...
                 'on a dictionary instance before it has been configured ' ...
                 'with key/value types.  Per MATLAB R2022b+, dictionaries ' ...
                 'require explicit type configuration via configureDictionary ' ...
                 'or an initial typed assignment before lookup operations.  ' ...
                 'Likely fix: initialise the dictionary with a typed empty ' ...
                 'literal (e.g. d = configureDictionary("string","double")) ' ...
                 'at object construction, or seed-and-clear an entry to ' ...
                 'lock the key/value types before the first lookup.'];

                'MATLAB:nonLogicalConditional', '', ...
                ['The code branched on a value that was not logical or ' ...
                 'numeric -- typically a string, dictionary handle, or DOM ' ...
                 'node passed where the if/while expected a boolean.  Likely ' ...
                 'fix: wrap the condition in isempty/isequal/strcmp or cast ' ...
                 'explicitly to logical at the boundary.'];

                'MATLAB:UndefinedFunction', '', ...
                ['MATLAB could not resolve a function or method call.  ' ...
                 'Common causes: a sibling source file is not on the path ' ...
                 'when the test runs; the method is private but called from ' ...
                 'outside the class; the call uses a typo or an old name.  ' ...
                 'Likely fix: add the missing folder to the path in the ' ...
                 'test setup, or confirm the method exists at the spelling ' ...
                 'used in the call.'];

                'MATLAB:validators:.*', '', ...
                ['An arguments-block validator rejected the synthetic input ' ...
                 'the autogen passed in.  This is signal that the validator ' ...
                 'is doing its job; the autogen could not synthesise an ' ...
                 'argument satisfying the constraint.  Likely fix: add a ' ...
                 'hand-written user_tests stub for this method that passes ' ...
                 'a domain-appropriate value, or relax the validator if it ' ...
                 'is over-restrictive.'];

                'MATLAB:fileread:cannotOpenFile', '', ...
                ['The code under test tried to fileread a path that did not ' ...
                 'exist or was not readable.  Common causes: the path is ' ...
                 'pwd-relative and the test runner is in a different cwd; a ' ...
                 'fixture file was not staged into the temp directory.  ' ...
                 'Likely fix: resolve paths via fullfile + an explicit base ' ...
                 'directory, and stage the fixture in the TestMethodSetup ' ...
                 'prelude.'];

                '', '(?i)Out of memory', ...
                ['The code under test ran the host MATLAB out of memory.  ' ...
                 'Common causes on autogen: a randomised vector size that ' ...
                 'grew unbounded; a smoke test that piped a synthetic input ' ...
                 'into a quadratic-time inner loop.  Likely fix: bound the ' ...
                 'input size at the validator level, or hand-write a stub ' ...
                 'in user_tests with a realistic upper bound.']};
        end

        function id = extractIdentifier(raw)
            %EXTRACTIDENTIFIER  Pull "MATLAB:..." identifier from raw diagnostic.
            id = '';
            % Look for "Error ID: ... 'MATLAB:foo:Bar'" or "Error using ..."
            % shape, then a bare MATLAB:... token.
            tok = regexp(raw, '''(MATLAB:[A-Za-z0-9_:]+)''', 'tokens', 'once');
            if isempty(tok)
                tok = regexp(raw, '\b(MATLAB:[A-Za-z0-9_:]+)\b', 'tokens', 'once');
            end
            if ~isempty(tok)
                id = char(tok{1});
            end
        end

        function msg = extractMessage(raw)
            %EXTRACTMESSAGE  Pull the first non-empty error-text paragraph.
            msg = '';
            % Strip JUnit boilerplate ("Error occurred in ... and it did
            % not run to completion.") so the actual error sentence lands
            % in the headline.
            cleaned = regexprep(raw, ...
                'Error occurred in [^\n]+ and it did not run to completion\.', '');
            cleaned = regexprep(cleaned, ...
                'An assumption was not met in [^\n]+\.', '');
            lines = strsplit(cleaned, char(10));
            for i = 1:numel(lines)
                ln = strtrim(lines{i});
                if isempty(ln), continue; end
                if startsWith(ln, '-') || startsWith(ln, 'Error ID')
                    continue;
                end
                if startsWith(ln, 'Error using ')
                    continue;
                end
                if length(ln) > 200, ln = [ln(1:200) '...']; end
                msg = ln;
                return;
            end
        end

        function frames = extractStack(raw)
            %EXTRACTSTACK  Cellstr of top-3 stack frames (truncated).
            frames = {};
            % Match "Error in <fn> (line N)" or "In <path>... at NN".
            re = '(?:Error in|In)\s+([^\n]+?)(?:\s+at\s+\d+)?\s*\n';
            tokens = regexp(raw, re, 'tokens');
            cap = 3;
            for i = 1:min(cap, numel(tokens))
                ln = strtrim(char(tokens{i}{1}));
                if length(ln) > 100, ln = [ln(1:100) '...']; end
                frames{end+1} = ln; %#ok<AGROW>
            end
        end
    end
end
