classdef tMlappParser < matlab.unittest.TestCase
    %TMLAPPPARSER  Self-tests for autotest.MlappParser and the App Designer
    %               codepath through autotest.TestGenerator.
    %
    %   These tests exercise the .mlapp -> SourceModel -> generated test
    %   class pipeline using a hand-crafted minimal .mlapp fixture
    %   (examples/SimpleApp.mlapp).  They do NOT launch the generated
    %   app tests because that would require an interactive MATLAB
    %   session with App Designer runtime; instead they verify the
    %   generated source contains the expected scaffolding.

    properties (Constant, Access = private)
        ExamplesDir = fullfile(fileparts(fileparts(mfilename('fullpath'))), 'examples');
    end

    properties (Access = private)
        AppPath
    end

    methods (TestMethodSetup)
        function addPaths(testCase)
            repoRoot = fileparts(fileparts(mfilename('fullpath')));
            addpath(repoRoot);
            testCase.addTeardown(@() rmpath(repoRoot));
            testCase.AppPath = fullfile(testCase.ExamplesDir, 'SimpleApp.mlapp');
        end
    end

    methods (Test)
        function fixtureExists(testCase)
            testCase.verifyTrue(isfile(testCase.AppPath), ...
                'examples/SimpleApp.mlapp fixture is missing');
        end

        function parsesMlappAsApp(testCase)
            p = autotest.MlappParser(testCase.AppPath);
            model = p.parse();
            testCase.verifyEqual(model.Kind, 'app');
            testCase.verifyEqual(model.ClassName, 'SimpleApp');
            testCase.verifyTrue(model.IsHandle, ...
                'matlab.apps.AppBase descendant should register as a handle class');
        end

        function parsesAppMethodsAndProperties(testCase)
            p = autotest.MlappParser(testCase.AppPath);
            model = p.parse();

            propNames = arrayfun(@(p) string(p.Name), model.Properties);
            testCase.verifyTrue(any(propNames == "UIFigure"), ...
                'UIFigure property should be parsed');
            testCase.verifyTrue(any(propNames == "MyButton"), ...
                'MyButton property should be parsed');
            testCase.verifyTrue(any(propNames == "PressCount"), ...
                'PressCount (private) property should be parsed');

            mNames = arrayfun(@(m) string(m.Name), model.Methods);
            testCase.verifyTrue(any(mNames == "startupFcn"));
            testCase.verifyTrue(any(mNames == "MyButtonPushed"));
            testCase.verifyTrue(any(mNames == "SimpleApp"));   % constructor
        end

        function identifiesCallbacks(testCase)
            p = autotest.MlappParser(testCase.AppPath);
            model = p.parse();

            cbNames = arrayfun(@(c) string(c.Name), model.Callbacks);
            testCase.verifyTrue(any(cbNames == "startupFcn"), ...
                'startupFcn should be classified as a callback');
            testCase.verifyTrue(any(cbNames == "MyButtonPushed"), ...
                'MyButtonPushed should be classified as a callback (matches Pushed$)');

            % ComponentTag should be wired for callbacks the appModel.xml
            % attaches to a tagged component.
            buttonIdx = find(cbNames == "MyButtonPushed", 1);
            testCase.verifyEqual(model.Callbacks(buttonIdx).ComponentTag, 'MyButton', ...
                'MyButtonPushed should be linked to the MyButton component tag');
        end

        function findsComponents(testCase)
            p = autotest.MlappParser(testCase.AppPath);
            model = p.parse();
            tags = arrayfun(@(c) string(c.Tag), model.Components);
            testCase.verifyTrue(any(tags == "UIFigure"), ...
                'UIFigure component should be present');
            testCase.verifyTrue(any(tags == "MyButton"), ...
                'MyButton component should be present');
        end

        function generatesTestForApp(testCase)
            outDir = tempname(); mkdir(outDir);
            cleaner = onCleanup(@() rmdir(outDir, 's')); %#ok<NASGU>

            t = generateTests(testCase.AppPath, 'OutputDir', outDir);
            testCase.verifyTrue(isfile(t));

            txt = fileread(t);
            testCase.verifyTrue(contains(txt, 'classdef tSimpleApp'), ...
                'Generated class should be named tSimpleApp');
            testCase.verifyTrue(contains(txt, 'matlab.unittest.TestCase'));
            testCase.verifyTrue(contains(txt, 'launchApp'), ...
                'App-mode TestMethodSetup should construct the app');
            testCase.verifyTrue(contains(txt, 'testAppLaunches'));
            testCase.verifyTrue(contains(txt, 'testAppHasUIFigure'));
            testCase.verifyTrue(contains(txt, 'testCallback_MyButtonPushed'), ...
                'A callback test should be generated for MyButtonPushed');
            testCase.verifyTrue(contains(txt, 'testCallback_startupFcn'), ...
                'A callback test should be generated for startupFcn');
            % The component tag should be referenced by the generated test
            % so the synthetic event resolves to the right widget.
            testCase.verifyTrue(contains(txt, 'findByTag'), ...
                'Generated tests should use findByTag helper');
            testCase.verifyTrue(contains(txt, '''MyButton'''), ...
                'Generated tests should reference the MyButton tag');
        end

        function appCallbackTestsCanBeDisabled(testCase)
            outDir = tempname(); mkdir(outDir);
            cleaner = onCleanup(@() rmdir(outDir, 's')); %#ok<NASGU>

            t = generateTests(testCase.AppPath, ...
                'OutputDir', outDir, ...
                'AppCallbackTests', false);
            testCase.verifyTrue(isfile(t));

            txt = fileread(t);
            testCase.verifyFalse(contains(txt, 'testCallback_MyButtonPushed'), ...
                'AppCallbackTests=false should suppress callback tests');
            % Core scaffolding still present.
            testCase.verifyTrue(contains(txt, 'testAppLaunches'));
        end
    end
end
