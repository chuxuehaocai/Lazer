-- Mockwave: a complete, offline music-gateway example.
--
-- Host contract: https://lazer.naominet.dev/docs (docs/lua-plugins.md in the
-- app repository, "Lua Plugin 开发说明" and "扩展的平台接口").
--
-- The gateway returns JSON-shaped tables only. It never touches Dart objects,
-- Flutter widgets, files or the network. Browsing uses the fixture catalogue;
-- playback uses a synthetic WAV served from 127.0.0.1 by tone_server.lua.
--
-- Sign in with any account name and any non-empty password. The session and
-- the liked-song list live in host.storage_* on this device.

local catalog = require("catalog")
local toneserver = require("tone_server")

local PLATFORM = "mockwave"
local SESSION_KEY = "mockwave.session"
local LIKED_KEY = "mockwave.liked"
local SEED_LIKED = { "s01", "s07", "s11" }

local CAPABILITIES = {
  "homeFeed", "search", "browseAlbums", "playlists",
  "favorites", "lyrics", "radio", "charts",
}

local function fail(code, message)
  return { error = { code = code, message = message } }
end

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

local function textLength(value)
  if utf8 and utf8.len then
    local ok, length = pcall(utf8.len, value)
    if ok and length then return length end
  end
  return string.len(value)
end

local function readJson(key)
  local raw = host.storage_get(key)
  if type(raw) ~= "string" or raw == "" then return nil end
  local ok, value = pcall(host.json_decode, raw)
  if ok then return value end
  return nil
end

local function writeJson(key, value)
  if value == nil then
    host.storage_set(key, nil)
    return
  end
  host.storage_set(key, host.json_encode(value))
end

