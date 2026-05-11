function info = generateSystemTestReport(folder, varargin)
%GENERATESYSTEMTESTREPORT  Phase 15 -- native MATLAB system test report.
%
%   info = autotest.generateSystemTestReport(folder, 'Name', value, ...)
%
%   Produces <OutputDir>/<basename>_TestReport.docx (and matching .pdf
%   when a PDF backend is available) using only MATLAB primitives.  No
%   external Node.js / Python / LibreOffice agent-side assembly is
%   required; the function selects between two backends:
%       1. RptgenBackend  - uses MATLAB Report Generator (mlreportgen.dom)
%                           when licensed.  Full-fidelity .docx and a
%                           native PDF via mlreportgen.utils.docToPDF.
%       2. OoxmlBackend   - hand-rolled OOXML (Word 2007+) using only
%                           built-in MATLAB.  PDF tier is delegated to
%                           the LibreOffice headless converter when
%                           available; otherwise PDF is skipped with a
%                           warning.  See PdfBackend below.
%
%   Name-value parameters (defaults in brackets):
%       'DisplayName'             [<basename of FOLDER, prettified>]
%       'Owner'                   ['Project Owner -- <DisplayName>']
%       'DocVersion'              ['1.0']
%       'ProjectPrefix'           [2-letter prefix from <DisplayName>]
%       'DistributionReason'      ['Administrative or Operational Use']
%       'DistributionDate'        [<Month YYYY of today>]
%       'DistributionController'  ['the Project Owner']
%       'OutputDir'               [<FOLDER>/_autotest/reports]
%       'OutputBaseName'          [<basename of FOLDER>]
%       'PdfBackend'              ['auto' | 'rptgen' | 'libreoffice' | 'none']
%       'Classification'          ['UNCLASSIFIED']  -- v1.4: CAPCO banner
%                                 level.  One of {UNCLASSIFIED, CONFIDENTIAL,
%                                 SECRET, TOP SECRET, FOUO}; unrecognised
%                                 values fall through to a charcoal banner.
%
%   Returns:
%       INFO  struct with fields {DocxPath, PdfPath, BackendLogPath,
%             BackendName, BackendDisplay}.  PdfPath is empty when no
%             PDF tier produced output.
%
%   The active backend choice is logged to
%   <OutputDir>/report_backend.log so subsequent runs are reproducible.
%
%   Generic across MATLAB projects.  No project-specific knowledge.
%
%   See also: AUTOTEST.RUNWORKFLOW.

    if ~(ischar(folder) || isstring(folder))
        error('autotest:generateSystemTestReport:Folder', ...
            'FOLDER must be a char or string scalar.');
    end
    folder = char(folder);
    p = inputParser();
    p.addParameter('DisplayName', '', @(x) ischar(x) || isstring(x));
    p.addParameter('Owner', '', @(x) ischar(x) || isstring(x));
    p.addParameter('DocVersion', '1.6', @(x) ischar(x) || isstring(x));
    p.addParameter('ProjectPrefix', '', @(x) ischar(x) || isstring(x));
    p.addParameter('DistributionReason', 'Administrative or Operational Use', @(x) ischar(x) || isstring(x));
    p.addParameter('DistributionDate', '', @(x) ischar(x) || isstring(x));
    p.addParameter('DistributionController', 'the Project Owner', @(x) ischar(x) || isstring(x));
    p.addParameter('OutputDir', '', @(x) ischar(x) || isstring(x));
    p.addParameter('OutputBaseName', '', @(x) ischar(x) || isstring(x));
    p.addParameter('PdfBackend', 'auto', @(x) ischar(x) || isstring(x));
    p.addParameter('Classification', 'UNCLASSIFIED', @(x) ischar(x) || isstring(x));
    % v1.5: self-contained HTML deliverable.  Default ON because it
    % has no Report Generator / Word dependency and ships inline SVG.
    p.addParameter('GenerateHtml', true, @(x) islogical(x) && isscalar(x));
    p.parse(varargin{:});

    opts = struct();
    fields = fieldnames(p.Results);
    for i = 1:numel(fields)
        v = p.Results.(fields{i});
        if isstring(v), v = char(v); end
        opts.(fields{i}) = v;
    end

    info = autotest.report.ReportBuilder.build(folder, opts);
end
