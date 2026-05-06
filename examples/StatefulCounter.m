classdef StatefulCounter < handle
    %STATEFULCOUNTER  Synthetic stateful class for Phase 11 portability tests.
    %
    %   The constructor leaves the Counts dictionary empty.  Phase 2.4
    %   detects this and sets IsStateful = true, which historically gated
    %   every instance method to testSkipped_<name>.  Phase 11 adds a
    %   StateInitializer prelude that calls zero-arg state-init methods
    %   (here `buildLookupMaps`) before each test, so the smoke layer can
    %   actually exercise the get/increment/total methods.
    %
    %   This class is intentionally small and generic -- no project-
    %   specific knowledge -- so it serves as portability evidence that
    %   the StateInitializer mechanism works for any MATLAB project that
    %   follows the common build/load/init naming convention.

    properties
        Counts dictionary
        Tag    (1,:) char
    end

    methods
        function obj = StatefulCounter(tag)
            arguments
                tag (1,:) char = 'default'
            end
            obj.Tag = tag;
            obj.Counts = dictionary;
        end

        function buildLookupMaps(obj)
            %BUILDLOOKUPMAPS  Populate the Counts dictionary with seed entries.
            obj.Counts('alpha') = 0;
            obj.Counts('beta')  = 0;
            obj.Counts('gamma') = 0;
        end

        function increment(obj, key)
            %INCREMENT  Bump the count for KEY by one.
            arguments
                obj
                key (1,:) char
            end
            if isKey(obj.Counts, key)
                obj.Counts(key) = obj.Counts(key) + 1;
            else
                obj.Counts(key) = 1;
            end
        end

        function n = get(obj, key)
            %GET  Return the current count for KEY (0 when not present).
            arguments
                obj
                key (1,:) char
            end
            if isKey(obj.Counts, key)
                n = obj.Counts(key);
            else
                n = 0;
            end
        end

        function n = total(obj)
            %TOTAL  Sum of all counts in the lookup table.
            ks = keys(obj.Counts);
            n = 0;
            for k = 1:numel(ks)
                n = n + obj.Counts(ks(k));
            end
        end

        function reset(obj)
            %RESET  Zero every entry currently in the table.
            ks = keys(obj.Counts);
            for k = 1:numel(ks)
                obj.Counts(ks(k)) = 0;
            end
        end
    end
end
