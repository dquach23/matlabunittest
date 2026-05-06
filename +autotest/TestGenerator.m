classdef TestGenerator < handle
    %TESTGENERATOR  Orchestrates parsing of MATLAB source and emission of tests.
    %
    %   TestGenerator is the entry point used by GENERATETESTS.  It dispatches
    %   to autotest.MFileParser or autotest.MlappParser based on file extension,
    %   then hands the resulting autotest.SourceModel to autotest.TestWriter.

    properties (SetAccess = immutable)
        SourcePath           (1,:) char
        SourceExt            (1,:) char
        OutputDir            (1,:) char
        UserStubDir          (1,:) char
        TestClassName        (1,:) char
        UserStubClassName    (1,:) char
        Overwrite            (1,1) logical
        PropertyTests        (1,1) logical
        EdgeCaseTests        (1,1) logical
        DocExampleTests      (1,1) logical
        AppCallbackTests     (1,1) logical
        Verbose              (1,1) logical
        FixtureProvider                       % autotest.FixtureProvider | []
        TargetFolder         (1,:) char       % project root, used by KnownRealSignal
    end

    methods
        function obj = TestGenerator(sourcePath, varargin)
            p = inputParser();
            p.addRequired('sourcePath', @(x) ischar(x) || (isstring(x) && isscalar(x)));
            p.addParameter('OutputDir', '', @(x) ischar(x) || isstring(x));
            p.addParameter('UserStubDir', '', @(x) ischar(x) || isstring(x));
            p.addParameter('TestClassName', '', @(x) ischar(x) || isstring(x));
            p.addParameter('UserStubClassName', '', @(x) ischar(x) || isstring(x));
            p.addParameter('Overwrite', true, @islogical);
            p.addParameter('PropertyTests', true, @islogical);
            p.addParameter('EdgeCaseTests', true, @islogical);
            p.addParameter('DocExampleTests', true, @islogical);
            p.addParameter('AppCallbackTests', true, @islogical);
            p.addParameter('Verbose', false, @islogical);
            p.addParameter('FixtureProvider', [], @(x) isempty(x) || isa(x, 'autotest.FixtureProvider'));
            p.addParameter('TargetFolder', '', @(x) ischar(x) || isstring(x));
            p.parse(sourcePath, varargin{:});
            r = p.Results;

            absPath = autotest.TestGenerator.resolvePath(char(r.sourcePath));
            if ~isfile(absPath)
                error('autotest:SourceNotFound', ...
                    'Source file does not exist: %s', absPath);
            end
            [srcDir, srcName, srcExt] = fileparts(absPath);

            obj.SourcePath       = absPath;
            obj.SourceExt        = lower(srcExt);
            if isempty(char(r.OutputDir))
                obj.OutputDir = srcDir;
            else
                obj.OutputDir = autotest.TestGenerator.resolvePath(char(r.OutputDir));
                if ~isfolder(obj.OutputDir)
                    mkdir(obj.OutputDir);
                end
            end
            if isempty(char(r.TestClassName))
                obj.TestClassName = ['t' srcName];
            else
                obj.TestClassName = char(r.TestClassName);
            end
            if isempty(char(r.UserStubDir))
                obj.UserStubDir = '';
            else
                obj.UserStubDir = autotest.TestGenerator.resolvePath(char(r.UserStubDir));
                if ~isfolder(obj.UserStubDir)
                    mkdir(obj.UserStubDir);
                end
            end
            if isempty(char(r.UserStubClassName))
                obj.UserStubClassName = ['u' srcName];
            else
                obj.UserStubClassName = char(r.UserStubClassName);
            end
            obj.Overwrite        = r.Overwrite;
            obj.PropertyTests    = r.PropertyTests;
            obj.EdgeCaseTests    = r.EdgeCaseTests;
            obj.DocExampleTests  = r.DocExampleTests;
            obj.AppCallbackTests = r.AppCallbackTests;
            obj.Verbose          = r.Verbose;
            obj.FixtureProvider  = r.FixtureProvider;
            obj.TargetFolder     = char(r.TargetFolder);
        end

        function testFile = run(obj)
            obj.log('Parsing %s', obj.SourcePath);

            switch obj.SourceExt
                case '.m'
                    parser = autotest.MFileParser(obj.SourcePath);
                case '.mlapp'
                    parser = autotest.MlappParser(obj.SourcePath);
                otherwise
                    error('autotest:UnsupportedExt', ...
                        'Unsupported source extension: %s', obj.SourceExt);
            end

            model = parser.parse();
            obj.log('Found %d functions, %d methods, %d properties, %d callbacks', ...
                numel(model.Functions), numel(model.Methods), ...
                numel(model.Properties), numel(model.Callbacks));

            testFile = fullfile(obj.OutputDir, [obj.TestClassName '.m']);
            if isfile(testFile) && ~obj.Overwrite
                error('autotest:Exists', ...
                    'Test file already exists and Overwrite=false: %s', testFile);
            end

            writer = autotest.TestWriter(model, obj);
            writer.writeTo(testFile);

            obj.log('Wrote %s', testFile);

            if ~isempty(obj.UserStubDir)
                stubFile = fullfile(obj.UserStubDir, [obj.UserStubClassName '.m']);
                wrote = writer.writeUserStubTo(stubFile, obj.UserStubClassName);
                if wrote
                    obj.log('Wrote user stub %s', stubFile);
                else
                    obj.log('Preserved existing user stub %s', stubFile);
                end
            end
        end
    end

    methods (Access = private)
        function log(obj, fmt, varargin)
            if obj.Verbose
                fprintf('[autotest] ');
                fprintf(fmt, varargin{:});
                fprintf('\n');
            end
        end
    end

    methods (Static, Access = private)
        function abs = resolvePath(p)
            if isempty(p)
                abs = '';
                return;
            end
            f = java.io.File(p);
            if f.isAbsolute()
                abs = char(f.getCanonicalPath());
            else
                abs = char(java.io.File(fullfile(pwd, p)).getCanonicalPath());
            end
        end
    end
end
