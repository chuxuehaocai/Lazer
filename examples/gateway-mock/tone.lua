-- Synthetic WAV fixtures for the Mockwave example.
--
-- The plugin ships no audio files. It renders a short, original arpeggio at
-- 8 kHz mono / 16-bit, one 4 KB PCM chunk at a time, and tone_server.lua serves
-- those bytes over a loopback HTTP server.
--
-- Why chunked? The host gives every plugin call a bounded instruction budget
-- (250k VM instructions in the current client). Rendering 24 seconds in one
-- call would exhaust it. Each chunk is 2048 samples and costs well under the
-- budget; the server builds one chunk per timer tick and caches it.
--
-- This is fixture audio, not a music engine: no real codec, no metadata, no
-- album art.

local M = {}

local RATE = 8000
local SECONDS = 24
local CHANNELS = 1
local BITS = 16
local STEP_SECONDS = 1.5
local NOTE_SAMPLES = math.floor(RATE * STEP_SECONDS)
local TOTAL_SAMPLES = RATE * SECONDS
local WAVE_SIZE = 64
local CHUNK_SAMPLES = 2048
local CHUNK_BYTES = CHUNK_SAMPLES * 2
local HEADER_BYTES = 44
local TAU = math.pi * 2
local WAVEFORM_GAIN = 0.30 * 32767

local unpackValues = table.unpack or unpack

-- Four transpositions of the same pentatonic figure. Roots stay below 250 Hz
-- so the octave partial is comfortable at an 8 kHz sample rate.
local ROOTS = { 196.00, 220.00, 246.94, 174.61 }
local PATTERNS = {
  { 0, 7, 12, 7, 3, 10, 15, 12 },
  { 0, 3, 7, 10, 12, 10, 7, 3 },
  { 0, 5, 9, 12, 16, 12, 9, 5 },
  { 0, 7, 5, 12, 10, 7, 3, 0 },
}

local variants = {}
local header

local function u16(value)
  value = math.floor(value) % 65536
  return string.char(value % 256, math.floor(value / 256) % 256)
end

local function u32(value)
  value = math.floor(value) % 4294967296
  return string.char(
    value % 256,
    math.floor(value / 256) % 256,
    math.floor(value / 65536) % 256,
    math.floor(value / 16777216) % 256
  )
end

local function normalise(variant)
  variant = math.floor(tonumber(variant) or 1)
  if variant < 1 or variant > #ROOTS then return 1 end
  return variant
end

local function dataFor(variant)
  local data = variants[variant]
  if data then return data end
  local root = ROOTS[variant]
  local pattern = PATTERNS[variant]
  data = { waves = {}, increments = {}, chunks = {} }
  for step = 1, #pattern do
    local frequency = root * (2 ^ (pattern[step] / 12))
    local wave = {}
    for index = 0, WAVE_SIZE - 1 do
      local angle = TAU * index / WAVE_SIZE
      wave[index + 1] = (math.sin(angle) + 0.25 * math.sin(angle * 2))
        * WAVEFORM_GAIN
    end
    data.waves[step] = wave
    data.increments[step] = frequency * WAVE_SIZE / RATE
  end
  variants[variant] = data
  return data
end

local function buildChunk(variant, index)
  local data = dataFor(variant)
  local first = index * CHUNK_SAMPLES
  local last = math.min(TOTAL_SAMPLES, first + CHUNK_SAMPLES) - 1
  local pattern = PATTERNS[variant]
  local pieces = {}
  local buffer = {}
  local used = 0

  for sample = first, last do
    local step = (math.floor(sample / NOTE_SAMPLES) % #pattern) + 1
    local localSample = sample % NOTE_SAMPLES
    local phase = (sample * data.increments[step]) % WAVE_SIZE
    local value = data.waves[step][math.floor(phase) + 1]
    local decay = 1 - (localSample / NOTE_SAMPLES)
    local sampleValue = math.floor(value * decay * decay + 0.5)

    used = used + 1
    buffer[used] = sampleValue % 256
    used = used + 1
    buffer[used] = math.floor(sampleValue / 256) % 256
    if used >= 4096 then
      pieces[#pieces + 1] = string.char(unpackValues(buffer, 1, used))
      used = 0
    end
  end
  if used > 0 then
    pieces[#pieces + 1] = string.char(unpackValues(buffer, 1, used))
  end
  return table.concat(pieces)
end

local function chunkAt(variant, index, allowBuild)
  local data = dataFor(variant)
  local cached = data.chunks[index]
  if cached ~= nil then return cached, false end
  if not allowBuild then return nil, false end
  local chunk = buildChunk(variant, index)
  data.chunks[index] = chunk
  return chunk, true
end

local function wavHeader()
  if header then return header end
  local dataBytes = TOTAL_SAMPLES * 2
  header = table.concat({
    "RIFF", u32(36 + dataBytes), "WAVE",
    "fmt ", u32(16), u16(1), u16(CHANNELS), u32(RATE),
    u32(RATE * CHANNELS * BITS / 8), u16(CHANNELS * BITS / 8), u16(BITS),
    "data", u32(dataBytes),
  })
  return header
end

--- Reads up to `count` bytes of the WAV starting at byte `offset`.
--- Builds at most one PCM chunk per call, so each call stays inside the
--- host instruction budget. Returns a possibly shorter string.
function M.read(variant, offset, count, allowBuild)
  variant = normalise(variant)
  offset = math.max(0, math.floor(tonumber(offset) or 0))
  count = math.max(0, math.floor(tonumber(count) or 0))
  local total = M.size()
  if offset >= total or count == 0 then return "", false end
  if count > total - offset then count = total - offset end

  if offset < HEADER_BYTES then
    local take = math.min(count, HEADER_BYTES - offset)
    return string.sub(wavHeader(), offset + 1, offset + take), false
  end

  local pcmOffset = offset - HEADER_BYTES
  local index = math.floor(pcmOffset / CHUNK_BYTES)
  local within = pcmOffset % CHUNK_BYTES
  local chunk, built = chunkAt(variant, index, allowBuild)
  if chunk == nil then return nil, false end
  local available = string.len(chunk) - within
  if available > count then available = count end
  return string.sub(chunk, within + 1, within + available), built
end

--- Total WAV size in bytes, including the 44-byte header.
function M.size()
  return HEADER_BYTES + TOTAL_SAMPLES * 2
end

function M.durationSeconds()
  return SECONDS
end

function M.rate()
  return RATE
end

return M