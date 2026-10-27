function ofdm_pager(mode)
% Launch a transmitter or an automatically listening receiver.
if nargin < 1
    mode = "rx";
end
mode = lower(string(mode));
if ~ismember(mode, ["tx", "rx"])
    error("ofdm_pager:InvalidMode", "Mode must be 'tx' or 'rx'.");
end
cfg = ofdm_pager_core("config");
if exist("audioDeviceReader", "class") ~= 8 || exist("audioDeviceWriter", "class") ~= 8
    error("ofdm_pager:AudioToolboxRequired", ...
        "Audio Toolbox is required for real-time audio. Install it and restart MATLAB.");
end
if ~license("test", "Distrib_Computing_Toolbox")
    error("ofdm_pager:ParallelComputingToolboxRequired", ...
        "Parallel Computing Toolbox is required for stable background decoding.");
end
readerProbe = audioDeviceReader;
rxDevices = getAudioDevices(readerProbe);
release(readerProbe);
writerProbe = audioDeviceWriter;
txDevices = getAudioDevices(writerProbe);
release(writerProbe);

fig = uifigure("Name", "OFDM QPSK Audio Pager", ...
    "Position", [100 100 720 560], "CloseRequestFcn", @closeApp);
tabs = uitabgroup(fig, "Position", [10 10 700 540]);
txTab = uitab(tabs, "Title", "Truyền");
rxTab = uitab(tabs, "Title", "Nhận");
if mode == "tx"
    tabs.SelectedTab = txTab;
else
    tabs.SelectedTab = rxTab;
end

uilabel(txTab, "Position", [20 490 650 24], ...
    "Text", "OFDM QPSK | Fs 96 kHz | FFT 1024 | 64 sóng mang | 30-36 kHz");
uilabel(txTab, "Position", [20 450 650 22], ...
    "Text", "Thiết bị phát:");
txDevice = uidropdown(txTab, "Items", txDevices, "Position", [20 420 660 28]);
uilabel(txTab, "Position", [20 380 650 22], ...
    "Text", "Nội dung tin nhắn (tự chia gói và ghép lại ở máy nhận):");
txMessage = uitextarea(txTab, "Position", [20 165 660 205], ...
    "Value", {'Xin chao!'});
uilabel(txTab, "Position", [20 125 120 22], "Text", "Số lần lặp:");
repeatCount = uieditfield(txTab, "numeric", "Position", [130 120 80 28], ...
    "Limits", [1 20], "RoundFractionalValues", "on", "Value", 8);
uilabel(txTab, "Position", [240 125 90 22], "Text", "Mức phát:");
txLevel = uieditfield(txTab, "numeric", "Position", [330 120 80 28], ...
    "Limits", [0.01 0.75], "Value", 0.3);
sendButton = uibutton(txTab, "push", "Text", "Gửi tin", ...
    "Position", [20 55 130 42], "ButtonPushedFcn", @sendMessage);
txStatus = uilabel(txTab, "Position", [170 55 510 42], ...
    "Text", "Khung cố định, lặp QPSK/bit và CRC-16; chọn thiết bị đúng.");

uilabel(rxTab, "Position", [20 490 650 24], ...
    "Text", "Thiết bị thu (chọn loopback/line-in nếu nối hữu tuyến):");
rxDevice = uidropdown(rxTab, "Items", rxDevices, "Position", [20 458 660 28], ...
    "ValueChangedFcn", @receiverDeviceChanged);
startButton = uibutton(rxTab, "push", "Text", "Nhận tự động / Bắt đầu lại", ...
    "Position", [20 402 140 38], "ButtonPushedFcn", @startReceiver);
stopButton = uibutton(rxTab, "push", "Text", "Dừng nhận", ...
    "Position", [175 402 120 38], "Enable", "off", ...
    "ButtonPushedFcn", @stopReceiver);
startButton.Position = [20 402 175 38];
rxStatus = uilabel(rxTab, "Position", [20 365 660 24], ...
    "Text", "Chờ bắt đầu thu.");
uilabel(rxTab, "Position", [20 330 650 22], "Text", "Tin nhắn nhận được:");
rxMessage = uitextarea(rxTab, "Position", [20 70 660 255], ...
    "Editable", "off", "Value", {''});
