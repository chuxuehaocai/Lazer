-- NetEase Cloud Music provider for Lazer's isolated Lua plugin runtime.
-- Credentials and rotated device cookies stay in host.storage_* only.
local API = "https://music.163.com"
local EAPI = "https://interfacepc.music.163.com"
local CLIENT_LOG = "https://clientlog.music.163.com"
local WEAPI_KEY = "0CoJUm6Qyw8W8jud"
local EAPI_KEY = "e82ckenh8dichen8"
local IV = "0102030405060708"
local RSA_MODULUS = "e0b509f6259df8642dbc35662901477df22677ec152b5ff68ace615bb7b72515" ..
  "2b3ab17a876aea8a5aa76d2e417629ec4ee341f56135fccf695280104e0312ec" ..
  "bda92557c93870114af6c9d05c4f7f0c3685b7a46bee255932575cce10b424d8" ..
  "13cfe4875d3e82047b97ddef52741d546b8e289dc6935b3ece0462db0a22b8e7"

local cookie_names = {
  MUSIC_U = true, MUSIC_A = true, NMTID = true, deviceId = true,
  sDeviceId = true, __csrf = true, __csrf_token = true,
  _ntes_nuid = true, _ntes_nnid = true, WNMCID = true, WEVNSM = true
}

local session_cookie = host.storage_get("session_cookie") or ""
local current_user = nil

local function text(value)
  if value == nil then return "" end
  return tostring(value)
end

-- Avoid pattern-dependent trimming: the embedded interpreter does not
-- implement all of standard Lua's non-greedy capture substitutions.
local function trim(value)
  local value = text(value)
  local first, last = 1, string.len(value)
  while first <= last and string.byte(value, first) <= 32 do first = first + 1 end
  while last >= first and string.byte(value, last) <= 32 do last = last - 1 end
  return string.sub(value, first, last)
end

