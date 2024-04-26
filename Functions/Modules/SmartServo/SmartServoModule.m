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

% SmartServoModule is a class to interface with the Bpod Smart Servo Module
% via its USB connection to the PC.
%
% User-configurable device parameters are exposed as class properties. Setting
% the value of a property will trigger its 'set' method to update the device.
%
% The Smart Servo Module has 3 channels, each of which control up to 8
% daisy-chained motors.
%
% Example usage:
%
% S = SmartServoModule('COM3'); % Create an instance of SmartServoModule,
%                               connecting to the Bpod Smart Servo Module on port COM3
%
% ---SmartServoInterface---
% myServo = S.newSmartServo(2, 1); % Create myServo, a SmartServoInterface object to control
%                                    the servo on channel 2 at address 1
% myServo.setPosition(90); % Move servo shaft to 90 degrees using default velocity and acceleration
% myServo.setPosition(0, 100, 200); % Return shaft to 0 degrees at 100RPM with 200RPM^2 acceleration
% myServo.setMode(4); % Set servo to continuous rotation mode with velocity control
% myServo.setVelocity(-10); % Start rotating clockwise at 10RPM
% myServo.setVelocity(0); % Stop rotating
% clear myServo; 
% 
% ---Motor Programs---
% prog1 = S.newProgram; % Create a new motor program
% prog1.addStep(prog1, 'Channel', 2,...             % Target motor channel (1-3)
%                      'Address', 1,...             % Target motor address (1-8)
%                      'GoalPosition', 90,...       % degrees
%                      'MaxVelocity', 100,...       % RPM
%                      'MaxAcceleration', 100,...   % rev/min^2
%                      'OnsetTime', 1.520);         % seconds after program start
% --Note: Add as many steps to prog1 as necessary with additional calls to addStep()
% S.loadProgram(2, prog1); % Load prog1 to the device at index 2
% S.runProgram(2); % Run program 2
%
% ---Motor Address Change---
% S.setMotorAddress(1, 2, 4); % Change a motor's address on channel 1 from
%                               2 to 4. This is a necessary step for
%                               setting up multiple daisy-chained motors
%                               per channel. The new address is stored in 
%                               the motor EEPROM and persists across power cycles.
% 
% clear S; % clear the objects from the workspace, releasing the USB serial port