uilabel(rxTab, "Position", [20 28 660 24], ...
    "Text", "RX tự chạy khi mở ứng dụng. Tin dài tự ghép theo số thứ tự và CRC.");

reader = [];
rxTimer = [];
ring = complex(zeros(cfg.RingSampleCount, 1));
ringWrite = 1;
ringCount = 0;
sampleCount = 0;
filterState = zeros(numel(ofdm_pager_core("filtercoeff")) - 1, 1);
filterCoefficients = ofdm_pager_core("filtercoeff");
decodeCountdown = 0;
decodeFuture = [];
assemblies = struct("MessageId", {}, "ChunkCount", {}, "TotalLength", {}, ...
    "MessageCrc", {}, "Chunks", {}, "Received", {}, "ReceivedCount", {}, ...
    "LastUpdate", {});
completedMessages = {};
completedMessageIds = zeros(0, 1);
drawnow;
if mode == "rx"
    startReceiver([], []);
end

    function sendMessage(~, ~)
        try
            message = strjoin(string(txMessage.Value), newline);
            packets = encodeMessagePackets(message);
            deviceName = txDevice.Value;
            if strcmp(deviceName, "Default")
                writer = audioDeviceWriter("SampleRate", cfg.SampleRate);
            else
                writer = audioDeviceWriter("SampleRate", cfg.SampleRate, "Device", deviceName);
            end
            writerCleanup = onCleanup(@() release(writer));
            sendButton.Enable = "off";
            txStatus.Text = "Đang phát...";
            drawnow limitrate;
            blockLength = cfg.AudioBlockLength;
            silence = zeros(blockLength, 1);
            writeSilence(ceil(0.15 * cfg.SampleRate / blockLength), writer, silence);
            repetitionCount = round(repeatCount.Value);
            for frameIndex = 1:numel(packets)
                waveform = txLevel.Value * ...
                    ofdm_pager_core("modulatebytes", packets{frameIndex});
                txStatus.Text = sprintf("Đang gửi gói %d/%d (%d lần lặp)...", ...
                    frameIndex, numel(packets), repetitionCount);
                drawnow limitrate;
                for repetition = 1:repetitionCount
                    for first = 1:blockLength:numel(waveform)
                        last = min(first + blockLength - 1, numel(waveform));
                        block = zeros(blockLength, 1);
                        block(1:last - first + 1) = waveform(first:last);
                        writer(block);
                    end
                    writeSilence(ceil(0.10 * cfg.SampleRate / blockLength), ...
                        writer, silence);
                end
            end
            txStatus.Text = sprintf("Đã gửi hoàn tất: %d gói, mỗi gói lặp %d lần.", ...
                numel(packets), repetitionCount);
        catch exception
            txStatus.Text = "Lỗi phát âm thanh.";
            uialert(fig, exception.message, "Không thể phát");
        end
        sendButton.Enable = "on";
    end

    function startReceiver(~, ~)
        try
            if ~isempty(rxTimer) && isvalid(rxTimer)
                stop(rxTimer);
                delete(rxTimer);
                rxTimer = [];
            end
            startButton.Enable = "off";
            rxStatus.Text = "Khởi động bộ thu âm thanh...";
            drawnow limitrate;
            warmupFuture = parfeval(backgroundPool, @() true, 1);
            fetchOutputs(warmupFuture);
            deviceName = rxDevice.Value;
            if strcmp(deviceName, "Default")
                reader = audioDeviceReader("SampleRate", cfg.SampleRate, ...
                    "SamplesPerFrame", cfg.AudioBlockLength, "NumChannels", 1);
            else
                reader = audioDeviceReader("SampleRate", cfg.SampleRate, ...
                    "SamplesPerFrame", cfg.AudioBlockLength, "NumChannels", 1, ...
                    "Device", deviceName);
            end

            ring(:) = 0;
            ringWrite = 1;
            ringCount = 0;
            sampleCount = 0;
            filterState(:) = 0;
            decodeCountdown = 0;
            decodeFuture = [];
            assemblies = struct("MessageId", {}, "ChunkCount", {}, "TotalLength", {}, ...
                "MessageCrc", {}, "Chunks", {}, "Received", {}, "ReceivedCount", {}, ...
                "LastUpdate", {});
            completedMessages = {};
            completedMessageIds = zeros(0, 1);
            rxTimer = timer("ExecutionMode", "fixedSpacing", ...
                "Period", cfg.AudioBlockLength / cfg.SampleRate, ...
                "BusyMode", "drop", "TimerFcn", @receiveTick);
            start(rxTimer);
            startButton.Enable = "off";
            stopButton.Enable = "on";
            rxStatus.Text = "Đang thu; hãy phát bằng tab Truyền hoặc máy khác.";
        catch exception
            releaseReader();
            startButton.Enable = "on";
            rxStatus.Text = "Không khởi động được bộ thu.";
            uialert(fig, exception.message, "Không thể bắt đầu thu");
        end
    end

    function receiverDeviceChanged(~, ~)
        if ~isempty(reader)
            stopReceiver([], []);
            startReceiver([], []);
        end
    end

    function receiveTick(~, ~)
        try
            input = reader();
            input = mean(double(input), 2);
            sampleIndex = sampleCount + (0:numel(input) - 1).';
            mixed = 2 * input .* exp(-1j * 2 * pi * cfg.CenterFrequency * ...
                sampleIndex / cfg.SampleRate);
            [baseband, filterState] = filter(filterCoefficients, 1, mixed, filterState);
            sampleCount = sampleCount + numel(input);
            [ring, ringWrite, ringCount] = pushRing(ring, ringWrite, ringCount, baseband);
            if ~isempty(decodeFuture) && strcmp(decodeFuture.State, "finished")
                [packet, info] = fetchOutputs(decodeFuture);
                decodeFuture = [];
                if ~isempty(packet)
                    acceptMessageChunk(packet);
                elseif ~info.FoundPreamble
                    levelSamples = linearizeRing(ring, ringWrite, ringCount);
                    levelDbfs = 20 * log10(sqrt(mean(abs(levelSamples).^2)) + eps);
                    peakDbfs = 20 * log10(max(abs(levelSamples)) + eps);
                    rxStatus.Text = sprintf( ...
                        "Tìm khung 30-36 kHz | RMS %.1f, peak %.1f dBFS | %.1f ks", ...
                        levelDbfs, peakDbfs, sampleCount / 1000);
                else
                    rxStatus.Text = sprintf( ...
                        "Đã đồng bộ (%.2f), lệch %.1f Hz; chờ khung lặp/CRC", ...
                        info.Correlation, info.CFOHz);
                end
            end
            decodeCountdown = decodeCountdown + numel(input);
            if isempty(decodeFuture) && decodeCountdown >= 6 * cfg.AudioBlockLength && ...
                    ringCount >= cfg.FrameSampleCount
                decodeCountdown = 0;
                samples = linearizeRing(ring, ringWrite, ringCount);
                decodeFuture = parfeval(backgroundPool, @ofdm_pager_core, 2, ...
                    "decodepacket", samples);
            end
        catch exception
            if ~isempty(rxTimer) && isvalid(rxTimer)
                stop(rxTimer);
                rxTimer.TimerFcn = [];
            end
            releaseReader();
            startButton.Enable = "on";
            stopButton.Enable = "off";
            rxStatus.Text = "Lỗi thu âm thanh: " + string(exception.message);
            uialert(fig, exception.message, "Lỗi thu âm thanh");
        end
    end

    function stopReceiver(~, ~)
        if ~isempty(rxTimer) && isvalid(rxTimer)
            stop(rxTimer);
            delete(rxTimer);
            rxTimer = [];
        end
        if ~isempty(decodeFuture)
            cancel(decodeFuture);
            decodeFuture = [];
        end
        releaseReader();
        startButton.Enable = "on";
        stopButton.Enable = "off";
        rxStatus.Text = "Đã dừng thu.";
    end

    function releaseReader()
        if ~isempty(reader)
            release(reader);
            reader = [];
        end
    end

    function closeApp(~, ~)
        stopReceiver([], []);
        delete(fig);
    end

    function acceptMessageChunk(packet)
        header = ofdm_pager_core("parsechunk", packet);
        if ~header.Valid
            return;
        end
        messageId = header.MessageId;
        if any(completedMessageIds == messageId)
            return;
        end
        chunkIndex = header.ChunkIndex;
        chunkCount = header.ChunkCount;
        totalLength = header.TotalLength;
        messageCrc = header.MessageCrc;
        chunk = header.Data;
        expireBefore = datetime("now") - minutes(2);
        if ~isempty(assemblies)
            assemblies = assemblies([assemblies.LastUpdate] >= expireBefore);
        end
        assemblyIndex = find([assemblies.MessageId] == messageId, 1);
        if isempty(assemblyIndex)
            if numel(assemblies) >= 8
                [~, oldest] = min([assemblies.LastUpdate]);
                assemblies(oldest) = [];
            end
            entry = struct("MessageId", messageId, "ChunkCount", chunkCount, ...
                "TotalLength", totalLength, "MessageCrc", messageCrc, ...
                "Chunks", {cell(1, chunkCount)}, "Received", false(1, chunkCount), ...
                "ReceivedCount", 0,                 "LastUpdate", datetime("now"));
            assemblies(end + 1) = entry;
            assemblyIndex = numel(assemblies);
        end
        entry = assemblies(assemblyIndex);
        if entry.ChunkCount ~= chunkCount || entry.TotalLength ~= totalLength || ...
                entry.MessageCrc ~= messageCrc
            assemblies(assemblyIndex) = [];
            return;
        end
        entry.LastUpdate = datetime("now");
        if ~entry.Received(chunkIndex)
            entry.Chunks{chunkIndex} = chunk;
            entry.Received(chunkIndex) = true;
            entry.ReceivedCount = entry.ReceivedCount + 1;
        end
        assemblies(assemblyIndex) = entry;
        rxStatus.Text = sprintf("Đang ghép tin %u: gói %d/%d", ...
            messageId, entry.ReceivedCount, entry.ChunkCount);
        if entry.ReceivedCount ~= entry.ChunkCount
            return;
        end
        messageBytes = [entry.Chunks{:}];
        assemblies(assemblyIndex) = [];
        if numel(messageBytes) ~= totalLength || ...
                ofdm_pager_core("crc16", messageBytes) ~= messageCrc
            rxStatus.Text = "Lỗi CRC toàn tin; vui lòng phát lại tin nhắn.";
            return;
        end
        decodedMessage = string(native2unicode(messageBytes, "UTF-8"));
        completedMessages{end + 1} = char(decodedMessage);
        completedMessageIds(end + 1, 1) = messageId;
        if numel(completedMessageIds) > 64
            completedMessageIds(1) = [];
        end
        if numel(completedMessages) > 50
            completedMessages(1) = [];
        end
        rxMessage.Value = completedMessages(:);
        rxStatus.Text = sprintf("Đã ghép tin hoàn chỉnh (%d byte, %d gói).", ...
            totalLength, chunkCount);
    end
