-- Mockwave fixture catalogue.
--
-- Everything in this file is synthetic and deterministic: no network, no
-- third-party metadata, no cover URLs. The client renders its own artwork, so
-- the example works with no network permission at all.
--
-- Returned tables use the JSON-shaped models documented at
-- https://lazer.naominet.dev/docs (docs/lua-plugins.md in the app repo).

local M = {}

M.durationMs = 24000

local ARTISTS = {
  { id = "ar-aster", name = "Aster Vale",
    description = "Mock artist: warm synths, slow drums, harbour weather.", albumCount = 2 },
  { id = "ar-kite", name = "Kite Machine",
    description = "Mock artist: tape loops recorded on the last bus.", albumCount = 2 },
  { id = "ar-lumen", name = "Lumen Field",
    description = "Mock artist: quiet machines and amber light.", albumCount = 2 },
}

local ALBUMS = {
  { id = "al-signal", title = "Signal Bloom", artistId = "ar-aster", year = 2024,
    description = "Three sketches about harbours and radio weather." },
  { id = "al-transit", title = "Night Transit", artistId = "ar-kite", year = 2023,
    description = "Night buses, terminal lights and tape hiss." },
  { id = "al-orbit", title = "Slow Orbit", artistId = "ar-lumen", year = 2025,
    description = "Small rooms moving at a very low speed." },
  { id = "al-garden", title = "Static Garden", artistId = "ar-lumen", year = 2022,
    description = "A mock compilation: noise planted like flowers." },
}

local TRACKS = {
  { id = "s01", title = "Glass Harbor", translatedTitle = "玻璃港湾",
    artistIds = { "ar-aster" }, albumId = "al-signal", lyrics = "signal" },
  { id = "s02", title = "Paper Satellites", translatedTitle = "纸卫星",
    artistIds = { "ar-aster" }, albumId = "al-signal", lyrics = "signal" },
  { id = "s03", title = "Low Tide Radio", translatedTitle = "低潮电台",
    artistIds = { "ar-aster" }, albumId = "al-signal", lyrics = "signal" },
  { id = "s04", title = "Night Transit", translatedTitle = "夜行列车",
    artistIds = { "ar-kite" }, albumId = "al-transit", lyrics = "transit" },
  { id = "s05", title = "Terminal Lights", translatedTitle = "航站楼灯光",
    artistIds = { "ar-kite" }, albumId = "al-transit", lyrics = "transit" },
  { id = "s06", title = "Last Bus Home", translatedTitle = "末班巴士",
    artistIds = { "ar-kite" }, albumId = "al-transit", lyrics = "transit" },
  { id = "s07", title = "Slow Orbit", translatedTitle = "缓慢轨道",
    artistIds = { "ar-lumen" }, albumId = "al-orbit", lyrics = "orbit" },
  { id = "s08", title = "Amber Hours", translatedTitle = "琥珀时刻",
    artistIds = { "ar-lumen" }, albumId = "al-orbit", lyrics = "orbit" },
  { id = "s09", title = "Quiet Machines", translatedTitle = "安静的机器",
    artistIds = { "ar-lumen" }, albumId = "al-orbit", lyrics = "orbit" },
  { id = "s10", title = "Copper Rain", translatedTitle = "铜色雨",
    artistIds = { "ar-lumen", "ar-aster" }, albumId = "al-garden", lyrics = "garden" },
  { id = "s11", title = "Soft Static", translatedTitle = "柔软静电",
    artistIds = { "ar-kite" }, albumId = "al-garden", lyrics = "garden" },
  { id = "s12", title = "Static Garden", translatedTitle = "静电花园",
    artistIds = { "ar-lumen", "ar-kite" }, albumId = "al-garden", lyrics = "garden" },
}

local PLAYLISTS = {
  { id = "pl-night", name = "Late Night Drive",
    description = "Headlights, empty roads and one long bridge.",
    songIds = { "s04", "s05", "s01", "s10", "s11" } },
  { id = "pl-focus", name = "Focus Loop",
    description = "Four tracks that do not ask for attention.",
    songIds = { "s07", "s08", "s09", "s02" } },
  { id = "pl-rain", name = "Rainy Window",
    description = "Static, copper rain and a kettle in the next room.",
    songIds = { "s10", "s11", "s12", "s03", "s06" } },
  { id = "pl-start", name = "Starter Pack",
    description = "The whole mock catalogue in one list.",
    songIds = { "s01", "s02", "s03", "s04", "s05", "s06",
                "s07", "s08", "s09", "s10", "s11", "s12" } },
}

