classdef Calculator < handle
    %CALCULATOR  Trivial accumulator class for autotest demonstrations.
    %
    %   c = Calculator() creates a calculator with Total set to 0.
    %   c = Calculator(initial) seeds Total with the given numeric value.
    %
    %   Example:
    %       c = Calculator(10);
    %       c.add(5);

    properties
        Total (1,1) double = 0
        Tag   (1,1) string = "default"
    end

    properties (SetAccess = private)
        OperationCount (1,1) double = 0
    end

    methods
        function obj = Calculator(initial)
            arguments
                initial (1,1) double = 0
            end
            obj.Total = initial;
        end

        function out = add(obj, x)
            arguments
                obj
                x (1,1) double
            end
            obj.Total = obj.Total + x;
            obj.OperationCount = obj.OperationCount + 1;
            out = obj.Total;
        end

        function out = subtract(obj, x)
            arguments
                obj
                x (1,1) double
            end
            obj.Total = obj.Total - x;
            obj.OperationCount = obj.OperationCount + 1;
            out = obj.Total;
        end

        function reset(obj)
            obj.Total = 0;
            obj.OperationCount = 0;
        end
    end

    methods (Static)
        function y = scale(x, k)
            arguments
                x {mustBeNumeric}
                k (1,1) double = 1
            end
            y = k * x;
        end
    end
end
