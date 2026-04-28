classdef tParser < matlab.unittest.TestCase
    %TPARSER  Self-tests for autotest.MFileParser.
    %
    %   These tests don't run the *generated* tests; they validate that
    %   the parser correctly extracts the structure of representative
    %   inputs.  Run via `runtests('tests')` from the repo root.

    properties (Constant, Access = private)
        ExamplesDir = fullfile(fileparts(fileparts(mfilename('fullpath'))), 'examples');
    end

    methods (TestMethodSetup)
        function addPaths(testCase)
            repoRoot = fileparts(fileparts(mfilename('fullpath')));
            addpath(repoRoot);
            testCase.addTeardown(@() rmpath(repoRoot));
        end
    end

    methods (Test)
        function parsesFunctionFile(testCase)
            p = autotest.MFileParser(fullfile(testCase.ExamplesDir, 'sampleFunctions.m'));
            model = p.parse();
            testCase.verifyEqual(model.Kind, 'function');
            testCase.verifyEqual(numel(model.Functions), 1);
            testCase.verifyEqual(model.Functions(1).Name, 'sampleFunctions');
            testCase.verifyEqual(model.Functions(1).Inputs, {'x','scale'});
            testCase.verifyEqual(model.Functions(1).Outputs, {'y'});
            testCase.verifyNotEmpty(model.Functions(1).ArgumentBlocks);
        end

        function parsesExamplesFromHelp(testCase)
            p = autotest.MFileParser(fullfile(testCase.ExamplesDir, 'sampleFunctions.m'));
            model = p.parse();
            testCase.verifyGreaterThanOrEqual(numel(model.Functions(1).Examples), 2);
        end

        function parsesClassdef(testCase)
            p = autotest.MFileParser(fullfile(testCase.ExamplesDir, 'Calculator.m'));
            model = p.parse();
            testCase.verifyEqual(model.Kind, 'classdef');
            testCase.verifyEqual(model.ClassName, 'Calculator');
            testCase.verifyTrue(model.IsHandle);

            propNames = arrayfun(@(p) string(p.Name), model.Properties);
            testCase.verifyTrue(any(propNames == "Total"));
            testCase.verifyTrue(any(propNames == "OperationCount"));

            mNames = arrayfun(@(m) string(m.Name), model.Methods);
            testCase.verifyTrue(any(mNames == "add"));
            testCase.verifyTrue(any(mNames == "subtract"));
            testCase.verifyTrue(any(mNames == "scale"));

            scaleIdx = find(mNames == "scale", 1);
            testCase.verifyTrue(model.Methods(scaleIdx).IsStatic);

            addIdx = find(mNames == "add", 1);
            testCase.verifyEqual(model.Methods(addIdx).Inputs, {'x'}, ...
                'obj should have been stripped from non-static method inputs');
        end

        function generatesTestForFunction(testCase)
            outDir = tempname(); mkdir(outDir);
            cleaner = onCleanup(@() rmdir(outDir, 's'));
            t = generateTests(fullfile(testCase.ExamplesDir, 'sampleFunctions.m'), ...
                'OutputDir', outDir);
            testCase.verifyTrue(isfile(t));
            txt = fileread(t);
            testCase.verifyTrue(contains(txt, 'classdef tsampleFunctions'));
            testCase.verifyTrue(contains(txt, 'matlab.unittest.TestCase'));
            testCase.verifyTrue(contains(txt, 'testSmoke_sampleFunctions'));
            testCase.verifyTrue(contains(txt, 'testEdge_sampleFunctions'));
        end

        function generatesTestForClassdef(testCase)
            outDir = tempname(); mkdir(outDir);
            cleaner = onCleanup(@() rmdir(outDir, 's'));
            t = generateTests(fullfile(testCase.ExamplesDir, 'Calculator.m'), ...
                'OutputDir', outDir);
            testCase.verifyTrue(isfile(t));
            txt = fileread(t);
            testCase.verifyTrue(contains(txt, 'classdef tCalculator'));
            testCase.verifyTrue(contains(txt, 'testProperty_Total'));
            testCase.verifyTrue(contains(txt, 'testSmoke_add'));
            testCase.verifyTrue(contains(txt, 'safeDelete'));
        end

        function generatedTestActuallyRuns(testCase)
            outDir = tempname(); mkdir(outDir);
            cleaner = onCleanup(@() rmdir(outDir, 's'));
            t = generateTests(fullfile(testCase.ExamplesDir, 'sampleFunctions.m'), ...
                'OutputDir', outDir);

            addpath(outDir);
            testCase.addTeardown(@() rmpath(outDir));

            [~, name] = fileparts(t);
            results = runtests(name);
            testCase.verifyEmpty([results.Failed], 'Generated tests should not fail');
            testCase.verifyEmpty([results.Incomplete], ...
                'Generated tests should not be incomplete');
            testCase.verifyGreaterThan(numel(results), 0);
        end

        fun