local CHARTS = {
  { id = "chart-week", name = "本周循环 Top 8",
    description = "Mock chart: the eight busiest tracks this week.",
    songIds = { "s01", "s04", "s07", "s10", "s02", "s05", "s08", "s11" } },
  { id = "chart-new", name = "新到货",
    description = "Mock chart: four recent additions.",
    songIds = { "s12", "s09", "s06", "s03" } },
}

-- [startMs, text, translation, romanization]; all lyrics are original.
local LYRICS = {
  signal = {
    { 0, "海面把信号折成光", "The sea folds the signal into light",
      "hǎi miàn bǎ xìn hào zhé chéng guāng" },
    { 3400, "我们在港口等一场慢雨", "We wait for a slow rain at the harbour",
      "wǒ men zài gǎng kǒu děng yī chǎng màn yǔ" },
    { 6800, "天线把夜色拉得很长", "The antenna stretches the night out long",
      "tiān xiàn bǎ yè sè lā de hěn cháng" },
    { 10200, "你说远方只是另一种频率", "You say the distance is just another frequency",
      "nǐ shuō yuǎn fāng zhǐ shì lìng yī zhǒng pín lǜ" },
    { 13600, "于是我把灯留在窗上", "So I leave the light on the window",
      "yú shì wǒ bǎ dēng liú zài chuāng shàng" },
    { 17000, "等回声慢慢靠岸", "Waiting for the echo to come ashore",
      "děng huí shēng màn màn kào àn" },
    { 20400, "玻璃港湾，晚安", "Glass harbour, good night",
      "bō lí gǎng wān wǎn ān" },
  },
  transit = {
    { 0, "末班车穿过城市背面", "The last bus crosses the back of the city",
      "mò bān chē chuān guò chéng shì bèi miàn" },
    { 3200, "窗外的灯像倒放的星", "Lights outside run backwards like stars",
      "chuāng wài de dēng xiàng dào fàng de xīng" },
    { 6400, "每一站都有人轻轻告别", "Someone says goodbye softly at every stop",
      "měi yī zhàn dōu yǒu rén qīng qīng gào bié" },
    { 9600, "广播说终点还很远", "The announcement says the terminus is far away",
      "guǎng bō shuō zhōng diǎn hái hěn yuǎn" },
    { 12800, "我把额头靠在夜上", "I rest my forehead against the night",
      "wǒ bǎ é tóu kào zài yè shàng" },
    { 16000, "下一站，仍然是你", "Next stop: still you",
      "xià yī zhàn réng rán shì nǐ" },
    { 19200, "夜行列车，别停", "Night train, do not stop",
      "yè xíng liè chē bié tíng" },
  },
  orbit = {
    { 0, "我们把日子调成慢速", "We set the days to slow motion",
      "wǒ men bǎ rì zi tiáo chéng màn sù" },
    { 3600, "让尘埃绕过房间", "Let the dust orbit the room",
      "ràng chén āi rào guò fáng jiān" },
    { 7200, "一颗星系在台灯上", "A star is tied to the desk lamp",
      "yī kē xīng xì zài tái dēng shàng" },
    { 10800, "转一圈需要一整年", "One turn takes a whole year",
      "zhuǎn yī quān xū yào yī zhěng nián" },
    { 14400, "别急着回到地面", "No need to hurry back to the ground",
      "bié jí zhe huí dào dì miàn" },
    { 18000, "缓慢轨道，正好", "A slow orbit is just right",
      "huǎn màn guǐ dào zhèng hǎo" },
  },
  garden = {
    { 0, "旧磁带在土里发芽", "Old tapes sprout in the soil",
      "jiù cí dài zài tǔ lǐ fā yá" },
    { 4000, "长出柔软的静电", "Growing a soft static",
      "zhǎng chū róu ruǎn de jìng diàn" },
    { 8000, "我们把噪音种成花", "We plant the noise into flowers",
      "wǒ men bǎ zào yīn zhòng chéng huā" },
    { 12000, "等一场无声的雨", "Waiting for a silent rain",
      "děng yī chǎng wú shēng de yǔ" },
    { 16000, "静电花园，无人看守", "Static garden, unguarded",
      "jìng diàn huā yuán wú rén kān shǒu" },
    { 20000, "风一吹，就亮起来", "One breath of wind and it lights up",
      "fēng yī chuī jiù liàng qǐ lái" },
  },
}

local artistById, albumById, trackById = {}, {}, {}
local playlistById, chartById = {}, {}
local tracksByAlbum, tracksByArtist = {}, {}

