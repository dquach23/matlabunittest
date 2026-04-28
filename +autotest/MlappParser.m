classdef MlappParser < handle
    %MLAPPPARSER  Parse a .mlapp App Designer archive into a SourceModel.
    %
    %   .mlapp files are ZIP archives.  This parser extracts the archive to
    %   a temporary directory, locates the embedded MATLAB source for the
    %   app's classdef (typically in matlab/document.xml), parses it with
    %   autotest.MFileParser, and additionally extracts the component tree
    %   from appdesigner/appModel.xml to populate Components and to map
    %   callback methods to component tags.

    properties (SetAccess = immutable)
        SourcePath (1,:) char
    end

    methods
        function obj = MlappParser(sourcePath)
            obj.SourcePath = sourcePath;
        end

        function model = parse(obj)
            tmpDir = tempname();
            mkdir(tmpDir);
            cleanup = onCleanup(@() autotest.MlappParser.tryRmdir(tmpDir));

            try
                unzip(obj.SourcePath, tmpDir);
            catch ME
                error('autotest:UnzipFailed', ...
                    'Could not unzip %s: %s', obj.SourcePath, ME.message);
            end

            srcM = obj.extractClassdefSource(tmpDir);
            if isempty(srcM)
                error('autotest:NoSource', ...
                    'No classdef source could be located in %s', obj.SourcePath);
            end

            % Write source to a temp .m file and parse with MFileParser to
            % reuse all of its logic.
            [~, appName] = fileparts(obj.SourcePath);
            tmpM = fullfile(tmpDir, [appName '.m']);
            fid = fopen(tmpM, 'w');
            fwrite(fid, srcM);
            fclose(fid);

            mfp = autotest.MFileParser(tmpM);
            model = mfp.parse();
            model.Kind       = 'app';
            model.SourcePath = obj.SourcePath;
            model.SourceName = appName;
            if isempty(model.ClassName)
                model.ClassName = appName;
            end

            % Inspect appModel.xml for the component tree so we can drive
            % callback tests with real component tags.
            [components, callbackMap] = obj.parseAppModel(tmpDir);
            model.Components = components;

            % Promote methods that look like callbacks (suffix Callback,
            % ButtonPushed, ValueChanged, etc.) into the Callbacks struct.
            model.Callbacks = obj.identifyCallbacks(model.Methods, callbackMap);
        end
    end

    methods (Access = private)
        function src = extractClassdefSource(~, tmpDir)
            src = '';
            % Most-likely locations.
            candidates = { ...
                fullfile(tmpDir, 'matlab', 'document.xml'), ...
                fullfile(tmpDir, 'appdesigner', 'document.xml'), ...
                };
            for k = 1:numel(candidates)
                if isfile(candidates{k})
                    txt = autotest.MlappParser.readText(candidates{k});
                    candidate = autotest.MlappParser.extractMatlabFromXml(txt);
                    if ~isempty(candidate)
                        src = candidate;
                        return;
                    end
                end
            end
            % Fallback: scan all .xml files for embedded classdef.
            xmlFiles = dir(fullfile(tmpDir, '**', '*.xml'));
            for k = 1:numel(xmlFiles)
                fp = fullfile(xmlFiles(k).folder, xmlFiles(k).name);
                txt = autotest.MlappParser.readText(fp);
                candidate = autotest.MlappParser.extractMatlabFromXml(txt);
                if ~isempty(candidate)
                    src = candidate;
                    return;
                end
            end
        end

        function [components, callbackMap] = parseAppModel(~, tmpDir)
            components = autotest.SourceModel.emptyComponent();
            callbackMap = containers.Map('KeyType','char','ValueType','char');
            appModel = fullfile(tmpDir, 'appdesigner', 'appModel.xml');
            if ~isfile(appModel)
                return;
            end
            try
                txt = autotest.MlappParser.readText(appModel);
            catch
                return;
            end

            tagMatches = regexp(txt, ...
                '<\s*([A-Za-z]\w*)[^>]*\s+Tag\s*=\s*"([^"]+)"', ...
                'tokens');
            for k = 1:numel(tagMatches)
                components(end+1) = autotest.SourceModel.makeComponent( ...
                    tagMatches{k}{2}, tagMatches{k}{1}); %#ok<AGROW>
            end

            % Two common App Designer encodings for callbacks:
            %   ButtonPushedFcn="@(s,e)app.MyCallback(s,e)"
            %   ButtonPushedFcn="@(s,e)MyCallback(s,e)"
            %   ButtonPushedFcn="createCallbackFcn(app, @MyCallback, true)"
            % We accept all three by allowing an optional 'app.' prefix
            % and an optional '@' for the createCallbackFcn variant.
            cbMatches = regexp(txt, ...
                ['Tag\s*=\s*"([^"]+)"[^>]*?' ...
                 '(?:\w+Fcn|\w+Callback)\s*=\s*"' ...
                 '(?:@\([^)]*\)\s*|createCallbackFcn\s*\(\s*app\s*,\s*@\s*)' ...
                 '(?:app\.)?([A-Za-z]\w*)'], ...
                'tokens');
            for k = 1:numel(cbMatches)
                callbackMap(cbMatches{k}{2}) = cbMatches{k}{1};
            end
        end

        function cbs = identifyCallbacks(~, methods, callbackMap)
            cbs = autotest.SourceModel.emptyCallback();
            patterns = { ...
                'Callback$', 'PushedFcn$', 'ValueChanged$', ...
                'Pushed$', 'Changed$', 'StartupFcn$', 'CloseRequest$', ...
                'KeyPress$', 'ButtonDown$', 'WindowKeyPress$'};
            for k = 1:numel(methods)
                m = methods(k);
                isCb = strcmp(m.Name, 'startupFcn');
                for p = 1:numel(patterns)
                    if ~isempty(regexp(m.Name, patterns{p}, 'once'))
                        isCb = true; break;
                    end
                end
                if isCb
                    cb = autotest.SourceModel.makeCallback(m.Name);
                    cb.Inputs = m.Inputs;
                    if isKey(callbackMap, m.Name)
                        cb.ComponentTag = callbackMap(m.Name);
                    end
                    cbs(end+1) = cb; %#ok<AGROW>
                end
            end
        end
    end

    methods (Static, Access = private)
        function txt = readText(filePath)
            fid = fopen(filePath, 'r', 'n', 'UTF-8');
            if fid < 0
                txt = '';
                return;
            end
            cleaner = onCleanup(@() fclose(fid));
            txt = fread(fid, '*char').';
        end

        function code = extractMatlabFromXml(xmlText)
            code = '';
            if isempty(xmlText), return; end
            % Look for a CDATA section containing "classdef".
            cdata = regexp(xmlText, '<!\[CDATA\[(.*?)\]\]>', 'tokens');
            for k = 1:numel(cdata)
                blob = cdata{k}{1};
                if contains(blob, 'classdef')
                    code = blob;
                    retur