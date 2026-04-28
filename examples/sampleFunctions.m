function y = sampleFunctions(x, scale)
%SAMPLEFUNCTIONS  Demo function used to exercise autotest test generation.
%
%   Y = SAMPLEFUNCTIONS(X, SCALE) returns SCALE multiplied by X.  X must be
%   numeric and SCALE must be a numeric scalar.  Outputs preserve the type
%   of X.
%
%   Example:
%       y = sampleFunctions(magic(3), 2);
%
%   Example:
%       y = sampleFunctions([1 2 3], 0.5);
%
%   See also: examples.Calculator.

    arguments
        x       {mustBeNumeric}
        scale   (1,1) double = 1
    end
    y = scale .* x;
end
