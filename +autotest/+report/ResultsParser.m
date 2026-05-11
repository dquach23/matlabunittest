classdef ResultsParser
    %RESULTSPARSER  Phase 15 -- read autotest reports/ artefacts into a struct.
    %
    %   data = autotest.report.ResultsParser.parse(folder)
    %
    %   Inputs:
    %       FOLDER  - the project folder (its <folder>/_autotest/reports/
    %                 directory is read).
    %
    %   Output (struct DATA) fields:
    %       Summary    -- counts (gen total/passed/failed/incomplete,
    %                     user_total, total, duration_s, timestamp)
    %       PerSource  -- struct array {File, Passed, Total, Failed,
    %                     Incomplete}, one per emitted source.
    %       Tests      -- struct array {Class, Method, Status, DurationS,
    %                     Message}, one per testcase in results.xml.
    %       Totals     -- {Passed, Failed, Incomplete, SuiteCount,
    %                     TotalDurationS}.
    %       KnownRealSignal -- struct array {Class, Method, Reason},
    %                     parsed from <folder>/_autotest/known_real_signal.txt
    %                     when present.
    %
    %   Generic across MATLAB projects: only the standard autotest
    %   output layout is consulted.

    methods (Static)
        function data = parse(folder)
            arguments
                folder (1,:) char
            end
            outRoot     = fullfile(folder, '_autotest');
            reportsDir  = fullfile(outRoot, 'reports');
            summaryFile = fullfile(reportsDir, 'summary.txt');
            xmlFile     = fullfile(reportsDir, 'results.xml');
            krsFile     = fullfile(outRoot, 'known_real_signal.txt');

            data = struct( ...
                'Summary',         struct(), ...
                'PerSource',       struct('File',{},'Passed',{},'Total',{},'Failed',{},'Incomplete',{}), ...
                'Tests',           struct('Class',{},'Method',{},'Status',{},'DurationS',{},'Message',{}), ...
                'Totals',          struct(), ...
                'KnownRealSignal', struct('Class',{},'Method',{},'Reason',{}));

            % --- summary.txt ------------------------------------------------
            data.Summary = autotest.report.ResultsParser.parseSummary(summaryFile);
            % --- results.xml ------------------------------------------------
            data.Tests = autotest.report.ResultsParser.parseResultsXml(xmlFile);
            % --- per-source breakdown (also from summary.txt) --------------
            data.PerSource = autotest.report.ResultsParser.parsePerSource(summaryFile);
            % --- known_real_signal.txt -------------------------------------
            data.KnownRealSignal = autotest.report.ResultsParser.parseKnownRealSignal(krsFile);
            % --- totals -----------------------------------------------------
            data.Totals = autotest.report.ResultsParser.computeTotals(data.Tests);
        end

        function summary = parseSummary(summaryFile)
            summary = struct( ...
                'Timestamp',         '', ...
                'SourcesScanned',    0, ...
                'GenTotal',          0, ...
                'GenPassed',         0, ...
                'GenFailed',         0, ...
                'GenIncomplete',     0, ...
                'UserTotal',         0, ...
                'Total',             0, ...
                'DurationS',         0);
            if ~isfile(summaryFile), return; end
            text = fileread(summaryFile);
            tok = regexp(text, 'Sources scanned:\s+(\d+)', 'tokens', 'once');
            if ~isempty(tok), summary.SourcesScanned = str2double(tok{1}); end
            tok = regexp(text, 'Generated tests:\s+(\d+)', 'tokens', 'once');
            if ~isempty(tok), summary.GenTotal = str2double(tok{1}); end
            tok = regexp(text, 'Generated tests:\s+\d+\s*\n\s*passed:\s+(\d+)', 'tokens', 'once');
            if ~isempty(tok), summary.GenPassed = str2double(tok{1}); end
            tok = regexp(text, 'Generated tests:[^\n]*\n\s*passed:[^\n]*\n\s*failed:\s+(\d+)', 'tokens', 'once');
            if ~isempty(tok), summary.GenFailed = str2double(tok{1}); end
            tok = regexp(text, 'Generated tests:[^\n]*\n[^\n]*\n[^\n]*\n\s*incomplete:\s+(\d+)', 'tokens', 'once');
            if ~isempty(tok), summary.GenIncomplete = str2double(tok{1}); end
            tok = regexp(text, 'User stub tests:\s+(\d+)', 'tokens', 'once');
            if ~isempty(tok), summary.UserTotal = str2double(tok{1}); end
            tok = regexp(text, 'Total tests:\s+(\d+)', 'tokens', 'once');
            if ~isempty(tok), summary.Total = str2double(tok{1}); end
            tok = regexp(text, 'Duration:\s+([\d.]+)\s*s', 'tokens', 'once');
            if ~isempty(tok), summary.DurationS = str2double(tok{1}); end
            tok = regexp(text, 'Timestamp:\s+(\S+)', 'tokens', 'once');
            if ~isempty(tok), summary.Timestamp = tok{1}; end
        end

        function perSrc = parsePerSource(summaryFile)
            perSrc = struct('File',{},'Passed',{},'Total',{},'Failed',{},'Incomplete',{});
            if ~isfile(summaryFile), return; end
            text = fileread(summaryFile);
            tokens = regexp(text, ...
                '\[gen\]\s+(\S+?\.(?:m|mlapp))\s+\(passed\s+(\d+)/(\d+),\s+failed\s+(\d+)\)', ...
                'tokens');
            for i = 1:numel(tokens)
                file = strrep(tokens{i}{1}, '\', '/');
                passed = str2double(tokens{i}{2});
                total  = str2double(tokens{i}{3});
                failed = str2double(tokens{i}{4});
                inc    = total - passed - failed;
                perSrc(end+1) = struct('File', file, ...
                    'Passed', passed, 'Total', total, ...
                    'Failed', failed, 'Incomplete', inc); %#ok<AGROW>
            end
        end

        function tests = parseResultsXml(xmlFile)
            tests = struct('Class',{},'Method',{},'Status',{},'DurationS',{},'Message',{});
            if ~isfile(xmlFile), return; end
            try
                doc = xmlread(xmlFile);
            catch
                return;
            end
            suites = doc.getElementsByTagName('testsuite');
            for i = 0:suites.getLength()-1
                suite = suites.item(i);
                clsName = char(suite.getAttribute('name'));
                cases = suite.getElementsByTagName('testcase');
                for j = 0:cases.getLength()-1
                    tc = cases.item(j);
                    name = char(tc.getAttribute('name'));
                    timeStr = char(tc.getAttribute('time'));
                    if isempty(timeStr), durS = 0;
                    else, durS = str2double(timeStr); end
                    if isnan(durS), durS = 0; end
                    [status, msg] = autotest.report.ResultsParser.classifyTestcase(tc);
                    tests(end+1) = struct( ...
                        'Class',     clsName, ...
                        'Method',    name, ...
                        'Status',    status, ...
                        'DurationS', durS, ...
                        'Message',   msg); %#ok<AGROW>
                end
            end
        end

        function [status, msg] = classifyTestcase(tc)
            % Failure / error / skipped child element (if any).
            failures = tc.getElementsByTagName('failure');
            errors   = tc.getElementsByTagName('error');
            skips    = tc.getElementsByTagName('skipped');
            if failures.getLength() > 0
                status = 'failed';
                msg = strtrim(char(failures.item(0).getTextContent()));
                return;
            elseif errors.getLength() > 0
                status = 'failed';
                msg = strtrim(char(errors.item(0).getTextContent()));
                return;
            elseif skips.getLength() > 0
                status = 'incomplete';
                msg = strtrim(char(skips.item(0).getTextContent()));
                return;
            end
            status = 'passed';
            msg = '';
        end

        function entries = parseKnownRealSignal(krsFile)
            entries = struct('Class',{},'Method',{},'Reason',{});
            if ~isfile(krsFile), return; end
            text = fileread(krsFile);
            lines = strsplit(text, newline);
            for i = 1:numel(lines)
                ln = strtrim(lines{i});
                if isempty(ln) || ln(1) == '#', continue; end
                tok = regexp(ln, '^(t\w+)\.(test\w+):\s*(.+)$', 'tokens', 'once');
                if isempty(tok), continue; end
                entries(end+1) = struct( ...
                    'Class', tok{1}, ...
                    'Method', tok{2}, ...
                    'Reason', tok{3}); %#ok<AGROW>
            end
        end

        function totals = computeTotals(tests)
            totals = struct( ...
                'Passed',         0, ...
                'Failed',         0, ...
                'Incomplete',     0, ...
                'SuiteCount',     0, ...
                'TotalDurationS', 0);
            if isempty(tests), return; end
            totals.Passed     = sum(strcmp({tests.Status}, 'passed'));
            totals.Failed     = sum(strcmp({tests.Status}, 'failed'));
            totals.Incomplete = sum(strcmp({tests.Status}, 'incomplete'));
            totals.SuiteCount = numel(unique({tests.Class}));
            totals.TotalDurationS = round(sum([tests.DurationS]), 2);
        end
    end
end