classdef SmartServoModule < handle

    properties
        port % ArCOM Serial port
        firmwareVersion
        hardwareVersion
    end

    properties (Access = private)
        modelNumbers = [1200 1190 1090 1060 1070 1080 1220 1210 1240 1230 1160 1120 1130 1020 1030 ...
                        1100 1110 1010 1000]; % Numeric code for Dynamixel X-series models
        modelNames = {'XL330-M288', 'XL330-M077', '2XL430-W250', 'XL430-W250',...
                      'XC430-T150/W150', 'XC430-T240/W240', 'XC330-T288', 'XC330-T181',...
                      'XC330-M288', 'XC330-M181', '2XC430-W250', 'XM540-W270', 'XM540-W150',...
                      'XM430-W350', 'XM430-W210', 'XH540-W270', 'XH540-W150', 'XH430-W210', 'XH430-W350'};
        isActive = zeros(3, 253); % Indicates motors that have been initialized as SmartServoInterface objects
                                  % 0 = not active, 1 = active. See newSmartServo() below
        isConnected = zeros(3, 253); % Indicates whether a servo was detected at (channel, address)
                                     % 0 = not detected, 1 = detected
        detectedModelName = cell(3, 253); % Stores the model name for each detected motor
        opMenuByte = 212; % Byte code to access op menu via USB
        maxPrograms % Maximium number of motor programs that can be stored on the device
        maxSteps % Maximum number of steps per motor program
        programLoaded % Indicates whether programs are loaded
    end

    methods
        function obj = SmartServoModule(portString)
            % Constructor, called when a new SmartServoModule object is created

            % Open the USB Serial Port
            obj.port = ArCOMObject_Bpod(portString, 480000000);

            % Handshake
            obj.port.write([obj.opMenuByte 249], 'uint8'); % Handshake
            reply = obj.port.read(1, 'uint8');
            if reply ~= 250
                error(['Error connecting to smart servo module. The device at port ' portString... 
                       ' returned an incorrect handshake.'])
            end

            % Get module information
            obj.port.write([obj.opMenuByte '?'], 'uint8'); 
            obj.firmwareVersion = obj.port.read(1, 'uint32');
            obj.hardwareVersion = obj.port.read(1, 'uint32');
            obj.maxPrograms = double(obj.port.read(1, 'uint32'));
            obj.maxSteps = double(obj.port.read(1, 'uint32'));

            % Detect connected motors
            obj.detectMotors;
            obj.programLoaded = zeros(1, obj.maxPrograms);
        end

        function smartServo = newSmartServo(obj, channel, address)
            % Create a new smart servo object, addressing a single motor on the module
            % Arguments:
            % channel: The target motor's channel on the smart servo module (1-3)
            % address: The target motor's address on the target channel (1-8)
            %
            % Returns:
            % smartServo, an instance of SmartServoInterface.m connected addressing the target servo
                if obj.isConnected(channel, address)
                    smartServo = SmartServoInterface(obj.port, channel, address, obj.detectedModelName{channel, address});
                    obj.isActive(channel, address) = 1;
                else
                    error(['No motor registered on channel ' num2str(channel) ' at address ' num2str(address) '.' ...
                           char(10) 'If a new servo was recently connected, run detectMotors().'])
                end
        end

        function detectMotors(obj)
            % detectMotors() detects motors connected to the smart servo module.
            % detectMotors() is run on creating a new SmartServoModule object.
            % This function must be run manually after attaching a new motor.

            disp('Detecting motors...');
            obj.port.write([obj.opMenuByte 'D'], 'uint8');
            pause(2);
            nMotorsFound = floor(obj.port.bytesAvailable/6);
            detectedChannel = [];
            detectedAddress = [];
            for i = 1:nMotorsFound
                motorChannel = obj.port.read(1, 'uint8');
                motorAddress = obj.port.read(1, 'uint8');
                motorModel = obj.port.read(1, 'uint32');
                modelName = 'Unknown model';
                modelNamePos = find(motorModel == obj.modelNumbers);
                if ~isempty(modelNamePos)
                    modelName = obj.modelNames{modelNamePos};
                end
                obj.isConnected(motorChannel, motorAddress) = 1;
                obj.detectedModelName{motorChannel, motorAddress} = modelName;
                disp(['Found: Ch: ' num2str(motorChannel) ' Address: ' num2str(motorAddress) ' Model: ' modelName]);
                detectedChannel = [detectedChannel motorChannel];
                detectedAddress = [detectedAddress motorAddress];
            end
            
            % Set detected motors to default instruction mode
            for i = 1:nMotorsFound
                obj.port.write([obj.opMenuByte 'M' detectedChannel(i) detectedAddress(i) 1], 'uint8');
                confirmed = obj.port.read(1, 'uint8');
                if confirmed ~= 1
                    error('Error setting default mode. Confirm code not returned.');
                end
            end
        end

        function setMotorAddress(obj, motorChannel, currentAddress, newAddress)
            % setMotorAddress() sets a new motor address for a motor on a given channel, 
            % e.g. for daisy-chain configuration.
            % The new address is written to the motor's EEPROM, and will persist across power cycles.
            %
            % Arguments:
            % motorChannel: The target motor's channel on the smart servo module (integer in range 1-3)
            % currentAddress: The target motor's current address on the target channel (integer in range 1-8)
            % newAddress: The new address of the target motor
            %
            % Returns:
            % None
            
            if obj.isActive(motorChannel, currentAddress)
                error(['setMotorAddress() cannot be used if an object to control the target motor has ' ...
                       char(10) 'already been created with newSmartServo().'])
            end
            if ~obj.isConnected(motorChannel, currentAddress)
                error(['No motor registered on channel ' num2str(motorChannel) ' at address ' num2str(currentAddress) '.' ...
                           char(10) 'If a new servo was recently connected, run detectMotors().'])
            end
            % Sets the network address of a motor on a given channel
            obj.port.write([obj.opMenuByte 'I' motorChannel currentAddress newAddress], 'uint8');
            confirmed = obj.port.read(1, 'uint8');
            if isempty(confirmed)
                error('Error setting motor address. Confirm code not returned.');
            elseif confirmed == 0
                error('Error setting motor address. The target motor did not acknowledge the instruction.')
            end
            obj.isConnected(motorChannel, currentAddress) = 0;
            disp('Address changed.')
            obj.detectMotors;
        end

        function bytes = param2Bytes(obj, paramValue)
            % param2Bytes() is a convenience function for state machine control. Position,
            % velocity, acceleration, current and RPM values must be
            % converted to bytes for use with the state machine serial interface.
            % Arguments:
            % paramValue, the value of the parameter to convert (type = double or single)
            %
            % Returns:
            % bytes, a 1x4 vector of bytes (type = uint8)
            bytes = typecast(single(paramValue), 'uint8');
        end

        function program = newProgram(obj)
            % Returns a blank motor program for use with addMovement(), setLoopDuration()
            % setMoveType() and sendMotorProgram().
            % Arguments: None
            % Return: program, a struct containing a blank motor program
                program = struct;
                program.nSteps = 0;
                program.moveType = 0;
                program.loopDuration = 0;
                program.channel = zeros(1, obj.maxSteps);
                program.address = zeros(1, obj.maxSteps);
                program.goalPosition = zeros(1, obj.maxSteps);
                program.velocity = zeros(1, obj.maxSteps);
                program.acceleration = zeros(1, obj.maxSteps);
                program.maxCurrent = zeros(1, obj.maxSteps);
                program.stepTime = zeros(1, obj.maxSteps);
        end

        function program = addMovement(obj, program, varargin)
            % addMovement() adds a movement to an existing motor program.
            %
            % Arguments:
            % program: The program struct to be extended with a new step
            % channel: The target motor's channel on the Smart Stepper Module (integer in range 1-3)
            % address: The target motor's address on the target channel (integer in range 1-8)
            % goalPosition: The position the motor will move to on this step (units = degrees)
            % ***Pass only if program.moveType = 0:
            %          velocity: The maximum velocity of the movement (units = RPM).
            %               Use 0 for max velocity.
            %          acceleration: The maximum acceleration/deceleration of the movement start
            %               and end (units = rev/min^2). Use 0 for max acceleration
            % ***Pass only if program.moveType = 1:
            %          maxCurrent: The maximum current for the move (unit = % of max current)
            % ***
            % stepTime: The time when this step will begin with respect to motor
            %           program start (units = seconds)
            %
            % Variable arguments must be given as alternating string/value
            % pairs, e.g. ...'maxVelocity', 100... Strings are ignored, but required to make the 
            % function calls human-readable (see example in comments at the top of this file)
            %
            % Returns:
            % program, the original program struct modified with the added step

            % Extract args
            channel = varargin{2};
            address = varargin{4};
            goalPosition = varargin{6};
            if program.moveType == 0
                if nargin ~= 14
                    error('Incorrect number of arguments');
                end
                velocity = varargin{8};
                acceleration = varargin{10};
                stepTime = varargin{12};
            else
                if nargin ~= 12
                    error('Incorrect number of arguments');
                end
                maxCurrent = varargin{8};
                stepTime = varargin{10};
            end

            nSteps = program.nSteps + 1;
            program.nSteps = nSteps;
            program.channel(nSteps) = channel;
            program.address(nSteps) = address;
            program.goalPosition(nSteps) = goalPosition;
            if program.moveType == 0
                program.velocity(nSteps) = velocity;
                program.acceleration(nSteps) = acceleration;
            else
                program.maxCurrent(nSteps) = maxCurrent;
            end
            program.stepTime(nSteps) = stepTime;
        end

        function program = setLoopDuration(obj, program, loopDuration)
            % setLoopDuration() sets a duration for which to loop an existing motor program.
            % A looping program returns to time 0 each time it completes its sequence of steps, 
            % and continues looping the program until loopDuration seconds.
            %
            % Arguments:
            % program: The program struct to be modified with the new loop duration
            % loopDuration: The duration for which to loop the motor
            % program each time it is run (units = seconds)
            %
            % Returns:
            % program, the original program struct modified with the added step

            program.loopDuration = loopDuration;
        end

        function program = setMoveType(obj, program, moveType)
            % setMoveType sets the type of move contained in the program.
            %
            % Arguments:
            % moveType, the type of move contained in the program. moveType must be either:
            % 0 = moves defined by goal position, max velocity and max acceleration
            % 1 = moves defined by goal position and max current (torque)
            if ~(moveType == 0 || moveType == 1)
                error('moveType must be either 0 or 1')
            end
            if program.nSteps > 0
                error('moveType must be set before steps are added to a program')
            end
            program.moveType = moveType;
        end

        function loadProgram(obj, programIndex, program)
            % loadProgram() loads a motor program to the Smart Servo Module's memory.
            % The Smart Servo Module can store up to 100 programs of up to 256 steps each.
            %
            % Arguments:
            % programIndex: The program's index on the device (integer in range 0-99)
            % program: The program struct to load to the device at position programIndex

            nSteps = program.nSteps;
            moveType = program.moveType;
            channel = program.channel(1:nSteps);
            address = program.address(1:nSteps);
            goalPosition = program.goalPosition(1:nSteps);
            velocity = program.velocity(1:nSteps);
            acceleration = program.acceleration(1:nSteps);
            maxCurrent = program.maxCurrent(1:nSteps);
            stepTime = program.stepTime(1:nSteps)*10000;
            loopDuration = program.loopDuration*10000;

            % If necessary, sort moves by timestamps
            if sum(diff(stepTime) < 0) > 0 % If any timestamps are out of order
                [~, sIndexes] = sort(stepTime);
                channel = channel(sIndexes);
                address = address(sIndexes);
                goalPosition = goalPosition(sIndexes);
                velocity = velocity(sIndexes);
                acceleration = acceleration(sIndexes);
                maxCurrent = maxCurrent(sIndexes);
                stepTime = stepTime(sIndexes);
            end
            if moveType == 0
                current_or_velocity = velocity;
            else
                current_or_velocity = maxCurrent;
            end

            % Convert the program to a byte string
            programBytes = [obj.opMenuByte 'L' programIndex moveType nSteps...
                            typecast(uint32(loopDuration), 'uint8')...
                            uint8(channel) uint8(address)...
                            typecast(single(goalPosition), 'uint8')...
                            typecast(single(current_or_velocity), 'uint8')...
                            typecast(single(acceleration), 'uint8')...
                            typecast(uint32(stepTime), 'uint8')];

            % Send the program and read confirmation
            obj.port.write(programBytes, 'uint8');
            confirmed = obj.port.read(1, 'uint8');
            if confirmed ~= 1
                error('Error loading motor program. Confirm code not returned.');
            end
            obj.programLoaded(programIndex) = 1;
        end

        function runProgram(obj, programIndex)
            % runProgram() runs a previously loaded motor program. Programs
            % can also be run directly from the state machine with the 'R'
            % command (see 'Serial Interfaces' section on the Bpod wiki)
            % 
            % Arguments: 
            % programIndex: The index of the program to run (integer, range = 0-99)
            if obj.programLoaded(programIndex) == 0
                error(['Cannot run motor program ' num2str(programIndex)... 
                       '. It must be loaded to the device first.'])
            end
            obj.port.write([obj.opMenuByte 'R' programIndex], 'uint8');
        end


        function delete(obj)
            % Class destructor, called when the SmartServoModule is cleared
            obj.port = []; % Trigger the ArCOM port's destructor function (closes and releases port)
        end

    end
end