end

function packets = encodeMessagePackets(message)
persistent nextMessageId
if isempty(nextMessageId)
    nextMessageId = uint32(mod(floor(posixtime(datetime("now")) * 1000), 2^32));
end
nextMessageId = uint32(mod(double(nextMessageId) + 1, 2^32));
[packets, ~] = ofdm_pager_core("packetize", message, nextMessageId);
end

function writeSilence(blockCount, writer, block)
for index = 1:blockCount
    writer(block);
end
end

function [ring, writeIndex, count] = pushRing(ring, writeIndex, count, input)
input = input(:);
capacity = numel(ring);
inputCount = numel(input);
if inputCount >= capacity
    writeIndex = mod(writeIndex + inputCount - 1, capacity) + 1;
    first = writeIndex;
    indices = mod((first - 1:first + capacity - 2), capacity) + 1;
    ring(indices) = input(end - capacity + 1:end);
    count = capacity;
    return;
end
last = writeIndex + inputCount - 1;
if last <= capacity
    ring(writeIndex:last) = input;
else
    firstPartCount = capacity - writeIndex + 1;
    ring(writeIndex:end) = input(1:firstPartCount);
    ring(1:last - capacity) = input(firstPartCount + 1:end);
end
writeIndex = mod(last, capacity) + 1;
count = min(capacity, count + inputCount);
end

function output = linearizeRing(ring, writeIndex, count)
first = mod(writeIndex - count - 1, numel(ring)) + 1;
indices = mod((first - 1:first + count - 2), numel(ring)) + 1;
output = ring(indices);
end
