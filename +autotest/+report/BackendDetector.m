classdef BackendDetector
    %BACKENDDETECTOR  Phase 15 -- pick the report-rendering backend.
    %
    %   info = autotest.report.BackendDetector.probe()
    %
    %   Returns a struct with fields:
    %       BackendName       -- 'rptgen' or 'ooxml'
    %       BackendDisplay    -- human-readable name used in the log
    %       HasReportGen      -- bool
    %       HasMlReportGenDom -- bool
    %       HasZip            -- bool
    %       PdfCandidates     -- cellstr listing the available PDF tiers,
    %                            ordered by preference
    %
    %   Probes in order:
    %     1. RptgenBackend     (mlreportgen.dom AND license)
    %     2. OoxmlBackend      (built-in MATLAB only)
    %   Errors with a clear, fail-loud message if neither tier is
    %   available.  No silent fallback to a third tier exists.

    methods (Static)
        function info = probe()
            info = struct( ...
                'BackendName',       '', ...
                'BackendDisplay',    '', ...
                'HasReportGen',      false, ...
                'HasMlReportGenDom', false, ...
                'HasZip',            false, ...
                'PdfCandidates',     {{}});

            % --- mlreportgen license + class probe ---------------------
            try
                info.HasReportGen = logical(license('test', 'MATLAB_Report_Gen'));
            catch
            end
            info.HasMlReportGenDom = ~isempty(which('mlreportgen.dom.Document'));

            % --- zip primitive probe (built-in zip()) ------------------
            info.HasZip = exist('zip', 'builtin') == 5 || exist('zip', 'file') > 0;

            if info.HasReportGen && info.HasMlReportGenDom
                info.BackendName    = 'rptgen';
                info.BackendDisplay = 'RptgenBackend (mlreportgen.dom + Report Generator)';
            elseif info.HasZip
                info.BackendName    = 'ooxml';
                info.BackendDisplay = 'OoxmlBackend (hand-rolled OOXML + builtin zip)';
            else
                error('autotest:report:NoBackend', ...
                    ['Could not produce a Word doc on this MATLAB install.\n' ...
                     'Probed:\n' ...
                     '  license(''test'',''MATLAB_Report_Gen'')      = %s\n' ...
                     '  ~isempty(which(''mlreportgen.dom.Document''))  = %s\n' ...
                     '  zip() builtin available                        = %s\n' ...
                     'Either install Report Generator OR ensure zip() is on the path.'], ...
                    string(info.HasReportGen), ...
                    string(info.HasMlReportGenDom), ...
                    string(info.HasZip));
            end

            % --- PDF tier candidates ----------------------------------
            pdfTiers = {};
            if info.HasReportGen && info.HasMlReportGenDom
                pdfTiers{end+1} = 'rptgen';
            end
            try
                lop = getpref('autotest', 'LibreOfficePath', '');
                if ~isempty(lop) && isfile(lop)
                    pdfTiers{end+1} = 'libreoffice';
                end
            catch
            end
            info.PdfCandidates = pdfTiers;
        end

        function logToFile(info, logFile)
            arguments
                info    struct
                logFile (1,:) char
            end
            try
                fid = fopen(logFile, 'w');
                if fid < 3, return; end
                fprintf(fid, 'Phase 15 backend selection log\n');
                fprintf(fid, '==============================\n');
                fprintf(fid, 'Captured:                                    %s\n', char(datetime('now')));
                fprintf(fid, 'license(''test'',''MATLAB_Report_Gen'')      = %s\n', tf(info.HasReportGen));
                fprintf(fid, '~isempty(which(''mlreportgen.dom.Document'')) = %s\n', tf(info.HasMlReportGenDom));
                fprintf(fid, 'builtin zip() available                    = %s\n', tf(info.HasZip));
                fprintf(fid, 'Backend selected:                          %s\n', info.BackendDisplay);
                fprintf(fid, 'PDF candidates (in order):                 %s\n', ...
                    strjoin(info.PdfCandidates, ', '));
                fclose(fid);
            catch
            end
            function s = tf(b)
                if b, s = 'true'; else, s = 'false'; end
            end
        end
    end
end
