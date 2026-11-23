-- Loopback HTTP/1.1 fixture server for Mockwave audio.
--
-- The host gives Lua a TCP listener through host.socket_server and a timer
-- through host.timer; this module turns those two primitives into a tiny
-- Range-capable HTTP server. It exists so the example gateway can return a
-- playable stream while still declaring no network permission: the client
-- fetches the WAV from 127.0.0.1, not from the internet.
--
-- Why a timer? Every plugin call has an instruction budget, so the WAV is
-- rendered chunk by chunk (tone.lua) and each tick sends one chunk. The server
-- is deliberately small: HTTP/1.1, GET/HEAD/OPTIONS, byte ranges,
-- Connection: close. It is a fixture, not a general web server.
--
-- Host limits: one listener per ID, 32 clients per listener, 1 MB per message.
-- The browser runtime cannot listen on TCP, so there `serve` reports an error
-- and browsing still works.
--
-- Parsing note: this Lua dialect does not implement the `%a`/`%d`/`%s`/`%.`
-- pattern classes, and `#` on a string throws. The request parser therefore
-- uses plain `string.find(..., true)` and `string.byte`, never `%` patterns.

local tone = require("tone")

local M = {}

local HOST = "127.0.0.1"
local SERVER_ID = "mockwave-tone"
local TIMER_ID = "mockwave-tone-pump"
local TICK_MS = 100
local SEND_BYTES = 4 * 1024
local MAX_CLIENTS = 8
local HEAD_LIMIT = 8 * 1024
local HEAD_TICKS = 250
local IDLE_TICKS = 500
local GRACE_TICKS = 3
local TOTAL_BYTES = tone.size()

local state = {
  port = nil,
  timer = false,
  idle = 0,
  clients = {},
  order = {},
  lastError = nil,
  blockedUntil = 0,
}

local function trim(value)
  value = tostring(value or "")
  local first = 1
  local last = string.len(value)
  while first <= last do
    local byte = string.byte(value, first)
    if byte ~= 32 and byte ~= 9 then break end
    first = first + 1
  end
  while last >= first do
    local byte = string.byte(value, last)
    if byte ~= 32 and byte ~= 9 then break end
    last = last - 1
  end
  return string.sub(value, first, last)
end

local function callServer(spec)
  local ok, result = pcall(host.socket_server, spec)
  if not ok then
    state.lastError = tostring(result)
    return nil
  end
  return result
end

local function stopTimer()
  if not state.timer then return end
  pcall(host.timer, { operation = "cancel", id = TIMER_ID })
  state.timer = false
end

local function ensureTimer()
  if state.timer then return true end
  local ok, err = pcall(host.timer, { id = TIMER_ID, intervalMs = TICK_MS })
  if not ok then
    state.lastError = tostring(err)
    state.timer = false
    return false
  end
  state.timer = true
  return true
end

local function ensureListening()
  if state.port then return state.port end
  -- A denied permission prompt is not worth repeating for every quality tier
  -- of the same play request; wait a few seconds before asking again.
  if state.blockedUntil > host.now() then return nil end
  local result = callServer({
    operation = "listen", id = SERVER_ID, host = HOST, port = 0,
  })
  if type(result) ~= "table" or type(result.port) ~= "number" then
    state.lastError = state.lastError or "listener unavailable"
    state.blockedUntil = host.now() + 5000
    return nil
  end
  state.port = result.port
  state.lastError = nil
  state.blockedUntil = 0
  return state.port
end

local function closeClient(client)
  callServer({ operation = "close_client", id = SERVER_ID, clientId = client.id })
  return false
end

local function byteSlice(bytes, count)
  local out = {}
  for index = 1, count do out[index] = string.byte(bytes, index) end
  return out
end

local function parseRequestLine(head)
  local firstBreak = string.find(head, "\r\n", 1, true)
  if not firstBreak then return nil end
  local line = string.sub(head, 1, firstBreak - 1)
  local firstSpace = string.find(line, " ", 1, true)
  if not firstSpace then return nil end
  local secondSpace = string.find(line, " ", firstSpace + 1, true)
  if not secondSpace then return nil end
  local method = string.sub(line, 1, firstSpace - 1)
  local target = string.sub(line, firstSpace + 1, secondSpace - 1)
  local version = string.sub(line, secondSpace + 1)
  if version ~= "HTTP/1.1" and version ~= "HTTP/1.0" then return nil end
  if method ~= "GET" and method ~= "HEAD" and method ~= "OPTIONS" then return nil end
  return method, target, firstBreak
