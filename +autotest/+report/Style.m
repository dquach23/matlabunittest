classdef Style
    %STYLE  Phase 15 native report generator -- shared style constants.
    %
    %   Used by both RptgenBackend (mlreportgen.dom) and OoxmlBackend
    %   (hand-rolled OOXML).  Page geometry follows US Letter with 1-inch
    %   margins; font choices match the Phase 14 reference report so the
    %   visual delta from the previous Node-built .docx is negligible.
    %
    %   v1.4 LOCKED PALETTE
    %   -------------------
    %   The colour palette was locked in v1.4 to give the deliverable a
    %   serious, DoD-friendly look without drifting cycle-over-cycle.  Do
    %   NOT change these hex values without a follow-on cycle whose
    %   handoff explicitly carries the new palette forward.
    %
    %     PrimaryText      #1F2937  charcoal     -- headings, body text
    %     SecondaryText    #4B5563  slate        -- metadata key cells, captions
    %     Accent           #B45309  muted gold   -- rules, section markers, chart highlights
    %     FailEmphasis     #991B1B  deep red     -- non-zero failed counts ONLY (sparingly)
    %     CodeFill         #F7FAFC  light grey   -- monospace code-block backgrounds
    %     HeaderShading    #E7E6E6  light grey   -- table headers (existing)
    %     MetaShading      #F2F2F2  pale grey    -- metadata key cells (existing)
    %
    %   v1.4 CAPCO classification banner colours: see classificationFill().

    properties (Constant)
        % Page geometry (DXA, twentieths of a point).
        PageWidth     = 12240;     % 8.5" * 1440
        PageHeight    = 15840;     % 11"  * 1440
        Margin        = 1440;      % 1" all sides
        ContentWidth  = 9360;      % page - 2*margin

        % Typography (half-points for OOXML; pts for rptgen elsewhere).
        BodyFontName  = 'Calibri';
        BodyFontSize  = 22;        % 11pt body (half-points)
        H1FontSize    = 32;        % 16pt
        H2FontSize    = 28;        % 14pt
        H3FontSize    = 24;        % 12pt
        TitleFontSize    = 112;    % 56pt -- v1.7 cover-page redesign (was 96/48pt)
        SubtitleFontSize = 32;     % 16pt -- v1.7 cover-page redesign (was 36/18pt)
        MonogramFontSize = 56;     % 28pt -- v1.7 cover-page monogram
        FooterFontSize   = 18;     % 9pt
        BannerFontSize   = 22;     % 11pt -- classification banner
        CodeFontSize     = 20;     % 10pt -- monospace diagnostic samples
        CodeFontName  = 'Consolas';

        % Colours (RGB hex, no '#').
        BodyColor       = '000000';   % legacy body colour (pre-palette)
        BorderColor     = 'BFBFBF';
        HeaderShading   = 'E7E6E6';
        MetaShading     = 'F2F2F2';

        % v1.4 LOCKED PALETTE.
        PrimaryText     = '1F2937';   % charcoal
        SecondaryText   = '4B5563';   % slate
        Accent          = 'B45309';   % muted gold
        FailEmphasis    = '991B1B';   % deep red
        CodeFill        = 'F7FAFC';   % light grey

        % Cell padding (DXA).
        CellPadTop    = 80;
        CellPadBottom = 80;
        CellPadLeft   = 120;
        CellPadRight  = 120;

        % Borders.
        BorderSize    = 4;         % light border (1/2 pt)
        HeavyBorder   = 12;        % bordered box around DistStmtD

        % v1.4 accent rule (1pt).
        AccentRuleSize = 8;        % 1pt = 8 eighths-of-a-point in OOXML

        % v1.6 status badges -- coloured pill markers for Pass / Fail /
        % Incomplete / Skipped statuses, used in the appendix listings
        % and per-source tables.  Hex pairs are (fill, text).
        BadgePassFill   = 'D1FAE5'; BadgePassText   = '065F46';
        BadgeFailFill   = 'FEE2E2'; BadgeFailText   = '991B1B';
        BadgeIncFill    = 'FEF3C7'; BadgeIncText    = '92400E';
        BadgeSkipFill   = 'E5E7EB'; BadgeSkipText   = '374151';

        % v1.6 body typography refresh -- serif body, sans-serif headings.
        BodyFontNameSerif    = 'Georgia';
        HeadingFontName      = 'Calibri';
        AltRowShading        = 'F7FAFC';   % light grey for alternating rows

        % v1.6 callout box for executive-summary metrics.
        CalloutFill          = 'F7FAFC';
        CalloutBorderColor   = 'B45309';
    end

    methods (Static)
        function levels = allowedClassifications()
            %ALLOWEDCLASSIFICATIONS  v1.7 -- single source of truth for valid Classification values.
            %   Returns the canonical, ordered set of allowed
            %   classification levels.  Callers (runWorkflow,
            %   generateReport, generateSystemTestReport) validate user
            %   input against this list and error fail-loud with the
            %   list printed when an unrecognised level is supplied.
            %   Add new levels here ONLY -- the marking helpers
            %   (portionCode, classificationFill, isUnclassified) all
            %   key off these strings.
            levels = { ...
                'UNCLASSIFIED', ...
                'UNCLASSIFIED//FOUO', ...
                'CONFIDENTIAL', ...
                'SECRET', ...
                'TOP SECRET', ...
                'TOP SECRET//SCI'};
        end

        function out = validateClassification(level)
            %VALIDATECLASSIFICATION  v1.7 -- normalise + enforce the allowed set.
            %   Returns the normalised (uppercase, trimmed) classification
            %   level when LEVEL is in the allowed list.  Errors fail-
            %   loud with the full allowed list printed when not.  An
            %   empty/missing input is treated as UNCLASSIFIED (the
            %   v1.4 default behaviour).
            if isstring(level), level = char(level); end
            if isempty(level)
                out = 'UNCLASSIFIED';
                return;
            end
            normalised = upper(strtrim(char(level)));
            allowed = autotest.report.Style.allowedClassifications();
            if ~any(strcmp(allowed, normalised))
                error('autotest:report:BadClassification', ...
                    ['Classification "%s" is not in the allowed set.\n' ...
                     '  Allowed values (case-insensitive):\n    %s\n' ...
                     '  Default when not specified: UNCLASSIFIED.\n' ...
                     '  Example: autotest.runWorkflow(folder, ''ReportOptions'', ' ...
                     'struct(''Classification'', ''SECRET''))'], ...
                    char(level), strjoin(allowed, ', '));
            end
            out = normalised;
        end

        function [fill, text, label] = statusBadge(status)
            %STATUSBADGE  v1.6 -- map a test status to its badge palette + label.
            %   Returns (fillHex, textHex, displayLabel).  Unknown
            %   statuses fall through to the grey "Skipped" palette
            %   so the visual still renders.
            arguments
                status (1,:) char
            end
            s = lower(strtrim(status));
            switch s
                case {'passed','pass'}
                    fill = autotest.report.Style.BadgePassFill;
                    text = autotest.report.Style.BadgePassText;
                    label = 'Pass';
                case {'failed','fail','error','errored'}
                    fill = autotest.report.Style.BadgeFailFill;
                    text = autotest.report.Style.BadgeFailText;
                    label = 'Fail';
                case {'incomplete','filtered','assumption'}
                    fill = autotest.report.Style.BadgeIncFill;
                    text = autotest.report.Style.BadgeIncText;
                    label = 'Incomplete';
                case {'skipped','skip'}
                    fill = autotest.report.Style.BadgeSkipFill;
                    text = autotest.report.Style.BadgeSkipText;
                    label = 'Skipped';
                otherwise
                    fill = autotest.report.Style.BadgeSkipFill;
                    text = autotest.report.Style.BadgeSkipText;
                    label = char(status);
            end
        end

        function code = portionCode(level)
            %PORTIONCODE  v1.6 / v1.7 (DoDI 5200.48 portion markings).
            %   Returns the parenthetical prefix to prepend on every
            %   body paragraph and heading under the given classification.
            %   v1.7 adds explicit handling for the //FOUO and //SCI
            %   compound markings.  Unknown levels fall through to (U).
            arguments
                level (1,:) char
            end
            switch upper(strtrim(level))
                case 'UNCLASSIFIED',         code = '(U)';
                case 'UNCLASSIFIED//FOUO',   code = '(U//FOUO)';
                case 'CONFIDENTIAL',         code = '(C)';
                case 'SECRET',               code = '(S)';
                case 'TOP SECRET',           code = '(TS)';
                case 'TOP SECRET//SCI',      code = '(TS//SCI)';
                case 'FOUO',                 code = '(U//FOUO)';
                otherwise,                   code = '(U)';
            end
        end

        function tf = isUnclassified(level)
            %ISUNCLASSIFIED  v1.6 / v1.7 -- plain-text banner for U / U//FOUO.
            %   DoDM 5200.01 V2 specifies UNCLASSIFIED (and U//FOUO when
            %   FOUO is the only handling caveat) renders as plain centred
            %   text -- no coloured background block.  Higher tiers retain
            %   the CAPCO-coloured banner.
            n = upper(strtrim(level));
            tf = strcmp(n, 'UNCLASSIFIED') || strcmp(n, 'UNCLASSIFIED//FOUO');
        end

        function hex = classificationBannerText(level)
            %CLASSIFICATIONBANNERTEXT  v1.7 -- text colour to pair with the fill.
            %   Returns '000000' (black) when the fill is a light/bright
            %   colour where white text fails contrast (TOP SECRET//SCI's
            %   CAPCO yellow), otherwise 'FFFFFF' (white).
            switch upper(strtrim(level))
                case 'TOP SECRET//SCI', hex = '000000';
                otherwise,              hex = 'FFFFFF';
            end
        end

        function hex = classificationFill(level)
            %CLASSIFICATIONFILL  CAPCO per-level banner background colour.
            %   Used only for non-UNCLASSIFIED tiers (UNCLASSIFIED and
            %   UNCLASSIFIED//FOUO render plain-text per DoDM 5200.01 V2).
            %   v1.7 extends the v1.4 map: TOP SECRET//SCI -> CAPCO yellow,
            %   the legacy 'FOUO' fallback retained for back-compat.
            arguments
                level (1,:) char
            end
            switch upper(strtrim(level))
                case 'UNCLASSIFIED',         hex = '007A33';   % CAPCO green (legacy; not used post-v1.6)
                case 'UNCLASSIFIED//FOUO',   hex = '007A33';   % (legacy; not used post-v1.6)
                case 'CONFIDENTIAL',         hex = '0033A0';   % CAPCO blue
                case 'SECRET',               hex = 'C8102E';   % CAPCO red
                case 'TOP SECRET',           hex = 'FF8C00';   % CAPCO orange
                case 'TOP SECRET//SCI',      hex = 'FCE300';   % CAPCO yellow
                case 'FOUO',                 hex = '000000';   % CAPCO black (legacy)
                otherwise,                   hex = '1F2937';   % charcoal fallback
            end
        end
    end
end
