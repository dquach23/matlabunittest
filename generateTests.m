function testFile = generateTests(sourcePath, varargin)
%GENERATETESTS  Auto-generate a matlab.unittest test class from a .m or .mlapp file.
%
%   T = GENERATETESTS(SOURCEPATH) parses the source at SOURCEPATH (a .m
%   function, a .m classdef, or a .mlapp App Designer app) and writes a
%   matlab.unittest.TestCase subclass next to it.  T is the absolute path
%   of the generated test file.
%
%   T = GENERATETESTS(SOURCEPATH, 'Name', VALUE, ...) supports:
%       'OutputDir'      - directory to write the test file into
%                          (default: alongside the source)
%       'TestClassName'  - override the generated class name
%                          (default: ['t' OriginalName])
%       'Overwrite'      - logical; overwrite existing file (default true)
%       'PropertyTests'  - logical; emit property-based tests with
%                          randomised inputs (default true)
%       'EdgeCaseTests'  - logical; emit empty/NaN/Inf edge-case tests
%                          (default true)
%       'DocExampleTests'- logical; emit tests derived from "Example:"
%                          blocks in help comments (default true)
%       'AppCallbackTests' - logical; for .mlapp files, emit tests that
%                          launch the app and exercise each callback
%                          (default true)
%       'Verbose'        - logical; print parsing diagnostics
%                          (default false)
%
%   Example:
%       generateTests('examples/sampleFunctions.m');
%       generateTests('examples/Calculator.m', 'OutputDir','tests');
%
%   See also: matlab.unittest.TestCase, autotest.TestGenerator.

    arguments
        sourcePath (1,:) char {mustBeNonempty}
    end
    arguments (Repeating)
        varargin
    end

    gen = autotest.TestGenerator(sourcePath, varargin{:});
    testFile = gen.run();
end
