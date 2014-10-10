classdef BPSorter < BP
    
    properties %#ok<*PROP,*CPROP>
        Debug               % debug mode (true|false)
        TempDir             % temporary folder
        BlockSize           % size of blocks with constant waveform (sec)
        ArtifactBlockSize   % block size used for detecting noise artifacts (sec)
        ArtifactThresh      % threshold for artifact detection (SD of noise in muV)
        MaxSamples          % max number of samples to use
        HighPass            % highpass cutoff [stop, pass] (Hz)
        
        % properties used for initialization only
        InitChannelOrder    % channel ordering (x|y|xy|yx)
        InitNumChannels     % number of channels to group
        InitDetectThresh    % multiple of noise SD used for spike detection
        InitExtractWin      % window used for extracting waveforms
        InitNumPC           % number of PCs to keep per channel for sorting
        InitDropClusterThresh   % threshold for dropping clusters
        InitOverlapTime     % minimum distance between two spikes (ms)
        
        % parameters for initial spike sorting (see MoKsm)
        InitSortDf          % degrees of freedom
        InitSortClusterCost % penalty for adding cluster
        InitSortDriftRate   % drift rate for mean waveform (Kalman filter)
        InitSortTolerance   % convergence criterion
        InitSortCovRidge    % ridge on covariance matrices (regularization)
    end
    
    
    properties (SetAccess = private)
        matfile
        N
    end
    
    
    methods
        
        function self = BPSorter(layout, varargin)
            % Constructor for BPSorter class
            
            p = inputParser;
            p.KeepUnmatched = true;
            p.addOptional('Debug', false);
            p.addOptional('TempDir', fullfile(tempdir(), datestr(now(), 'BP_yyyymmdd_HHMMSS')));
            p.addOptional('BlockSize', 60);
            p.addOptional('ArtifactBlockSize', 0.25)
            p.addOptional('ArtifactThresh', 25)
            p.addOptional('MaxSamples', 2e7);
            p.addOptional('HighPass', [400 600]);
            p.addOptional('Fs', 12000);
            p.addOptional('InitChannelOrder', 'y');
            p.addOptional('InitNumChannels', 5);
            p.addOptional('InitDetectThresh', 5);
            p.addOptional('InitExtractWin', -8 : 19);
            p.addOptional('InitNumPC', 3);
            p.addOptional('InitDropClusterThresh', 0.6);
            p.addOptional('InitOverlapTime', 0.4);
            p.addOptional('InitSortDf', 5);
            p.addOptional('InitSortClusterCost', 0.002);
            p.addOptional('InitSortDriftRate', 400 / 3600 / 1000);
            p.addOptional('InitSortTolerance', 0.005);
            p.addOptional('InitSortCovRidge', 1.5);
            p.parse(varargin{:});
            
            assert(~isfield(p.Unmatched, 'dt'), 'Cannot set parameter dt. Use BlockSize instead!')
            self = self@BP(layout, p.Unmatched);
            
            par = fieldnames(p.Results);
            for i = 1 : numel(par)
                self.(par{i}) = p.Results.(par{i});
            end
            assert(rem(self.BlockSize / self.ArtifactBlockSize + 1e-5, 1) < 2e-5, ...
                'BlockSize must be multiple of ArtifactBlockSize!')

            if ~exist(self.TempDir, 'file')
                mkdir(self.TempDir)
            elseif ~self.Debug
                delete([self.TempDir '/*'])
            end
        end
        
        
        function delete(self)
            % Class destructor
            
            % remove temp directory unless in debug mode
            if ~self.Debug
                delete(fullfile(self.TempDir, '*'))
                rmdir(self.TempDir)
            end
        end
        
        
        function [X, U] = fit(self)
            % Fit model.
            
            % initialize on subset of the data using traditional spike
            % detection + sorting algorithm
            self.log(false, 'Initializing model using Mixture of Kalman filter model...\n')
            [V, X0] = self.initialize();
            
            % fit BP model on subset of the data
            self.log('Starting to fit BP model on subset of the data\n\n')
            
            % adjust dt and driftRate to account for the fact that we're
            % using only subsets of each block
            nBlocks = fix(self.N / (self.BlockSize * self.Fs));
            fraction = (size(V, 1) / nBlocks / self.Fs) / self.BlockSize;
            self.dt = self.BlockSize * fraction;
            self.driftRate = self.driftRate / fraction;
            
            % whiten data
            U = self.estimateWaveforms(V, X0);
            V = self.whitenData(V, self.residuals(V, X0, U));
            
            split = true;
            doneSplitMerge = false;
            priors = sum(X0 > 0, 1) / size(X0, 1);
            i = 0;
            iter = 1;
            M = 0;
            while i <= iter || ~doneSplitMerge
                
                % estimate waveforms
                Uw = self.estimateWaveforms(V, X);
                
                % merge templates that are too similar
                if ~doneSplitMerge
                    [Uw, priors, merged] = self.mergeTemplates(Uw, priors);
                end
                
                % stop merging when number of templates does not increase
                % compared to previous iteration
                if numel(priors) <= M || (~split && ~merged)
                    doneSplitMerge = true;
                else
                    M = numel(priors);
                end
                
                % prune waveforms and estimate spikes
                Uw = self.pruneWaveforms(Uw);
                [X, priors] = self.estimateSpikes(V, Uw, priors);
                
                % split templates with bimodal amplitude distribution
                if ~doneSplitMerge
                    [X, priors, split] = self.splitTemplates(X, priors);
                else
                    i = i + 1;
                end
                
                self.log('\n')
            end
            
            % Order templates spatially
            Uw = self.orderTemplates(Uw, X, priors, 'yx');
            
            % final run in chunks over entire dataset
            self.dt = self.BlockSize;
            self.driftRate = self.driftRate * fraction;
            [X, U] = self.bp.estimateByBlock(Uw, priors);
            
            % apply the same pruning as to whitened waveforms
            nnz = max(sum(abs(Uw), 1), [], 4) > 1e-6;
            U = bsxfun(@times, U, nnz);
            
            self.log('\n--\nDone fitting model [%.0fs]\n\n', (now - t) * 24 * 60 * 60)
        end
        
        
        function readData(self, br)
            % Read raw data, downsample and store in local temp file
            
            % create memory-mapped Matlab file
            dataFile = fullfile(self.TempDir, 'data.mat');
            self.matfile = matfile(dataFile, 'writable', true);
            if ~exist(dataFile, 'file')
                nBlocksWritten = 0;
                save(dataFile, '-v7.3', 'nBlocksWritten');
            else
                nBlocksWritten = self.matfile.nBlocksWritten;
                if isinf(nBlocksWritten) % file is already complete
                    fprintf('Using existing temp file: %s\n', dataFile)
                    return
                end
            end
            
            assert(self.K == getNbChannels(br), ...
                'Dataset and channel layout are incompatible: %d vs. %d channels!', ...
                getNbChannels(br), self.K)
            
            % read data, resample, and store to temp file
            raw.Fs = getSamplingRate(br);
            fr = filteredReader(br, filterFactory.createHighpass(self.HighPass(1), self.HighPass(2), raw.Fs));
            raw.blockSize = round(self.BlockSize * raw.Fs);
            raw.artifactBlockSize = round(self.ArtifactBlockSize * raw.Fs);
            nArtifactBlocks = length(fr) / raw.artifactBlockSize;
            nArtifactBlocksPerDataBlock = round(self.BlockSize / self.ArtifactBlockSize);
            raw.N = fix(nArtifactBlocks) * raw.artifactBlockSize;
            nBlocks = ceil(raw.N / raw.blockSize);
            pr = packetReader(fr, 1, 'stride', raw.blockSize);
            [p, q] = rat(self.Fs / raw.Fs);
            new.lastBlockSize = ceil((raw.N - (nBlocks - 1) * raw.blockSize) * p / q);
            new.blockSize = ceil(raw.blockSize * p / q);
            new.artifactBlockSize = round(self.ArtifactBlockSize * self.Fs);
            self.N = (nBlocks - 1) * new.blockSize + new.lastBlockSize;
            if ~nBlocksWritten
                h5create(dataFile, '/V', [self.N self.K], 'ChunkSize', [new.blockSize self.K]);
                h5create(dataFile, '/artifact', [nArtifactBlocks 1], 'DataType', 'uint8');
            end
            fprintf('Writing temporary file containing resampled data [%d blocks]\n%s\n', nBlocks, dataFile)
            for i = nBlocksWritten + 1 : nBlocks
                if ~rem(i, 10)
                    fprintf('%d ', i)
                end
                V = toMuV(br, resample(pr(i), p, q));
                if i == nBlocks
                    V = V(1 : new.lastBlockSize, :); % crop to multiple of artifact block size
                end
                
                % detect noise artifacts
                V = reshape(V, [new.artifactBlockSize, size(V, 1) / new.artifactBlockSize, self.K]);
                artifact = any(median(abs(V), 1) / 0.6745 > self.ArtifactThresh, 3);
                artifact = conv(double(artifact), ones(1, 3), 'same') > 0;
                sa = (i - 1) * nArtifactBlocksPerDataBlock;
                artifact(1) = artifact(1) || (i > 1 && self.matfile.artifact(sa, 1));
                V(:, artifact, :) = 0;
                V = reshape(V, [], self.K);
                
                % write to disk
                sb = (i - 1) * new.blockSize;
                self.matfile.V(sb + (1 : size(V, 1)), :) = V;
                if i > 1 && artifact(1)
                    self.matfile.V(sb + (-new.artifactBlockSize : 0), :) = 0;
                    self.matfile.artifact(sa, 1) = true;
                end
                self.matfile.artifact(sa + (1 : numel(artifact)), 1) = artifact(:);
                self.matfile.nBlocksWritten = i;
            end
            self.matfile.nBlocksWritten = inf;
            fprintf('done\n')
        end
        
        
        function [V, X] = initialize(self)
            % Initialize model
            
            % load subset of the data
            nskip = ceil(self.N / self.MaxSamples);
            if nskip == 1
                V = self.matfile.V; % load full dataset
            else
                blockSize = self.BlockSize * self.Fs;
                nBlocks = fix(self.N / blockSize);
                subBlockSize = round(blockSize / nskip);
                V = zeros(nBlocks * subBlockSize, size(self.matfile, 'V', 2));
                for i = 1 : nBlocks
                    idxFile = blockSize * (i - 1) + (1 : subBlockSize);
                    idxV = subBlockSize * (i - 1) + (1 : subBlockSize);
                    V(idxV, :) = self.matfile.V(idxFile, :);
                end
            end
            
            % Create channel groups
            channels = self.layout.channelOrder(self.InitChannelOrder);
            num = self.InitNumChannels;
            idx = bsxfun(@plus, 1 : num, (0 : numel(channels) - num)');
            groups = channels(idx);
            nGroups = size(groups, 1);
            
            % Spike sorter
            %   dt needs to be adjusted since we're skipping a fraction of the data
            %   drift rate is per ms, so it needs to be adjusted as well
            m = MoKsm('DTmu', self.BlockSize / nskip * 1000, ...
                'DriftRate', self.InitSortDriftRate * nskip, ...
                'ClusterCost', self.InitSortClusterCost, ...
                'Df', self.InitSortDf, ...
                'Tolerance', self.InitSortTolerance, ...
                'CovRidge', self.InitSortCovRidge);
            
            % detect and sort spikes in groups
            models(nGroups) = m;
            parfor i = 1 : nGroups
                Vi = V(:, groups(i, :));
                [t, w] = detectSpikes(Vi, self.Fs, self.InitDetectThresh, self.InitExtractWin);
                b = extractFeatures(w, self.InitNumPC);
                models(i) = m.fit(b, t);
            end
            
            % remove duplicate clusters that were created above because the
            % channel groups overlap
            X = self.removeDuplicateClusters(models, size(V, 1));
        end
        
        
        function N = get.N(self)
            if isempty(self.N)
                self.N = size(self.matfile, 'V', 1);
            end
            N = self.N;
        end
        
        
        function m = get.matfile(self)
            if isempty(self.matfile)
                error('Temporary data file not initialized. Run self.readData() first!')
            end
            m = self.matfile;
        end
        
    end
    
    
    methods (Access = private)
        
        function X = removeDuplicateClusters(self, models, N)
            % Remove duplicate clusters.
            %   X = self.keepMaxClusters(models, N) keeps only those
            %   clusters that have their largest waveform on the center
            %   channel. The models are assumed to be fitted to groups of K
            %   channels, with K-1 channels overlap between adjacent
            %   models. Duplicate spikes are removed, keeping the spike
            %   from the cluster with the larger waveform.
            
            % find all clusters having maximum energy on the center channel
            K = self.InitNumChannels;
            center = (K + 1) / 2;
            q = self.InitNumPC;
            nModels = numel(models);
            spikes = {};
            clusters = {};
            mag = [];
            for i = 1 : nModels
                model = models(i);
                a = model.cluster();
                [~, Ndt, M] = size(model.mu);
                for j = 1 : M;
                    nrm = sqrt(sum(sum(reshape(model.mu(:, :, j), [q K Ndt]), 1) .^ 2, 3));
                    [m, idx] = max(nrm);
                    if idx == center || (i == 1 && idx < center) || (i == nModels && idx > center)
                        spikes{end + 1} = round(model.t(a == j) * self.Fs / 1000); %#ok<AGROW>
                        clusters{end + 1} = repmat(numel(spikes), size(spikes{end})); %#ok<AGROW>
                        mag(end + 1) = m; %#ok<AGROW>
                    end
                end
            end
            M = numel(spikes);
            spikesPerCluster = cellfun(@numel, spikes);
            
            spikes = [spikes{:}];
            clusters = [clusters{:}];
            
            % order spikes in time
            [spikes, order] = sort(spikes);
            clusters = clusters(order);
            
            % remove smaller spikes from overlaps
            totalSpikes = numel(spikes);
            keep = true(totalSpikes, 1);
            prev = 1;
            refrac = self.InitOverlapTime * self.Fs / 1000;
            for i = 2 : totalSpikes
                if spikes(i) - spikes(prev) < refrac
                    if mag(clusters(i)) < mag(clusters(prev))
                        keep(i) = false;
                    else
                        keep(prev) = false;
                        prev = i;
                    end
                else
                    prev = i;
                end
            end
            spikes = spikes(keep);
            clusters = clusters(keep);
            
            % remove clusters that lost too many spikes to other clusters
            frac = hist(clusters, 1 : M) ./ spikesPerCluster;
            keep = true(numel(spikes), 1);
            for i = 1 : M
                if frac(i) < self.InitDropClusterThresh
                    keep(clusters == i) = false;
                end
            end
            spikes = spikes(keep);
            clusters = clusters(keep);
            [~, ~, clusters] = unique(clusters);
            
            % create spike matrix
            X = sparse(spikes, clusters, 1, N, max(clusters));
        end
        
    end
    
end