local function likedIds()
  local stored = readJson(LIKED_KEY)
  local out = {}
  if type(stored) ~= "table" then return out end
  for _, value in ipairs(stored) do
    if type(value) == "string" and catalog.track(value) then out[#out + 1] = value end
  end
  return out
end

local function currentUser()
  local stored = readJson(SESSION_KEY)
  if type(stored) ~= "table" or type(stored.account) ~= "string" then return nil end
  return {
    id = "listener-" .. tostring(stored.hash or "guest"),
    name = stored.account,
    signature = "Mockwave 本地演示账号",
    membership = "MOCK",
  }
end

local function page(items, offset, limit)
  offset = math.max(0, math.floor(tonumber(offset) or 0))
  limit = math.max(1, math.min(200, math.floor(tonumber(limit) or 50)))
  local out = {}
  local last = math.min(#items, offset + limit)
  for index = offset + 1, last do out[#out + 1] = items[index] end
  return out
end

local function albumList(sort)
  local items = catalog.albumModels()
  if sort == "random" then
    local shift = math.floor((host.now() / 1000) % math.max(1, #items))
    local rotated = {}
    for index = 1, #items do
      rotated[index] = items[((index + shift - 1) % #items) + 1]
    end
    return rotated
  end
  table.sort(items, function(left, right)
    return (left.year or 0) > (right.year or 0)
  end)
  return items
end

local handlers = {}

function handlers.describe()
  return {
    providers = {
      {
        id = PLATFORM,
        name = "Mockwave 模拟音源",
        auth = { "password" },
        capabilities = CAPABILITIES,
        loginHint = "任意账号 + 任意密码即可登录；账号只写入本机插件存储。",
        experimental = true,
      },
    },
  }
end

function handlers.session()
  return currentUser()
end

function handlers.loginPassword(args)
  local account = trim(args.account)
  local password = tostring(args.password or "")
  local length = textLength(account)
  if length < 1 or length > 32 then
    return fail(401, "账号需要 1–32 个字符")
  end
  if string.len(password) < 1 then
    return fail(401, "密码不能为空（Mockwave 接受任意密码）")
  end
  local hash = host.crypto({ operation = "md5", text = account }):sub(1, 12)
  writeJson(SESSION_KEY, {
    account = account, hash = hash, signedInAt = host.now(),
  })
  if host.storage_get(LIKED_KEY) == nil then
    writeJson(LIKED_KEY, SEED_LIKED)
  end
  host.log("info", "mockwave login", { account = account })
  return currentUser()
end

function handlers.loginCookie()
  return fail(400, "Mockwave 只声明了 password 登录")
end

function handlers.logout()
  writeJson(SESSION_KEY, nil)
  return true
end

function handlers.search(args)
  return catalog.search(args.query, args.offset, args.limit)
end

function handlers.homeFeed()
  return catalog.home(currentUser(), likedIds())
end

function handlers.albums(args)
  return page(albumList(args.sort), args.offset, args.limit)
end

function handlers.album(args)
  local model = catalog.albumModel(tostring(args.id or ""))
  if not model then return fail(404, "unknown album") end
  return model
end

function handlers.albumSongs(args)
  return page(catalog.albumSongs(tostring(args.id or "")), args.offset, args.limit)
end

function handlers.artist(args)
  local model = catalog.artistModel(tostring(args.id or ""))
  if not model then return fail(404, "unknown artist") end
  return model
end

function handlers.artistSongs(args)
  return page(catalog.artistSongs(tostring(args.id or "")), args.offset, args.limit)
end

function handlers.artistAlbums(args)
  return page(catalog.artistAlbums(tostring(args.id or "")), args.offset, args.limit)
end

function handlers.song(args)
  local model = catalog.songModel(catalog.track(tostring(args.id or "")))
  if not model then return fail(404, "unknown track") end
  return model
end

function handlers.playlists(args)
  local user = currentUser()
  local items = user
    and catalog.userPlaylists(user, likedIds())
    or catalog.publicPlaylists()
  return page(items, args.offset, args.limit)
end

function handlers.playlist(args)
  local model = catalog.playlist(tostring(args.id or ""), currentUser(), likedIds())
  if not model then return fail(404, "unknown playlist") end
  return model
end

function handlers.playlistSongs(args)
  local songs = catalog.playlistSongModels(tostring(args.id or ""), likedIds())
  return page(songs, args.offset, args.limit)
end

function handlers.favorites(args)
  return page(catalog.modelsForIds(likedIds()), args.offset, args.limit)
end

function handlers.setFavorite(args)
  local trackId = tostring(args.id or "")
  if not catalog.track(trackId) then return fail(404, "unknown track") end
  local set = {}
  for _, value in ipairs(likedIds()) do set[value] = true end
  if args.favorite == true then set[trackId] = true else set[trackId] = nil end
  local nextLiked = {}
  for _, track in ipairs(catalog.tracks()) do
    if set[track.id] then nextLiked[#nextLiked + 1] = track.id end
  end
  writeJson(LIKED_KEY, nextLiked)
  return true
end

function handlers.lyrics(args)
  return catalog.lyrics(tostring(args.id or ""))
end

function handlers.radio(args)
  return catalog.radio(args.kind, args.seed, args.limit)
end

function handlers.charts()
  return catalog.chartModels()
end

function handlers.stream(args)
  local track = catalog.track(tostring(args.id or ""))
  if not track then return fail(404, "unknown track") end
  local url, size = toneserver.serve(track.id, catalog.variant(track.id))
  if not url then
    host.log("warn", "mockwave tone server unavailable", { reason = tostring(size) })
    return fail(503, "本地音频演示不可用：" .. tostring(size))
  end
  return {
    url = url,
    contentType = "audio/wav",
    suffix = "wav",
    bitRate = 128000,
    size = size,
  }
end

function handlers.timer(args)
  toneserver.pump(args.id)
  return true
end

return {
  call = function(operation, args)
    args = args or {}
    local handler = handlers[operation]
    if handler == nil then
      return fail(400, "unsupported operation: " .. tostring(operation))
    end
    return handler(args)
  end,
}
