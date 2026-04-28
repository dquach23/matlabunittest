function y = addOne(x)
%ADDONE  Add one to a numeric input. Fixture for tAutotestGUI.
%
%   Y = ADDONE(X) returns X + 1.
%
%   Example:
%       y = addOne(3);

    arguments
        x {mustBeNumeric}
    end
    y = x + 1;
end
