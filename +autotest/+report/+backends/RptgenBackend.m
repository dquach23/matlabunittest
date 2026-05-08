classdef RptgenBackend < handle
    %RPTGENBACKEND  Phase 15 -- mlreportgen.dom + report path.
    %
    %   Used as the primary path when MATLAB Report Generator is
    %   licensed and mlreportgen.dom is on the path.  Uses
    %   mlreportgen.dom.Document for the .docx and (optionally)
    %   mlreportgen.dom.PDFMaker for the .pdf.
    %
    %   Public API mirrors OoxmlBackend.

    properties (SetAccess = immutable)
        OutputPath  (1,:) char
    end

    properties (SetAccess = private)
        Doc                                 % mlreportgen.dom.Document
        ContentWidth double = 9360
    end

    methods
        function obj = RptgenBackend(outputPath)
            arguments
                outputPath (1,:) char
            end
            obj.OutputPath = outputPath;
            obj.ContentWidth = autotest.report.Style.ContentWidth;
            obj.Doc = mlreportgen.dom.Document(outputPath, 'docx');
            % Set page geometry to US Letter, 1" margins.
            try
                obj.Doc.CurrentPageLayout.PageSize.Width  = '8.5in';
                obj.Doc.CurrentPageLayout.PageSize.Height = '11in';
                obj.Doc.CurrentPageLayout.PageMargins.Top    = '1in';
                obj.Doc.CurrentPageLayout.PageMargins.Bottom = '1in';
                obj.Doc.CurrentPageLayout.PageMargins.Left   = '1in';
                obj.Doc.CurrentPageLayout.PageMargins.Right  = '1in';
            catch
                % page layout settings vary by R-version; non-fatal.
            end
            % Phase 16 (Part B item 1): centred Page X of Y footer.
            % Mirrors OoxmlBackend so visible output is consistent
            % across backends.  Best-effort: mlreportgen's footer API
            % varies between R-versions; failure to attach is non-fatal
            % (the doc still renders, just without page numbers).
            try
                import mlreportgen.dom.*
                footers = obj.Doc.CurrentPageLayout.PageFooters;
                if ~isempty(footers)
                    footer = footers(1);
                    para = Paragraph();
                    para.HAlign = 'center';
                    para.FontSize = '9pt';
                    para.FontFamilyName = 'Calibri';
                    append(para, Text('Page '));
                    append(para, Page());
                    append(para, Text(' of '));
                    append(para, NumPages());
                    append(footer, para);
                end
            catch
                % rptgen footer API varies; non-fatal.
            end
        end

        function addCoverPage(obj, fields, distHeader, distBody)
            import mlreportgen.dom.*
            % Title block.
            blank = Paragraph(' ');
            blank.OutlineLevel = 0;
            append(obj.Doc, blank);

            title = Paragraph(fields.Title);
            title.HAlign = 'center';
            title.FontSize = '36pt';
            title.Bold = true;
            append(obj.Doc, title);

            subtitle = Paragraph(fields.Subtitle);
            subtitle.HAlign = 'center';
            subtitle.FontSize = '24pt';
            append(obj.Doc, subtitle);

            % Metadata table.
            mtable = FormalTable({'Field', 'Value'});
            mtable.Header = []; % Hide header row (we have plain k/v).
            append(obj.Doc, Paragraph(' '));
            t = Table(2);
            t.Width = '6.5in';
            t.HAlign = 'center';
            t.Border = 'solid';
            t.BorderColor = 'lightgray';
            for i = 1:size(fields.Metadata, 1)
                row = TableRow();
                k = TableEntry(fields.Metadata{i,1});
                k.Bold = true;
                k.BackgroundColor = '#F2F2F2';
                k.InnerMargin = '4pt';
                v = TableEntry(fields.Metadata{i,2});
                v.InnerMargin = '4pt';
                append(row, k);
                append(row, v);
                append(t, row);
            end
            append(obj.Doc, t);

            append(obj.Doc, Paragraph(' '));
            append(obj.Doc, Paragraph(' '));

            % Distribution Statement D box.
            dist = Table(1);
            dist.Width = '6.5in';
            dist.HAlign = 'center';
            dist.Border = 'solid';
            dist.BorderColor = 'black';
            dist.BorderWidth = '1.5pt';
            row = TableRow();
            cell = TableEntry();
            cell.InnerMargin = '12pt';
            cell.BorderColor = 'black';
            cell.BorderWidth = '1.5pt';
            head = Paragraph(distHeader);
            head.HAlign = 'center';
            head.Bold = true;
            head.FontSize = '14pt';
            append(cell, head);
            body = Paragraph(distBody);
            body.HAlign = 'center';
            body.FontSize = '11pt';
            append(cell, body);
            append(row, cell);
            append(dist, row);
            append(obj.Doc, dist);

            obj.addPageBreak();
        end

        function addHeading(obj, level, text)
            import mlreportgen.dom.*
            cls = sprintf('Heading%d', level);
            p = Paragraph(text);
            try
                p.StyleName = cls;
            catch
            end
            sizeMap = {'16pt', '14pt', '12pt'};
            p.FontSize = sizeMap{level};
            p.Bold = true;
            p.OutlineLevel = level;
            append(obj.Doc, p);
        end

        function addParagraph(obj, text)
            import mlreportgen.dom.*
            p = Paragraph(text);
            p.WhiteSpace = 'preserve';
            append(obj.Doc, p);
        end

        function addPageBreak(obj)
            import mlreportgen.dom.*
            br = PageBreak();
            append(obj.Doc, br);
        end

        function addBlankParagraph(obj, ~)
            import mlreportgen.dom.*
            append(obj.Doc, Paragraph(' '));
        end

        function addTOC(obj, headingText)
            import mlreportgen.dom.*
            if nargin < 2, headingText = 'Table of Contents'; end
            h = Paragraph(headingText);
            h.HAlign = 'center';
            h.FontSize = '18pt';
            h.Bold = true;
            append(obj.Doc, h);
            toc = TOC();
            try
                toc.UpdateTOC = true;
                toc.NumberOfLevels = 3;
            catch
            end
            append(obj.Doc, toc);
            obj.addPageBreak();
        end

        function addTable(obj, headers, rows, columnWidths) %#ok<INUSD>
            import mlreportgen.dom.*
            n = numel(headers);
            t = Table(n);
            t.Border = 'solid';
            t.BorderColor = 'lightgray';
            t.ColSep = 'solid';
            t.RowSep = 'solid';
            % Header row.
            hr = TableRow();
            for c = 1:n
                he = TableEntry(headers{c});
                he.Bold = true;
                he.BackgroundColor = '#E7E6E6';
                he.InnerMargin = '4pt';
                append(hr, he);
            end
            append(t, hr);
            % Body rows.
            for r = 1:size(rows, 1)
                tr = TableRow();
                for c = 1:n
                    val = rows{r, c};
                    if isnumeric(val), val = num2str(val); end
                    te = TableEntry(char(val));
                    te.InnerMargin = '4pt';
                    append(tr, te);
                end
                append(t, tr);
            end
            append(obj.Doc, t);
            append(obj.Doc, Paragraph(' '));
        end

        function addMetaTable(obj, kvRows)
            import mlreportgen.dom.*
            t = Table(2);
            t.Width = '6.5in';
            t.HAlign = 'center';
            t.Border = 'solid';
            t.BorderColor = 'lightgray';
            for i = 1:size(kvRows, 1)
                tr = TableRow();
                k = TableEntry(kvRows{i,1});
                k.Bold = true;
                k.BackgroundColor = '#F2F2F2';
                k.InnerMargin = '4pt';
                v = TableEntry(kvRows{i,2});
                v.InnerMargin = '4pt';
                append(tr, k);
                append(tr, v);
                append(t, tr);
            end
            append(obj.Doc, t);
        end

        function close(obj)
            close(obj.Doc);
            % Phase 16 (Part B item 4): remove the per-document _docs
            % intermediate that mlreportgen.dom emits next to the .docx.
            % Best-effort; if Word still has handles open, the rmdir
            % silently fails and the directory persists harmlessly.
            try
                [folder, base, ~] = fileparts(obj.OutputPath);
                docsDir = fullfile(folder, [base '_docs']);
                if isfolder(docsDir)
                    rmdir(docsDir, 's');
                end
            catch
            end
        end

        function pdfPath = renderPdf(obj, mode, ~) %#ok<INUSL>
            % Convert the .docx to .pdf using the Report Generator's
            % docToPDF utility.  Requires Report Generator AND Microsoft
            % Word or LibreOffice on PATH (Report Generator drives them
            % internally).  MODE: 'rptgen' (force) or 'auto' (return
            % empty on failure).
            pdfPath = '';
            try
                [folder, base, ~] = fileparts(obj.OutputPath);
                pdfPath = fullfile(folder, [base '.pdf']);
                if exist('mlreportgen.utils.docToPDF', 'file') ~= 0 ...
                        || ~isempty(which('mlreportgen.utils.docToPDF'))
                    mlreportgen.utils.docToPDF(obj.OutputPath, pdfPath);
                else
                    rptview(obj.OutputPath, 'pdf');
                    % rptview produces same-name .pdf next to .docx.
                    cand = fullfile(folder, [base '.pdf']);
                    if isfile(cand), pdfPath = cand; end
                end
            catch ME
                pdfPath = '';
                if strcmp(mode, 'rptgen')
                    rethrow(ME);
                end
            end
        end
    end
end
