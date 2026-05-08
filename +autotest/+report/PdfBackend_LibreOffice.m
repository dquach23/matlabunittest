classdef PdfBackend_LibreOffice
    %PDFBACKEND_LIBREOFFICE  Phase 16 (Part B item 3) -- LibreOffice PDF tier.
    %
    %   Wraps the LibreOffice headless converter with a pre-conversion
    %   StarBasic macro that walks oDoc.DocumentIndexes and updates each
    %   one (TOC, list of figures, list of tables, etc.) before
    %   storeToURL writer_pdf_Export.  The resulting .pdf has populated
    %   TOC page numbers without requiring the user to open the .docx in
    %   Word first.
    %
    %   Usage:
    %       pdfPath = autotest.report.PdfBackend_LibreOffice.render(docxPath, pdfPath)
    %
    %   Returns the produced PDF path, or '' when:
    %     - LibreOffice is not on PATH and not in the autotest preference
    %     - the conversion fails (e.g. .docx still locked by Word)
    %
    %   Implementation notes:
    %     The cleanest way to invoke a one-off StarBasic macro from a
    %     headless soffice is to (a) provision a fresh user profile via
    %     `-env:UserInstallation=...`, (b) drop a .xba library file into
    %     that profile's Basic/Standard/ subdirectory before launch, and
    %     (c) invoke `macro:///Standard.AutoTOC.RefreshAndExport(...)`.
    %     This module does that, and falls back to a bare
    %     `--convert-to pdf` (which produces a .pdf with an unpopulated
    %     TOC) when any step fails.  The fallback PDF is still a valid
    %     deliverable -- Word will refresh fields on first open if the
    %     reader has the .docx alongside.
    %
    %   The user's primary path is RptgenBackend (license-gated MATLAB
    %   Report Generator) which produces a fully-refreshed .pdf via
    %   mlreportgen.utils.docToPDF.  This LibreOffice tier is the
    %   portability fallback for installations without Report Generator.

    methods (Static)
        function out = render(docxPath, pdfPath)
            arguments
                docxPath (1,:) char
                pdfPath  (1,:) char
            end
            out = '';
            soffice = autotest.report.PdfBackend_LibreOffice.findSoffice();
            if isempty(soffice), return; end

            % Tier 1: provisioned user profile + UNO macro for full TOC refresh.
            outFromMacro = autotest.report.PdfBackend_LibreOffice.tryMacroPath( ...
                soffice, docxPath, pdfPath);
            if ~isempty(outFromMacro) && isfile(outFromMacro)
                out = outFromMacro;
                return;
            end

            % Tier 2: bare --convert-to pdf.  Produces a .pdf with an
            % unpopulated TOC page-number column when the source .docx
            % was emitted with `<w:updateFields w:val="true"/>` (Word
            % refresh-on-open is not honoured by LibreOffice's
            % --convert-to pipeline).  Better than no PDF.
            outFromBare = autotest.report.PdfBackend_LibreOffice.bareConvert( ...
                soffice, docxPath, pdfPath);
            if ~isempty(outFromBare) && isfile(outFromBare)
                out = outFromBare;
                return;
            end
        end

        function path = findSoffice()
            %FINDSOFFICE  Resolve the LibreOffice executable path.
            %   Order: autotest.LibreOfficePath preference; standard
            %   install paths on Windows / macOS / Linux.  Returns ''
            %   when nothing matches.
            path = '';
            try
                lop = getpref('autotest', 'LibreOfficePath', '');
                if ~isempty(lop) && isfile(lop)
                    path = lop; return;
                end
            catch
            end
            candidates = { ...
                'C:\Program Files\LibreOffice\program\soffice.exe', ...
                'C:\Program Files (x86)\LibreOffice\program\soffice.exe', ...
                '/Applications/LibreOffice.app/Contents/MacOS/soffice', ...
                '/usr/bin/soffice', ...
                '/usr/bin/libreoffice'};
            for i = 1:numel(candidates)
                if isfile(candidates{i})
                    path = candidates{i};
                    try, setpref('autotest', 'LibreOfficePath', path); catch, end
                    return;
                end
            end
        end

        function out = tryMacroPath(soffice, docxPath, pdfPath)
            %TRYMACROPATH  Provision profile + run UNO macro.  '' on failure.
            out = '';
            tmpProfile = tempname();
            cleanup = onCleanup(@() autotest.report.PdfBackend_LibreOffice.cleanupDir(tmpProfile));
            try
                basicDir = fullfile(tmpProfile, 'user', 'basic', 'Standard');
                if ~isfolder(basicDir), mkdir(basicDir); end
                % Drop the .xba library file + script.xlb / dialog.xlb stubs
                % into the standard library so soffice loads it on launch.
                xbaPath = fullfile(basicDir, 'AutoTOC.xba');
                fid = fopen(xbaPath, 'w');
                if fid < 3, return; end
                fwrite(fid, autotest.report.PdfBackend_LibreOffice.xbaSource(), 'char');
                fclose(fid);
                xlbPath = fullfile(basicDir, 'script.xlb');
                fid = fopen(xlbPath, 'w');
                if fid < 3, return; end
                fwrite(fid, autotest.report.PdfBackend_LibreOffice.scriptXlb(), 'char');
                fclose(fid);
                dlgPath = fullfile(basicDir, 'dialog.xlb');
                fid = fopen(dlgPath, 'w');
                if fid < 3, return; end
                fwrite(fid, autotest.report.PdfBackend_LibreOffice.dialogXlb(), 'char');
                fclose(fid);
            catch
                return;
            end
            inUrl  = autotest.report.PdfBackend_LibreOffice.toFileUrl(docxPath);
            outUrl = autotest.report.PdfBackend_LibreOffice.toFileUrl(pdfPath);
            profUrl = autotest.report.PdfBackend_LibreOffice.toFileUrl(tmpProfile);
            cmd = sprintf([ ...
                '"%s" --headless --norestore --nologo --nofirststartwizard ' ...
                '-env:UserInstallation=%s ' ...
                '"macro:///Standard.AutoTOC.RefreshAndExport(%s,%s)"'], ...
                soffice, profUrl, inUrl, outUrl);
            [status, ~] = system(cmd);
            if status == 0 && isfile(pdfPath)
                out = pdfPath;
            end
        end

        function out = bareConvert(soffice, docxPath, pdfPath)
            %BARECONVERT  Tier-2 fallback: --convert-to pdf, no macro.
            out = '';
            outDir = fileparts(pdfPath);
            cmd = sprintf('"%s" --headless --convert-to pdf --outdir "%s" "%s"', ...
                soffice, outDir, docxPath);
            [status, ~] = system(cmd);
            if status ~= 0, return; end
            [~, base, ~] = fileparts(docxPath);
            cand = fullfile(outDir, [base '.pdf']);
            if ~isfile(cand), return; end
            if ~strcmp(cand, pdfPath)
                try, movefile(cand, pdfPath, 'f'); catch, end
            end
            if isfile(pdfPath), out = pdfPath; end
        end

        function url = toFileUrl(p)
            %TOFILEURL  Convert a local path to file:// URL form.
            %   Forward-slashes throughout, no Windows backslashes.
            p = strrep(char(p), '\', '/');
            if length(p) >= 2 && p(2) == ':'
                url = ['file:///' p];
            elseif startsWith(p, '/')
                url = ['file://' p];
            else
                % Best effort -- treat as already-URL-ish.
                url = ['file:///' p];
            end
        end

        function src = xbaSource()
            %XBASOURCE  Phase 16 Part B item 3 -- StarBasic library source.
            %   The RefreshAndExport sub takes a docx file:// URL and a
            %   pdf file:// URL; opens the doc, walks every DocumentIndex
            %   and calls .update(), then exports as PDF and closes.
            src = [ ...
                '<?xml version="1.0" encoding="UTF-8"?>' newline ...
                '<!DOCTYPE library:library PUBLIC "-//OpenOffice.org//DTD OfficeDocument 1.0//EN" "library.dtd">' newline ...
                '<library:library xmlns:library="http://openoffice.org/2000/library" library:name="Standard" library:link="false">' newline ...
                ' <library:element library:name="AutoTOC"/>' newline ...
                '</library:library>' newline ...
                '<?xml version="1.0" encoding="UTF-8"?>' newline ...
                '<!DOCTYPE script:module PUBLIC "-//OpenOffice.org//DTD OfficeDocument 1.0//EN" "module.dtd">' newline ...
                '<script:module xmlns:script="http://openoffice.org/2000/script" script:name="AutoTOC" script:language="StarBasic">' newline ...
                'Sub RefreshAndExport(sInputUrl As String, sOutputUrl As String)' newline ...
                '    Dim oDoc As Object' newline ...
                '    Dim oArgs(0) As New com.sun.star.beans.PropertyValue' newline ...
                '    Dim oSaveArgs(0) As New com.sun.star.beans.PropertyValue' newline ...
                '    oArgs(0).Name  = "Hidden"' newline ...
                '    oArgs(0).Value = True' newline ...
                '    oDoc = StarDesktop.loadComponentFromURL(sInputUrl, "_blank", 0, oArgs())' newline ...
                '    If IsNull(oDoc) Then Exit Sub' newline ...
                '    Dim i As Integer' newline ...
                '    For i = 0 To oDoc.DocumentIndexes.Count - 1' newline ...
                '        oDoc.DocumentIndexes.getByIndex(i).update()' newline ...
                '    Next i' newline ...
                '    oSaveArgs(0).Name  = "FilterName"' newline ...
                '    oSaveArgs(0).Value = "writer_pdf_Export"' newline ...
                '    oDoc.storeToURL(sOutputUrl, oSaveArgs())' newline ...
                '    oDoc.close(True)' newline ...
                'End Sub' newline ...
                '</script:module>' newline];
        end

        function src = scriptXlb()
            src = [ ...
                '<?xml version="1.0" encoding="UTF-8"?>' newline ...
                '<!DOCTYPE library:library PUBLIC "-//OpenOffice.org//DTD OfficeDocument 1.0//EN" "library.dtd">' newline ...
                '<library:library xmlns:library="http://openoffice.org/2000/library" library:name="Standard" library:link="false" library:readonly="false">' newline ...
                ' <library:element library:name="AutoTOC"/>' newline ...
                '</library:library>' newline];
        end

        function src = dialogXlb()
            src = [ ...
                '<?xml version="1.0" encoding="UTF-8"?>' newline ...
                '<!DOCTYPE library:library PUBLIC "-//OpenOffice.org//DTD OfficeDocument 1.0//EN" "library.dtd">' newline ...
                '<library:library xmlns:library="http://openoffice.org/2000/library" library:name="Standard" library:link="false"/>' newline];
        end

        function cleanupDir(dirPath)
            try
                if ~isempty(dirPath) && isfolder(dirPath)
                    rmdir(dirPath, 's');
                end
            catch
            end
        end
    end
end
