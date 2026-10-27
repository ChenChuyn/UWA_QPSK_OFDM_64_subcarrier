function varargout = ofdm_pager_core(action, varargin)
% OFDM pager modem core. Requires MATLAB base functionality only.

switch lower(action)
    case "config"
        varargout{1} = modemConfig();
    case "modulate"
        varargout{1} = modulateMessage(varargin{1});
    case "modulatebytes"
        varargout{1} = modulatePayload(varargin{1});
    case "filtercoeff"
        varargout{1} = lowpassCoefficients();
    case "decodebaseband"
        [varargout{1:nargout}] = decodeBaseband(varargin{1});
    case "decodepacket"
        [varargout{1:nargout}] = decodePacket(varargin{1});
    case "crc16"
        varargout{1} = crc16(varargin{1});
    case "packetize"
        [varargout{1:nargout}] = packetizeMessage(varargin{:});
    case "parsechunk"
        varargout{1} = parseMessageChunk(varargin{1});
    otherwise
        error("ofdm_pager_core:UnknownAction", "Unknown modem action: %s", action);
end
end

function cfg = modemConfig()
cfg.SampleRate = 96000;
cfg.CenterFrequency = 33000;
cfg.FFTLength = 1024;
cfg.CyclicPrefixLength = 128;
cfg.ActiveOffsets = [-32:-1, 1:32].';
cfg.ActiveBins = mod(cfg.ActiveOffsets, cfg.FFTLength) + 1;
cfg.ActiveCarrierCount = numel(cfg.ActiveOffsets);
cfg.PilotIndices = (1:4:cfg.ActiveCarrierCount).';
cfg.DataIndices = setdiff((1:cfg.ActiveCarrierCount).', cfg.PilotIndices, "stable");
cfg.PilotCount = numel(cfg.PilotIndices);
cfg.DataCarrierCount = numel(cfg.DataIndices);
cfg.DataSymbolCount = 14;
cfg.PreambleSymbolCount = 2;
cfg.TrainingSymbolCount = 1;
cfg.SymbolLength = cfg.FFTLength + cfg.CyclicPrefixLength;
cfg.FrameSymbolCount = cfg.PreambleSymbolCount + cfg.TrainingSymbolCount + cfg.DataSymbolCount;
cfg.FrameSampleCount = cfg.SymbolLength * cfg.FrameSymbolCount;
cfg.MaxPayloadBytes = floor(cfg.DataCarrierCount * 2 * cfg.DataSymbolCount / 16) - 4;
cfg.AudioBlockLength = 7680;
cfg.RingSampleCount = cfg.FrameSampleCount * 4;
preambleIndex = (0:cfg.ActiveCarrierCount - 1).';
cfg.Preamble = exp(-1j * pi * 5 * preambleIndex .^ 2 / cfg.ActiveCarrierCount);
end

function waveform = modulateMessage(message)
message = reshape(char(message), 1, []);
payload = unicode2native(message, "UTF-8");
waveform = modulatePayload(uint8(payload(:).'));
end

function waveform = modulatePayload(payload)
cfg = modemConfig();
payload = uint8(payload(:).');
if isempty(payload)
    error("ofdm_pager_core:EmptyPayload", "Frame payload cannot be empty.");
end
if numel(payload) > cfg.MaxPayloadBytes
    error("ofdm_pager_core:MessageTooLong", ...
        "Frame payload is %d bytes; the fixed frame supports at most %d.", ...
        numel(payload), cfg.MaxPayloadBytes);
end

packet = [uint8(floor(numel(payload) / 256)), uint8(mod(numel(payload), 256)), payload];
crc = crc16(packet);
packet = [packet, uint8(floor(double(crc) / 256)), uint8(mod(double(crc), 256))];
bits = bytesToBits(packet);
capacity = cfg.DataCarrierCount * 2 * cfg.DataSymbolCount;
rawCapacity = capacity / 2;
bits(end + 1:rawCapacity, 1) = 0;
rawBitPairs = reshape(bits, 2, []);
bitPairs = repelem(rawBitPairs, 1, 2);
dataSymbols = (1 - 2 * double(bitPairs(1, :))) + ...
    1j * (1 - 2 * double(bitPairs(2, :)));
dataSymbols = dataSymbols / sqrt(2);
dataSymbols = reshape(dataSymbols, cfg.DataCarrierCount, cfg.DataSymbolCount);

symbols = complex(zeros(cfg.FFTLength, cfg.FrameSymbolCount));
symbols(cfg.ActiveBins, 1:cfg.PreambleSymbolCount) = ...
    repmat(cfg.Preamble, 1, cfg.PreambleSymbolCount);
trainingColumn = cfg.PreambleSymbolCount + 1;
dataColumnStart = trainingColumn + 1;
symbols(cfg.ActiveBins, trainingColumn) = 1;
for symbolIndex = 1:cfg.DataSymbolCount
    activeValues = complex(zeros(cfg.ActiveCarrierCount, 1));
    activeValues(cfg.PilotIndices) = pilotValues(symbolIndex, cfg.PilotCount);
    activeValues(cfg.DataIndices) = dataSymbols(:, symbolIndex);
    symbols(cfg.ActiveBins, symbolIndex + dataColumnStart - 1) = activeValues;
end

timeSymbols = ifft(symbols, cfg.FFTLength, 1);
withPrefix = [timeSymbols(end - cfg.CyclicPrefixLength + 1:end, :); timeSymbols];
baseband = withPrefix(:);
sampleIndex = (0:numel(baseband) - 1).';
waveform = real(baseband .* exp(1j * 2 * pi * cfg.CenterFrequency * ...
    sampleIndex / cfg.SampleRate));
peak = max(abs(waveform));
if peak > 0
    waveform = 0.75 * waveform / peak;
end
end

function [message, info] = decodeBaseband(samples)
[payload, info] = decodePacket(samples);
message = "";
if ~isempty(payload)
    message = string(native2unicode(payload, "UTF-8"));
end
end

function [payload, info] = decodePacket(samples)
cfg = modemConfig();
payload = uint8([]);
info = struct("FoundPreamble", false, "Correlation", 0, "CFOHz", NaN);
samples = samples(:);
preambleTime = ifftPlace(cfg.Preamble, cfg);
preamble = [preambleTime(end - cfg.CyclicPrefixLength + 1:end); preambleTime];
templateLength = numel(preamble);
if numel(samples) < cfg.FrameSampleCount
    return;
end

correlationLength = numel(samples) + templateLength - 1;
fftLength = 2 ^ nextpow2(correlationLength);
correlation = ifft(fft(samples, fftLength) .* ...
    fft(conj(flipud(preamble)), fftLength));
lastCompleteStart = numel(samples) - cfg.FrameSampleCount + 1;
lastCorrelationIndex = lastCompleteStart + templateLength - 1;
valid = correlation(templateLength:lastCorrelationIndex);
scores = abs(valid);
peakMask = false(size(scores));
if isscalar(scores)
    peakMask(1) = true;
else
    peakMask(1) = scores(1) > scores(2);
    peakMask(end) = scores(end) >= scores(end - 1);
    if numel(scores) > 2
        peakMask(2:end - 1) = scores(2:end - 1) >= scores(1:end - 2) & ...
            scores(2:end - 1) > scores(3:end);
    end
end
candidateStarts = find(peakMask);
[~, order] = sort(scores(candidateStarts), "descend");
candidateStarts = candidateStarts(order);
testedStarts = zeros(min(numel(candidateStarts), 24), 1);
testedCount = 0;
for candidateIndex = 1:min(numel(candidateStarts), 24)
    frameStart = candidateStarts(candidateIndex);
    if any(abs(testedStarts(1:testedCount) - frameStart) < cfg.SymbolLength)
        continue;
    end
    testedCount = testedCount + 1;
    testedStarts(testedCount) = frameStart;
    local = samples(frameStart:frameStart + templateLength - 1);
    firstQuality = abs(sum(local .* conj(preamble))) / ...
        (sqrt(sum(abs(local).^2) * sum(abs(preamble).^2)) + eps);
    secondStart = frameStart + cfg.SymbolLength;
    second = samples(secondStart:secondStart + templateLength - 1);
    secondQuality = abs(sum(second .* conj(preamble))) / ...
        (sqrt(sum(abs(second).^2) * sum(abs(preamble).^2)) + eps);
    quality = sqrt(firstQuality * secondQuality);
    if quality < 0.5
        continue;
    end
    firstSymbol = samples(frameStart:frameStart + cfg.SymbolLength - 1);
    secondSymbol = samples(secondStart:secondStart + cfg.SymbolLength - 1);
    candidateCFO = angle(sum(conj(firstSymbol) .* secondSymbol)) * ...
        cfg.SampleRate / (2 * pi * cfg.SymbolLength);
    if ~info.FoundPreamble
        info.FoundPreamble = true;
        info.Correlation = quality;
        info.CFOHz = candidateCFO;
    end

    sampleIndex = (0:numel(samples) - 1).' - (frameStart - 1);
    corrected = samples .* exp(-1j * 2 * pi * candidateCFO * ...
        sampleIndex / cfg.SampleRate);
    trainingStart = frameStart + cfg.PreambleSymbolCount * cfg.SymbolLength;
    trainingBody = corrected(trainingStart + cfg.CyclicPrefixLength: ...
        trainingStart + cfg.CyclicPrefixLength + cfg.FFTLength - 1);
    trainingSpectrum = fft(trainingBody, cfg.FFTLength);
    channel = trainingSpectrum(cfg.ActiveBins);
    if any(abs(channel) < 1e-8)
        continue;
    end

    codedSoftBits = zeros(cfg.DataCarrierCount * 2 * cfg.DataSymbolCount, 1);
    bitOffset = 0;
    for symbolIndex = 1:cfg.DataSymbolCount
        symbolStart = frameStart + ...
            (symbolIndex + cfg.PreambleSymbolCount + cfg.TrainingSymbolCount - 1) * ...
            cfg.SymbolLength;
        body = corrected(symbolStart + cfg.CyclicPrefixLength: ...
            symbolStart + cfg.CyclicPrefixLength + cfg.FFTLength - 1);
        spectrum = fft(body, cfg.FFTLength);
        active = spectrum(cfg.ActiveBins);
        channelAtPilots = channel(cfg.PilotIndices);
        expectedPilots = pilotValues(symbolIndex, cfg.PilotCount);
        phaseError = angle(sum((active(cfg.PilotIndices) ./ ...
            (channelAtPilots .* expectedPilots))));
        active = active * exp(-1j * phaseError);
        equalized = active(cfg.DataIndices) ./ channel(cfg.DataIndices);
        pairSoftBits = [real(equalized).'; imag(equalized).'];
        count = numel(pairSoftBits);
        codedSoftBits(bitOffset + (1:count)) = pairSoftBits(:);
        bitOffset = bitOffset + count;
    end

    qpskSoftBits = reshape(codedSoftBits, 2, []);
    combinedBits = (qpskSoftBits(:, 1:2:end) + ...
        qpskSoftBits(:, 2:2:end)) < 0;
    bytes = bitsToBytes(combinedBits);
    payloadLength = double(bytes(1)) * 256 + double(bytes(2));
    if payloadLength < 1 || payloadLength > cfg.MaxPayloadBytes
        continue;
    end
    packetEnd = payloadLength + 2;
    receivedCrc = uint16(double(bytes(packetEnd + 1)) * 256 + ...
        double(bytes(packetEnd + 2)));
    packet = bytes(1:packetEnd);
    if crc16(packet) ~= receivedCrc
        continue;
    end
    payload = bytes(3:packetEnd);
    return;
end
end

function output = ifftPlace(activeValues, cfg)
frequency = complex(zeros(cfg.FFTLength, 1));
frequency(cfg.ActiveBins) = activeValues;
output = ifft(frequency, cfg.FFTLength);
end

function values = pilotValues(symbolIndex, count)
values = exp(1j * pi / 2 * mod((0:count - 1).' + symbolIndex - 1, 4));
end

function bits = bytesToBits(bytes)
bytes = uint8(bytes(:));
bits = zeros(numel(bytes) * 8, 1);
for index = 1:numel(bytes)
    bits((index - 1) * 8 + (1:8)) = bitget(bytes(index), 8:-1:1);
end
end

function bytes = bitsToBytes(bits)
bitMatrix = reshape(double(bits), 8, []);
bytes = uint8(sum(bitMatrix .* (2 .^ (7:-1:0).'), 1));
end

function value = crc16(bytes)
value = uint16(hex2dec("FFFF"));
polynomial = uint16(hex2dec("1021"));
for byte = uint8(bytes(:).')
    value = bitxor(value, bitshift(uint16(byte), 8));
    for bitIndex = 1:8
        if bitget(value, 16)
            value = bitxor(bitshift(value, 1), polynomial);
        else
            value = bitshift(value, 1);
        end
    end
end
end

function coefficients = lowpassCoefficients()
cfg = modemConfig();
tapCount = 129;
middle = (tapCount - 1) / 2;
index = (-middle:middle).';
normalizedCutoff = 4500 / cfg.SampleRate;
ideal = 2 * normalizedCutoff * sinc(2 * normalizedCutoff * index);
window = 0.54 - 0.46 * cos(2 * pi * (0:tapCount - 1).' / (tapCount - 1));
coefficients = ideal .* window;
coefficients = coefficients / sum(coefficients);
end

function [chunks, metadata] = packetizeMessage(message, messageId)
cfg = modemConfig();
payload = uint8(unicode2native(reshape(char(message), 1, []), "UTF-8"));
if isempty(payload)
    error("ofdm_pager_core:EmptyMessage", "Enter a non-empty message.");
end
if numel(payload) > 4e6
    error("ofdm_pager_core:MessageTooLong", ...
        "Message exceeds the 4 MB per-send limit.");
end
headerLength = 17;
chunkCapacity = cfg.MaxPayloadBytes - headerLength;
chunkCount = ceil(numel(payload) / chunkCapacity);
if chunkCount > 65535
    error("ofdm_pager_core:MessageTooLong", ...
        "Message requires too many fixed-size frames.");
end
messageId = uint32(messageId);
messageCrc = crc16(payload);
chunks = cell(1, chunkCount);
for index = 1:chunkCount
    first = (index - 1) * chunkCapacity + 1;
    last = min(index * chunkCapacity, numel(payload));
    header = [uint8(hex2dec("4F")), uint8(hex2dec("46")), uint8(1), ...
        packInteger(messageId, 4), packInteger(index, 2), ...
        packInteger(chunkCount, 2), packInteger(numel(payload), 4), ...
        packInteger(messageCrc, 2)];
    chunks{index} = [header, payload(first:last)];
end
metadata = struct("MessageId", double(messageId), "ChunkCount", chunkCount, ...
    "TotalLength", numel(payload), "MessageCrc", double(messageCrc));
end

function header = parseMessageChunk(packet)
header = struct("Valid", false, "MessageId", 0, "ChunkIndex", 0, ...
    "ChunkCount", 0, "TotalLength", 0, "MessageCrc", 0, "Data", uint8([]));
packet = uint8(packet(:).');
if numel(packet) < 18 || ~isequal(packet(1:3), uint8([hex2dec("4F"), ...
        hex2dec("46"), 1]))
    return;
end
header.MessageId = unpackInteger(packet(4:7));
header.ChunkIndex = unpackInteger(packet(8:9));
header.ChunkCount = unpackInteger(packet(10:11));
header.TotalLength = unpackInteger(packet(12:15));
header.MessageCrc = unpackInteger(packet(16:17));
header.Data = packet(18:end);
cfg = modemConfig();
header.Valid = header.ChunkCount >= 1 && ...
    header.ChunkIndex >= 1 && header.ChunkIndex <= header.ChunkCount && ...
    header.TotalLength >= 1 && header.TotalLength <= 4e6 && ...
    header.ChunkCount <= 65535 && ...
    numel(header.Data) <= cfg.MaxPayloadBytes - 17 && ...
    ~isempty(header.Data);
if header.Valid
    expectedCount = ceil(header.TotalLength / (cfg.MaxPayloadBytes - 17));
    expectedLength = min(cfg.MaxPayloadBytes - 17, ...
        header.TotalLength - (header.ChunkIndex - 1) * (cfg.MaxPayloadBytes - 17));
    header.Valid = header.ChunkCount == expectedCount && ...
        numel(header.Data) == expectedLength;
end
end

function bytes = packInteger(value, byteCount)
bytes = zeros(1, byteCount, "uint8");
value = uint64(value);
for index = 1:byteCount
    bytes(index) = uint8(bitand(bitshift(value, -8 * (index - 1)), 255));
end
end

function value = unpackInteger(bytes)
value = 0;
for index = 1:numel(bytes)
    value = value + double(bytes(index)) * 256 ^ (index - 1);
end
end
