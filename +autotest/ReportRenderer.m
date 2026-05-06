classdef ReportRenderer
%AUTOTEST.REPORTRENDERER  Render workflow results to HTML, Markdown, PDF.
%
%   autotest.ReportRenderer.renderAll(INFO) writes report.html, report.md
%   and (best-effort) report.pdf into INFO.ReportsDir.  INFO is the struct
%   returned by AUTOTEST.RUNWORKFLOW.
%
%   The HTML report is fully self-contained: CSS lives inline in a <style>
%   block, the bar chart is pure inline SVG, and there is no JavaScript or
%   external network dependency.  The Markdown report mirrors the same
%   content using GitHub-style summary tables.  The PDF is produced via
%   one of three fallbacks, in order of preference:
%
%     1. mlreportgen.dom (Report Generator toolbox), if present
%     2. uifigure + uihtml + exportapp on the rendered HTML
%     3. plain figure with annotation textboxes + print(-dpdf)
%
%   Each strategy is tried in turn; failures are caught and the next
%   strategy is attempted.  If all strategies fail, a warning line is
%   appended to <LogsDir>/report-pdf.log and renderAll still returns.
%
%   See also: AUTOTEST.RUNWORKFLOW.

    methods (Static)

        function renderAll(info)
            % Top-level dispatcher.  Always writes HTML and Markdown;
            % attempts the PDF cascade and logs any final failure.
            if ~isfield(info, 'ReportsDir') || isempty(info.ReportsDir)
                error('autotest:ReportRenderer:BadInfo', ...
                    'INFO.ReportsDir is required.');
            end
            if ~isfolder(info.ReportsDir)
                mkdir(info.ReportsDir);
            end

            data = autotest.ReportRenderer.collectViewModel(info);

            htmlPath = fullfile(info.ReportsDir, 'report.html');
            mdPath   = fullfile(info.ReportsDir, 'report.md');
            pdfPath  = fullfile(info.ReportsDir, 'report.pdf');

            try
                autotest.ReportRenderer.writeHtml(htmlPath, data);
            catch ME
                warning('autotest:ReportRenderer:Html', ...
                    'Failed to write %s: %s', htmlPath, ME.message);
            end

            try
                autotest.ReportRenderer.writeMarkdown(mdPath, data);
            catch ME
                warning('autotest:ReportRenderer:Md', ...
                    'Failed to write %s: %s', mdPath, ME.message);
            end

            autotest.ReportRenderer.writePdf(pdfPath, htmlPath, data, info);
        end

    end

    % =====================================================================
    % View model + per-format writers
    % =====================================================================
    methods (Static, Access = private)

        function data = collectViewModel(info)
            % Reduce INFO to a denormalised struct that the writers can
            % consume without touching the original results array again.
            [~, projName] = fileparts(autotest.ReportRenderer.getf(info, 'Folder', ''));
            if isempty(projName)
                projName = '(unknown project)';
            end

            sources = autotest.ReportRenderer.getf(info, 'Sources', struct([]));
            results = autotest.ReportRenderer.getf(info, 'Results', []);
            summary = autotest.ReportRenderer.getf(info, 'Summary', ...
                struct('Total', 0, 'Passed', 0, 'Failed', 0, ...
                       'Incomplete', 0, 'DurationSeconds', 0));
            genErrs = autotest.ReportRenderer.getf(info, 'GenerationErrors', {});

            % Sort sources alphabetically by RelPath for stable output.
            if ~isempty(sources)
                rels = {sources.RelPath};
                [~, idx] = sort(lower(rels));
                sources = sources(idx);
            end

            % Group results by class (everything before first '/').
            groups = autotest.ReportRenderer.groupResults(results);

            % Per-source statistics, keyed by the generated test class name.
            srcRows = autotest.ReportRenderer.buildSourceRows(sources, groups);

            % Status banner classification.
            % Phase 2.1: prefer the generated-only counts when the summary
            % carries them, so the headline reflects what the generator
            % actually exercised vs. the user-stub Incompletes (which are
            % "awaiting implementation", not "broken").
            getf2 = @autotest.ReportRenderer.getf;
            hasSplit = isfield(summary, 'GeneratedTotal');
            if hasSplit
                hTotal      = getf2(summary, 'GeneratedTotal',      summary.Total);
                hPassed     = getf2(summary, 'GeneratedPassed',     summary.Passed);
                hFailed     = getf2(summary, 'GeneratedFailed',     summary.Failed);
                hIncomplete = getf2(summary, 'GeneratedIncomplete', summary.Incomplete);
                userStub    = getf2(summary, 'UserStubTotal',       0);
            else
                hTotal      = summary.Total;
                hPassed     = summary.Passed;
                hFailed     = summary.Failed;
                hIncomplete = summary.Incomplete;
                userStub    = 0;
            end
            if hFailed > 0
                bClass = 'banner-bad';
                bText  = sprintf('%d of %d generated test%s passed (%d failed, %d incomplete)', ...
                    hPassed, hTotal, ...
                    autotest.ReportRenderer.iif(hTotal == 1, '', 's'), ...
                    hFailed, hIncomplete);
            elseif hIncomplete > 0
                bClass = 'banner-warn';
                bText  = sprintf('%d of %d generated test%s passed (%d incomplete)', ...
                    hPassed, hTotal, ...
                    autotest.ReportRenderer.iif(hTotal == 1, '', 's'), ...
                    hIncomplete);
            elseif hTotal == 0
                bClass = 'banner-warn';
                bText  = 'No generated tests were executed';
            else
                bClass = 'banner-good';
                bText  = sprintf('All %d generated test%s passed', hTotal, ...
                    autotest.ReportRenderer.iif(hTotal == 1, '', 's'));
            end
            if userStub > 0
                stubText = sprintf('%d user-written test stub%s await%s implementation', ...
                    userStub, ...
                    autotest.ReportRenderer.iif(userStub == 1, '', 's'), ...
                    autotest.ReportRenderer.iif(userStub == 1, 's', ''));
            else
                stubText = '';
            end
            banner = struct('class', bClass, 'text', bText, ...
                'StubText', stubText, ...
                'GeneratedTotal',      hTotal, ...
                'GeneratedPassed',     hPassed, ...
                'GeneratedFailed',     hFailed, ...
                'GeneratedIncomplete', hIncomplete, ...
                'UserStubTotal',       userStub);

            data = struct( ...
                'ProjectName', projName, ...
                'Folder',      autotest.ReportRenderer.getf(info, 'Folder', ''), ...
                'OutputRoot',  autotest.ReportRenderer.getf(info, 'OutputRoot', ''), ...
                'Timestamp',   autotest.ReportRenderer.getf(info, 'Timestamp', ''), ...
                'LogFile',     autotest.ReportRenderer.getf(info, 'LogFile', ''), ...
                'Summary',     summary, ...
                'Banner',      banner, ...
                'SourceRows',  {srcRows}, ...
                'Groups',      {groups}, ...
                'GenErrors',   {cellstr(genErrs)});
        end

        function groups = groupResults(results)
            % Returns a cell array of struct('Class', char, 'Tests', ...)
            % where Tests is a struct array sorted by name.
            groups = {};
            if isempty(results)
                return
            end
            classNames = cell(numel(results), 1);
            methodNames = cell(numel(results), 1);
            for i = 1:numel(results)
                nm = results(i).Name;
                slash = find(nm == '/', 1, 'first');
                if isempty(slash)
                    classNames{i}  = '(unbound)';
                    methodNames{i} = nm;
                else
                    classNames{i}  = nm(1:slash-1);
                    methodNames{i} = nm(slash+1:end);
                end
            end
            uniq = unique(classNames);
            uniq = sort(uniq);
            groups = cell(numel(uniq), 1);
            for k = 1:numel(uniq)
                cn = uniq{k};
                mask = strcmp(classNames, cn);
                idx = find(mask);
                tests = repmat(struct('Name', '', 'Status', '', ...
                    'DurationMs', 0, 'Diagnostic', ''), 0, 1);
                for j = 1:numel(idx)
                    r = results(idx(j));
                    if r.Passed
                        st = 'pass';
                    elseif r.Failed
                        st = 'fail';
                    elseif r.Incomplete
                        st = 'incomplete';
                    else
                        st = 'unknown';
                    end
                    diag = '';
                    if ~r.Passed
                        diag = autotest.ReportRenderer.extractDiagnostic(r);
                    end
                    tests(end+1, 1) = struct( ...
                        'Name',       methodNames{idx(j)}, ...
                        'Status',     st, ...
                        'DurationMs', r.Duration * 1000, ...
                        'Diagnostic', diag); %#ok<AGROW>
                end
                % Sort tests by name within the class.
                if ~isempty(tests)
                    [~, ord] = sort(lower({tests.Name}));
                    tests = tests(ord);
                end
                groups{k} = struct('Class', cn, 'Tests', tests);
            end
        end

        function txt = extractDiagnostic(r)
            % Best-effort retrieval of the diagnostic report.  The
            % Details.DiagnosticRecord shape varies across MATLAB
            % releases, so we wrap every step.
            txt = '';
            try
                d = r.Details;
            catch
                d = struct();
            end
            rec = [];
            try
                if isfield(d, 'DiagnosticRecord') || isprop(d, 'DiagnosticRecord')
                    rec = d.DiagnosticRecord;
                end
            catch
                rec = [];
            end
            if ~isempty(rec)
                chunks = strings(0, 1);
                for k = 1:numel(rec)
                    try
                        chunks(end+1, 1) = string(rec(k).Report); %#ok<AGROW>
                    catch
                        try
                            chunks(end+1, 1) = string(getReport(rec(k))); %#ok<AGROW>
                        catch
                            % give up on this record
                        end
                    end
                end
                if ~isempty(chunks)
                    txt = char(strjoin(chunks, newline + "" + newline));
                    return
                end
            end

            % Phase 2.4 fallback: assumption-filtered tests (assumeFail)
            % don't populate Details.DiagnosticRecord, so the renderer
            % otherwise has nothing to show.  Reach into the generated
            % test class source and extract the literal assumeFail
            % message -- that's the testSkipped_<name> reason text the
            % autogenerator wrote, including the per-class
            % StatefulReason and the user_tests/u<Class>.m::userTest_<m>
            % pointer.
            try
                nm = char(r.Name);
            catch
                return
            end
            slash = strfind(nm, '/');
            if isempty(slash), return; end
            cls  = nm(1:slash(1)-1);
            mthd = nm(slash(1)+1:end);
            srcPath = which(cls);
            if isempty(srcPath) || ~exist(srcPath, 'file')
                return
            end
            try
                fid = fopen(srcPath, 'r');
                if fid < 0, return; end
                cleaner = onCleanup(@() fclose(fid));
                src = fread(fid, '*char').';
            catch
                return
            end
            pat = ['function\s+' regexptranslate('escape', mthd) ...
                '\s*\(\s*\w+\s*\)([\s\S]*?)\n\s*end'];
            body = regexp(src, pat, 'tokens', 'once');
            if isempty(body), return; end
            msg = regexp(body{1}, ...
                'assumeFail\s*\(\s*''((?:[^'']|'''')*)''\s*\)', ...
                'tokens', 'once');
            if isempty(msg), return; end
            txt = strrep(msg{1}, '''''', '''');
        end

        function rows = buildSourceRows(sources, groups)
            % Compose per-source rows: stats come from matching groups
            % whose Class equals the basename of GeneratedTest.
            rows = repmat(struct('RelPath', '', 'Kind', '', ...
                'Generated', false, 'Total', 0, 'Passed', 0, ...
                'Failed', 0, 'Incomplete', 0, 'Error', ''), 0, 1);
            for i = 1:numel(sources)
                s = sources(i);
                stats = struct('Total', 0, 'Passed', 0, ...
                    'Failed', 0, 'Incomplete', 0);
                if s.Generated && ~isempty(s.GeneratedTest)
                    [~, cls] = fileparts(s.GeneratedTest);
                    for k = 1:numel(groups)
                        if strcmp(groups{k}.Class, cls)
                            t = groups{k}.Tests;
                            stats.Total      = numel(t);
                            stats.Passed     = sum(strcmp({t.Status}, 'pass'));
                            stats.Failed     = sum(strcmp({t.Status}, 'fail'));
                            stats.Incomplete = sum(strcmp({t.Status}, 'incomplete'));
                            break
                        end
                    end
                end
                rows(end+1, 1) = struct( ...
                    'RelPath',    s.RelPath, ...
                    'Kind',       s.Kind, ...
                    'Generated',  logical(s.Generated), ...
                    'Total',      stats.Total, ...
                    'Passed',     stats.Passed, ...
                    'Failed',     stats.Failed, ...
                    'Incomplete', stats.Incomplete, ...
                    'Error',      s.Error); %#ok<AGROW>
            end
        end

        % -----------------------------------------------------------------
        % HTML
        % -----------------------------------------------------------------
        function writeHtml(path, data)
            esc = @autotest.ReportRenderer.htmlEscape;
            fmtDur = @autotest.ReportRenderer.formatDuration;

            lines = strings(0, 1);
            lines(end+1, 1) = "<!DOCTYPE html>";
            lines(end+1, 1) = "<html lang=""en"">";
            lines(end+1, 1) = "<head>";
            lines(end+1, 1) = "<meta charset=""utf-8"">";
            lines(end+1, 1) = "<title>autotest report - " + esc(data.ProjectName) + "</title>";
            lines(end+1, 1) = "<style>";
            lines(end+1, 1) = autotest.ReportRenderer.htmlStyles();
            lines(end+1, 1) = "</style>";
            lines(end+1, 1) = "</head>";
            lines(end+1, 1) = "<body>";

            % Header
            lines(end+1, 1) = "<header>";
            lines(end+1, 1) = "  <h1>" + esc(data.ProjectName) + "</h1>";
            lines(end+1, 1) = "  <div class=""subtitle"">autotest run &middot; " + ...
                esc(data.Timestamp) + "</div>";
            lines(end+1, 1) = "  <div class=""folder"">" + esc(data.Folder) + "</div>";
            lines(end+1, 1) = "</header>";

            % Banner
            lines(end+1, 1) = "<div class=""banner " + esc(data.Banner.class) + """>" + ...
                esc(data.Banner.text) + "</div>";
            % Phase 2.1: user-stub sub-banner.
            if isfield(data.Banner, 'StubText') && ~isempty(data.Banner.StubText)
                lines(end+1, 1) = "<div class=""banner banner-info"">" + ...
                    esc(data.Banner.StubText) + ...
                    " &mdash; fill in <code>user_tests/u&lt;Name&gt;.m</code> to enable.</div>";
            end

            % Summary cards (generated-only counts; user stubs are tracked
            % separately so they don't drag the headline numbers).
            s = data.Summary;
            b = data.Banner;
            lines(end+1, 1) = "<section class=""cards"">";
            lines(end+1, 1) = autotest.ReportRenderer.cardHtml('Generated',  sprintf('%d', b.GeneratedTotal),      'card-total');
            lines(end+1, 1) = autotest.ReportRenderer.cardHtml('Passed',     sprintf('%d', b.GeneratedPassed),     'card-pass');
            lines(end+1, 1) = autotest.ReportRenderer.cardHtml('Failed',     sprintf('%d', b.GeneratedFailed),     'card-fail');
            lines(end+1, 1) = autotest.ReportRenderer.cardHtml('Incomplete', sprintf('%d', b.GeneratedIncomplete), 'card-warn');
            lines(end+1, 1) = autotest.ReportRenderer.cardHtml('User stubs', sprintf('%d', b.UserStubTotal),       'card-info');
            lines(end+1, 1) = autotest.ReportRenderer.cardHtml('Duration',   fmtDur(s.DurationSeconds * 1000),     'card-time');
            lines(end+1, 1) = "</section>";

            % SVG bar chart
            lines(end+1, 1) = "<section class=""chart"">";
            lines(end+1, 1) = "  <h2>Distribution</h2>";
            lines(end+1, 1) = autotest.ReportRenderer.svgBarChart(s);
            lines(end+1, 1) = "</section>";

            % Per-source breakdown
            lines(end+1, 1) = "<section>";
            lines(end+1, 1) = "  <h2>Per-source breakdown</h2>";
            if isempty(data.SourceRows)
                lines(end+1, 1) = "  <p class=""empty"">No sources discovered.</p>";
            else
                lines(end+1, 1) = "  <table class=""tbl"">";
                lines(end+1, 1) = "    <thead><tr>" + ...
                    "<th>Source</th><th>Kind</th><th>Generated</th>" + ...
                    "<th class=""num"">Tests</th><th class=""num"">Passed</th>" + ...
                    "<th class=""num"">Failed</th><th class=""num"">Incomplete</th>" + ...
                    "</tr></thead>";
                lines(end+1, 1) = "    <tbody>";
                for i = 1:numel(data.SourceRows)
                    r = data.SourceRows(i);
                    failClass = autotest.ReportRenderer.iif(r.Failed > 0, ' class="bad"', '');
                    incClass  = autotest.ReportRenderer.iif(r.Incomplete > 0, ' class="warn"', '');
                    genCell = autotest.ReportRenderer.iif(r.Generated, ...
                        '<span class="ok">yes</span>', '<span class="bad">no</span>');
                    lines(end+1, 1) = "      <tr>" + ...
                        "<td class=""path"">" + esc(r.RelPath) + "</td>" + ...
                        "<td>" + esc(r.Kind) + "</td>" + ...
                        "<td>" + string(genCell) + "</td>" + ...
                        "<td class=""num"">" + sprintf('%d', r.Total) + "</td>" + ...
                        "<td class=""num"">" + sprintf('%d', r.Passed) + "</td>" + ...
                        "<td class=""num" + string(failClass) + """>" + sprintf('%d', r.Failed) + "</td>" + ...
                        "<td class=""num" + string(incClass) + """>" + sprintf('%d', r.Incomplete) + "</td>" + ...
                        "</tr>"; %#ok<AGROW>
                    if ~r.Generated && ~isempty(r.Error)
                        lines(end+1, 1) = "      <tr class=""errrow""><td colspan=""7"">" + ...
                            esc(r.Error) + "</td></tr>"; %#ok<AGROW>
                    end
                end
                lines(end+1, 1) = "    </tbody>";
                lines(end+1, 1) = "  </table>";
            end
            lines(end+1, 1) = "</section>";

            % Test results (collapsible per class)
            lines(end+1, 1) = "<section>";
            lines(end+1, 1) = "  <h2>Test results</h2>";
            if isempty(data.Groups)
                lines(end+1, 1) = "  <p class=""empty"">No tests were executed.</p>";
            else
                for k = 1:numel(data.Groups)
                    g = data.Groups{k};
                    nFail = sum(strcmp({g.Tests.Status}, 'fail'));
                    nInc  = sum(strcmp({g.Tests.Status}, 'incomplete'));
                    nPass = sum(strcmp({g.Tests.Status}, 'pass'));
                    statusBadge = autotest.ReportRenderer.classBadge(nFail, nInc, nPass);
                    openAttr = autotest.ReportRenderer.iif(nFail > 0, ' open', '');
                    lines(end+1, 1) = "  <details" + string(openAttr) + ">"; %#ok<AGROW>
                    lines(end+1, 1) = "    <summary>" + string(statusBadge) + ...
                        "<span class=""cls"">" + esc(g.Class) + "</span>" + ...
                        "<span class=""tally"">" + ...
                        sprintf('%d passed, %d failed, %d incomplete', nPass, nFail, nInc) + ...
                        "</span></summary>"; %#ok<AGROW>
                    lines(end+1, 1) = "    <table class=""tbl"">"; %#ok<AGROW>
                    lines(end+1, 1) = "      <thead><tr><th>Status</th><th>Test</th>" + ...
                        "<th class=""num"">Duration</th></tr></thead>"; %#ok<AGROW>
                    lines(end+1, 1) = "      <tbody>"; %#ok<AGROW>
                    for j = 1:numel(g.Tests)
                        t = g.Tests(j);
                        icon = autotest.ReportRenderer.statusIconHtml(t.Status);
                        lines(end+1, 1) = "        <tr>" + ...
                            "<td>" + string(icon) + "</td>" + ...
                            "<td class=""path"">" + esc(t.Name) + "</td>" + ...
                            "<td class=""num"">" + esc(fmtDur(t.DurationMs)) + "</td>" + ...
                            "</tr>"; %#ok<AGROW>
                        if ~strcmp(t.Status, 'pass') && ~isempty(t.Diagnostic)
                            lines(end+1, 1) = "        <tr class=""diagrow""><td colspan=""3"">" + ...
                                "<pre>" + esc(t.Diagnostic) + "</pre></td></tr>"; %#ok<AGROW>
                        end
                    end
                    lines(end+1, 1) = "      </tbody>"; %#ok<AGROW>
                    lines(end+1, 1) = "    </table>"; %#ok<AGROW>
                    lines(end+1, 1) = "  </details>"; %#ok<AGROW>
                end
            end
            lines(end+1, 1) = "</section>";

            % Generation errors
            if ~isempty(data.GenErrors)
                lines(end+1, 1) = "<section>";
                lines(end+1, 1) = "  <h2>Generation errors</h2>";
                lines(end+1, 1) = "  <ul class=""errlist"">";
                for i = 1:numel(data.GenErrors)
                    lines(end+1, 1) = "    <li>" + esc(data.GenErrors{i}) + "</li>"; %#ok<AGROW>
                end
                lines(end+1, 1) = "  </ul>";
                lines(end+1, 1) = "</section>";
            end

            % Footer
            logHref = autotest.ReportRenderer.fileUri(data.LogFile);
            lines(end+1, 1) = "<footer>";
            if ~isempty(logHref)
                lines(end+1, 1) = "  Run log: <a href=""" + esc(logHref) + """>" + ...
                    esc(data.LogFile) + "</a>";
            end
            lines(end+1, 1) = "</footer>";

            lines(end+1, 1) = "</body></html>";

            autotest.ReportRenderer.writeFile(path, strjoin(lines, newline));
        end

        function s = htmlStyles()
            % CSS lifted into a single string so writeHtml can drop it
            % straight into a <style> block.  No external assets.
            s = strjoin([
                ":root {"
                "  --fg:#1f2933; --muted:#52606d; --bg:#ffffff;"
                "  --line:#e4e7eb; --accent:#1f6feb;"
                "  --pass:#1a7f37; --fail:#cf222e; --warn:#bf8700; --info:#1f6feb;"
                "  --pass-bg:#dafbe1; --fail-bg:#ffebe9; --warn-bg:#fff8c5; --info-bg:#ddf4ff;"
                "}"
                "* { box-sizing: border-box; }"
                "body { font-family: -apple-system, Segoe UI, Roboto, Helvetica, Arial, sans-serif;"
                "  color: var(--fg); background: var(--bg);"
                "  margin: 0; padding: 24px 32px; max-width: 1200px; }"
                "header h1 { margin: 0 0 4px; font-size: 28px; }"
                "header .subtitle { color: var(--muted); font-size: 14px; }"
                "header .folder { color: var(--muted); font-size: 12px;"
                "  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;"
                "  margin-top: 4px; word-break: break-all; }"
                "h2 { margin: 28px 0 12px; font-size: 18px;"
                "  border-bottom: 1px solid var(--line); padding-bottom: 4px; }"
                ".banner { margin: 16px 0; padding: 12px 16px; border-radius: 6px;"
                "  font-weight: 600; }"
                ".banner-good { background: var(--pass-bg); color: var(--pass); }"
                ".banner-bad  { background: var(--fail-bg); color: var(--fail); }"
                ".banner-warn { background: var(--warn-bg); color: var(--warn); }"
                ".banner-info { background: var(--info-bg); color: var(--info); }"
                ".cards { display: grid;"
                "  grid-template-columns: repeat(auto-fit, minmax(140px, 1fr));"
                "  gap: 12px; margin: 12px 0; }"
                ".card { padding: 14px 16px; border: 1px solid var(--line);"
                "  border-radius: 6px; background: #fafbfc; }"
                ".card .label { color: var(--muted); font-size: 12px;"
                "  text-transform: uppercase; letter-spacing: 0.04em; }"
                ".card .value { font-size: 26px; font-weight: 700; margin-top: 4px; }"
                ".card-pass .value { color: var(--pass); }"
                ".card-fail .value { color: var(--fail); }"
                ".card-warn .value { color: var(--warn); }"
                ".card-info .value { color: var(--info); }"
                ".chart svg { display: block; max-width: 100%; height: auto; }"
                "table.tbl { width: 100%; border-collapse: collapse; font-size: 14px;"
                "  margin: 8px 0; }"
                "table.tbl th, table.tbl td { padding: 6px 10px; text-align: left;"
                "  border-bottom: 1px solid var(--line); vertical-align: top; }"
                "table.tbl thead th { background: #f6f8fa; font-weight: 600;"
                "  border-bottom: 2px solid var(--line); }"
                "table.tbl td.num, table.tbl th.num { text-align: right;"
                "  font-variant-numeric: tabular-nums; }"
                "table.tbl td.path { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;"
                "  font-size: 12px; }"
                "table.tbl td.num.bad  { background: var(--fail-bg); color: var(--fail); font-weight: 600; }"
                "table.tbl td.num.warn { background: var(--warn-bg); color: var(--warn); font-weight: 600; }"
                "table.tbl tr.errrow td { background: var(--fail-bg); color: var(--fail);"
                "  font-family: ui-monospace, monospace; font-size: 12px; }"
                "table.tbl tr.diagrow td { background: #f6f8fa; padding: 0; }"
                "table.tbl tr.diagrow pre { margin: 0; padding: 12px 16px;"
                "  font-size: 12px; white-space: pre-wrap; word-break: break-word;"
                "  color: var(--fail); }"
                "details { border: 1px solid var(--line); border-radius: 6px;"
                "  margin: 8px 0; background: #fff; }"
                "details > summary { padding: 10px 14px; cursor: pointer;"
                "  list-style: none; display: flex; gap: 10px; align-items: center; }"
                "details > summary::-webkit-details-marker { display: none; }"
                "details[open] > summary { border-bottom: 1px solid var(--line); }"
                "details > summary .cls { font-weight: 600; }"
                "details > summary .tally { color: var(--muted); font-size: 13px;"
                "  margin-left: auto; }"
                ".badge { display: inline-block; min-width: 22px; padding: 2px 8px;"
                "  border-radius: 999px; font-size: 12px; font-weight: 700; text-align: center; }"
                ".badge-pass { background: var(--pass-bg); color: var(--pass); }"
                ".badge-fail { background: var(--fail-bg); color: var(--fail); }"
                ".badge-warn { background: var(--warn-bg); color: var(--warn); }"
                ".badge-none { background: #eef0f2; color: var(--muted); }"
                ".icon { display: inline-block; font-weight: 700;"
                "  width: 18px; text-align: center; }"
                ".icon-pass { color: var(--pass); }"
                ".icon-fail { color: var(--fail); }"
                ".icon-warn { color: var(--warn); }"
                ".icon-none { color: var(--muted); }"
                ".ok  { color: var(--pass); font-weight: 600; }"
                ".bad { color: var(--fail); font-weight: 600; }"
                ".warn { color: var(--warn); font-weight: 600; }"
                ".errlist li { color: var(--fail);"
                "  font-family: ui-monospace, monospace; font-size: 13px;"
                "  margin: 4px 0; }"
                ".empty { color: var(--muted); font-style: italic; }"
                "footer { margin-top: 32px; padding-top: 12px;"
                "  border-top: 1px solid var(--line); color: var(--muted);"
                "  font-size: 12px; }"
                "footer a { color: var(--accent); }"
                ], newline);
        end

        function html = cardHtml(label, value, klass)
            esc = @autotest.ReportRenderer.htmlEscape;
            html = "  <div class=""card " + esc(klass) + """>" + ...
                "<div class=""label"">" + esc(label) + "</div>" + ...
                "<div class=""value"">" + esc(value) + "</div></div>";
        end

        function s = svgBarChart(summary)
            % Pure inline SVG horizontal stacked bar.  Falls back to a
            % single grey segment when there are no tests.
            total = max(summary.Total, 1);
            w = 720;
            h = 56;
            barH = 28;
            barY = 8;
            wPass = round(summary.Passed     / total * w);
            wFail = round(summary.Failed     / total * w);
            wInc  = round(summary.Incomplete / total * w);
            % Clamp to width.
            used = wPass + wFail + wInc;
            if used > w
                wInc = max(0, wInc - (used - w));
            elseif used < w && summary.Total > 0
                wPass = wPass + (w - used); % give remainder to passed
            end

            xPass = 0;
            xFail = wPass;
            xInc  = wPass + wFail;

            parts = strings(0, 1);
            parts(end+1, 1) = sprintf( ...
                '<svg viewBox="0 0 %d %d" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="Test result distribution">', ...
                w, h);
            parts(end+1, 1) = sprintf( ...
                '<rect x="0" y="%d" width="%d" height="%d" fill="#eef0f2" rx="4"/>', ...
                barY, w, barH);
            if summary.Total > 0
                if wPass > 0
                    parts(end+1, 1) = sprintf( ...
                        '<rect x="%d" y="%d" width="%d" height="%d" fill="#1a7f37"/>', ...
                        xPass, barY, wPass, barH);
                end
                if wFail > 0
                    parts(end+1, 1) = sprintf( ...
                        '<rect x="%d" y="%d" width="%d" height="%d" fill="#cf222e"/>', ...
                        xFail, barY, wFail, barH);
                end
                if wInc > 0
                    parts(end+1, 1) = sprintf( ...
                        '<rect x="%d" y="%d" width="%d" height="%d" fill="#bf8700"/>', ...
                        xInc, barY, wInc, barH);
                end
            end
            % Legend below the bar.
            legendY = barY + barH + 14;
            legend = autotest.ReportRenderer.svgLegend(legendY, ...
                summary.Passed, summary.Failed, summary.Incomplete);
            parts(end+1, 1) = legend;
            parts(end+1, 1) = "</svg>";
            s = strjoin(parts, "");
        end

        function s = svgLegend(y, nPass, nFail, nInc)
            entries = { ...
                struct('color', '#1a7f37', 'label', sprintf('Passed (%d)', nPass)), ...
                struct('color', '#cf222e', 'label', sprintf('Failed (%d)', nFail)), ...
                struct('color', '#bf8700', 'label', sprintf('Incomplete (%d)', nInc))};
            x = 0;
            parts = strings(0, 1);
            for i = 1:numel(entries)
                e = entries{i};
                parts(end+1, 1) = sprintf( ...
                    '<rect x="%d" y="%d" width="10" height="10" fill="%s" rx="2"/>', ...
                    x, y - 9, e.color); %#ok<AGROW>
                parts(end+1, 1) = sprintf( ...
                    '<text x="%d" y="%d" font-family="sans-serif" font-size="12" fill="#52606d">%s</text>', ...
                    x + 14, y, autotest.ReportRenderer.htmlEscape(e.label)); %#ok<AGROW>
                x = x + 14 + 10 + numel(e.label) * 7 + 12;
            end
            s = strjoin(parts, "");
        end

        function s = statusIconHtml(status)
            esc = @autotest.ReportRenderer.htmlEscape;
            switch status
                case 'pass'
                    s = '<span class="icon icon-pass" title="Passed">' + string(esc(char(10003))) + '</span>';
                case 'fail'
                    s = '<span class="icon icon-fail" title="Failed">' + string(esc(char(10007))) + '</span>';
                case 'incomplete'
                    s = '<span class="icon icon-warn" title="Incomplete">!</span>';
                otherwise
                    s = '<span class="icon icon-none" title="No status">' + string(esc(char(8211))) + '</span>';
            end
        end

        function s = classBadge(nFail, nInc, nPass)
            if nFail > 0
                s = sprintf('<span class="badge badge-fail">%d</span>', nFail);
            elseif nInc > 0
                s = sprintf('<span class="badge badge-warn">%d</span>', nInc);
            elseif nPass > 0
                s = sprintf('<span class="badge badge-pass">%d</span>', nPass);
            else
                s = '<span class="badge badge-none">0</span>';
            end
        end

        % -----------------------------------------------------------------
        % Markdown
        % -----------------------------------------------------------------
        function writeMarkdown(path, data)
            esc = @autotest.ReportRenderer.mdEscapeCell;
            fmtDur = @autotest.ReportRenderer.formatDuration;

            lines = strings(0, 1);
            lines(end+1, 1) = "# autotest report - " + string(data.ProjectName);
            lines(end+1, 1) = "";
            lines(end+1, 1) = "- Project folder: `" + string(data.Folder) + "`";
            lines(end+1, 1) = "- Output root: `" + string(data.OutputRoot) + "`";
            lines(end+1, 1) = "- Timestamp: `" + string(data.Timestamp) + "`";
            lines(end+1, 1) = "- Status: **" + string(data.Banner.text) + "**";
            lines(end+1, 1) = "";

            s = data.Summary;
            b = data.Banner;
            lines(end+1, 1) = sprintf('Generated tests: %d total, %d passed, %d failed, %d incomplete (duration %s)', ...
                b.GeneratedTotal, b.GeneratedPassed, b.GeneratedFailed, b.GeneratedIncomplete, ...
                fmtDur(s.DurationSeconds * 1000));
            if b.UserStubTotal > 0
                lines(end+1, 1) = sprintf('User-written test stubs awaiting implementation: %d', ...
                    b.UserStubTotal);
            end
            lines(end+1, 1) = "";

            % Per-source breakdown
            lines(end+1, 1) = "## Per-source breakdown";
            lines(end+1, 1) = "";
            if isempty(data.SourceRows)
                lines(end+1, 1) = "_No sources discovered._";
            else
                lines(end+1, 1) = "| Source | Kind | Generated | Tests | Passed | Failed | Incomplete |";
                lines(end+1, 1) = "|---|---|---|---:|---:|---:|---:|";
                for i = 1:numel(data.SourceRows)
                    r = data.SourceRows(i);
                    genStr = autotest.ReportRenderer.iif(r.Generated, 'yes', 'no');
                    lines(end+1, 1) = "| " + esc(r.RelPath) + ...
                        " | " + esc(r.Kind) + ...
                        " | " + esc(genStr) + ...
                        " | " + sprintf('%d', r.Total) + ...
                        " | " + sprintf('%d', r.Passed) + ...
                        " | " + sprintf('%d', r.Failed) + ...
                        " | " + sprintf('%d', r.Incomplete) + " |"; %#ok<AGROW>
                end
                % List generation errors as separate notes after the table.
                anyErr = false;
                for i = 1:numel(data.SourceRows)
                    if ~data.SourceRows(i).Generated && ~isempty(data.SourceRows(i).Error)
                        if ~anyErr
                            lines(end+1, 1) = "";
                            lines(end+1, 1) = "Generation failures:"; %#ok<AGROW>
                            anyErr = true;
                        end
                        lines(end+1, 1) = sprintf('- `%s` &mdash; %s', ...
                            data.SourceRows(i).RelPath, ...
                            data.SourceRows(i).Error); %#ok<AGROW>
                    end
                end
            end
            lines(end+1, 1) = "";

            % Test results by class
            lines(end+1, 1) = "## Test results";
            lines(end+1, 1) = "";
            if isempty(data.Groups)
                lines(end+1, 1) = "_No tests were executed._";
            else
                for k = 1:numel(data.Groups)
                    g = data.Groups{k};
                    nFail = sum(strcmp({g.Tests.Status}, 'fail'));
                    nInc  = sum(strcmp({g.Tests.Status}, 'incomplete'));
                    nPass = sum(strcmp({g.Tests.Status}, 'pass'));
                    lines(end+1, 1) = sprintf('### %s', g.Class); %#ok<AGROW>
                    lines(end+1, 1) = sprintf('%d passed, %d failed, %d incomplete', nPass, nFail, nInc); %#ok<AGROW>
                    lines(end+1, 1) = ""; %#ok<AGROW>
                    lines(end+1, 1) = "| Status | Test | Duration |"; %#ok<AGROW>
                    lines(end+1, 1) = "|---|---|---:|"; %#ok<AGROW>
                    for j = 1:numel(g.Tests)
                        t = g.Tests(j);
                        statusLabel = autotest.ReportRenderer.mdStatusLabel(t.Status);
                        lines(end+1, 1) = "| " + esc(statusLabel) + ...
                            " | " + esc(t.Name) + ...
                            " | " + esc(fmtDur(t.DurationMs)) + " |"; %#ok<AGROW>
                    end
                    lines(end+1, 1) = ""; %#ok<AGROW>
                    % Diagnostics: rendered after the table to keep cells clean.
                    for j = 1:numel(g.Tests)
                        t = g.Tests(j);
                        if ~strcmp(t.Status, 'pass') && ~isempty(t.Diagnostic)
                            lines(end+1, 1) = sprintf('**%s**', t.Name); %#ok<AGROW>
                            lines(end+1, 1) = ""; %#ok<AGROW>
                            block = autotest.ReportRenderer.mdFenceForContent(t.Diagnostic);
                            lines(end+1, 1) = block; %#ok<AGROW>
                            lines(end+1, 1) = ""; %#ok<AGROW>
                        end
                    end
                end
            end
            lines(end+1, 1) = "";

            % Generation errors
            if ~isempty(data.GenErrors)
                lines(end+1, 1) = "## Generation errors";
                lines(end+1, 1) = "";
                for i = 1:numel(data.GenErrors)
                    lines(end+1, 1) = "- " + string(data.GenErrors{i}); %#ok<AGROW>
                end
                lines(end+1, 1) = "";
            end

            % Footer
            if ~isempty(data.LogFile)
                lines(end+1, 1) = "---";
                lines(end+1, 1) = "Run log: `" + string(data.LogFile) + "`";
            end

            autotest.ReportRenderer.writeFile(path, strjoin(lines, newline));
        end

        function block = mdFenceForContent(txt)
            % Pick a fence longer than the longest backtick run inside TXT.
            t = char(txt);
            longest = 0;
            run = 0;
            for i = 1:numel(t)
                if t(i) == '`'
                    run = run + 1;
                    if run > longest
                        longest = run;
                    end
                else
                    run = 0;
                end
            end
            fenceLen = max(3, longest + 1);
            fence = repmat('`', 1, fenceLen);
            block = sprintf('%s\n%s\n%s', fence, t, fence);
        end

        function s = mdStatusLabel(status)
            switch status
                case 'pass';       s = 'Pass';
                case 'fail';       s = 'Fail';
                case 'incomplete'; s = 'Incomplete';
                otherwise;         s = '-';
            end
        end

        % -----------------------------------------------------------------
        % PDF cascade
        % -----------------------------------------------------------------
        function writePdf(pdfPath, htmlPath, data, info)
            attempts = strings(0, 1);

            ok = false;
            try
                if autotest.ReportRenderer.hasReportGenerator()
                    autotest.ReportRenderer.pdfViaReportGen(pdfPath, data);
                    ok = true;
                end
            catch ME
                attempts(end+1, 1) = sprintf('mlreportgen: %s', ME.message);
            end

            if ~ok
                try
                    autotest.ReportRenderer.pdfViaUiHtml(pdfPath, htmlPath);
                    ok = true;
                catch ME
                    attempts(end+1, 1) = sprintf('uihtml: %s', ME.message);
                end
            end

            if ~ok
                try
                    autotest.ReportRenderer.pdfViaFigure(pdfPath, data);
                    ok = true;
                catch ME
                    attempts(end+1, 1) = sprintf('figure: %s', ME.message);
                end
            end

            if ~ok
                logsDir = autotest.ReportRenderer.getf(info, 'LogsDir', '');
                if isempty(logsDir)
                    logsDir = fileparts(pdfPath);
                end
                if ~isfolder(logsDir)
                    try
                        mkdir(logsDir);
                    catch
                        % swallow
                    end
                end
                logPath = fullfile(logsDir, 'report-pdf.log');
                try
                    fid = fopen(logPath, 'a');
                    if fid >= 0
                        fprintf(fid, '[%s] PDF generation failed.\n', ...
                            char(datetime('now')));
                        for i = 1:numel(attempts)
                            fprintf(fid, '  - %s\n', attempts(i));
                        end
                        fclose(fid);
                    end
                catch
                    % logging failure is non-fatal
                end
                warning('autotest:ReportRenderer:Pdf', ...
                    'Could not produce report.pdf; see %s', logPath);
            end
        end

        function tf = hasReportGenerator()
            tf = false;
            try
                w = which('mlreportgen.report.Report');
                tf = ~isempty(w);
            catch
                tf = false;
            end
        end

        function pdfViaReportGen(pdfPath, data)
            % Minimal mlreportgen.dom document mirroring the markdown.
            import mlreportgen.dom.*

            d = Document(pdfPath, 'pdf');
            try
                append(d, Heading1(sprintf('autotest report - %s', data.ProjectName)));
                append(d, Paragraph(sprintf('Project folder: %s', data.Folder)));
                append(d, Paragraph(sprintf('Timestamp: %s', data.Timestamp)));
                bp = Paragraph(data.Banner.text);
                bp.Bold = true;
                append(d, bp);

                s = data.Summary;
                append(d, Paragraph(sprintf( ...
                    'Summary: %d total, %d passed, %d failed, %d incomplete (duration %s)', ...
                    s.Total, s.Passed, s.Failed, s.Incomplete, ...
                    autotest.ReportRenderer.formatDuration(s.DurationSeconds * 1000))));

                % Per-source table
                append(d, Heading2('Per-source breakdown'));
                if isempty(data.SourceRows)
                    append(d, Paragraph('No sources discovered.'));
                else
                    rows = numel(data.SourceRows);
                    cells = cell(rows + 1, 7);
                    cells(1, :) = {'Source', 'Kind', 'Generated', ...
                        'Tests', 'Passed', 'Failed', 'Incomplete'};
                    for i = 1:rows
                        r = data.SourceRows(i);
                        cells{i+1, 1} = r.RelPath;
                        cells{i+1, 2} = r.Kind;
                        cells{i+1, 3} = autotest.ReportRenderer.iif(r.Generated, 'yes', 'no');
                        cells{i+1, 4} = sprintf('%d', r.Total);
                        cells{i+1, 5} = sprintf('%d', r.Passed);
                        cells{i+1, 6} = sprintf('%d', r.Failed);
                        cells{i+1, 7} = sprintf('%d', r.Incomplete);
                    end
                    t = Table(cells);
                    t.Border = 'solid';
                    t.RowSep = 'solid';
                    t.ColSep = 'solid';
                    append(d, t);
                end

                % Test results
                append(d, Heading2('Test results'));
                if isempty(data.Groups)
                    append(d, Paragraph('No tests were executed.'));
                else
                    for k = 1:numel(data.Groups)
                        g = data.Groups{k};
                        append(d, Heading3(g.Class));
                        rowsT = numel(g.Tests);
                        cellsT = cell(rowsT + 1, 3);
                        cellsT(1, :) = {'Status', 'Test', 'Duration'};
                        for j = 1:rowsT
                            tt = g.Tests(j);
                            cellsT{j+1, 1} = autotest.ReportRenderer.mdStatusLabel(tt.Status);
                            cellsT{j+1, 2} = tt.Name;
                            cellsT{j+1, 3} = autotest.ReportRenderer.formatDuration(tt.DurationMs);
                        end
                        tbl = Table(cellsT);
                        tbl.Border = 'solid';
                        tbl.RowSep = 'solid';
                        tbl.ColSep = 'solid';
                        append(d, tbl);
                        for j = 1:rowsT
                            tt = g.Tests(j);
                            if ~strcmp(tt.Status, 'pass') && ~isempty(tt.Diagnostic)
                                append(d, Paragraph(sprintf('Diagnostic for %s:', tt.Name)));
                                pp = Preformatted(tt.Diagnostic);
                                append(d, pp);
                            end
                        end
                    end
                end

                if ~isempty(data.GenErrors)
                    append(d, Heading2('Generation errors'));
                    for i = 1:numel(data.GenErrors)
                        append(d, Paragraph(data.GenErrors{i}));
                    end
                end

                close(d);
            catch ME
                try
                    close(d);
                catch
                end
                rethrow(ME);
            end
        end

        function pdfViaUiHtml(pdfPath, htmlPath)
            % Render the actual HTML via uihtml + exportapp.  Note that
            % uihtml needs an absolute file:// URL or a local path; we
            % feed it the on-disk path that we just wrote.
            if ~isfile(htmlPath)
                error('autotest:ReportRenderer:NoHtml', ...
                    'HTML report does not exist: %s', htmlPath);
            end
            fig = uifigure('Visible', 'off', 'Position', [100 100 1100 1400]);
            cleanup = onCleanup(@() autotest.ReportRenderer.safeDelete(fig)); %#ok<NASGU>
            h = uihtml(fig, 'Position', [0 0 1100 1400]);
            h.HTMLSource = htmlPath;
            % Give the browser component a moment to paint before export.
            drawnow;
            pause(0.5);
            exportapp(fig, pdfPath);
        end

        function pdfViaFigure(pdfPath, data)
            % Last-resort plain-figure PDF: text-only summary built from
            % annotation textboxes.  Always available, never pretty.
            fig = figure('Visible', 'off', 'Color', 'w', ...
                'PaperOrientation', 'portrait', ...
                'Units', 'inches', 'PaperUnits', 'inches', ...
                'PaperSize', [8.5 11], 'PaperPosition', [0 0 8.5 11]);
            cleanup = onCleanup(@() autotest.ReportRenderer.safeDelete(fig)); %#ok<NASGU>

            ax = axes('Parent', fig, 'Position', [0 0 1 1], 'Visible', 'off');
            xlim(ax, [0 1]); ylim(ax, [0 1]);

            lines = autotest.ReportRenderer.plainTextSummary(data);
            text(ax, 0.05, 0.97, sprintf('autotest report - %s', data.ProjectName), ...
                'FontSize', 16, 'FontWeight', 'bold', ...
                'VerticalAlignment', 'top');
            text(ax, 0.05, 0.93, lines, ...
                'FontSize', 10, 'FontName', 'Courier New', ...
                'VerticalAlignment', 'top', 'Interpreter', 'none');

            print(fig, pdfPath, '-dpdf', '-fillpage');
        end

        function txt = plainTextSummary(data)
            % Compact text body for the plain-figure fallback.
            buf = strings(0, 1);
            buf(end+1, 1) = sprintf('Folder:    %s', data.Folder);
            buf(end+1, 1) = sprintf('Timestamp: %s', data.Timestamp);
            buf(end+1, 1) = sprintf('Status:    %s', data.Banner.text);
            s = data.Summary;
            b = data.Banner;
            buf(end+1, 1) = sprintf('Summary:   generated=%d passed=%d failed=%d incomplete=%d', ...
                b.GeneratedTotal, b.GeneratedPassed, b.GeneratedFailed, b.GeneratedIncomplete);
            if b.UserStubTotal > 0
                buf(end+1, 1) = sprintf('Stubs:     %d user-written tests awaiting implementation', ...
                    b.UserStubTotal);
            end
            buf(end+1, 1) = sprintf('Duration:  %s', ...
                autotest.ReportRenderer.formatDuration(s.DurationSeconds * 1000));
            buf(end+1, 1) = "";
            buf(end+1, 1) = "Per-source:";
            for i = 1:numel(data.SourceRows)
                r = data.SourceRows(i);
                buf(end+1, 1) = sprintf('  %-40s tests=%d pass=%d fail=%d inc=%d', ...
                    autotest.ReportRenderer.truncate(r.RelPath, 40), ...
                    r.Total, r.Passed, r.Failed, r.Incomplete); %#ok<AGROW>
            end
            if ~isempty(data.GenErrors)
                buf(end+1, 1) = "";
                buf(end+1, 1) = "Generation errors:";
                for i = 1:numel(data.GenErrors)
                    buf(end+1, 1) = sprintf('  - %s', ...
                        autotest.ReportRenderer.truncate(data.GenErrors{i}, 80)); %#ok<AGROW>
                end
            end
            txt = char(strjoin(buf, newline));
        end

        % -----------------------------------------------------------------
        % Small utilities
        % -----------------------------------------------------------------
        function s = htmlEscape(in)
            % Escape the five characters that matter inside HTML text or
            % an attribute value.  Returns a char row.
            t = char(in);
            if isempty(t)
                s = '';
                return
            end
            t = strrep(t, '&',  '&amp;');
            t = strrep(t, '<',  '&lt;');
            t = strrep(t, '>',  '&gt;');
            t = strrep(t, '"',  '&quot;');
            t = strrep(t, '''', '&#39;');
            s = t;
        end

        function s = mdEscapeCell(in)
            % Escape the characters that break a Markdown table cell.
            t = char(in);
            if isempty(t)
                s = '';
                return
            end
            t = strrep(t, '\', '\\');
            t = strrep(t, '|', '\|');
            % Newlines would split the row in two; collapse them.
            t = regexprep(t, '\r\n|\n|\r', ' ');
            s = t;
        end

        function s = formatDuration(ms)
            % ms < 1000 => "NNN ms" ; otherwise "S.S s".  One decimal.
            if isempty(ms) || ~isfinite(ms)
                s = '-';
                return
            end
            if ms < 1000
                s = sprintf('%.1f ms', ms);
            else
                s = sprintf('%.1f s', ms / 1000);
            end
        end

        function out = iif(cond, a, b)
            if cond
                out = a;
            else
                out = b;
            end
        end

        function v = getf(s, name, default)
            if isstruct(s) && isfield(s, name)
                v = s.(name);
            else
                v = default;
            end
        end

        function s = truncate(in, maxLen)
            t = char(in);
            if numel(t) > maxLen
                s = [t(1:max(1, maxLen-3)) '...'];
            else
                s = t;
            end
        end

        function safeDelete(h)
            try
                if ~isempty(h) && isvalid(h)
                    delete(h);
                end
            catch
            end
        end

        function writeFile(path, txt)
            [folder, ~, ~] = fileparts(path);
            if ~isempty(folder) && ~isfolder(folder)
                mkdir(folder);
            end
            fid = fopen(path, 'w');
            if fid < 0
                error('autotest:ReportRenderer:Write', 'Cannot open %s', path);
            end
            cleanup = onCleanup(@() fclose(fid)); %#ok<NASGU>
            fwrite(fid, char(txt), 'char');
        end

        function uri = fileUri(p)
            if isempty(p)
                uri = '';
                return
            end
            t = char(p);
            t = strrep(t, '\', '/');
            if ~isempty(regexp(t, '^[A-Za-z]:/', 'once'))
                uri = ['file:///' t];
            elseif startsWith(t, '/')
                uri = ['file://' t];
            else
                uri = ['file:///' t];
            end
        end
    end
end
