classdef tAutotestGUI < matlab.unittest.TestCase
    %TAUTOTESTGUI  Self-tests for the autotest workflow pipeline.
    %
    %   These exercise the *non-GUI* core (autotest.runWorkflow) against a
    %   small fixture project living under tests/fixtures/sampleProject so
    %   that we don't need a display to run them.

    properties (Constant, Access = private)
        FixtureDir = fullfile( ...
            fileparts(fileparts(mfilename('fullpath'))), ...
            'tests', 'fixtures', 'sampleProject');
    end

    properties (Access = private)
        WorkRoot   (1,:) char
        OutRoot    (1,:) char
    end

    methods (TestMethodSetup)
        function addPaths(testCase)
            repoRoot = fileparts(fileparts(mfilename('fullpath')));
            addpath(repoRoot);
            testCase.addTeardown(@() rmpath(repoRoot));
        end

        function stageFixture(testCase)
            % Copy the static fixture into a fresh tempdir so the workflow
            % can write _autotest/ into a clean tree without polluting the
            % repo or stepping on a prior run.
            scratch = tempname();
            mkdir(scratch);
            testCase.WorkRoot = scratch;
            testCase.OutRoot  = fullfile(scratch, '_autotest');
            copyfile(testCase.FixtureDir, scratch);
            testCase.addTeardown(@() removeQuietly(scratch));
        end
    end

    methods (Test)
        function discoversAndGenerates(testCase)
            info = autotest.runWorkflow(testCase.WorkRoot);

            % We expect 2 .m sources (addOne, Counter) and 1 .mlapp.
            kinds = {info.Sources.Kind};
            testCase.verifyEqual(sum(strcmp(kinds, '.m')), 2, ...
                'Expected 2 .m sources in fixture');
            testCase.verifyEqual(sum(strcmp(kinds, '.mlapp')), 1, ...
                'Expected 1 .mlapp source in fixture');
            testCase.verifyTrue(all([info.Sources.Generated]), ...
                'All fixture sources should generate cleanly');
        end

        function outputLayoutExists(testCase)
            info = autotest.runWorkflow(testCase.WorkRoot);

            testCase.verifyTrue(isfolder(info.GeneratedDir));
            testCase.verifyTrue(isfolder(info.ReportsDir));
            testCase.verifyTrue(isfolder(info.LogsDir));
            testCase.verifyTrue(isfolder(info.ExportsDir));

            testCase.verifyTrue(isfile(fullfile(info.ReportsDir, 'summary.txt')));
            % TAP and JUnit plugins write only when at least one test runs.
            testCase.verifyTrue(isfile(fullfile(info.ReportsDir, 'results.tap')));
            testCase.verifyTrue(isfile(fullfile(info.ReportsDir, 'results.xml')));

            % Diary file should exist with the timestamped name.
            d = dir(fullfile(info.LogsDir, 'run-*.log'));
            testCase.verifyNotEmpty(d, 'Expected a timestamped run log');
        end

        function generatedTreeMirrorsSources(testCase)
            info = autotest.runWorkflow(testCase.WorkRoot);

            % addOne.m is at root -> tests/generated/taddOne.m
            testCase.verifyTrue(isfile( ...
                fullfile(info.GeneratedDir, 'taddOne.m')));
            % Counter.m is at sub/ -> tests/generated/sub/tCounter.m
            testCase.verifyTrue(isfile( ...
                fullfile(info.GeneratedDir, 'sub', 'tCounter.m')));
            % SimpleApp.mlapp at root -> tests/generated/tSimpleApp.m
            testCase.verifyTrue(isfile( ...
                fullfile(info.GeneratedDir, 'tSimpleApp.m')));
        end

        function testsActuallyRan(testCase)
            info = autotest.runWorkflow(testCase.WorkRoot);

            testCase.verifyGreaterThan(info.Summary.Total, 0, ...
                'Should have produced at least one runnable test');
            testCase.verifyEqual(info.Summary.Failed, 0, ...
                'Generated fixture tests should not fail');
            testCase.verifyEqual(info.Summary.Incomplete, 0, ...
                'Generated fixture tests should not be incomplete');
        end

        function rerunReplacesGeneratedAndPreservesLogs(testCase)
            first  = autotest.runWorkflow(testCase.WorkRoot);
            pause(1.1);  % ensure timestamped log filename will differ
            second = autotest.runWorkflow(testCase.WorkRoot);

            testCase.verifyNotEqual(first.Timestamp, second.Timestamp, ...
                'Re-run should produce a fresh timestamp');
            logs = dir(fullfile(second.LogsDir, 'run-*.log'));
            testCase.verifyGreaterThanOrEqual(numel(logs), 2, ...
                'Both run logs should be preserved in logs/');

            % generated/ should still contain the fresh tests; reports/
            % should have been overwritten with the latest summary.
            testCase.verifyTrue(isfile( ...
                fullfile(second.GeneratedDir, 'taddOne.m')));
            testCase.verifyTrue(isfile( ...
                fullfile(second.ReportsDir, 'summary.txt')));
        end

        function skipsAutotestOutputDir(testCase)
            % Pre-populate _autotest/ with a fake .m file; runWorkflow
            % should not pick it up as a source to generate tests for.
            mkdir(testCase.OutRoot);
            decoyDir = fullfile(testCase.OutRoot, 'previousJunk');
            mkdir(decoyDir);
            decoyFile = fullfile(decoyDir, 'shouldBeIgnored.m');
            fid = fopen(decoyFile, 'w');
            fprintf(fid, 'function y = shouldBeIgnored(x)\n y = x;\nend\n');
            fclose(fid);

            info = autotest.runWorkflow(testCase.WorkRoot);
            paths = {info.Sources.Path};
            mask  = contains(paths, [filesep '_autotest' filesep]);
            testCase.verifyFalse(any(mask), ...
                'Files inside _autotest/ should be skipped during discovery');
        end

        function skipsExistingTestFiles(testCase)
            % Drop a file that looks like a test (tFoo.m) into the fixture
            % and make sure it is not regenerated.
            decoy = fullfile(testCase.WorkRoot, 'tDecoy.m');
            fid = fopen(decoy, 'w');
            fprintf(fid, 'classdef tDecoy < matlab.unittest.TestCase\nend\n');
            fclose(fid);

            info = autotest.runWorkflow(testCase.WorkRoot);
            rels = {info.Sources.RelPath};
            testCase.verifyFalse(any(strcmp(rels, 'tDecoy.m')), ...
                'Files matching ^t[A-Z] should be treated as tests, not sources');
        end
    end
end

function removeQuietly(p)
    try
        if isfolder(p)
            rmdir(p, 's');
        end
    catch
    end
end
