% Run BP sorting

bps = BPSorter('V1x32-Poly2', ...
    'TempDir', '/kyb/agmbrecordings/tmp/Charles/2014-07-21_13-50-16', ...
    'Debug', true, ...
    'Verbose', true, ...
    'MaxSamples', 5e6, ...
    'BlockSize', 5 * 60, ...
    'pruningRadius', 55, ...
    'waveformBasis', getfield(load('B'), 'B'), ...
    'samples', -12 : 24, ...
    'logging', true, ...
    'mergeThreshold', 0.85, ...
    'pruningThreshold', 1.5, ...
    'driftRate', 0.005);
bps.readData();
[X, Uw, priors, temporal, spatial] = bps.fit();
