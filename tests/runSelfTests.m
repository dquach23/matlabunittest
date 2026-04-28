function results = runSelfTests()
%RUNSELFTESTS  Run the autotest self-test suite.
%
%   Add the repo root to path and run all tests under the tests/ folder.
%   Returns the matlab.unittest.TestResult array.

    here   = fileparts(mfilename('fullpath'));
    root   = fileparts(here);
    addpath(root);
    cleaner = onCleanup(@() rmpath(root)); %#ok<NASGU>
    results = runtests(here);
    disp(results);
end
