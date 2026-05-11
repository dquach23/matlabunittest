classdef HtmlBackend < handle
    %HTMLBACKEND  v1.5 -- self-contained HTML system test report.
    %
    %   Emits a single .html file with inline CSS + inline SVG charts.
    %   No external assets, no JavaScript, no fonts to download -- the
    %   file can be emailed, archived in a record system, or opened in
    %   any browser without dependencies.
    %
    %   The HtmlBackend exists because:
    %     * MATLAB Report Generator is licensed separately and missing
    %       on most work-machine MATLAB installs.
    %     * The OoxmlBackend (.docx) requires Word to view sensibly and
    %       cannot be diffed or grep'd as raw text by reviewers.
    %     * Email gateways routinely strip .docx attachments and
    %       intercept network calls; a self-contained .html survives.
    %
    %   Public surface mirrors OoxmlBackend so SectionBuilder can drive
    %   either without conditionals.  The one extension is addSvgChart()
    %   for inline-SVG pie / bar charts; SectionBuilder prefers that
    %   path over addImage() when the backend exposes it.
    %
    %   v1.4 palette (locked):
    %       PrimaryText  #1F2937   SecondaryText #4B5563
    %       Accent       #B45309   FailEmphasis  #991B1B
    %       CodeFill     #F7FAFC   HeaderShading #E7E6E6
    %       MetaShading  #F2F2F2

    properties (SetAccess = immutable)
        OutputPath     (1,:) char
        Classification (1,:) char = 'UNCLASSIFIED'
    end

    properties (SetAccess = private)
        BodyParts string = string.empty   % HTML fragments accumulated in order
        Title     (1,:) char = 'System Test Report'
    end

    methods
        function obj = HtmlBackend(outputPath, classification)
            arguments
                outputPath     (1,:) char
                classification (1,:) char = 'UNCLASSIFIED'
            end
            obj.OutputPath = outputPath;
            obj.Classification = classification;
        end

        % ===================================================== Cover page

        function addCoverPage(obj, fields, distHeader, distBody)
            %ADDCOVERPAGE  Title block + metadata table + bordered dist box.
            wantRule = isfield(fields, 'AccentRule') && fields.AccentRule;
            obj.Title = char(fields.Title);
            html = strings(0,1);
            html(end+1,1) = "<section class=""cover"">";
            html(end+1,1) = string(['<h1 class="cover-title">' ...
                autotest.report.backends.HtmlBackend.esc(fields.Title) '</h1>']);
            html(end+1,1) = string(['<p class="cover-subtitle">' ...
                autotest.report.backends.HtmlBackend.esc(fields.Subtitle) '</p>']);
            html(end+1,1) = string(autotest.report.backends.HtmlBackend.kvTableHtml( ...
                fields.Metadata, 'cover-meta'));
            if wantRule
                html(end+1,1) = "<hr class=""accent-rule"" />";
            end
            html(end+1,1) = "<aside class=""dist-box"">";
            html(end+1,1) = string(['<h2>' ...
                autotest.report.backends.HtmlBackend.esc(distHeader) '</h2>']);
            html(end+1,1) = string(['<p>' ...
                autotest.report.backends.HtmlBackend.esc(distBody) '</p>']);
            html(end+1,1) = "</aside>";
            html(end+1,1) = "</section>";
            obj.BodyParts(end+1) = strjoin(html, newline);
        end

        % ===================================================== Headings + body

        function addHeading(obj, level, text)
            arguments
                obj
                level (1,1) double {mustBeMember(level, [1 2 3])}
                text  (1,:) char
            end
            tag = sprintf('h%d', level + 1);   % h2/h3/h4 below the cover h1
            anchor = autotest.report.backends.HtmlBackend.slugify(text);
            obj.BodyParts(end+1) = string(sprintf( ...
                '<%s id="%s" class="lvl%d">%s</%s>', ...
                tag, anchor, level, ...
                autotest.report.backends.HtmlBackend.esc(text), tag));
        end

        function addParagraph(obj, text)
            arguments
                obj
                text (1,:) char
            end
            obj.BodyParts(end+1) = string(['<p>' ...
                autotest.report.backends.HtmlBackend.esc(text) '</p>']);
        end

        function addPageBreak(obj)
            % Browsers honour `break-before: page` when printing.  In on-
            % screen viewing it's a no-op; the section spacing handles the
            % visual separation.
            obj.BodyParts(end+1) = "<div class=""page-break""></div>";
        end

        function addBlankParagraph(obj, ~)
            obj.BodyParts(end+1) = "<p class=""blank"">&nbsp;</p>";
        end

        function addAccentRule(obj)
            obj.BodyParts(end+1) = "<hr class=""accent-rule"" />";
        end

        function addImage(obj, pngPath, ~, ~)
            %ADDIMAGE  Backwards-compat: PNG -> base64 data URI.
            %   Only used when SectionBuilder falls back from
            %   addSvgChart (i.e. on a backend that didn't render
            %   the chart as inline SVG).  We embed the PNG as a
            %   data URI so the HTML stays self-contained.
            arguments
                obj
                pngPath (1,:) char
                ~
                ~
            end
            if ~isfile(pngPath)
                return;
            end
            try
                fid = fopen(pngPath, 'r');
                if fid < 3, return; end
                cleanup = onCleanup(@() fclose(fid)); %#ok<NASGU>
                bytes = fread(fid, '*uint8');
                b64 = matlab.net.base64encode(bytes);
            catch
                return;
            end
            obj.BodyParts(end+1) = string(['<p class="chart"><img alt="chart" ' ...
                'src="data:image/png;base64,' char(b64) '" /></p>']);
        end

        function addSvgChart(obj, svgMarkup)
            %ADDSVGCHART  v1.5 -- inline SVG chart.
            %   SectionBuilder prefers this over addImage when the
            %   backend exposes it.  The SVG is dropped verbatim into
            %   the body so charts scale crisply and stay searchable /
            %   diffable as text.
            arguments
                obj
                svgMarkup (1,:) char
            end
            obj.BodyParts(end+1) = string(['<figure class="chart">' ...
                svgMarkup '</figure>']);
        end

        function addCodeBlock(obj, text)
            %ADDCODEBLOCK  Monospace + light-grey-fill multi-line block.
            arguments
                obj
                text (1,:) char
            end
            esc = autotest.report.backends.HtmlBackend.esc(text);
            obj.BodyParts(end+1) = string(['<pre class="diag">' esc '</pre>']);
        end

        % ===================================================== TOC

        function addTOC(obj, ~)
            % HTML doesn't need an explicit TOC field; the H2/H3 anchors
            % make jumping cheap.  The browser's outline view + ctrl-F
            % cover the use case.  We DO emit a minimal in-page nav for
            % printed copies, populated after close() walks BodyParts.
            obj.BodyParts(end+1) = "<!--TOC_PLACEHOLDER-->";
        end

        % ===================================================== Tables

        function addTable(obj, headers, rows, ~)
            arguments
                obj
                headers cell
                rows    cell
                ~
            end
            hdr = '';
            for c = 1:numel(headers)
                hdr = [hdr '<th>' ...
                    autotest.report.backends.HtmlBackend.esc(headers{c}) ...
                    '</th>']; %#ok<AGROW>
            end
            body = '';
            for r = 1:size(rows, 1)
                body = [body '<tr>']; %#ok<AGROW>
                for c = 1:size(rows, 2)
                    val = rows{r, c};
                    if isnumeric(val), val = num2str(val); end
                    cls = '';
                    % Highlight non-zero Failed cells in deep red.
                    if c <= numel(headers) ...
                            && strcmpi(strtrim(char(headers{c})), 'failed') ...
                            && ~isempty(strtrim(char(val))) ...
                            && ~strcmp(strtrim(char(val)), '0')
                        cls = ' class="fail"';
                    end
                    body = [body '<td' cls '>' ...
                        autotest.report.backends.HtmlBackend.esc(val) ...
                        '</td>']; %#ok<AGROW>
                end
                body = [body '</tr>']; %#ok<AGROW>
            end
            obj.BodyParts(end+1) = string([ ...
                '<table class="data"><thead><tr>' hdr '</tr></thead>' ...
                '<tbody>' body '</tbody></table>']);
        end

        function addMetaTable(obj, kvRows)
            obj.BodyParts(end+1) = string( ...
                autotest.report.backends.HtmlBackend.kvTableHtml(kvRows, 'meta'));
        end

        % ===================================================== Output

        function close(obj)
            tocHtml = obj.buildToc();
            % Substitute TOC_PLACEHOLDER (if present from addTOC).
            body = strjoin(obj.BodyParts, newline);
            body = strrep(char(body), '<!--TOC_PLACEHOLDER-->', tocHtml);

            html = strings(0,1);
            html(end+1,1) = "<!DOCTYPE html>";
            html(end+1,1) = "<html lang=""en"">";
            html(end+1,1) = "<head>";
            html(end+1,1) = "<meta charset=""UTF-8"">";
            html(end+1,1) = string(['<title>' ...
                autotest.report.backends.HtmlBackend.esc(obj.Title) ...
                ' -- System Test Report</title>']);
            html(end+1,1) = "<meta name=""viewport"" content=""width=device-width, initial-scale=1"">";
            html(end+1,1) = "<style>";
            html(end+1,1) = string(autotest.report.backends.HtmlBackend.styleSheet());
            html(end+1,1) = "</style>";
            html(end+1,1) = "</head>";
            html(end+1,1) = "<body>";
            html(end+1,1) = string(autotest.report.backends.HtmlBackend.classificationBanner( ...
                obj.Classification, 'top'));
            html(end+1,1) = "<main>";
            html(end+1,1) = string(body);
            html(end+1,1) = "</main>";
            html(end+1,1) = string(autotest.report.backends.HtmlBackend.classificationBanner( ...
                obj.Classification, 'bottom'));
            html(end+1,1) = "</body></html>";

            outDir = fileparts(obj.OutputPath);
            if ~isempty(outDir) && ~isfolder(outDir)
                mkdir(outDir);
            end
            if isfile(obj.OutputPath)
                try, delete(obj.OutputPath); catch, end
            end
            finalHtml = char(strjoin(html, newline));
            % v1.5: self-attesting content checksum.  Mirrors the
            % docx two-pass technique: compute sha256 over the file
            % AS WRITTEN (with the sentinel intact), then substitute
            % the sentinel for the hash and rewrite.  Reviewers can
            % verify by reversing the substitution and rehashing.
            if contains(finalHtml, '__DOCX_SHA256_SLOT__')
                preHash = autotest.report.backends.HtmlBackend.sha256OfString(finalHtml);
                if ~isempty(preHash)
                    finalHtml = strrep(finalHtml, '__DOCX_SHA256_SLOT__', preHash);
                end
            end
            fid = fopen(obj.OutputPath, 'w');
            if fid < 3
                error('autotest:report:HtmlWrite', ...
                    'Cannot write %s', obj.OutputPath);
            end
            cleanup = onCleanup(@() fclose(fid)); %#ok<NASGU>
            fwrite(fid, unicode2native(finalHtml, 'UTF-8'));
        end

        function pdfPath = renderPdf(~, ~, ~)
            pdfPath = '';   % HTML has no native PDF tier.
        end
    end

    % ====================================================== private helpers

    methods (Access = private)
        function tocHtml = buildToc(obj)
            % Walk the accumulated H2 (level 1) / H3 (level 2) headings
            % and build a flat nav block.  Cheap, deterministic, and
            % survives reordering of the body without manual edits.
            entries = strings(0,1);
            entries(end+1,1) = "<nav class=""toc""><h2>Contents</h2><ol>";
            currentLvl1Open = false;
            for i = 1:numel(obj.BodyParts)
                line = char(obj.BodyParts(i));
                tok2 = regexp(line, '^<h2 id="([^"]+)" class="lvl1">([^<]*)</h2>', ...
                    'tokens', 'once');
                if ~isempty(tok2)
                    if currentLvl1Open
                        entries(end+1,1) = "</ol></li>"; %#ok<AGROW>
                    end
                    entries(end+1,1) = string(sprintf( ...
                        '<li><a href="#%s">%s</a><ol>', ...
                        tok2{1}, ...
                        autotest.report.backends.HtmlBackend.esc(tok2{2}))); %#ok<AGROW>
                    currentLvl1Open = true;
                    continue;
                end
                tok3 = regexp(line, '^<h3 id="([^"]+)" class="lvl2">([^<]*)</h3>', ...
                    'tokens', 'once');
                if ~isempty(tok3) && currentLvl1Open
                    entries(end+1,1) = string(sprintf( ...
                        '<li><a href="#%s">%s</a></li>', ...
                        tok3{1}, ...
                        autotest.report.backends.HtmlBackend.esc(tok3{2}))); %#ok<AGROW>
                end
            end
            if currentLvl1Open
                entries(end+1,1) = "</ol></li>";
            end
            entries(end+1,1) = "</ol></nav>";
            tocHtml = char(strjoin(entries, newline));
        end
    end

    methods (Static)
        function svg = pieChartSvg(passed, failed, incomplete)
            %PIECHARTSVG  v1.5 -- inline SVG pie chart.
            %
            %   Colours follow the locked v1.4 palette: muted gold for
            %   passed, deep red for failed, slate for incomplete.
            %   Renders at viewBox 0..400 so the browser can scale.
            vals = double([passed, failed, incomplete]);
            names = {'Passed','Failed','Incomplete'};
            colours = {'#B45309', '#991B1B', '#4B5563'};
            total = sum(vals);
            cx = 200; cy = 200; r = 140;
            parts = strings(0,1);
            parts(end+1,1) = "<svg xmlns=""http://www.w3.org/2000/svg"" " + ...
                "viewBox=""0 0 600 420"" class=""pie"" role=""img"" " + ...
                "aria-label=""Test Results Breakdown"">";
            parts(end+1,1) = "<title>Test Results Breakdown</title>";
            if total <= 0
                parts(end+1,1) = string(sprintf( ...
                    '<circle cx="%d" cy="%d" r="%d" fill="#4B5563" />', ...
                    cx, cy, r));
                parts(end+1,1) = "<text x=""200"" y=""370"" " + ...
                    "text-anchor=""middle"" fill=""#1F2937"" " + ...
                    "font-family=""Calibri, sans-serif"" font-size=""18"">" + ...
                    "(no tests)</text>";
                parts(end+1,1) = "</svg>";
                svg = char(strjoin(parts, ''));
                return;
            end
            % Slices.
            startAng = -pi/2;   % start at 12 o'clock
            legendY = 60;
            legendX = 420;
            for k = 1:numel(vals)
                if vals(k) <= 0, continue; end
                frac = vals(k) / total;
                endAng = startAng + frac * 2 * pi;
                x1 = cx + r * cos(startAng);
                y1 = cy + r * sin(startAng);
                x2 = cx + r * cos(endAng);
                y2 = cy + r * sin(endAng);
                largeArc = double(frac > 0.5);
                if frac >= 1 - 1e-9
                    % Single-slice case: a full circle can't be drawn as
                    % a single `A` arc, so emit two halves.
                    parts(end+1,1) = string(sprintf( ...
                        '<path d="M %g %g A %d %d 0 1 1 %g %g A %d %d 0 1 1 %g %g Z" fill="%s" stroke="#FFFFFF" stroke-width="2"/>', ...
                        cx + r, cy, r, r, cx - r, cy, r, r, cx + r, cy, ...
                        colours{k})); %#ok<AGROW>
                else
                    parts(end+1,1) = string(sprintf( ...
                        '<path d="M %d %d L %g %g A %d %d 0 %d 1 %g %g Z" fill="%s" stroke="#FFFFFF" stroke-width="2"/>', ...
                        cx, cy, x1, y1, r, r, largeArc, x2, y2, ...
                        colours{k})); %#ok<AGROW>
                end
                % Legend entry.
                parts(end+1,1) = string(sprintf( ...
                    '<rect x="%d" y="%d" width="18" height="18" fill="%s"/>', ...
                    legendX, legendY, colours{k})); %#ok<AGROW>
                parts(end+1,1) = string(sprintf( ...
                    '<text x="%d" y="%d" fill="#1F2937" font-family="Calibri, sans-serif" font-size="16">%s (%d)</text>', ...
                    legendX + 26, legendY + 14, names{k}, vals(k))); %#ok<AGROW>
                legendY = legendY + 32;
                startAng = endAng;
            end
            parts(end+1,1) = "<text x=""200"" y=""390"" text-anchor=""middle"" " + ...
                "fill=""#1F2937"" font-family=""Calibri, sans-serif"" " + ...
                "font-size=""18"" font-weight=""bold"">Test Results Breakdown</text>";
            parts(end+1,1) = "</svg>";
            svg = char(strjoin(parts, ''));
        end

        function svg = barChartSvg(perSource)
            %BARCHARTSVG  v1.5 -- inline SVG horizontal bar chart of pass rate per source.
            if isempty(perSource)
                svg = '';
                return;
            end
            n = numel(perSource);
            rowH = 28;
            padTop = 50; padBottom = 30; padLeft = 200; padRight = 80;
            barAreaW = 540;
            totalH = padTop + n * rowH + padBottom;
            totalW = padLeft + barAreaW + padRight;
            parts = strings(0,1);
            parts(end+1,1) = string(sprintf([ ...
                '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %d %d" ' ...
                'class="bar" role="img" aria-label="Pass Rate per Source File">'], ...
                totalW, totalH));
            parts(end+1,1) = "<title>Pass Rate per Source File</title>";
            parts(end+1,1) = string(sprintf( ...
                '<text x="%d" y="28" fill="#1F2937" font-family="Calibri, sans-serif" font-size="18" font-weight="bold">Pass Rate per Source File</text>', ...
                padLeft));
            % X axis gridlines at 0/25/50/75/100.
            for g = 0:25:100
                xg = padLeft + (g/100) * barAreaW;
                parts(end+1,1) = string(sprintf( ...
                    '<line x1="%g" y1="%d" x2="%g" y2="%d" stroke="#D1D5DB" stroke-width="1"/>', ...
                    xg, padTop, xg, padTop + n * rowH)); %#ok<AGROW>
                parts(end+1,1) = string(sprintf( ...
                    '<text x="%g" y="%d" text-anchor="middle" fill="#4B5563" font-family="Calibri, sans-serif" font-size="12">%d%%</text>', ...
                    xg, padTop + n * rowH + 16, g)); %#ok<AGROW>
            end
            for i = 1:n
                p = perSource(i);
                if isfield(p, 'Total') && p.Total > 0
                    rate = 100 * p.Passed / p.Total;
                else
                    rate = 0;
                end
                y = padTop + (i-1) * rowH + 4;
                barW = (rate/100) * barAreaW;
                lbl = char(p.File);
                if length(lbl) > 28, lbl = ['...' lbl(end-25:end)]; end
                parts(end+1,1) = string(sprintf( ...
                    '<text x="%d" y="%g" text-anchor="end" fill="#1F2937" font-family="Calibri, sans-serif" font-size="13">%s</text>', ...
                    padLeft - 12, y + 14, ...
                    autotest.report.backends.HtmlBackend.esc(lbl))); %#ok<AGROW>
                parts(end+1,1) = string(sprintf( ...
                    '<rect x="%d" y="%g" width="%g" height="%d" fill="#B45309"/>', ...
                    padLeft, y, barW, rowH - 10)); %#ok<AGROW>
                parts(end+1,1) = string(sprintf( ...
                    '<text x="%g" y="%g" fill="#1F2937" font-family="Calibri, sans-serif" font-size="12">%.1f%%</text>', ...
                    padLeft + barW + 6, y + 14, rate)); %#ok<AGROW>
            end
            parts(end+1,1) = "</svg>";
            svg = char(strjoin(parts, ''));
        end
    end

    methods (Static, Access = private)
        function out = esc(text)
            t = char(text);
            t = strrep(t, '&', '&amp;');
            t = strrep(t, '<', '&lt;');
            t = strrep(t, '>', '&gt;');
            t = strrep(t, '"', '&quot;');
            t = strrep(t, '''', '&#39;');
            out = t;
        end

        function s = slugify(text)
            t = lower(char(text));
            t = regexprep(t, '[^a-z0-9]+', '-');
            t = regexprep(t, '^-+|-+$', '');
            if isempty(t), t = 'section'; end
            s = t;
        end

        function html = kvTableHtml(kvRows, cls)
            rows = '';
            for r = 1:size(kvRows, 1)
                k = kvRows{r,1};
                v = kvRows{r,2};
                if isnumeric(v), v = num2str(v); end
                rows = [rows '<tr><th scope="row">' ...
                    autotest.report.backends.HtmlBackend.esc(k) ...
                    '</th><td>' ...
                    autotest.report.backends.HtmlBackend.esc(v) ...
                    '</td></tr>']; %#ok<AGROW>
            end
            html = ['<table class="kv ' cls '"><tbody>' rows ...
                '</tbody></table>'];
        end

        function s = classificationBanner(level, where)
            fill = autotest.report.Style.classificationFill(level);
            s = ['<div class="banner banner-' where '" ' ...
                'style="background:#' fill ';color:#FFFFFF;">' ...
                upper(strtrim(level)) '</div>'];
        end

        function hash = sha256OfString(text)
            %SHA256OFSTRING  Hex sha256 of TEXT (UTF-8 bytes) via Java.
            %   Used by close() to embed a self-attesting content hash
            %   in place of the __DOCX_SHA256_SLOT__ sentinel.  Returns
            %   '' on any failure -- the sentinel just stays in place.
            hash = '';
            try
                digest = java.security.MessageDigest.getInstance('SHA-256');
                bytes = unicode2native(char(text), 'UTF-8');
                digest.update(bytes);
                raw = typecast(digest.digest(), 'uint8');
                hash = lower(reshape(dec2hex(raw, 2)', 1, []));
            catch
                hash = '';
            end
        end

        function css = styleSheet()
            % v1.4 palette baked in; no external font calls.
            css = [ ...
                ':root{--text:#1F2937;--text2:#4B5563;--accent:#B45309;' ...
                '--fail:#991B1B;--codefill:#F7FAFC;--hdrshade:#E7E6E6;' ...
                '--metashade:#F2F2F2;--border:#BFBFBF;}' newline ...
                '*{box-sizing:border-box}' newline ...
                'html,body{margin:0;padding:0;background:#FFFFFF;' ...
                'color:var(--text);font-family:Calibri,"Segoe UI",Arial,sans-serif;' ...
                'font-size:14px;line-height:1.5}' newline ...
                'main{max-width:960px;margin:0 auto;padding:24px 32px 48px}' newline ...
                '.banner{font-weight:bold;text-align:center;padding:6px 0;' ...
                'letter-spacing:0.08em;font-size:13px}' newline ...
                '.banner-bottom{margin-top:32px}' newline ...
                'h1.cover-title{font-size:48px;font-weight:bold;color:var(--text);' ...
                'text-align:center;margin:32px 0 8px}' newline ...
                'p.cover-subtitle{font-style:italic;color:var(--text2);' ...
                'text-align:center;font-size:18px;margin:0 0 24px}' newline ...
                'h2.lvl1{color:var(--text);font-size:22px;border-bottom:1px solid var(--accent);' ...
                'padding-bottom:4px;margin:32px 0 12px}' newline ...
                'h3.lvl2{color:var(--text);font-size:18px;margin:24px 0 8px}' newline ...
                'h4.lvl3{color:var(--text);font-size:15px;margin:16px 0 6px}' newline ...
                'p{margin:8px 0 12px}' newline ...
                'p.blank{margin:18px 0}' newline ...
                'hr.accent-rule{border:0;border-top:1px solid var(--accent);' ...
                'margin:18px auto;width:88%}' newline ...
                'table{border-collapse:collapse;width:100%;margin:8px 0 20px}' newline ...
                'table.data th,table.data td{border:1px solid var(--border);' ...
                'padding:6px 10px;text-align:left;vertical-align:top;font-size:13px}' newline ...
                'table.data th{background:var(--hdrshade);font-weight:bold}' newline ...
                'table.data td.fail{color:var(--fail);font-weight:bold}' newline ...
                'table.kv{margin:8px auto;max-width:680px}' newline ...
                'table.kv th{background:var(--metashade);color:var(--text2);' ...
                'text-align:left;font-weight:normal;width:38%;padding:6px 12px;' ...
                'border:1px solid var(--border);font-size:13px}' newline ...
                'table.kv td{padding:6px 12px;border:1px solid var(--border);font-size:13px}' newline ...
                'aside.dist-box{border:2px solid #000;padding:18px 24px;margin:18px auto;' ...
                'max-width:720px;text-align:center}' newline ...
                'aside.dist-box h2{margin-top:0;font-size:14px;letter-spacing:0.08em}' newline ...
                'aside.dist-box p{font-size:13px;color:var(--text)}' newline ...
                'pre.diag{background:var(--codefill);border:1px solid #E5E7EB;' ...
                'padding:10px 14px;font-family:Consolas,"Cascadia Mono",Courier,monospace;' ...
                'font-size:12px;color:var(--text);white-space:pre-wrap;' ...
                'word-break:break-word;margin:6px 0 12px;border-radius:3px}' newline ...
                'figure.chart{margin:12px 0 18px;text-align:center}' newline ...
                'figure.chart svg{max-width:100%;height:auto}' newline ...
                'nav.toc{background:var(--metashade);border:1px solid var(--border);' ...
                'padding:14px 22px;margin:20px 0 28px;border-radius:3px}' newline ...
                'nav.toc h2{margin-top:0;font-size:16px;color:var(--text2)}' newline ...
                'nav.toc ol{margin:4px 0 4px 22px;padding:0}' newline ...
                'nav.toc a{color:var(--text);text-decoration:none}' newline ...
                'nav.toc a:hover{text-decoration:underline}' newline ...
                'section.cover{padding:18px 0 32px}' newline ...
                '.page-break{break-before:page;page-break-before:always;height:0}' newline ...
                '@media print{.banner{position:fixed;left:0;right:0;z-index:10}' ...
                '.banner-top{top:0}.banner-bottom{bottom:0}' ...
                'main{padding-top:48px;padding-bottom:48px}}' newline];
        end
    end
end
