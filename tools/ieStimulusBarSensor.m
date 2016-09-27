function iStim = ieStimulusBar(varargin)
% Creates a dynamic cone mosaic response to a moving bar stimulus
% 
% Inputs: a parameter structure that defines
%   * the bar stimulus properties
%   * cone mosaic properties
%   
%  Stimulus parameters:
%    display, barWidth, meanLuminance, nSteps,row, col, fov, 
%    startFrames   - Frames before stimulus (uniform, mean luminance)
%    stimFrames    - Number of stimulus frames
%    endFrames     - Frames after stimulus end (uniform, mean luminance)
%
%  Cone mosaic parameters:
%    os, expTime, eccentricity, angle, side
%
% Outputs: iStim is a structure that contains 
%   * display model
%   * original static bar scene
%   * optical image of the scene
%   * cone mosaic responses to the scene as the bar translates 
%      (no eye movements)
% 
% Example:
%   clear params; params.barWidth = 10; params.fov=1;
%   iStim = ieStimulusBar(params);
%   iStim.cMosaic.window;
%
%  Returns the same 
%   iStim = ieStimulusBar(iStim.params);
%   iStim.cMosaic.window;
%
% 3/2016 JRG (c) isetbio team

%% Parse inputs
p = inputParser;

% Stimulus parameters
addParameter(p,'display',   'LCD-Apple',@ischar);
addParameter(p,'barWidth',       5,     @isnumeric); % Pixels
addParameter(p,'meanLuminance',  200,   @isnumeric); % Cd/m2
addParameter(p,'row',            96,    @isnumeric);  
addParameter(p,'col',            96,    @isnumeric);  
addParameter(p,'fov',            0.6,   @isnumeric); % Deg 
addParameter(p,'startFrames',    60,    @isnumeric); % ms 
addParameter(p,'stimFrames',     inf,   @isnumeric); % determined by cols
addParameter(p,'endFrames',      30,    @isnumeric); % ms 

% OS and mosaic parameters
addParameter(p,'os',            'linear',@ischar);
addParameter(p,'radius',         0,  @isnumeric);  % Degrees?
addParameter(p,'theta',          0,  @isnumeric);  % Degrees?
addParameter(p,'side',           'left',  @ischar);% Left/right

p.parse(varargin{:});
params = p.Results;
fov = params.fov;
osType = p.Results.os;
startFrames = params.startFrames;
endFrames   = params.endFrames;

% We insist on turning off the wait bar
wFlag = ieSessionGet('wait bar');
ieSessionSet('wait bar',false);
%% Compute a Gabor patch scene as a placeholder for the bar image

% Create display
display = displayCreate(params.display);

% Set up scene, oi and sensor
scene = sceneCreate();
scene = sceneSet(scene, 'h fov', fov);
% vcAddObject(scene); sceneWindow;

%% Initialize the optics and the sensor
oi  = oiCreate('wvf human');

% compute cone packing density
fLength = oiGet(oi, 'focal length');
eccMM = 2 * tand(params.radius/2) * fLength * 1e3;
coneD = coneDensity(eccMM, [params.radius params.theta], params.side);
coneSz(1) = sqrt(1./coneD) * 1e-3;  % avg cone size with gap in meters
coneSz(2) = coneSz(1);

if strcmpi(osType, 'biophys');
    osCM = osBioPhys();            % peripheral (fast) cone dynamics
    osCM.set('noise flag',0);
%     osCM = osBioPhys('osType',true);  % foveal (slow) cone dynamics
    cm = coneMosaic('os',osCM);
    
elseif strcmpi(osType,'hex')    
    rng('default'); rng(219347);
    
    % Generate a hex mosaic with a medium resamplingFactor
    mosaicParams = struct(...
        'resamplingFactor', 9, ...                 % controls the accuracy of the hex mosaic grid
        'spatiallyVaryingConeDensity', false, ...  % whether to have an eccentricity based, spatially - varying density
        'centerInMM', [0.5 0.3], ...               % mosaic eccentricity
        'spatialDensity', [0 0.62 0.31 0.07],...
        'noiseFlag', false ...
        );
    cm = coneMosaicHex(...
        mosaicParams.resamplingFactor, ...
        mosaicParams.spatiallyVaryingConeDensity, ...
        'center', mosaicParams.centerInMM*1e-3, ...
        'spatialDensity', mosaicParams.spatialDensity, ...
        'noiseFlag', mosaicParams.noiseFlag ...
        );
    
    % Set the mosaic's FOV to a wide aspect ratio
    cm.setSizeToFOVForHexMosaic([0.9 0.6]);
