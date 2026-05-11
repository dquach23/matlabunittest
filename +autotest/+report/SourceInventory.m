classdef SourceInventory
    %SOURCEINVENTORY  Phase 15 -- walks PROJECT_PATH for .m and .mlapp.
    %
    %   inv = autotest.report.SourceInventory.scan(folder)
    %
    %   Returns a struct array with one entry per source file (matching
    %   the discovery rules in autotest.runWorkflow.discoverSources).
    %   Each entry has fields {File, Kind, Summary, IsApp, IsClass}.
    %
    %   Summary is the H1 line (first contiguous comment block after the
    %   classdef / function declaration), quoted verbatim from the source
    %   file.  When no H1 is present (a .mlapp with no embedded summary
    %   comment, or a function with no help text), Summary is a one-line
    %   factual description marked as derived.
    %
    %   Generic across MATLAB projects.

    methods (Static)
        function inv = scan(folder)
            arguments
                folder (1,:) char
            end
            inv = struct('File',{},'Kind',{},'Summary',{},'IsApp',{},'IsClass',{});
            if ~isfolder(folder), return; end

            outRoot = fullfile(folder, '_autotest');
            list = dir(fullfile(folder, '**', '*'));
            for i = 1:numel(list)
                d = list(i);
                if d.isdir, continue; end
                full = fullfile(d.folder, d.name);
                if startsWith(autotest.report.SourceInventory.norm(full), ...
                        [autotest.report.SourceInventory.norm(outRoot) filesep])
                    continue;
                end
                if autotest.report.SourceInventory.insideIgnored(d.folder, folder)
                    continue;
                end
                [~, base, ext] = fileparts(d.name);
                lext = lower(ext);
                if ~ismember(lext, {'.m', '.mlapp'}), continue; end
                if autotest.report.SourceInventory.looksLikeTest(base), continue; end

                rel = autotest.report.SourceInventory.relativeTo(full, folder);
                rel = strrep(rel, '\', '/');

                isApp = strcmp(lext, '.mlapp');
                isClass = false;
                if strcmp(lext, '.m')
                    try
                        h = autotest.report.SourceInventory.firstNonCommentLine(full);
                        if ~isempty(h) && ~isempty(regexp(h, '^\s*classdef\s', 'once'))
                            isClass = true;
                        end
                    catch
                    end
                end

                kind = autotest.report.SourceInventory.classifyKind(full, lext, isApp, isClass);
                summary = autotest.report.SourceInventory.h1Or(full, isApp, base);

                inv(end+1) = struct( ...
                    'File',    rel, ...
                    'Kind',    kind, ...
                    'Summary', summary, ...
                    'IsApp',   isApp, ...
                    'IsClass', isClass); %#ok<AGROW>
            end
            % Stable sort: by File path.
            if ~isempty(inv)
                [~, ord] = sort({inv.File});
                inv = inv(ord);
            end
        end

        function n = norm(p)
            n = char(p);
            if ~isempty(n) && n(end) == filesep, n(end) = []; end
        end

        function tf = insideIgnored(folderOfFile, projectRoot)
            ignored = {'.git', '.svn', '.hg', '.idea', '.vscode', ...
                       'node_modules', '_autotest'};
            rel = autotest.report.SourceInventory.relativeTo(folderOfFile, projectRoot);
            if isempty(rel), tf = false; return; end
            parts = strsplit(rel, filesep);
            parts(cellfun(@isempty, parts)) = [];
            tf = any(ismember(parts, ignored));
        end

        function tf = looksLikeTest(name)
            tf = ~isempty(regexp(name, '^t[A-Z]', 'once')) || ...
                 ~isempty(regexp(name, '^test[A-Z]', 'once')) || ...
                 ~isempty(regexp(name, '^run_[A-Za-z]', 'once'));
        end

        function rel = relativeTo(target, base)
            target = autotest.report.SourceInventory.norm(target);
            base   = autotest.report.SourceInventory.norm(base);
            if strcmpi(target, base)
                rel = '';
            elseif startsWith(lower(target), [lower(base) filesep])
                rel = target(numel(base)+2:end);
            else
                rel = target;
            end
        end

        function kind = classifyKind(full, lext, isApp, isClass)
            if isApp
                kind = 'App Designer (.mlapp)';
                return;
            end
            if isClass
                allText = '';
                try
                    fid = fopen(full, 'r');
                    if fid >= 3
                        allText = fread(fid, [1, inf], '*char');
                        fclose(fid);
                    end
                catch
                end
                if contains(allText, '< handle')
                    kind = 'handle classdef';
                    return;
                end
                if ~isempty(regexp(allText, 'methods\s*\(\s*Static\s*\)', 'once'))
                    if isempty(regexp(allText, 'methods\s*\([^)]*Access', 'once'))
                        kind = 'classdef (Static)';
                        return;
                    end
                end
                kind = 'classdef';
                return;
            end
            kind = 'function';
        end

        function summary = h1Or(full, isApp, base)
            summary = '';
            if isApp
                % Try to extract embedded classdef summary from
                % matlab/document.xml inside the .mlapp zip.
                try
                    summary = autotest.report.SourceInventory.mlappH1(full);
                catch
                end
                if isempty(summary)
                    summary = sprintf('App Designer application (no embedded summary; derived: %s.mlapp)', base);
                end
                return;
            end
            try
                fid = fopen(full, 'r');
                cleanup = onCleanup(@() autotest.report.SourceInventory.tryClose(fid));
                if fid < 3, return; end
                lines = {};
                while ~feof(fid)
                    ln = fgetl(fid);
                    if ~ischar(ln), break; end
                    lines{end+1} = ln; %#ok<AGROW>
                    if numel(lines) > 200, break; end
                end
            catch
                return;
            end
            % Find the first non-blank, non-comment line (declares
            % function/classdef), then collect contiguous % comments
            % that follow it.
            startIdx = 0;
            for i = 1:numel(lines)
                ln = strtrim(lines{i});
                if isempty(ln) || ln(1) == '%', continue; end
                if ~isempty(regexp(ln, '^(function|classdef)\b', 'once'))
                    startIdx = i;
                    break;
                end
            end
            if startIdx == 0, return; end
            commentLines = {};
            for j = startIdx+1:numel(lines)
                ln = strtrim(lines{j});
                if isempty(ln), continue; end
                if ln(1) ~= '%', break; end
                commentLines{end+1} = strtrim(ln(2:end)); %#ok<AGROW>
                if numel(commentLines) > 8, break; end
            end
            if isempty(commentLines)
                summary = sprintf('(no help text in source; derived: %s.m)', base);
                return;
            end
            % Take first 1-2 comment lines and join.
            n = min(2, numel(commentLines));
            parts = commentLines(1:n);
            summary = strjoin(parts, ' ');
            summary = regexprep(summary, '\s+', ' ');
        end

        function summary = mlappH1(full)
            summary = '';
            tmpDir = tempname();
            try
                unzip(full, tmpDir);
                xmlPath = fullfile(tmpDir, 'matlab', 'document.xml');
                if ~isfile(xmlPath), return; end
                xmlText = fileread(xmlPath);
                % CDATA contains the embedded classdef.
                tok = regexp(xmlText, '<!\[CDATA\[(.*?)\]\]>', 'tokens', 'once');
                if isempty(tok), return; end
                cdata = tok{1};
                lines = strsplit(cdata, newline);
                startIdx = 0;
                for i = 1:numel(lines)
                    ln = strtrim(lines{i});
                    if ~isempty(regexp(ln, '^classdef\b', 'once'))
                        startIdx = i;
                        break;
                    end
                end
                if startIdx == 0, return; end
                commentLines = {};
                for j = startIdx+1:numel(lines)
                    ln = strtrim(lines{j});
                    if isempty(ln), continue; end
                    if ~isempty(ln) && ln(1) ~= '%', break; end
                    commentLines{end+1} = strtrim(ln(2:end)); %#ok<AGROW>
                    if numel(commentLines) > 6, break; end
                end
                if ~isempty(commentLines)
                    n = min(2, numel(commentLines));
                    summary = regexprep(strjoin(commentLines(1:n), ' '), '\s+', ' ');
                end
            catch
            end
            try
                if isfolder(tmpDir), rmdir(tmpDir, 's'); end
            catch
            end
        end

        function ln = firstNonCommentLine(full)
            ln = '';
            fid = fopen(full, 'r');
            if fid < 3, return; end
            cleanup = onCleanup(@() autotest.report.SourceInventory.tryClose(fid));
            while ~feof(fid)
                row = fgetl(fid);
                if ~ischar(row), break; end
                t = strtrim(row);
                if isempty(t) || t(1) == '%', continue; end
                ln = row; return;
            end
        end

        function tryClose(fid)
            try
                if isnumeric(fid) && fid >= 3, fclose(fid); end
            catch
            end
        end
    end
end