end

local function parseHeaders(head, position)
  local headers = {}
  local length = string.len(head)
  while position <= length do
    local nextBreak = string.find(head, "\r\n", position, true)
    if not nextBreak then break end
    local line = string.sub(head, position, nextBreak - 1)
    if line == "" then break end
    local colon = string.find(line, ":", 1, true)
    if colon then
      local name = string.lower(string.sub(line, 1, colon - 1))
      headers[name] = trim(string.sub(line, colon + 1))
    end
    position = nextBreak + 2
  end
  return headers
end

local function parseVariant(path)
  local marker = string.find(path, "/tone/", 1, true)
  if not marker then return 1 end
  local rest = string.sub(path, marker + 6)
  local dot = string.find(rest, ".wav", 1, true)
  if not dot then return 1 end
  return tonumber(string.sub(rest, 1, dot - 1)) or 1
end

local function parseRange(value, total)
  local start, finish = 0, total - 1
  local partial = false
  if type(value) ~= "string" then return start, finish, partial end
  local prefix = string.sub(string.lower(value), 1, 6)
  if prefix ~= "bytes=" then return start, finish, partial end
  local rest = string.sub(value, 7)
  local dash = string.find(rest, "-", 1, true)
  if not dash then return start, finish, partial end
  local first = string.sub(rest, 1, dash - 1)
  local last = string.sub(rest, dash + 1)
  if first == "" then
    local suffix = tonumber(last)
    if suffix and suffix > 0 then start = math.max(0, total - suffix) end
  else
    start = tonumber(first) or 0
    finish = tonumber(last) or (total - 1)
  end
  return start, finish, true
end