else
    cm = coneMosaic;
end

% Set the cone aperture size
cm.pigment.width  = coneSz(1); 
cm.pigment.height = coneSz(2);

% Set cone mosaic field of view to match the scene
sceneFOV = [sceneGet(scene, 'h fov') sceneGet(scene, 'v fov')];
sceneDist = sceneGet(scene, 'distance');
cm.setSizeToFOV(sceneFOV, 'sceneDist', sceneDist, 'focalLength', fLength);

% Set the exposure time for each step
cm.integrationTime = cm.os.timeStep;

%% Compute a dynamic set of cone absorptions for moving bar
fprintf('Computing cone isomerizations:    \n');

% ieSessionSet('wait bar',true);
wbar = waitbar(0,'Stimulus movie');

% This is the mean oi that we use at the start and end
% barMovie = ones([sceneGet(scene, 'size'), 3])*0.005;  % Gray background
barMovie = ones([params.row, params.col, 3])*0.5;  % Gray background
scene    = sceneFromFile(barMovie, 'rgb', params.meanLuminance, display);
oiMean   = oiCompute(oi,scene);

absorptions = sensorCreate('human');

absorptions = sensorSetSizeToFOV(absorptions, params.fov, scene, oi);


sceneSize = sceneGet(scene,'size');
sensorSize = sensorGet(absorptions,'size');
aspectRatioMovie = sceneSize(1)/sceneSize(2);
absorptions = sensorSet(absorptions,'size',[aspectRatioMovie*sensorSize(2) sensorSize(2)]);

absorptions = sensorSet(absorptions, 'exp time', cm.os.timeStep); 
absorptions = sensorSet(absorptions, 'time interval', cm.os.timeStep); 

% nSteps = min(sceneGet(scene,'cols')+grayStart+grayEnd, params.nSteps);
stimFrames = (sceneGet(scene,'cols') - params.barWidth);
nSteps = startFrames + stimFrames + endFrames;

for t = 1 : nSteps
    waitbar(t/nSteps,wbar);

    if ~(t > startFrames && t < (startFrames + stimFrames + 1))
        % Use uniform field oi for time prior to and after stimulus
        oi = oiMean;
    else
        
        % Gray background
        barMovie = ones([sceneGet(scene, 'size'), 3])*0.5;  
        
        % Bar at this time
        colStart = t - startFrames + 1;
        colEnd   = colStart + params.barWidth - 1;
        % barMovie(:,t-startFrames + 1:(t-startFrames+1+params.barWidth-1),:) = 1;
        barMovie(:,colStart:colEnd,:) = 1;

        % Generate scene object from stimulus RGB matrix and display object
        scene = sceneFromFile(barMovie, 'rgb', params.meanLuminance, display);
        
        scene = sceneSet(scene, 'h fov', fov);
        if t ==1
            sceneRGB = zeros([sceneGet(scene, 'size'), nSteps, 3]);
            
            oi = oiCompute(oi, scene);
            absorptions = sensorComputeNoiseFree(absorptions, oi);
        end
        
        % Get scene RGB data
        sceneRGB(:,:,t,:) = sceneGet(scene,'rgb');
        
        % Compute optical image
        oi = oiCompute(oi, scene);
    end
    
    
    % Compute absorptions and photocurrent
%     cm.compute(oi, 'append', true, 'emPath', [0 0]);
    cm.compute(oi, 'append', true, 'currentFlag', false, 'emPath', [0 0]);
    
end

% Need to compute current after otherwise osAddNoise is wrong


if strcmpi(osType, 'biophys');
    osBParams.bgR = 10*mean(cm.absorptions(:)./cm.os.timeStep);
    cm.computeCurrent(osBParams);
else
    cm.computeCurrent();
end

delete(wbar);

% Restore
ieSessionSet('wait bar',wFlag);

% These are both the results and the data needed to run this
% script. So calling isomerizationBar(iStim.params) should produce the same
% results.
iStim.params  = params;
iStim.display = display;
iStim.scene   = scene;
iStim.sceneRGB = sceneRGB;
iStim.oi       = oi;
iStim.cMosaic  = cm;
iStim.absorptions   = absorptions;
end
