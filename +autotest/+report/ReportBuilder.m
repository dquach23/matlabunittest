classdef ReportBuilder
    %REPORTBUILDER  Phase 15 -- top-level orchestrator.
    %
    %   info = autotest.report.ReportBuilder.build(folder, opts)
    %
    %   Inputs:
    %     FOLDER  - the project folder.  <folder>/_autotest/reports/
    %               must already contain summary.txt + results.xml from
    %               a previous autotest.runWorkflow call.
    %     OPTS    - struct with the public-API keys (DisplayName, Owner,
    %               DocVersion, ProjectPrefix, DistributionReason,
    %               DistributionDate, DistributionController, OutputDir,
    %               PdfBackend).  Missing fields are filled in with
    %               defaults.
    %
    %   Output:
    %     INFO    - struct with paths to the generated artefacts:
    %                 .DocxPath, .PdfPath, .BackendLogPath, .BackendName.

    methods (Static)
        function info = build(folder, opts)
            arguments
                folder (1,:) char
                opts struct
            end
            opts = autotest.report.ReportBuilder.applyDefaults(folder, opts);
            outputDir = opts.OutputDir;
            if ~isfolder(outputDir), mkdir(outputDir); end

            % Probe and log backend.
            detector = autotest.report.BackendDetector.probe();
            backendLog = fullfile(outputDir, 'report_backend.log');
            autotest.report.BackendDetector.logToFile(detector, backendLog);

            % Read inputs.
            data      = autotest.report.ResultsParser.parse(folder);
            inventory = autotest.report.SourceInventory.scan(folder);
            defects   = autotest.report.DefectRegister.build(data, opts.ProjectPrefix);

            % Resolve output paths.
            base = autotest.report.ReportBuilder.outputBaseName(folder, opts);
            docxPath = fullfile(outputDir, [base '_TestReport.docx']);
            pdfPath = fullfile(outputDir, [base '_TestReport.pdf']);

            % If the docx is currently open in Word, rename it out of the
            % way so the rebuild succeeds.
            if isfile(docxPath)
                try
                    delete(docxPath);
                catch
                    moved = [docxPath sprintf('.locked-%s.bak', char(datetime('now','Format','HHmmss')))];
                    try, movefile(docxPath, moved, 'f'); catch, end
                end
            end

            % Construct backend.
            switch detector.BackendName
                case 'rptgen'
                    backend = autotest.report.backends.RptgenBackend(docxPath);
                case 'ooxml'
                    backend = autotest.report.backends.OoxmlBackend(docxPath, opts.Classification);
                otherwise
                    error('autotest:report:Backend', 'No backend selected.');
            end

            % Phase 16 (Part B item 7): collect audit data BEFORE
            % emitting so Appendix E can render the textual fields
            % (commit hash, timestamps, backend choice, Pass count).
            % File checksums are computed AFTER the .docx + .pdf are
            % written and published in a sidecar (`<base>_audit.txt`)
            % next to the deliverables -- a file's sha256 cannot be
            % embedded inside itself.
            audit = autotest.report.ReportBuilder.collectAudit( ...
                opts, data, detector, docxPath, pdfPath);

            % Build context for SectionBuilder.
            ctx = struct( ...
                'Opts',          opts, ...
                'Data',          data, ...
                'Inventory',     inventory, ...
                'Defects',       defects, ...
                'ProjectPrefix', opts.ProjectPrefix, ...
                'Audit',         audit);

            % Emit the cover page, TOC, body, appendices.
            % v1.4: cover() consolidated into SectionBuilder so the
            % former +autotest/+report/CoverPage.m can be retired.
            ctxOpts = autotest.report.ReportBuilder.coverFields(opts, data);
            autotest.report.SectionBuilder.cover(backend, ctxOpts);
            backend.addTOC('Table of Contents');
            autotest.report.SectionBuilder.emit(backend, ctx);
            backend.close();

            % v1.3 Part B item 2: self-attesting embedded sha256.
            % SectionBuilder.appendixE wrote the sentinel
            % `__DOCX_SHA256_SLOT__` into Appendix E.5; now that the
            % .docx is on disk, compute its sha256, unzip, substitute
            % the sentinel for the hex, and re-zip.  The inline value
            % is the pre-substitution hash; reviewers can verify it
            % by reverting the substitution.  Best-effort: failures
            % are non-fatal -- the sentinel just stays in the
            % document and the sidecar still carries the
            % post-substitution hash.
            try
                autotest.report.ReportBuilder.embedSelfChecksum(docxPath);
            catch
            end

            % Render PDF if requested.
            generatedPdfPath = '';
            if ~strcmpi(opts.PdfBackend, 'none')
                generatedPdfPath = autotest.report.ReportBuilder.tryRenderPdf( ...
                    backend, docxPath, pdfPath, opts.PdfBackend, detector);
            end

            % Phase 16 (Part B item 7): write the audit sidecar AFTER
            % both deliverables exist on disk.  Carries the post-write
            % sha256 of the .docx and .pdf so an Authority's reviewer
            % has tamper-evident evidence the deliverable hasn't been
            % modified since the cycle.  Sidecar name matches the
            % docxPath stem so file managers sort the trio together.
            sidecarPath = audit.SidecarPath;
            try
                autotest.report.ReportBuilder.writeAuditSidecar( ...
                    sidecarPath, audit, docxPath, generatedPdfPath);
            catch
                % Sidecar is best-effort; never block the main flow.
                sidecarPath = '';
            end

            % 2026-05-14 -- minimal HTML deliverable.  Standalone single
            % file with CAPCO-colored top/bottom banners and a compact
            % summary table.  ALWAYS paints the classification fill
            % colour (UNCLASSIFIED is the CAPCO green #007A33); the
            % v1.7 worktree's "plain text for U / U//FOUO" override is
            % intentionally NOT applied here -- the user wants the
            % visual signal at a glance.
            htmlPath = '';
            try
                htmlPath = fullfile(outputDir, [base '_TestReport.html']);
                autotest.report.ReportBuilder.emitHtml(htmlPath, data, ...
                    opts, audit, generatedPdfPath, docxPath, sidecarPath);
            catch ME
                warning('autotest:report:Html', ...
                    'HTML emit failed (non-fatal): %s', ME.message);
                htmlPath = '';
            end

            info = struct( ...
                'DocxPath',       docxPath, ...
                'PdfPath',        generatedPdfPath, ...
                'HtmlPath',       htmlPath, ...
                'BackendLogPath', backendLog, ...
                'BackendName',    detector.BackendName, ...
                'BackendDisplay', detector.BackendDisplay, ...
                'AuditSidecar',   sidecarPath);
        end

        function audit = collectAudit(opts, data, detector, docxPath, pdfPath)
            %COLLECTAUDIT  Phase 16 Part B item 7 -- gather audit fields.
            audit = struct();
            % Repo provenance.
            repoPath = autotest.report.ReportBuilder.matlabunittestRepoPath();
            [commit, treeClean] = autotest.report.ReportBuilder.gitProvenance(repoPath);
            audit.CommitHash     = commit;
            audit.TreeClean      = treeClean;
            audit.CycleTimestamp = data.Summary.Timestamp;
            audit.BuiltAt        = char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss'));
            % Verification outcome.
            s = data.Summary;
            audit.PassCount = num2str(s.GenPassed);
            audit.FailCount = num2str(s.GenFailed);
            audit.IncCount  = num2str(s.GenIncomplete);
            if s.GenFailed == 0
                if s.GenTotal > 0
                    pct = 100 * s.GenPassed / s.GenTotal;
                    audit.PhaseStatus = sprintf('PASSED (Failed=0; Pass=%.1f%% of generated)', pct);
                else
                    audit.PhaseStatus = 'PASSED (no generated tests)';
                end
            else
                audit.PhaseStatus = sprintf('FAILED (%d failed test(s))', s.GenFailed);
            end
            % Backend + PDF tier.
            audit.BackendDisplay = detector.BackendDisplay;
            if isfield(opts, 'PdfBackend') && ~isempty(opts.PdfBackend)
                audit.PdfTier = opts.PdfBackend;
            else
                audit.PdfTier = 'auto';
            end
            % Sidecar location (referenced inside Appendix E).
            [outDir, base, ~] = fileparts(docxPath);
            audit.SidecarPath = fullfile(outDir, [base '_audit.txt']);
            audit.DocxPath = docxPath;
            audit.PdfPath  = pdfPath;
        end

        function p = matlabunittestRepoPath()
            %MATLABUNITTESTREPOPATH  Resolve the repo root from THIS file.
            %   This file lives at <root>/+autotest/+report/ReportBuilder.m,
            %   so the root is two `..` up.  Avoids any dependency on
            %   `pwd` or cd state.
            here = mfilename('fullpath');
            p = fileparts(fileparts(fileparts(here)));
        end

        function [hash, treeClean] = gitProvenance(repoPath)
            %GITPROVENANCE  Capture commit hash + tree-clean status.
            hash = '';
            treeClean = '';
            if isempty(repoPath) || ~isfolder(repoPath), return; end
            origDir = pwd;
            try
                cd(repoPath);
                [s, out] = system('git rev-parse HEAD');
                if s == 0
                    hash = strtrim(out);
                end
                [s, out] = system('git status --porcelain');
                if s == 0
                    if isempty(strtrim(out))
                        treeClean = 'true';
                    else
                        treeClean = 'false (uncommitted modifications present)';
                    end
                end
            catch
            end
            try, cd(origDir); catch, end
        end

        function writeAuditSidecar(path, audit, docxPath, pdfPath)
            %WRITEAUDITSIDECAR  Phase 16 Part B item 7 -- emit the audit sidecar.
            fid = fopen(path, 'w');
            if fid < 3, return; end
            cleanup = onCleanup(@() fclose(fid));
            fprintf(fid, 'matlabunittest -- Audit Trail Sidecar\n');
            fprintf(fid, '======================================\n\n');
            fprintf(fid, 'matlabunittest commit hash: %s\n', audit.CommitHash);
            fprintf(fid, 'matlabunittest tree clean:  %s\n', audit.TreeClean);
            fprintf(fid, 'Test-cycle timestamp:       %s\n', audit.CycleTimestamp);
            fprintf(fid, 'Report build time:          %s\n', audit.BuiltAt);
            fprintf(fid, 'Verification status:        %s\n', audit.PhaseStatus);
            fprintf(fid, 'Generated tests passed:     %s\n', audit.PassCount);
            fprintf(fid, 'Generated tests failed:     %s\n', audit.FailCount);
            fprintf(fid, 'Generated tests incomplete: %s\n', audit.IncCount);
            fprintf(fid, 'Selected report backend:    %s\n', audit.BackendDisplay);
            fprintf(fid, 'PDF tier (chosen):          %s\n', audit.PdfTier);
            fprintf(fid, '\nFile checksums (sha256):\n');
            fprintf(fid, '------------------------\n');
            if ~isempty(docxPath) && isfile(docxPath)
                fprintf(fid, '%s\n', autotest.report.ReportBuilder.formatChecksum(docxPath));
            end
            if ~isempty(pdfPath) && isfile(pdfPath)
                fprintf(fid, '%s\n', autotest.report.ReportBuilder.formatChecksum(pdfPath));
            end
            fprintf(fid, '\n');
            fprintf(fid, 'To verify:\n');
            fprintf(fid, '  - Compute sha256 of each deliverable on receipt.\n');
            fprintf(fid, '  - Compare against the entry above.\n');
            fprintf(fid, '  - Mismatches indicate post-cycle modification.\n');
        end

        function entry = formatChecksum(path)
            hash = autotest.report.ReportBuilder.sha256OfFile(path);
            if isempty(hash)
                entry = sprintf('(unavailable) %s', path);
            else
                entry = sprintf('%s  %s', hash, path);
            end
        end

        function preHash = embedSelfChecksum(docxPath)
            %EMBEDSELFCHECKSUM  v1.3 Part B item 2 -- two-pass self-attestation.
            %
            %   SectionBuilder.appendixE writes the sentinel
            %   `__DOCX_SHA256_SLOT__` into Appendix E.5.  After the
            %   .docx is closed, unzip into a temp stage, compute the
            %   sha256 of `word/document.xml` AS WRITTEN (with the
            %   sentinel still in place); this is `preHash`.  Replace
            %   the sentinel inside the file with `preHash`, re-zip.
            %   The inline hex is the pre-substitution content hash
            %   so a reviewer can:
            %     1. unzip the .docx, read `word/document.xml`
            %     2. extract the 64-char hex in Appendix E.5
            %     3. substitute the hex back to the literal string
            %        `__DOCX_SHA256_SLOT__`
            %     4. sha256 the resulting file -- it must equal the
            %        extracted hex
            %   This proves the inline hex is a genuine hash of the
            %   document content as the autogen wrote it.  The hash
            %   is over `word/document.xml` (the content) rather than
            %   over the .docx zip (the wrapper) so it is robust to
            %   MATLAB's non-deterministic zip metadata (timestamps,
            %   order); only the actual content matters.
            %
            %   Returns the embedded hash; empty on failure.
            preHash = '';
            if ~isfile(docxPath), return; end
            tmpStage = tempname();
            mkdir(tmpStage);
            cleanup = onCleanup(@() ...
                autotest.report.ReportBuilder.tryRmdir(tmpStage)); %#ok<NASGU>
            try
                unzip(docxPath, tmpStage);
            catch
                return;
            end
            docXml = fullfile(tmpStage, 'word', 'document.xml');
            if ~isfile(docXml), return; end
            raw = fileread(docXml);
            if ~contains(raw, '__DOCX_SHA256_SLOT__')
                % Sentinel absent -- nothing to embed.
                return;
            end
            % Compute sha256 over the file as written (sentinel intact).
            preHash = autotest.report.ReportBuilder.sha256OfFile(docXml);
            if isempty(preHash), return; end
            % Substitute the sentinel for the hash.
            patched = strrep(raw, '__DOCX_SHA256_SLOT__', preHash);
            fid = fopen(docXml, 'w');
            if fid < 3
                preHash = '';
                return;
            end
            fwrite(fid, unicode2native(patched, 'UTF-8'));
            fclose(fid);
            % Re-zip back to the original docxPath.
            tmpZip = [tempname() '.zip'];
            files = autotest.report.ReportBuilder.listStageFiles(tmpStage);
            origDir = pwd;
            try
                cd(tmpStage);
                zip(tmpZip, files);
                cd(origDir);
            catch innerME
                try, cd(origDir); catch, end
                preHash = '';
                rethrow(innerME);
            end
            try
                if isfile(docxPath), delete(docxPath); end
                movefile(tmpZip, docxPath, 'f');
            catch
                preHash = '';
                return;
            end
        end

        function tryRmdir(p)
            try
                if ~isempty(p) && isfolder(p)
                    rmdir(p, 's');
                end
            catch
            end
        end

        function files = listStageFiles(stageDir)
            files = {};
            list = dir(fullfile(stageDir, '**', '*'));
            for i = 1:numel(list)
                d = list(i);
                if d.isdir, continue; end
                full = fullfile(d.folder, d.name);
                rel = strrep(full, [stageDir filesep], '');
                files{end+1} = rel; %#ok<AGROW>
            end
        end

        function hash = sha256OfFile(path)
            %SHA256OFFILE  Phase 16 Part B item 7 -- file digest via Java.
            %   Uses java.security.MessageDigest -- always available in
            %   MATLAB.  Reads the file in 64 KB chunks; empty / missing
            %   files produce an empty hash.
            hash = '';
            if ~isfile(path), return; end
            try
                digest = java.security.MessageDigest.getInstance('SHA-256');
                fid = fopen(path, 'r');
                if fid < 3, return; end
                cleanup = onCleanup(@() fclose(fid));
                chunkSize = 65536;
                while true
                    chunk = fread(fid, chunkSize, '*uint8');
                    if isempty(chunk), break; end
                    digest.update(chunk);
                end
                rawBytes = typecast(digest.digest(), 'uint8');
                hex = lower(reshape(dec2hex(rawBytes, 2)', 1, []));
                hash = hex;
            catch
                hash = '';
            end
        end

        function fields = coverFields(opts, data)
            ts = data.Summary.Timestamp;
            if isempty(ts)
                ts = char(datetime('now', 'Format', 'yyyyMMdd-HHmmss'));
            end
            issued = char(datetime('now', 'Format', 'd MMMM yyyy'));
            fields = struct( ...
                'DisplayName',     opts.DisplayName, ...
                'DocVersion',      opts.DocVersion, ...
                'ProjectOwner',    opts.Owner, ...
                'DocDateIssued',   issued, ...
                'TestCycle',       ts, ...
                'DistReason',      opts.DistributionReason, ...
                'DistDate',        opts.DistributionDate, ...
                'DistController',  opts.DistributionController, ...
                'Classification',  opts.Classification);
        end

        function pdfPath = tryRenderPdf(backend, docxPath, pdfPath, mode, detector)
            pdfPath = ''; %#ok<NASGU>
            tiers = autotest.report.ReportBuilder.pdfTierOrder(mode, detector);
            for i = 1:numel(tiers)
                tier = tiers{i};
                switch tier
                    case 'rptgen'
                        out = backend.renderPdf('auto');
                        if ~isempty(out) && isfile(out)
                            pdfPath = out; return;
                        end
                    case 'libreoffice'
                        % Phase 16 (Part B item 3): PdfBackend_LibreOffice
                        % wraps the LibreOffice tier with a UNO macro that
                        % refreshes DocumentIndexes (TOC, list-of-figures)
                        % before storeToURL writer_pdf_Export.  Falls back
                        % to bare --convert-to pdf when the macro path
                        % can't be provisioned (best effort).
                        out = autotest.report.PdfBackend_LibreOffice.render( ...
                            docxPath, pdfPath);
                        if ~isempty(out) && isfile(out)
                            pdfPath = out; return;
                        end
                end
            end
            pdfPath = '';
            if strcmpi(mode, 'rptgen') || strcmpi(mode, 'libreoffice')
                error('autotest:report:Pdf', ...
                    'Forced PDF tier "%s" failed to produce a .pdf', mode);
            else
                warning('autotest:report:Pdf', ...
                    'No PDF tier produced a .pdf; .docx-only output.');
            end
        end

        function tiers = pdfTierOrder(mode, detector)
            switch lower(mode)
                case 'auto'
                    tiers = detector.PdfCandidates;
                case 'rptgen'
                    tiers = {'rptgen'};
                case 'libreoffice'
                    tiers = {'libreoffice'};
                case 'none'
                    tiers = {};
                otherwise
                    error('autotest:report:PdfMode', ...
                        'Unknown PdfBackend "%s"', mode);
            end
        end

        function out = renderPdfViaLibreOffice(docxPath, pdfPath)
            out = '';
            lop = '';
            try
                lop = getpref('autotest', 'LibreOfficePath', '');
            catch
            end
            if isempty(lop) || ~isfile(lop)
                lop = autotest.report.ReportBuilder.askLibreOfficePath();
                if isempty(lop), return; end
            end
            outDir = fileparts(pdfPath);
            cmd = sprintf('"%s" --headless --convert-to pdf --outdir "%s" "%s"', ...
                lop, outDir, docxPath);
            [status, ~] = system(cmd);
            if status == 0
                [~, base, ~] = fileparts(docxPath);
                cand = fullfile(outDir, [base '.pdf']);
                if isfile(cand)
                    if ~strcmp(cand, pdfPath)
                        try, movefile(cand, pdfPath, 'f'); catch, end
                    end
                    out = pdfPath;
                end
            end
        end

        function lop = askLibreOfficePath()
            lop = '';
            % Best-effort autodetect on Windows + macOS + Linux.
            candidates = { ...
                'C:\Program Files\LibreOffice\program\soffice.exe', ...
                'C:\Program Files (x86)\LibreOffice\program\soffice.exe', ...
                '/Applications/LibreOffice.app/Contents/MacOS/soffice', ...
                '/usr/bin/soffice', ...
                '/usr/bin/libreoffice'};
            for i = 1:numel(candidates)
                if isfile(candidates{i})
                    lop = candidates{i};
                    try
                        setpref('autotest', 'LibreOfficePath', lop);
                    catch
                    end
                    return;
                end
            end
        end

        function opts = applyDefaults(folder, opts)
            if ~isfield(opts, 'DisplayName') || isempty(opts.DisplayName)
                [~, b, ~] = fileparts(folder);
                opts.DisplayName = autotest.report.ReportBuilder.prettify(b);
            end
            if ~isfield(opts, 'Owner') || isempty(opts.Owner)
                opts.Owner = ['Project Owner -- ' opts.DisplayName];
            end
            if ~isfield(opts, 'DocVersion') || isempty(opts.DocVersion)
                opts.DocVersion = '1.0';
            end
            if ~isfield(opts, 'ProjectPrefix') || isempty(opts.ProjectPrefix)
                opts.ProjectPrefix = autotest.report.ReportBuilder.derivePrefix( ...
                    opts.DisplayName);
            end
            if ~isfield(opts, 'DistributionReason') || isempty(opts.DistributionReason)
                opts.DistributionReason = 'Administrative or Operational Use';
            end
            if ~isfield(opts, 'DistributionDate') || isempty(opts.DistributionDate)
                opts.DistributionDate = char(datetime('now', 'Format', 'MMMM yyyy'));
            end
            if ~isfield(opts, 'DistributionController') || isempty(opts.DistributionController)
                opts.DistributionController = 'the Project Owner';
            end
            if ~isfield(opts, 'OutputDir') || isempty(opts.OutputDir)
                opts.OutputDir = fullfile(folder, '_autotest', 'reports');
            end
            if ~isfield(opts, 'PdfBackend') || isempty(opts.PdfBackend)
                opts.PdfBackend = 'auto';
            end
            % v1.4: CAPCO classification banner.  Defaults to UNCLASSIFIED
            % so existing callers see the green banner without any change.
            if ~isfield(opts, 'Classification') || isempty(opts.Classification)
                opts.Classification = 'UNCLASSIFIED';
            end
        end

        function s = prettify(name)
            s = strrep(name, '_', ' ');
            s = strrep(s, '-', ' ');
            % Capitalise each word.
            parts = strsplit(s);
            for i = 1:numel(parts)
                if isempty(parts{i}), continue; end
                parts{i} = [upper(parts{i}(1)) parts{i}(2:end)];
            end
            s = strjoin(parts, ' ');
        end

        function p = derivePrefix(displayName)
            % Take the initials of the first 1-2 words; uppercase.
            words = strsplit(strtrim(displayName));
            if numel(words) >= 2
                p = upper([words{1}(1) words{2}(1)]);
            elseif ~isempty(words)
                w = words{1};
                if length(w) >= 2
                    p = upper(w(1:2));
                else
                    p = upper([w 'X']);
                end
            else
                p = 'XX';
            end
            % Keep only A-Z.
            p = regexprep(p, '[^A-Z]', 'X');
            if length(p) < 2, p = [p repmat('X', 1, 2-length(p))]; end
            if length(p) > 2, p = p(1:2); end
        end

        function base = outputBaseName(folder, opts)
            if isfield(opts, 'OutputBaseName') && ~isempty(opts.OutputBaseName)
                base = opts.OutputBaseName; return;
            end
            [~, base, ~] = fileparts(folder);
            base = regexprep(base, '[^A-Za-z0-9_-]+', '_');
        end
        function emitHtml(path, data, opts, audit, pdfPath, docxPath, sidecarPath)
            %EMITHTML  Standalone HTML deliverable with CAPCO banner.
            %   Writes a single self-contained .html file with the
            %   classification banner painted in the CAPCO fill colour
            %   (UNCLASSIFIED -> green) at both the top and bottom of
            %   the page, a metadata table, the headline pass/fail
            %   counts, and the per-source breakdown.  Intentionally
            %   compact -- the .docx remains the full-fidelity
            %   deliverable; this is the easy-to-skim companion.
            if nargin < 5, pdfPath = ''; end
            if nargin < 6, docxPath = ''; end
            if nargin < 7, sidecarPath = ''; end

            cls = 'UNCLASSIFIED';
            if isfield(opts, 'Classification') && ~isempty(opts.Classification)
                cls = char(opts.Classification);
            end
            fill = autotest.report.Style.classificationFill(cls);
            textColor = 'FFFFFF';

            s = data.Summary;
            gTot  = 0; if isfield(s, 'GenTotal'),      gTot  = s.GenTotal;      end
            gPass = 0; if isfield(s, 'GenPassed'),     gPass = s.GenPassed;     end
            gFail = 0; if isfield(s, 'GenFailed'),     gFail = s.GenFailed;     end
            gInc  = 0; if isfield(s, 'GenIncomplete'), gInc  = s.GenIncomplete; end

            displayName = '';
            if isfield(opts, 'DisplayName'), displayName = char(opts.DisplayName); end
            owner = '';
            if isfield(opts, 'Owner'), owner = char(opts.Owner); end
            docVersion = '';
            if isfield(opts, 'DocVersion'), docVersion = char(opts.DocVersion); end

            esc = @autotest.report.ReportBuilder.htmlEscape;
            bannerStyle = sprintf( ...
                'background:#%s;color:#%s;font-weight:bold;text-align:center;padding:10px 0;letter-spacing:0.08em;font-family:Calibri,Segoe UI,Arial,sans-serif;font-size:14px;', ...
                fill, textColor);

            buf = strings(0,1);
            buf(end+1,1) = "<!DOCTYPE html>";
            buf(end+1,1) = sprintf("<html lang=""en""><head><meta charset=""utf-8""><title>%s -- Test Report</title>", esc(displayName));
            buf(end+1,1) = "<style>";
            buf(end+1,1) = "body{margin:0;padding:0;background:#FFFFFF;color:#1F2937;font-family:Georgia,'Times New Roman',serif;font-size:14px;line-height:1.55}";
            buf(end+1,1) = "main{max-width:880px;margin:0 auto;padding:24px}";
            buf(end+1,1) = "h1{font-family:Calibri,'Segoe UI',Arial,sans-serif;font-size:26px;margin:18px 0 4px}";
            buf(end+1,1) = "h2{font-family:Calibri,'Segoe UI',Arial,sans-serif;font-size:18px;margin:24px 0 8px;color:#1F2937;border-bottom:2px solid #B45309;padding-bottom:4px}";
            buf(end+1,1) = "table{border-collapse:collapse;width:100%;margin:8px 0 16px}";
            buf(end+1,1) = "th,td{border:1px solid #BFBFBF;padding:6px 10px;text-align:left;font-size:13px}";
            buf(end+1,1) = "th{background:#E7E6E6;font-weight:bold;font-family:Calibri,'Segoe UI',Arial,sans-serif}";
            buf(end+1,1) = ".kv th{width:30%;background:#F2F2F2;font-weight:normal;color:#4B5563}";
            buf(end+1,1) = ".pill{display:inline-block;padding:2px 10px;border-radius:10px;font-family:Calibri,'Segoe UI',Arial,sans-serif;font-size:12px;font-weight:bold}";
            buf(end+1,1) = ".pill-pass{background:#D1FAE5;color:#065F46}";
            buf(end+1,1) = ".pill-fail{background:#FEE2E2;color:#991B1B}";
            buf(end+1,1) = ".pill-inc{background:#FEF3C7;color:#92400E}";
            buf(end+1,1) = sprintf(".banner{%s}", bannerStyle);
            buf(end+1,1) = "</style></head><body>";

            buf(end+1,1) = sprintf("<div class=""banner"">%s</div>", esc(cls));
            buf(end+1,1) = "<main>";

            if isempty(displayName), displayName = 'Project'; end
            buf(end+1,1) = sprintf("<h1>%s &mdash; System Test Report</h1>", esc(displayName));
            if ~isempty(docVersion)
                buf(end+1,1) = sprintf("<div style=""color:#4B5563;font-family:Calibri,'Segoe UI',Arial,sans-serif;font-size:13px;margin-bottom:8px;"">Document version %s</div>", esc(docVersion));
            end

            buf(end+1,1) = "<h2>Metadata</h2><table class=""kv"">";
            buf(end+1,1) = sprintf("<tr><th>Classification</th><td>%s</td></tr>", esc(cls));
            buf(end+1,1) = sprintf("<tr><th>Owner</th><td>%s</td></tr>", esc(owner));
            if isfield(audit, 'CycleTimestamp')
                buf(end+1,1) = sprintf("<tr><th>Test-cycle timestamp</th><td>%s</td></tr>", esc(audit.CycleTimestamp));
            end
            if isfield(audit, 'BuiltAt')
                buf(end+1,1) = sprintf("<tr><th>Report built</th><td>%s</td></tr>", esc(audit.BuiltAt));
            end
            if isfield(audit, 'CommitHash')
                buf(end+1,1) = sprintf("<tr><th>matlabunittest commit</th><td>%s</td></tr>", esc(audit.CommitHash));
            end
            if isfield(audit, 'BackendDisplay')
                buf(end+1,1) = sprintf("<tr><th>DOCX backend</th><td>%s</td></tr>", esc(audit.BackendDisplay));
            end
            buf(end+1,1) = "</table>";

            buf(end+1,1) = "<h2>Generated tests &mdash; headline</h2><table>";
            buf(end+1,1) = "<tr><th>Total</th><th>Passed</th><th>Failed</th><th>Incomplete</th></tr>";
            buf(end+1,1) = sprintf("<tr><td>%d</td><td><span class=""pill pill-pass"">%d</span></td><td><span class=""pill pill-fail"">%d</span></td><td><span class=""pill pill-inc"">%d</span></td></tr>", ...
                gTot, gPass, gFail, gInc);
            buf(end+1,1) = "</table>";

            if isfield(data, 'PerSource') && ~isempty(data.PerSource)
                buf(end+1,1) = "<h2>Per-source breakdown</h2><table>";
                buf(end+1,1) = "<tr><th>Source</th><th>Total</th><th>Passed</th><th>Failed</th></tr>";
                ps = data.PerSource;
                if iscell(ps)
                    for k = 1:numel(ps)
                        row = ps{k};
                        if iscell(row) && numel(row) >= 4
                            buf(end+1,1) = sprintf("<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>", ...
                                esc(char(row{1})), esc(char(row{2})), esc(char(row{3})), esc(char(row{4})));
                        end
                    end
                end
                buf(end+1,1) = "</table>";
            end

            buf(end+1,1) = "<h2>Companion deliverables</h2><table class=""kv"">";
            if ~isempty(docxPath)
                buf(end+1,1) = sprintf("<tr><th>DOCX</th><td>%s</td></tr>", esc(docxPath));
            end
            if ~isempty(pdfPath)
                buf(end+1,1) = sprintf("<tr><th>PDF</th><td>%s</td></tr>", esc(pdfPath));
            else
                buf(end+1,1) = "<tr><th>PDF</th><td><em>(no PDF tier on this machine)</em></td></tr>";
            end
            if ~isempty(sidecarPath)
                buf(end+1,1) = sprintf("<tr><th>Audit sidecar</th><td>%s</td></tr>", esc(sidecarPath));
            end
            buf(end+1,1) = "</table>";

            buf(end+1,1) = "</main>";
            buf(end+1,1) = sprintf("<div class=""banner"">%s</div>", esc(cls));
            buf(end+1,1) = "</body></html>";

            fid = fopen(path, 'w');
            if fid < 3
                error('autotest:report:Html', 'Cannot open %s for writing.', path);
            end
            cleanup = onCleanup(@() fclose(fid)); %#ok<NASGU>
            for i = 1:numel(buf)
                fprintf(fid, '%s\n', char(buf(i)));
            end
        end

        function s = htmlEscape(s)
            if isempty(s), s = ''; return; end
            s = strrep(char(s), '&', '&amp;');
            s = strrep(s, '<', '&lt;');
            s = strrep(s, '>', '&gt;');
            s = strrep(s, '"', '&quot;');
        end

    end
end
