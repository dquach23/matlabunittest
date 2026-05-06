% verify_phase9.m -- one-shot Phase 9 verification.
% Run this from MATLAB:  cd into matlabunittest, type  verify_phase9
% or just  run('C:\Users\Duy\Projects\matlabunittest\verify_phase9.m')

close all force;
delete(findall(0,'Type','figure'));
clear classes;

target = 'C:\Users\Duy\OneDrive\Documents\MATLAB\removal_redaction_tool';
runner = fullfile(target, 'run_autotest.m');

if ~exist(runner, 'file')
    error('verify_phase9:missing', 'run_autotest.m not found at %s', runner);
end

run(runner);

summaryPath = fullfile(target, '_autotest', 'reports', 'summary.txt');
if exist(summaryPath, 'file')
    fprintf('\n\n========== Phase 9 verification summary ==========\n');
    disp(fileread(summaryPath));
end
