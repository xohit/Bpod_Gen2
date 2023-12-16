%{
----------------------------------------------------------------------------

This file is part of the Sanworks Bpod repository
Copyright (C) Sanworks LLC, Rochester, New York, USA

----------------------------------------------------------------------------

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, version 3.

This program is distributed  WITHOUT ANY WARRANTY and without even the 
implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  
See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.
%}

% Usage Notes:
% Required: Bpod HiFi Module, manual sound level meter
%
% Parameters:
% FreqRange:     a 2-element vector specifying the range of frequencies to calibrate in Hz, e.g. [1000 20000] for 1kHz to 20kHz
% nMeasurements: the number of separate pure tone frequencies to measure within FreqRange. These will be log-spaced.
% dbSPL_Target:  the target sound level for each frequency in dB SPL
% nSpeakers:     1 for mono and 2 for stereo
% digitalAtt_dB: a Bpod HiFi module parameter specifying digital attenuation. Units = dB FS. 0 = no attenuation, -120 = max attenuation
%                Usage Note: Attenuating will reduce the amount your waveform has to be compressed within the DAC bit range to achieve 
%                the target dB SPL. Choose the digitalAtt_dB that results in the largest possible attenuation factors in your system, 
%                or (even better) set digitalAtt_dB to 0 and attenuate with the audio amplifier volume control.
%                Computed attenuation factors for the supplied digitalAtt_dB are visible in SoundCal, the output of this function.
%                IMPORTANT: your protocol must use the same digital attenuation as used for calibration! 
%                           Set in your protocol .m file with H.DigitalAttenuation_dB = value.
%
% Returns:
% SoundCal: a struct contining Bpod sound calibration data, stored by default in /Bpod_Local/Calibration Files/Sound Calibration/
%
% Example:
% SoundCal = SoundCalibration_Manual([1000 80000], 10, 60, 2, 0); % Measure attenuation factors for 10
% frequencies between 1khz and 80kHz such that a full scale tone * attenuation factor --> 60dB with no digital attenuation. 
% Return a best-fit polynomial function for interpolation.
%
% Once SoundCal is returned, calibrated pure tones can be generated with CalibratedPureTone().
% A sample-wise attentuation envelope for pure frequency sweep waveforms can be calculated
% with toneAtt = polyval(SoundCal(1,s).Coefficient,freqvec) where freqvec contains the instantaneous frequency at each sample.

function SoundCal = SoundCalibration_Manual(FreqRange, nMeasurements, dbSPL_Target, nSpeakers, digitalAtt_dB)

global BpodSystem
%% Resolve HiFi Module USB port
if (isfield(BpodSystem.ModuleUSB, 'HiFi1'))
    %% Create an instance of the HiFi module
    H = BpodHiFi(BpodSystem.ModuleUSB.HiFi1);
else
    error('Error: To run this protocol, you must first pair the HiFi module with its USB port. Click the USB config button on the Bpod console.')
end
% Params
H.DigitalAttenuation_dB = digitalAtt_dB;
H.SamplingRate = 192000;
H.AMenvelope = 1/192:1/192:1;
FreqRangeError = 0;
nTriesPerFrequency = 7;
toneDuration = 5; % Seconds
AcceptableDifference_dBSPL = 0.5;

% Sanitize inputs
if (length(FreqRange) ~= 2) || (sum(FreqRange < 20) > 0) || (sum(FreqRange > 100000) > 0)
    FreqRangeError = 1;
elseif FreqRange(1) > FreqRange(2)
    FreqRangeError = 1;
end
if (dbSPL_Target < 10) || (dbSPL_Target > 120)
    error('Error: target dB SPL must be in range [10, 120]')
end
if nSpeakers > 2
    error('Error: this function can calibrate 1 or 2 speakers.')
end
if FreqRangeError
    error('Error: Frequency range must be a two element vector specifying the range of frequencies to calibrate')
end

% Setup sound cal struct
SoundCal = struct;
for i = 1:nSpeakers
    SoundCal(i).Table = [];
    SoundCal(i).CalibrationTargetRange = FreqRange;
    SoundCal(i).TargetSPL = dbSPL_Target;
    SoundCal(i).LastDateModified = date;
    SoundCal(i).Coefficient = [];
end

% Calibraiton main loop
MinFreq = FreqRange(1);
MaxFreq = FreqRange(2);
FrequencyVector =  logspace(log10(MinFreq),log10(MaxFreq),nMeasurements);
SpeakerNames = {'Left', 'Right'};
for s = 1:nSpeakers
    ThisTable = zeros(nMeasurements, 2);
    disp([char(10) 'Begin calibrating ' SpeakerNames{s} ' speaker.'])
    for m = 1:nMeasurements
        attFactor = 0.2;
        found = 0;
        nTries = 0;
        while found == 0
            nTries = nTries + 1;
            if nTries > nTriesPerFrequency
                error(['Error: Could not resolve an attenuation factor for ' num2str(FrequencyVector(m))])
            end
            input(['Press Enter to play the next tone. This tone = ' num2str(FrequencyVector(m)) ' Hz, ' num2str(attFactor) ' FS amplitude.'], 's'); 
            Wave = GenerateSineWave(192000, FrequencyVector(m), toneDuration)*attFactor;
            if s == 1
                H.load(1, [Wave; zeros(1,length(Wave))]); H.push; pause(.1);
            else
                H.load(1, [zeros(1,length(Wave)); Wave]); H.push; pause(.1);
            end
            
            H.play(1);
            pause(toneDuration);
            dbSPL_Measured = input(['Enter dB SPL measured > ']);
            if abs(dbSPL_Measured - dbSPL_Target) <= AcceptableDifference_dBSPL
                ThisTable(m,1) = FrequencyVector(m);
                ThisTable(m,2) = attFactor;
                found = 1;
            else
                AmpFactor = sqrt(10^((dbSPL_Measured - dbSPL_Target)/10));
                attFactor = attFactor/AmpFactor;
                if attFactor > 1
                    attFactor = 1;
                end
            end
        end
    end
    SoundCal(s).Table = ThisTable;
    SoundCal(s).Coefficient = polyfit(ThisTable(:,1)',ThisTable(:,2)',1);
end
SoundCal.DigitalAttenuation_dB = digitalAtt_dB;