local function phone_account(value)
  local parts = {}
  for index = 1, string.len(value) do
    local char = string.sub(value, index, index)
    local byte = string.byte(value, index)
    if byte >= 48 and byte <= 57 or char == "+" and index == 1 then
      parts[#parts + 1] = char
    elseif char ~= " " and char ~= "-" then
      return nil
    end
  end
  local phone = table.concat(parts)
  if string.sub(phone, 1, 3) == "+86" then phone = string.sub(phone, 4) end
  if phone == "" then return nil end
  return phone
end

local function number(value, fallback)
  local parsed = tonumber(value)
  if parsed == nil then return fallback or 0 end
  return math.floor(parsed)
end

local function list(value)
  if type(value) == "table" then return value end
  return {}
end

local function field(value, ...)
  if type(value) ~= "table" then return nil end
  for i = 1, select("#", ...) do
    local key = select(i, ...)
    if value[key] ~= nil then return value[key] end
  end
  return nil
end

local function normalize_cookie(value)
  local compact = host.cookie_compact(text(value)) or ""
  local values = {}
  for name in pairs(cookie_names) do
    local item = host.cookie_field(compact, name)
    if item ~= nil then values[name] = item end
  end
  local ordered = {}
  for name, item in pairs(values) do
    ordered[#ordered + 1] = name .. "=" .. item
  end
  table.sort(ordered)
  return table.concat(ordered, "; ")
end

local function save_cookie(value)
  session_cookie = normalize_cookie(value)
  if session_cookie == "" then
    host.storage_set("session_cookie", nil)
  else
    host.storage_set("session_cookie", session_cookie)
  end
end

local function form_encode(value)
  return string.gsub(host.url_encode(text(value)), "%%20", "+")
end

local function form_body(values)
  local keys = {}
  for key in pairs(values) do keys[#keys + 1] = key end
  table.sort(keys)
  local encoded = {}
  for _, key in ipairs(keys) do
    local value = values[key]
    if type(value) == "table" then value = host.json_encode(value) end
    if type(value) == "boolean" then value = value and "true" or "false" end
    encoded[#encoded + 1] = form_encode(key) .. "=" .. form_encode(value)
  end
  return table.concat(encoded, "&")
end

local function csrf()
  return host.cookie_field(session_cookie, "__csrf") or
    host.cookie_field(session_cookie, "__csrf_token") or ""
end

local function crypto(operation, values)
  values.operation = operation
  return host.crypto(values)
end

local function eapi_params(path, payload)
  local json = host.json_encode(payload)
  local digest = crypto("md5", {
    text = "nobody" .. path .. "use" .. json .. "md5forencrypt"
  })
  local value = path .. "-36cd479b6b5-" .. json ..
    "-36cd479b6b5-" .. digest
  return crypto("aes", {
    text = value,
    key = EAPI_KEY,
    mode = "ecb",
    encoding = "hex"
  })
end

local function weapi_params(payload)
  local alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
  local secret = {}
  while #secret < 16 do
    local entropy = host.random_hex(32)
    for i = 1, 32 do
      if #secret >= 16 then break end
      local byte = tonumber(string.sub(entropy, (i - 1) * 2 + 1, i * 2), 16) or 255
      if byte < 248 then
        local index = (byte % 62) + 1
        secret[#secret + 1] = string.sub(alphabet, index, index)
      end
    end
  end
  local key = table.concat(secret)
  local json = host.json_encode(payload)
  local first = crypto("aes", {
    text = json,
    key = WEAPI_KEY,
    mode = "cbc",
    iv = IV
  })
  local second = crypto("aes", {
    text = first,
    key = key,
    mode = "cbc",
    iv = IV
  })
  local enc_sec_key = crypto("rsa_modpow", {
    text = key,
    inputEncoding = "utf8",
    reverse = true,
    modulus = RSA_MODULUS,
    exponent = 65537,
    width = 256
  })
  return { params = second, encSecKey = string.upper(enc_sec_key) }
end

local function checked_response(decoded)
  local code = number(decoded.code, 200)
  if code ~= 200 and code ~= 201 and code ~= 800 and code ~= 801 and code ~= 802 and code ~= 803 then
    error("Gateway code " .. tostring(code), 0)
  end
  return decoded
end

local function request_once(url, path, payload, encoding, options)
  options = options or {}
  local outgoing = {}
  for key, value in pairs(payload or {}) do outgoing[key] = value end
  local body
  if encoding == "weapi" then
    outgoing.csrf_token = csrf()
    local encrypted = weapi_params(outgoing)
    body = form_body(encrypted)
  elseif encoding == "eapi" then
    outgoing.e_r = false
    local os_name = options.desktop and "osx" or options.mobile and "android" or "pc"
    local appver = options.desktop and "3.1.10.5100" or
      options.mobile and "9.5.95" or "3.1.17.204416"
    local osver = options.desktop and "15.5" or
      options.mobile and "14" or "Microsoft-Windows-10-Professional-build-19045-64bit"
    local header = {
      os = os_name,
      appver = appver,
      osver = osver,
      channel = options.mobile and "xiaomi" or "netease",
      __csrf = csrf(),
      requestId = tostring(host.now()) .. "_" .. host.random_hex(4)
    }
    if options.mobile then header.versioncode = "9005095" end
    for _, name in ipairs({ "MUSIC_U", "MUSIC_A", "NMTID", "deviceId" }) do
      local value = host.cookie_field(session_cookie, name)
      if value ~= nil then header[name] = value end
    end
    outgoing.header = header
    body = form_body({ params = string.upper(eapi_params(path, outgoing)) })
  else
    body = form_body(outgoing)
  end

  local headers = {
    ["Accept"] = "application/json",
    ["Cache-Control"] = "no-cache",
    ["Content-Type"] = "application/x-www-form-urlencoded; charset=utf-8",
    ["Referer"] = "https://music.163.com/",
    ["User-Agent"] = options.desktop and
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.5 Safari/605.1.15 NeteaseMusic/3.1.10.5100" or
      "Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Safari/537.36 Chrome/91.0.4472.164 NeteaseMusicDesktop/3.1.29.205117"
  }
  local request_cookie = session_cookie
  if options.mobile then
    request_cookie = (request_cookie ~= "" and request_cookie .. "; " or "") ..
      "os=android; appver=9.5.95; versioncode=9005095"
  elseif options.desktop then
    request_cookie = (request_cookie ~= "" and request_cookie .. "; " or "") ..
      "os=osx; appver=3.1.10.5100; osver=15.5; channel=netease"
  end
  if request_cookie ~= "" then headers.Cookie = request_cookie end

  local response = host.http({
    url = url,
    method = "POST",
    headers = headers,
    body = body
  })
  local status = number(response.status, 0)
  if status < 200 or status >= 300 then error("HTTP " .. tostring(status), 0) end
  local response_headers = response.headers or {}
  local set_cookie = response_headers["set-cookie"] or response_headers["Set-Cookie"] or ""
  if set_cookie ~= "" then save_cookie(host.cookie_merge(session_cookie, set_cookie)) end
  local ok, decoded = pcall(host.json_decode, response.body or "")
  if not ok or type(decoded) ~= "table" then error("INVALID_JSON", 0) end
  return checked_response(decoded)
end

local function route(path, payload, encoding, options)
  options = options or {}
  if encoding == "plain" then
    return request_once(API .. path, path, payload, "plain", options)
  elseif encoding == "weapi" then
    return request_once(API .. "/weapi" .. string.sub(path, 5), path, payload, "weapi", options)
  end
  local domain = options.domain or EAPI
  local epath = string.sub(path, 5)
  local ok, response = pcall(request_once, domain .. "/eapi" .. epath, path, payload, "eapi", options)
  if ok then return response end
  if response ~= "INVALID_JSON" or not options.public_fallback then error(response, 0) end
  -- Several public endpoints occasionally return an empty encrypted response.
  local method = options.public_method or "GET"
  local public_url = API .. path
  local public_body
  if method == "GET" then
    local query = {}
    for key, value in pairs(payload or {}) do
      if type(value) == "table" then value = host.json_encode(value) end
      query[#query + 1] = form_encode(key) .. "=" .. form_encode(value)
    end
    if #query > 0 then public_url = public_url .. "?" .. table.concat(query, "&") end
  else
    public_body = form_body(payload or {})
  end
  local headers = {
    Accept = "application/json",
    Referer = "https://music.163.com/",
    ["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 Chrome/91.0.4472.164 NeteaseMusicDesktop/3.1.29.205117"
  }
  if session_cookie ~= "" then headers.Cookie = session_cookie end
  if public_body ~= nil then headers["Content-Type"] = "application/x-www-form-urlencoded; charset=utf-8" end
  local result = host.http({ url = public_url, method = method, headers = headers, body = public_body })
  if number(result.status, 0) < 200 or number(result.status, 0) >= 300 then
    error("NetEase request failed", 0)
  end
  local decoded_ok, decoded = pcall(host.json_decode, result.body or "")
  if not decoded_ok or type(decoded) ~= "table" then error("INVALID_JSON", 0) end
  return checked_response(decoded)
end

local function weapi(path, payload, fallback, public_method)
  local options = { public_fallback = fallback == true, public_method = public_method }
  local ok, response = pcall(request_once, API .. "/weapi" .. string.sub(path, 5), path, payload, "weapi", options)
  if ok then return response end
  if response ~= "INVALID_JSON" or not options.public_fallback then error(response, 0) end
  local method = options.public_method or "GET"
  local public_url = API .. path
  local public_body
  if method == "GET" then
    local query = {}
    for key, value in pairs(payload or {}) do
      if type(value) == "table" then value = host.json_encode(value) end
      query[#query + 1] = form_encode(key) .. "=" .. form_encode(value)
    end
    if #query > 0 then public_url = public_url .. "?" .. table.concat(query, "&") end
  else
    public_body = form_body(payload or {})
  end
  local headers = {
    Accept = "application/json",
    Referer = "https://music.163.com/",
    ["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 Chrome/91.0.4472.164 NeteaseMusicDesktop/3.1.29.205117"
  }
  if session_cookie ~= "" then headers.Cookie = session_cookie end
  if public_body ~= nil then headers["Content-Type"] = "application/x-www-form-urlencoded; charset=utf-8" end
  local result = host.http({ url = public_url, method = method, headers = headers, body = public_body })
  if number(result.status, 0) < 200 or number(result.status, 0) >= 300 then
    error("NetEase request failed", 0)
  end
  local decoded_ok, decoded = pcall(host.json_decode, result.body or "")
  if not decoded_ok or type(decoded) ~= "table" then error("INVALID_JSON", 0) end
  return checked_response(decoded)
end

local function eapi(path, payload, fallback, options)
  options = options or {}
  options.public_fallback = fallback == true
  return route(path, payload, "eapi", options)
end

local function current_profile(body)
  local data = type(body) == "table" and (type(body.data) == "table" and body.data or body) or nil
  local profile = type(data) == "table" and data.profile or nil
  local account = type(data) == "table" and data.account or nil
  local uid = field(profile, "userId", "id") or field(account, "id")
  if uid == nil or text(uid) == "" or text(uid) == "0" then return nil end
  return {
    id = tostring(uid),
    name = text(field(profile, "nickname") or field(account, "userName") or "网易云用户"),
    avatarUrl = field(profile, "avatarUrl")
  }
end

local function session()
  if session_cookie == "" then current_user = nil; return nil end
  local ok, body = pcall(weapi, "/api/w/nuser/account/get", {}, true)
  if not ok then return nil end
  current_user = current_profile(body)
  return current_user
end

local function require_user()
  if current_user == nil then session() end
  if current_user == nil then error("请先登录网易云音乐账号。", 0) end
  return current_user
end

local function map_artist(value)
  value = type(value) == "table" and value or {}
  return {
    id = text(field(value, "id", "userId") or ""),
    name = text(value.name),
    coverUrl = field(value, "coverUrl", "cover", "picUrl", "img1v1Url", "avatarUrl")
  }
end

local function map_song(value)
  value = type(value) == "table" and value or {}
  local album = field(value, "al", "album") or {}
  local raw_artists = field(value, "ar", "artists")
  local artists = {}
  for _, artist in ipairs(list(raw_artists)) do
    if type(artist) == "table" then artists[#artists + 1] = map_artist(artist) end
  end
  local translated = {}
  for _, name in ipairs(list(field(value, "tns", "transNames"))) do
    if type(name) == "string" and name ~= "" and name ~= value.name then
      translated[#translated + 1] = name
    end
  end
  return {
    id = text(value.id or ""),
    title = text(field(value, "name", "title")),
    artists = artists,
    albumId = text(field(album, "id") or ""),
    albumName = text(field(album, "name") or ""),
    coverUrl = field(album, "picUrl", "coverUrl", "blurPicUrl") or value.coverUrl,
    durationMs = number(field(value, "dt", "duration", "durationMs"), 0),
    translatedTitle = #translated > 0 and table.concat(translated, " / ") or nil,
    starred = value.starred == true,
    contentType = value.contentType,
    suffix = value.suffix,
    bitRate = value.bitRate ~= nil and number(value.bitRate) or nil
  }
end

local function map_album(value)
  value = type(value) == "table" and value or {}
  local raw_artists = value.artists
  if type(raw_artists) ~= "table" then
    raw_artists = type(value.artist) == "table" and { value.artist } or {}
  end
  local artists = {}
  for _, artist in ipairs(raw_artists) do artists[#artists + 1] = map_artist(artist) end
  return {
    id = text(value.id or ""),
    title = text(field(value, "name", "title")),
    artists = artists,
    coverUrl = field(value, "picUrl", "blurPicUrl", "coverUrl"),
    songCount = number(field(value, "size", "trackCount"), 0),
    description = text(value.description),
    year = nil
  }
end

local function map_playlist(value)
  value = type(value) == "table" and value or {}
  local creator = type(value.creator) == "table" and value.creator or {}
  local owner_id = field(creator, "userId")
  local user = current_user
  local writable = value.created == true or
    (owner_id ~= nil and user ~= nil and tostring(owner_id) == tostring(user.id))
  local is_private = value.privacy == 10 or value.privacy == "10" or value.privacy == 1
  return {
    id = text(value.id or ""),
    name = text(value.name),
    description = text(value.description),
    coverUrl = field(value, "coverImgUrl", "picUrl", "coverUrl"),
    songCount = number(field(value, "trackCount", "trackNumber"), 0),
    owner = owner_id ~= nil and tostring(owner_id) or nil,
    writable = writable,
    isPublic = not is_private,
    isFavorites = number(value.specialType, 0) == 5
  }
end

local function page(values, limit, offset)
  local out = {}
  local first = math.max(0, offset or 0) + 1
  local last = math.min(#values, (offset or 0) + limit + 1)
  for i = first, last do out[#out + 1] = values[i] end
  return out
end

local function response_list(body, ...)
  return list(field(body, ...))
end

local function has_timed_lyrics(lrc, yrc)
  local lrc_timed = string.find(lrc, "[", 1, true) ~= nil and
    string.find(lrc, ":", 1, true) ~= nil
  local yrc_timed = string.find(yrc, "[", 1, true) ~= nil and
    string.find(yrc, ",", 1, true) ~= nil
  return lrc_timed or yrc_timed
end

local function ids_json(ids)
  local result = {}
  for _, id in ipairs(ids) do result[#result + 1] = { id = number(id, 0) } end
  return host.json_encode(result)
end

local function details(ids)
  if #ids == 0 then return {} end
  local body = weapi("/api/v3/song/detail", { c = ids_json(ids) }, true, "POST")
  local by_id, ordered = {}, {}
  for _, song in ipairs(response_list(body, "songs")) do by_id[tostring(song.id)] = song end
  for _, id in ipairs(ids) do
    local song = by_id[tostring(id)]
    if song ~= nil then ordered[#ordered + 1] = song end
  end
  return ordered
end

local function playlist_detail(id)
  return eapi("/api/v6/playlist/detail", { id = number(id), n = 100000, s = 8 }, false)
end

local function playlist_track_values(id, offset, limit)
  local body = playlist_detail(id)
  local playlist = type(body.playlist) == "table" and body.playlist or {}
  local tracks = response_list(playlist, "trackIds")
  if #tracks == 0 then return page(response_list(playlist, "tracks"), limit, offset) end
  local ids = {}
  for index = (offset or 0) + 1, math.min(#tracks, (offset or 0) + limit + 1) do
    local track = tracks[index]
    local track_id = type(track) == "table" and track.id or track
    if track_id ~= nil then ids[#ids + 1] = track_id end
  end
  return details(ids)
end

local function map_login(body)
  if type(body.profile) == "table" and body.profile.userId then
    return {
      id = tostring(body.profile.userId),
      name = text(body.profile.nickname or "网易云用户"),
      avatarUrl = body.profile.avatarUrl
    }
  end
  if type(body.account) == "table" and body.account.id then
    return {
      id = tostring(body.account.id),
      name = text(body.account.userName or "网易云用户"),
      avatarUrl = nil
    }
  end
  return current_profile(body)
end

local function attempt_login(callback)
  local previous = session_cookie
  local ok, result = pcall(callback)
  if ok then
    local user = map_login(result)
    if user ~= nil then current_user = user; return user end
  end
  save_cookie(previous)
  current_user = session()
  return nil
end

local function logged_in(body)
  if type(body) ~= "table" then return false end
  local code = number(body.code, 0)
  return code == 200 and map_login(body) ~= nil
end

local function search_type(query, kind, limit, offset, key)
  local body = eapi("/api/cloudsearch/pc", {
    s = query,
    type = kind,
    limit = limit + 1,
    offset = offset,
    total = true
  }, false)
  local result = type(body.result) == "table" and body.result or {}
  local mapped = {}
  for _, item in ipairs(response_list(result, key)) do
    if key == "songs" then mapped[#mapped + 1] = map_song(item)
    elseif key == "albums" then mapped[#mapped + 1] = map_album(item)
    elseif key == "artists" then mapped[#mapped + 1] = map_artist(item)
    elseif key == "playlists" then mapped[#mapped + 1] = map_playlist(item) end
  end
  return mapped
end

local function search(args)
  local query = trim(args.query)
  if query == "" then return { songs = {}, albums = {}, artists = {}, playlists = {} } end
  local limit = math.max(1, math.min(500, number(args.limit, 30)))
  local offset = math.max(0, number(args.offset, 0))
  return {
    songs = search_type(query, 1, limit, offset, "songs"),
    albums = search_type(query, 10, limit, offset, "albums"),
    artists = search_type(query, 100, limit, offset, "artists"),
    playlists = search_type(query, 1000, limit, offset, "playlists")
  }
end

local function require_platform(args)
  if args.platform ~= nil and args.platform ~= "netease" then
    error("Unsupported music platform", 0)
  end
end

local function call(operation, args)
  args = type(args) == "table" and args or {}
  require_platform(args)

  if operation == "describe" then
    return { providers = {
      {
        id = "netease",
        name = "网易云音乐",
        auth = { "qr", "cookie", "password", "sms" },
        capabilities = {
          "search", "browseAlbums", "savedAlbums", "playlists", "editPlaylists",
          "favorites", "lyrics", "scrobble", "recommendations", "comments"
        },
        loginHint = "扫码、手机号或邮箱登录网易云音乐",
        cookieHint = "粘贴网易云音乐 Cookie"
      }
    } }
  elseif operation == "session" then
    return session()
  elseif operation == "loginCookie" then
    return attempt_login(function()
      local candidate = normalize_cookie(args.cookie)
      if candidate == "" then return {} end
      save_cookie(candidate)
      local body = weapi("/api/w/nuser/account/get", {}, true)
      return logged_in(body) and body or {}
    end)
  elseif operation == "loginPassword" then
    return attempt_login(function()
      local account = trim(args.account)
      local password = text(args.password)
      if account == "" or password == "" then return {} end
      local body
      local phone = phone_account(account)
      if phone ~= nil then
        body = weapi("/api/w/login/cellphone", {
          type = "1", https = "true", phone = phone, countrycode = "86",
          remember = "true", password = crypto("md5", { text = password })
        }, false)
      else
        body = weapi("/api/w/login", {
          type = "0", https = "true", username = account,
          password = crypto("md5", { text = password }), rememberLogin = "true"
        }, false)
      end
      if not logged_in(body) then return {} end
      return body
    end)
  elseif operation == "sendCaptcha" then
    local phone = text(args.phone)
    if phone == "" then error("手机号不能为空", 0) end
    local body = eapi("/api/middle/captcha/sent/v1", {
      ctcode = "86", secrete = "music_middleuser_pclogin", cellphone = phone, scene = "0"
    }, false)
    if number(body.code, 0) ~= 200 then error("验证码发送失败", 0) end
    return true
  elseif operation == "loginCaptcha" then
    return attempt_login(function()
      local phone, captcha = text(args.phone), text(args.captcha)
      if phone == "" or captcha == "" then return {} end
      local body = weapi("/api/w/login/cellphone", {
        type = "1", https = "true", phone = phone, countrycode = "86",
        remember = "true", captcha = captcha
      }, false)
      if not logged_in(body) then return {} end
      return body
    end)
  elseif operation == "qrKey" then
    local body = route("/api/login/qrcode/unikey", { type = 3 }, "plain")
    local data = type(body.data) == "table" and body.data or body
    return text(data.unikey)
  elseif operation == "qrUrl" then
    local key = text(args.key)
    if key == "" then return "" end
    return API .. "/login?codekey=" .. form_encode(key)
  elseif operation == "qrCheck" then
    local body = route("/api/login/qrcode/client/login", {
      key = text(args.key), type = 3, secureCaptcha = text(args.secureCaptcha)
    }, "plain")
    return number(body.code, 0)
  elseif operation == "logout" then
    pcall(weapi, "/api/logout", {}, false)
    save_cookie("")
    current_user = nil
    return true
  elseif operation == "search" then
    return search(args)
  elseif operation == "song" then
    local body = weapi("/api/v3/song/detail", {
      c = ids_json({ args.id })
    }, true, "POST")
    local songs = response_list(body, "songs")
    if #songs == 0 then error("歌曲不存在", 0) end
    return map_song(songs[1])
  elseif operation == "album" then
    local id = number(args.id)
    local body = weapi("/api/v1/album/" .. id, {}, true)
    local album = type(body.album) == "table" and body.album or nil
    if album == nil then error("专辑不存在", 0) end
    return map_album(album)
  elseif operation == "albumSongs" then
    local id = number(args.id)
    local limit = math.max(1, math.min(500, number(args.limit, 100)))
    local offset = math.max(0, number(args.offset, 0))
    local body = weapi("/api/v1/album/" .. id, {}, true)
    local songs = {}
    for _, item in ipairs(response_list(body, "songs")) do songs[#songs + 1] = map_song(item) end
    return page(songs, limit, offset)
  elseif operation == "albums" then
    local limit = math.max(1, math.min(500, number(args.limit, 30)))
    local offset = math.max(0, number(args.offset, 0))
    local body = weapi("/api/album/new", { area = "ALL", limit = limit + 1, offset = offset, total = true }, true)
    local albums = {}
    for _, item in ipairs(response_list(body, "albums")) do albums[#albums + 1] = map_album(item) end
    return albums
  elseif operation == "savedAlbums" then
    require_user()
    local limit = math.max(1, math.min(500, number(args.limit, 30)))
    local offset = math.max(0, number(args.offset, 0))
    local body = weapi("/api/album/sublist", { limit = limit + 1, offset = offset, total = true }, false)
    local albums = {}
    for _, item in ipairs(response_list(body, "data", "albums")) do albums[#albums + 1] = map_album(item) end
    return albums
  elseif operation == "artist" then
    local id = number(args.id)
    local body = eapi("/api/artist/head/info/get", { id = id }, false)
    local data = type(body.data) == "table" and body.data or {}
    local raw = type(data.artist) == "table" and data.artist or body.artist or {}
    return map_artist(raw)
  elseif operation == "artistAlbums" then
    local id = number(args.id)
    local limit = math.max(1, math.min(500, number(args.limit, 30)))
    local offset = math.max(0, number(args.offset, 0))
    local body = weapi("/api/artist/albums/" .. id, { limit = limit + 1, offset = offset, total = true }, false)
    local albums = {}
    for _, item in ipairs(response_list(body, "hotAlbums")) do albums[#albums + 1] = map_album(item) end
    return albums
  elseif operation == "playlists" then
    local user = require_user()
    local limit = math.max(1, math.min(500, number(args.limit, 30)))
    local offset = math.max(0, number(args.offset, 0))
    local body = weapi("/api/user/playlist", {
      uid = user.id, limit = limit + 1, offset = offset, includeVideo = true
    }, true)
    local playlists = {}
    for _, item in ipairs(response_list(body, "playlist")) do playlists[#playlists + 1] = map_playlist(item) end
    return playlists
  elseif operation == "playlist" then
    local body = playlist_detail(args.id)
    if type(body.playlist) ~= "table" then error("歌单不存在", 0) end
    return map_playlist(body.playlist)
  elseif operation == "playlistSongs" then
    local limit = math.max(1, math.min(500, number(args.limit, 100)))
    local offset = math.max(0, number(args.offset, 0))
    local songs = playlist_track_values(args.id, offset, limit)
    local mapped = {}
    for _, song in ipairs(songs) do mapped[#mapped + 1] = map_song(song) end
    return mapped
  elseif operation == "createPlaylist" then
    require_user()
    local name = trim(args.name)
    if name == "" or string.len(name) > 120 then error("歌单名称无效", 0) end
    local body = weapi("/api/playlist/create", {
      name = name, privacy = args.isPublic == true and "0" or "10", type = "NORMAL"
    }, false)
    local data = type(body.data) == "table" and body.data or {}
    local raw = body.playlist or data.playlist
    if type(raw) == "table" then return map_playlist(raw) end
    local id = body.id or body.playlistId or data.id or data.playlistId
    if id == nil then error("创建歌单失败", 0) end
    return {
      id = tostring(id), name = name, description = "", coverUrl = nil,
      songCount = 0, owner = current_user.id, writable = true,
      isPublic = args.isPublic == true, isFavorites = false
    }
  elseif operation == "addToPlaylist" then
    local ids = {}
    for _, id in ipairs(list(args.songs)) do ids[#ids + 1] = number(id) end
    if #ids == 0 then return true end
    local serialized_ids = {}
    for _, id in ipairs(ids) do serialized_ids[#serialized_ids + 1] = tostring(id) end
    weapi("/api/playlist/manipulate/tracks", {
      op = "add", pid = number(args.playlist), trackIds = "[" .. table.concat(serialized_ids, ",") .. "]", imme = "true"
    }, false)
    return true
  elseif operation == "removeFromPlaylist" then
    local detail = playlist_detail(args.playlist)
    local raw = type(detail.playlist) == "table" and detail.playlist or {}
    local track_ids = {}
    for _, item in ipairs(response_list(raw, "trackIds")) do
      track_ids[#track_ids + 1] = type(item) == "table" and item.id or item
    end
    local removals = {}
    local indexes = list(args.indexes)
    if #indexes == 0 then error("未选择歌单歌曲", 0) end
    for _, index in ipairs(indexes) do
      local position = number(index) + 1
      if track_ids[position] == nil then error("歌单位置超出范围", 0) end
      removals[#removals + 1] = track_ids[position]
    end
    for _, song_id in ipairs(removals) do
      local occurrences = 0
      for _, track_id in ipairs(track_ids) do
        if tostring(track_id) == tostring(song_id) then occurrences = occurrences + 1 end
      end
      if occurrences > 1 then error("网易云无法按位置删除重复歌曲", 0) end
    end
    if #removals > 0 then
      weapi("/api/playlist/manipulate/tracks", {
        op = "del", pid = number(args.playlist), trackIds = host.json_encode(removals), imme = "true"
      }, false)
    end
    return true
  elseif operation == "favorites" then
    local user = require_user()
    local body = eapi("/api/song/like/get", { uid = number(user.id) }, false)
    local ids = response_list(body, "ids")
    local limit = math.max(1, math.min(500, number(args.limit, 100)))
    local offset = math.max(0, number(args.offset, 0))
    local selected = {}
    for i = offset + 1, math.min(#ids, offset + limit + 1) do selected[#selected + 1] = ids[i] end
    local songs = details(selected)
    local mapped = {}
    for _, song in ipairs(songs) do
      local value = map_song(song); value.starred = true; mapped[#mapped + 1] = value
    end
    return mapped
  elseif operation == "setFavorite" then
    local user = require_user()
    eapi("/api/song/like", {
      trackId = number(args.id), userid = number(user.id), like = args.favorite == true
    }, false)
    return true
  elseif operation == "stream" then
    local quality = text(args.quality)
    local level = ({ original = "lossless", high = "exhigh", medium = "higher", low = "standard" })[quality] or "lossless"
    local body = weapi("/api/song/enhance/player/url", {
      ids = "[" .. number(args.id) .. "]",
      br = ({ lossless = 999000, exhigh = 320000, higher = 192000, standard = 128000 })[level]
    }, true)
    local data = response_list(body, "data")
    local item = data[1] or {}
    local url = text(item.url)
    if string.sub(url, 1, 7) == "http://" then url = "https://" .. string.sub(url, 8) end
    if url == "" then error("歌曲暂无可用音源", 0) end
    local suffix = text(item.type)
    return {
      url = url,
      contentType = suffix ~= "" and ("audio/" .. suffix) or nil,
      suffix = suffix,
      bitRate = number(item.br, nil),
      size = number(item.size, nil),
      transcoded = false
    }
  elseif operation == "lyrics" then
    local id = number(args.id)
    local body
    local ok, value = pcall(eapi, "/api/song/lyric/v1", {
      id = id, cp = false, tv = 0, lv = 0, rv = 0, kv = 0,
      yv = 0, ytv = 0, yrv = 0
    }, false)
    if ok then body = value end
    local function lyric_text(value)
      return type(value) == "table" and text(value.lyric) or ""
    end
    local lrc = body and lyric_text(body.lrc) or ""
    local yrc = body and lyric_text(body.yrc) or ""
    local translation = body and (lyric_text(body.tlyric) ~= "" and lyric_text(body.tlyric) or lyric_text(body.ytlrc)) or ""
    local timed = has_timed_lyrics(lrc, yrc)
    if body == nil or (not body.pureMusic and not timed and lrc == "" and yrc == "") then
      local fallback = eapi("/api/song/lyric", { id = id, tv = -1, lv = -1, rv = -1, kv = -1, _nmclfl = 1 }, false)
      body = fallback
      lrc = lyric_text(body.lrc)
      yrc = lyric_text(body.yrc)
      translation = lyric_text(body.tlyric)
      if translation == "" then translation = lyric_text(body.ytlrc) end
      timed = has_timed_lyrics(lrc, yrc)
    end
    if body and (body.pureMusic == true or body.nolyric == true) then return {} end
    if lrc == "" and yrc == "" then error("歌词暂时不可用", 0) end
    return {{ lrc = lrc, wordByWord = yrc, translation = translation, synced = timed, offsetMs = 0 }}
  elseif operation == "comments" then
    local id = number(args.id)
    local body = weapi("/api/v1/resource/comments/R_SO_4_" .. id, {
      rid = id, limit = math.max(1, math.min(100, number(args.limit, 20))),
      offset = math.max(0, number(args.offset, 0)), beforeTime = 0
    }, false)
    local function mapped_comments(values)
      local result = {}
      for _, value in ipairs(list(values)) do
        local user = type(value.user) == "table" and value.user or {}
        local replies = {}
        for _, reply in ipairs(list(value.beReplied)) do
          replies[#replies + 1] = { author = text(field(reply.user, "nickname")), content = text(reply.content) }
        end
        result[#result + 1] = {
          id = number(value.commentId), content = text(value.content), author = text(user.nickname),
          userId = number(user.userId), avatarUrl = user.avatarUrl, time = number(value.time),
          liked = value.liked == true, likedCount = number(value.likedCount),
          location = field(value.ipLocation, "location"), replies = replies
        }
      end
      return result
    end
    return { total = number(body.total), more = body.more == true,
      hot = mapped_comments(body.hotComments), latest = mapped_comments(body.comments) }
  elseif operation == "setCommentLiked" then
    require_user()
    weapi("/api/v1/comment/" .. (args.liked == true and "like" or "unlike"), {
      threadId = "R_SO_4_" .. number(args.id), commentId = number(args.commentId)
    }, false)
    return true
  elseif operation == "scrobble" then
    local user = require_user()
    local played = number(args.playedMs, 0)
    local action, data
    if args.submission == false then
      action = "startplay"
      data = {
        id = number(args.id), type = "song", mainsite = "1", mainsiteWeb = "1", content = "id=0"
      }
    else
      if played <= 0 then return true end
      action = "play"
      data = {
        download = 0, finish = 0, endMarker = "playend", id = number(args.id),
        sourceId = "0", time = math.floor(played / 1000), type = "song", wifi = 0,
        source = "list", mainsite = "1", mainsiteWeb = "1", content = "id=0"
      }
      data["end"] = "playend"
      data.endMarker = nil
    end
    local logs = {{ action = action, json = data }}
    eapi("/api/feedback/weblog", { logs = host.json_encode(logs) }, false, { domain = CLIENT_LOG, desktop = true })
    return true
  elseif operation == "playStats" then
    local user = require_user()
    local body = weapi("/api/v1/play/record", { uid = number(user.id), type = "0" }, true)
    local rows = response_list(body, "allData")
    local records = {}
    for _, item in ipairs(rows) do
      if type(item.song) == "table" then
        records[#records + 1] = { song = map_song(item.song), playCount = number(item.playCount, 0) }
      end
    end
    local limit = math.max(1, math.min(500, number(args.limit, 100)))
    return { records = page(records, limit, math.max(0, number(args.offset, 0))) }
  elseif operation == "recommendations" then
    require_user()
    local body = weapi("/api/v3/discovery/recommend/songs", {}, true)
    local data = type(body.data) == "table" and body.data or {}
    local songs = {}
    for _, item in ipairs(response_list(data, "dailySongs")) do songs[#songs + 1] = map_song(item) end
    if #songs == 0 then
      for _, item in ipairs(response_list(body, "recommend")) do songs[#songs + 1] = map_song(item) end
    end
    local limit = math.max(1, math.min(500, number(args.limit, 30)))
    return page(songs, limit, 0)
  end

  error("Unsupported operation: " .. text(operation), 0)
end

return { call = call }
