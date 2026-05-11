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
        TitleFontSize    = 96;     % 48pt -- v1.4 cover-page refresh (was 72/36pt)
        SubtitleFontSize = 36;     % 18pt -- v1.4 cover-page refresh (was 48/24pt)
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
    end

    methods (Static)
        function hex = classificationFill(level)
            %CLASSIFICATIONFILL  CAPCO per-level banner background colour.
            %
            %   Returns the 6-char RGB hex (no '#') for the classification
            %   banner background.  v1.4 introduced a single locked colour
            %   map keyed off the Classification ReportOption so the
            %   banner cannot drift cycle-over-cycle.
            %
            %   Per CAPCO marking guidance the banner text is white; the
            %   background is the per-level colour below.  Unknown levels
            %   fall back to charcoal so the banner still renders.
            arguments
                level (1,:) char
            end
            switch upper(strtrim(level))
                case 'UNCLASSIFIED', hex = '007A33';   % CAPCO green
                case 'CONFIDENTIAL', hex = '0033A0';   % CAPCO blue
                case 'SECRET',       hex = 'C8102E';   % CAPCO red
                case 'TOP SECRET',   hex = 'FF8C00';   % CAPCO orange
                case 'FOUO',         hex = '000000';   % CAPCO black
                otherwise,           hex = '1F2937';   % charcoal fallback
            end
        end
    end
end
