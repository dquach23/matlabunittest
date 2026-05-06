classdef KnownRealSignal
    %KNOWNREALSIGNAL  Per-target opt-out for known real-signal failures.
    %
    %   When a generated test fails because the project under test has a
    %   genuine bug that's outside the autogenerator's scope to fix
    %   (e.g. an existing line of project code that throws on a perfectly
    %   reasonable input), the user can list those tests in
    %
    %       <targetFolder>/_autotest/known_real_signal.txt
    %
    %   and TestWriter will emit a `testSkipped_<methodName>` Incomplete
    %   carrying the user-supplied reason text instead of generating a
    %   test that's guaranteed to fail.  This keeps the report green for
    %   the autogen tool's responsibilities while leaving a paper trail
    %   for issues the user has chosen to track separately.
    %
    %   File format: one entry per line, blank lines and lines starting
    %   with '#' are ignored.  Each entry has the form
    %
    %       <testClassName>.<testMethodName>: <reason text>
    %
    %   Example contents:
    %
    %       # Real-signal failures we've triaged for removal_redaction_tool.
    %       tCellRefUtils.testEdge_isCellInRange_cellRef_empty: project bug (CellRefUtils.isCellInRange line 78 -- MATLAB:nonLogicalConditional)
    %       tCellRefUtils.testRandomized_isCellInRange: project bug (CellRefUtils.isCellInRange line 78)
    %       tRedactionToolGUI.testCallback_sheetStatusChanged: project bug (cascade through CellRefUtils.isCellInRange line 78)
    %
    %   Missing or unreadable files are treated as "no entries" -- callers
    %   never see an exception out of match().  See CLAUDE.md ("Excluding
    %   known real-signal failures") for the user-facing workflow.

    methods (Static)
        function reason = match(targetFolder, testClass, testName)
            %MATCH  Return reason text for a (testClass, testName), '' if none.
            %
            %   reason = autotest.KnownRealSignal.match(folder, cls, name)
            %
            %   Caches the parsed file per-targetFolder in a persistent
            %   variable -- TestWriter calls match() once per emitted
            %   test method, all during one generation pass, so the
            %   first call pays the I/O cost and the rest are O(1)
            %   hash lookups.  `clear classes` between runs clears the
            %   cache, so an updated config is picked up on the next
            %   workflow.
            persistent cacheRoot cacheMap
            reason = '';
            if isempty(targetFolder) || isempty(testClass) || isempty(testName)
                return;
            end
            targetFolder = char(targetFolder);
            testClass    = char(testClass);
            testName     = char(testName);
            if isempty(cacheRoot) || ~strcmp(cacheRoot, targetFolder)
                cacheRoot = targetFolder;
                cacheMap  = autotest.KnownRealSignal.loadFile(targetFolder);
            end
            if isempty(cacheMap), return; end
            key = [testClass '.' testName];
            if isKey(cacheMap, key)
                reason = cacheMap(key);
            end
        end

        function p = configPath(targetFolder)
            %CONFIGPATH  Where the known-real-signal config lives for FOLDER.
            p = fullfile(char(targetFolder), '_autotest', 'known_real_signal.txt');
        end

        function map = loadFile(targetFolder)
            %LOADFILE  Parse the per-target config; returns empty map on miss.
            map = containers.Map('KeyType', 'char', 'ValueType', 'char');
            cfg = autotest.KnownRealSignal.configPath(targetFolder);
            if ~isfile(cfg), return; end
            fid = -1;
            try
                fid = fopen(cfg, 'r');
                if fid < 0, return; end
                while true
                    line = fgetl(fid);
                    if ~ischar(line), break; end
                    line = strtrim(line);
                    if isempty(line) || line(1) == '#'
                        continue;
                    end
                    colonIdx = strfind(line, ':');
                    if isempty(colonIdx), continue; end
                    lhs = strtrim(line(1:colonIdx(1)-1));
                    rhs = strtrim(line(colonIdx(1)+1:end));
                    if isempty(lhs) || isempty(rhs), continue; end
                    map(lhs) = rhs;
                end
                fclose(fid);
                fid = -1;
            catch
                if fid >= 0
                    try, fclose(fid); catch, end %#ok<CTCH>
                end
                map = containers.Map('KeyType', 'char', 'ValueType', 'char');
            end
        end
    end
end