for _, artist in ipairs(ARTISTS) do artistById[artist.id] = artist end
for _, album in ipairs(ALBUMS) do albumById[album.id] = album; tracksByAlbum[album.id] = {} end
for _, playlist in ipairs(PLAYLISTS) do playlistById[playlist.id] = playlist end
for _, chart in ipairs(CHARTS) do chartById[chart.id] = chart end
for _, track in ipairs(TRACKS) do
  trackById[track.id] = track
  tracksByAlbum[track.albumId][#tracksByAlbum[track.albumId] + 1] = track
  for _, artistId in ipairs(track.artistIds) do
    tracksByArtist[artistId] = tracksByArtist[artistId] or {}
    tracksByArtist[artistId][#tracksByArtist[artistId] + 1] = track
  end
end

local function lower(value)
  return string.lower(tostring(value or ""))
end

local function contains(haystack, needle)
  if needle == "" then return true end
  return string.find(lower(haystack), needle, 1, true) ~= nil
end

local function paginate(items, offset, limit)
  offset = math.max(0, math.floor(tonumber(offset) or 0))
  limit = math.max(1, math.min(200, math.floor(tonumber(limit) or 50)))
  local out = {}
  local last = math.min(#items, offset + limit)
  for index = offset + 1, last do out[#out + 1] = items[index] end
  return out
end

function M.artistModel(id)
  local artist = artistById[id]
  if not artist then return nil end
  return {
    id = artist.id,
    name = artist.name,
    description = artist.description,
    albumCount = artist.albumCount,
  }
end

function M.albumModel(id)
  local album = albumById[id]
  if not album then return nil end
  local artists = {}
  local artist = M.artistModel(album.artistId)
  if artist then artists[1] = artist end
  return {
    id = album.id,
    title = album.title,
    artists = artists,
    year = album.year,
    songCount = #tracksByAlbum[album.id],
    description = album.description,
  }
end

function M.songModel(track)
  if not track then return nil end
  local artists = {}
  for _, artistId in ipairs(track.artistIds) do
    local artist = M.artistModel(artistId)
    if artist then artists[#artists + 1] = artist end
  end
  local album = albumById[track.albumId]
  return {
    id = track.id,
    title = track.title,
    translatedTitle = track.translatedTitle,
    artists = artists,
    albumId = track.albumId,
    albumName = album and album.title or "",
    durationMs = M.durationMs,
    bitRate = 128000,
    suffix = "wav",
    contentType = "audio/wav",
  }
end

function M.playlistModel(playlist)
  return {
    id = playlist.id,
    name = playlist.name,
    description = playlist.description,
    songCount = #playlist.songIds,
    owner = "mockwave",
    writable = false,
    isPublic = true,
  }
end

function M.favoritesModel(user, likedIds)
  return {
    id = "liked",
    name = (user and user.name or "Mockwave") .. "喜欢的音乐",
    description = "Mockwave 本地收藏；数据保存在插件存储里。",
    songCount = #(likedIds or {}),
    owner = user and user.id or "mockwave",
    writable = true,
    isFavorites = true,
  }
end

function M.artistSongs(artistId)
  local out = {}
  for _, track in ipairs(tracksByArtist[artistId] or {}) do
    out[#out + 1] = M.songModel(track)
  end
  return out
end

function M.albumSongs(albumId)
  local out = {}
  for _, track in ipairs(tracksByAlbum[albumId] or {}) do
    out[#out + 1] = M.songModel(track)
  end
  return out
end

function M.albumModels()
  local out = {}
  for _, album in ipairs(ALBUMS) do out[#out + 1] = M.albumModel(album.id) end
  return out
end

function M.artistAlbums(artistId)
  local out = {}
  for _, album in ipairs(ALBUMS) do
    if album.artistId == artistId then out[#out + 1] = M.albumModel(album.id) end
  end
  return out
end

function M.track(id)
  return trackById[id]
end

function M.tracks()
  return TRACKS
end

function M.modelsForIds(ids)
  local out = {}
  for _, id in ipairs(ids or {}) do
    local model = M.songModel(trackById[id])
    if model then out[#out + 1] = model end
  end
  return out
end

function M.playlistSongModels(id, likedIds)
  if id == "liked" then return M.modelsForIds(likedIds) end
  local playlist = playlistById[id] or chartById[id]
  if not playlist then return {} end
  return M.modelsForIds(playlist.songIds)
end

function M.playlist(id, user, likedIds)
  if id == "liked" then return M.favoritesModel(user, likedIds) end
  local playlist = playlistById[id]
  if playlist then return M.playlistModel(playlist) end
  local chart = chartById[id]
  if chart then
    return {
      id = chart.id,
      name = chart.name,
      description = chart.description,
      songCount = #chart.songIds,
      owner = "mockwave",
      writable = false,
      isPublic = true,
    }
  end
  return nil
end

function M.publicPlaylists()
  local out = {}
  for _, playlist in ipairs(PLAYLISTS) do out[#out + 1] = M.playlistModel(playlist) end
  return out
end

function M.variant(trackId)
  local sum = 0
  trackId = tostring(trackId or "")
  for index = 1, string.len(trackId) do
    sum = (sum + string.byte(trackId, index) * index) % 997
  end
  return (sum % 4) + 1
end

function M.userPlaylists(user, likedIds)
  local out = { M.favoritesModel(user, likedIds) }
  for _, playlist in ipairs(PLAYLISTS) do out[#out + 1] = M.playlistModel(playlist) end
  return out
end

function M.chartModels()
  local out = {}
  for _, chart in ipairs(CHARTS) do
    out[#out + 1] = {
      id = chart.id,
      name = chart.name,
      description = chart.description,
      songCount = #chart.songIds,
      owner = "mockwave",
      writable = false,
      isPublic = true,
    }
  end
  return out
end

function M.search(query, offset, limit)
  local needle = lower(query)
  local songs, albums, artists, playlists = {}, {}, {}, {}

  for _, track in ipairs(TRACKS) do
    local album = albumById[track.albumId]
    local haystack = table.concat({
      track.title, track.translatedTitle, album and album.title or "",
    }, " ")
    for _, artistId in ipairs(track.artistIds) do
      haystack = haystack .. " " .. artistById[artistId].name
    end
    if contains(haystack, needle) then songs[#songs + 1] = M.songModel(track) end
  end
  for _, artist in ipairs(ARTISTS) do
    if contains(artist.name .. " " .. artist.description, needle) then
      artists[#artists + 1] = M.artistModel(artist.id)
    end
  end
  for _, album in ipairs(ALBUMS) do
    local artist = artistById[album.artistId]
    if contains(album.title .. " " .. album.description .. " " .. artist.name, needle) then
      albums[#albums + 1] = M.albumModel(album.id)
    end
  end
  for _, playlist in ipairs(PLAYLISTS) do
    if contains(playlist.name .. " " .. playlist.description, needle) then
      playlists[#playlists + 1] = M.playlistModel(playlist)
    end
  end

  return {
    songs = paginate(songs, offset, limit),
    albums = paginate(albums, offset, limit),
    artists = paginate(artists, offset, limit),
    playlists = paginate(playlists, offset, limit),
  }
end

function M.radio(kind, seed, limit)
  limit = math.max(1, math.min(100, math.floor(tonumber(limit) or 30)))
  local pool = TRACKS
  if kind == "artist" and seed then
    pool = tracksByArtist[seed] or {}
  elseif kind == "heart" then
    pool = { TRACKS[1], TRACKS[4], TRACKS[7], TRACKS[10], TRACKS[11] }
  end
  local out = {}
  for index = 1, math.min(limit, #pool) do out[#out + 1] = M.songModel(pool[index]) end
  return out
end

function M.lyrics(trackId)
  local track = trackById[trackId]
  if not track then return {} end
  local lines = {}
  for _, line in ipairs(LYRICS[track.lyrics] or {}) do
    lines[#lines + 1] = {
      text = line[2],
      startMs = line[1],
      translation = line[3],
      romanization = line[4],
    }
  end
  return { { synced = true, lines = lines } }
end

function M.home(user, likedIds)
  local signal = M.albumSongs("al-signal")
  local quick = {}
  for index, trackId in ipairs({ "s01", "s04", "s07", "s10" }) do
    quick[index] = M.songModel(trackById[trackId])
  end
  local daily = {}
  for index, trackId in ipairs({ "s02", "s05", "s08", "s11" }) do
    daily[index] = M.songModel(trackById[trackId])
  end
  local recommended = {
    M.playlistModel(playlistById["pl-night"]),
    M.playlistModel(playlistById["pl-focus"]),
    M.playlistModel(playlistById["pl-rain"]),
  }
  return {
    featured = M.albumModel("al-signal"),
    featuredSongs = signal,
    quick = quick,
    daily = daily,
    recommended = recommended,
    playlists = user and M.userPlaylists(user, likedIds) or M.publicPlaylists(),
    albums = M.albumModels(),
    editorialPlaylists = M.chartModels(),
  }
end

return M