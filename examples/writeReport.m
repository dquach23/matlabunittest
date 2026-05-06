function writeReport(message, fileID)
%WRITEREPORT  Write a status line to an open file handle.
%
%   WRITEREPORT(MESSAGE, FILEID) writes MESSAGE followed by a newline to
%   the file handle FILEID using fprintf.  FILEID must be a valid file
%   identifier returned by fopen.  Used by the Phase 10 portability
%   demo to verify that autotest's fileID-aware input synthesis emits
%   working tests for fid-style args without project-specific opt-outs.

    arguments
        message (1,:) char
        fileID  (1,1) double
    end
    fprintf(fileID, '%s\n', message);
end
