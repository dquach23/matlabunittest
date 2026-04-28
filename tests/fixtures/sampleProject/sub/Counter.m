classdef Counter < handle
    %COUNTER  Tiny counter class fixture for tAutotestGUI.
    %
    %   c = Counter() starts at 0.
    %
    %   Example:
    %       c = Counter();
    %       c.bump();

    properties
        Value (1,1) double = 0
    end

    methods
        function out = bump(obj)
            obj.Value = obj.Value + 1;
            out = obj.Value;
        end

        function reset(obj)
            obj.Value = 0;
        end
    end
end