local function prepare(client)
  local head = client.head
  local method, target, firstBreak = parseRequestLine(head)
  if not method then
    state.lastError = "invalid request line"
    return false
  end
  local path = target
  local query = string.find(target, "?", 1, true)
  if query then path = string.sub(target, 1, query - 1) end
  local variant = parseVariant(path)
  local total = TOTAL_BYTES
  local headers = parseHeaders(head, firstBreak + 2)

  if method == "OPTIONS" then
    client.header = table.concat({
      "HTTP/1.1 204 No Content\r\n",
      "Access-Control-Allow-Methods: GET, HEAD, OPTIONS\r\n",
      "Content-Length: 0\r\nConnection: close\r\n\r\n",
    })
    client.variant = variant
    client.start = 0
    client.length = 0
    client.sent = 0
    client.stage = "body"
    return true
  end

  if method == "HEAD" then
    client.header = table.concat({
      "HTTP/1.1 200 OK\r\n",
      "Content-Type: audio/wav\r\n",
      "Accept-Ranges: bytes\r\n",
      "Content-Length: ", tostring(total), "\r\n",
      "Cache-Control: no-store\r\nConnection: close\r\n",
      "Access-Control-Allow-Origin: *\r\n\r\n",
    })
    client.variant = variant
    client.start = 0
    client.length = 0
    client.sent = 0
    client.stage = "body"
    return true
  end

  local start, finish, partial = parseRange(headers["range"], total)
  if start > finish or start >= total or finish < 0 then
    client.header = table.concat({
      "HTTP/1.1 416 Range Not Satisfiable\r\n",
      "Content-Range: bytes */", tostring(total), "\r\n",
      "Content-Length: 0\r\nConnection: close\r\n\r\n",
    })
    client.variant = variant
    client.start = 0
    client.length = 0
    client.sent = 0
    client.stage = "body"
    return true
  end
  if finish >= total then finish = total - 1 end

  local length = finish - start + 1
  local status = (partial and (start > 0 or finish < total - 1))
    and "206 Partial Content" or "200 OK"
  local header = {
    "HTTP/1.1 ", status, "\r\n",
    "Content-Type: audio/wav\r\n",
    "Accept-Ranges: bytes\r\n",
    "Content-Length: ", tostring(length), "\r\n",
  }
  if status == "206 Partial Content" then
    header[#header + 1] = "Content-Range: bytes "
    header[#header + 1] = tostring(start) .. "-" .. tostring(finish)
    header[#header + 1] = "/" .. tostring(total) .. "\r\n"
  end
  header[#header + 1] = "Cache-Control: no-store\r\n"
  header[#header + 1] = "Connection: close\r\n"
  header[#header + 1] = "Access-Control-Allow-Origin: *\r\n\r\n"

  client.header = table.concat(header)
  client.variant = variant
  client.start = start
  client.length = length
  client.sent = 0
  client.stage = "body"
  return true
end

local function stepClient(client, allowBuild)
  if client.stage == "head" then
    client.age = client.age + 1
    local data = callServer({
      operation = "receive", id = SERVER_ID, clientId = client.id,
      format = "text", timeoutMs = 0,
    })
    if type(data) == "string" and string.len(data) > 0 then
      client.head = client.head .. data
      if string.len(client.head) > HEAD_LIMIT then return closeClient(client) end
      if string.find(client.head, "\r\n\r\n", 1, true) then
        if not prepare(client) then return closeClient(client) end
      end
    end
    if client.stage == "head" and client.age > HEAD_TICKS then
      return closeClient(client)
    end
    return true
  end

  if not client.headerSent then
    local ok = callServer({
      operation = "send", id = SERVER_ID, clientId = client.id,
      data = client.header,
    })
    if not ok then return closeClient(client) end
    client.headerSent = true
    return true
  end

  if client.sent >= client.length then
    client.grace = (client.grace or 0) + 1
    if client.grace >= GRACE_TICKS then return closeClient(client) end
    return true
  end

  local want = math.min(SEND_BYTES, client.length - client.sent)
  local piece, built = tone.read(
    client.variant, client.start + client.sent, want, allowBuild
  )
  if piece == nil then return true, false end
  local size = string.len(piece)
  if size == 0 then return closeClient(client) end
  local ok = callServer({
    operation = "send", id = SERVER_ID, clientId = client.id,
    data = byteSlice(piece, size),
  })
  if not ok then return closeClient(client) end
  client.sent = client.sent + size
  return true, built
end

--- Serves one variant and returns its URL plus the exact byte length.
function M.serve(trackId, variant)
  local port = ensureListening()
  if not port then
    return nil, "listen: " .. tostring(state.lastError or "loopback listener unavailable")
  end
  if not ensureTimer() then
    return nil, "timer: " .. tostring(state.lastError or "timer unavailable")
  end
  state.idle = 0
  local url = string.format(
    "http://%s:%d/tone/%d.wav?track=%s",
    HOST, port, variant, host.url_encode(tostring(trackId))
  )
  return url, TOTAL_BYTES
end

--- Timer callback. The host invokes call("timer", {id=...}) for every plugin
--- timer, so ignore IDs that belong to someone else.
function M.pump(id)
  if id ~= nil and id ~= TIMER_ID then return end
  if not state.port then stopTimer(); return end

  for _ = 1, 4 do
    local accepted = callServer({
      operation = "accept", id = SERVER_ID, timeoutMs = 0,
    })
    if type(accepted) ~= "table" or not accepted.clientId then break end
    local clientId = accepted.clientId
    if state.clients[clientId] or #state.order >= MAX_CLIENTS then
      callServer({ operation = "close_client", id = SERVER_ID, clientId = clientId })
    else
      state.clients[clientId] = {
        id = clientId, head = "", age = 0, stage = "head",
        sent = 0, length = 0, headerSent = false,
      }
      state.order[#state.order + 1] = clientId
      state.idle = 0
    end
  end

  local budget = 1
  local index = 1
  while index <= #state.order do
    local clientId = state.order[index]
    local client = state.clients[clientId]
    local keep = false
    if client ~= nil then
      local ok, result, used = pcall(stepClient, client, budget > 0)
      if ok then
        keep = result
        if used then budget = budget - 1 end
      else
        state.lastError = "step: " .. tostring(result)
        closeClient(client)
      end
    end
    if keep then
      index = index + 1
    else
      state.clients[clientId] = nil
      table.remove(state.order, index)
    end
  end

  if #state.order == 0 then
    state.idle = state.idle + 1
    if state.idle >= IDLE_TICKS then stopTimer() end
  else
    state.idle = 0
  end
end

function M.url()
  if not state.port then return nil end
  return string.format("http://%s:%d", HOST, state.port)
end

function M.close()
  stopTimer()
  for clientId in pairs(state.clients) do
    callServer({ operation = "close_client", id = SERVER_ID, clientId = clientId })
  end
  state.clients = {}
  state.order = {}
  callServer({ operation = "close", id = SERVER_ID })
  state.port = nil
end

return M