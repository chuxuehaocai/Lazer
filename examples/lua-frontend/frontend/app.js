'use strict';
const client = new LazerClient();
const $ = id => document.getElementById(id);
// Lua has one table type: empty arrays round-trip as empty JSON objects.
const list = value => Array.isArray(value) ? value : [];
let connected = false, busy = false, libraryQuery = null, offset = 0;
let queueSignature = '', lyricsSignature = '', lyricNodes = [], lyricTimes = [];

function notice(message) { $('notice').textContent = message; }
function reset() {
  connected = false;
  $('workspace').hidden = true;
  $('connection-status').textContent = '未连接';
  for (const id of ['library', 'queue', 'lyrics', 'user-data']) $(id).replaceChildren();
  queueSignature = lyricsSignature = '';
  lyricNodes = []; lyricTimes = [];
}
async function task(action) {
  if (busy) return;
  busy = true;
  try { await action(); }
  catch (error) { notice(error.message); }
  finally { busy = false; }
}
function row(title, subtitle, action, active = false) {
  const button = document.createElement('button');
  button.textContent = title || '未命名';
  const small = document.createElement('small');
  small.textContent = subtitle || '';
  button.append(small);
  button.classList.toggle('active', active);
  button.addEventListener('click', () => task(action));
  return button;
}
function time(ms) {
  const seconds = Math.floor(Math.max(0, Number(ms) || 0) / 1000);
  return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, '0')}`;
}
async function refresh() {
  const state = await client.request('state');
  const track = state.track;
  $('now-title').textContent = track?.title || '暂未播放';
  $('artist').textContent = [track?.artist, track?.album].filter(Boolean).join(' · ');
  $('toggle').textContent = state.state === 'playing' ? '暂停' : '播放';
  $('time').textContent = `${time(state.positionMs)} / ${time(state.durationMs)}`;
  if (document.activeElement !== $('seek')) $('seek').value = Math.round((state.progress || 0) * 1000);
  if (document.activeElement !== $('volume')) $('volume').value = Math.round((state.volume ?? 1) * 100);
  $('shuffle').textContent = `随机：${state.shuffle ? '开' : '关'}`;
  $('repeat').value = state.repeat || 'off';
  const cover = track?.coverUrl;
  const safeCover = typeof cover === 'string' && /^https?:\/\//i.test(cover);
  $('cover').hidden = !safeCover;
  $('cover-placeholder').hidden = safeCover;
  if (safeCover && $('cover').getAttribute('src') !== cover) $('cover').src = cover;
  if (!safeCover) $('cover').removeAttribute('src');
  const queue = await client.request('queue');
  const signature = JSON.stringify(queue);
  if (signature !== queueSignature) {
    queueSignature = signature;
    $('queue').replaceChildren(...list(queue.tracks).map((item, index) =>
      row(item.title, item.artist, () => control('play_index', {index}), index === queue.index)));
  }
  const lyrics = await client.request('lyrics');
  const newLyrics = JSON.stringify(list(lyrics.lines));
  if (newLyrics !== lyricsSignature) {
    lyricsSignature = newLyrics;
    lyricTimes = list(lyrics.lines).map(line => line.startTime ?? line.time);
    lyricNodes = list(lyrics.lines).map(line => {
      const node = document.createElement('p'); node.textContent = line.text;
      if (line.translation) { const translation = document.createElement('small'); translation.textContent = line.translation; node.append(translation); }
      return node;
    });
    $('lyrics').replaceChildren(...lyricNodes);
  }
  const index = lyricTimes.findLastIndex(start => start <= state.positionMs);
  lyricNodes.forEach((node, i) => {
    const newlyActive = i === index && !node.classList.contains('active');
    node.classList.toggle('active', i === index);
    if (newlyActive) $('lyrics').scrollTop = node.offsetTop - $('lyrics').offsetTop - 80;
  });
}
async function control(command, args = {}) {
  await client.request('player', {...args, command});
  await refresh();
}
async function library(query, append = false) {
  notice('正在读取；如出现授权提示，请在 Lazer 中确认。');
  if (!append) { libraryQuery = query; offset = 0; $('library').replaceChildren(); }
  const result = await client.request('library', {...query, offset, limit: 50});
  const page = query.operation === 'search' ? result.tracks : result;
  const items = list(page.items);
  for (const item of items) {
    const playlist = query.operation === 'playlists';
    $('library').append(row(playlist ? item.name : item.title,
      playlist ? `${item.trackCount ?? 0} 首 · 点击查看` : item.artist,
      async () => {
        if (playlist) await library({operation: 'tracks', id: item.id});
        else {
          await client.request('library', {operation: 'play', kind: 'song', id: item.id});
          await refresh();
        }
      }));
  }
  offset += items.length;
  $('more').hidden = !page.hasMore;
  notice(`已读取 ${offset} / ${page.total} 项`);
}

$('connect-form').addEventListener('submit', event => {
  event.preventDefault();
  task(async () => {
    reset();
    notice('连接中…');
    const token = $('token').value.trim();
    $('token').value = '';
    await client.connect($('address').value.trim(), token);
    connected = true;
    $('workspace').hidden = false;
    $('connection-status').textContent = '已连接 · 本地 Lua';
    notice('已连接。账号、歌单和播放记录仅在主动访问时请求授权。');
    await refresh();
  });
});
$('disconnect').onclick = () => { client.close(); reset(); notice('已断开连接。'); };
for (const button of document.querySelectorAll('[data-command]')) button.onclick = () => task(() => control(button.dataset.command));
$('seek').onchange = () => task(() => control('seek', {fraction: Number($('seek').value) / 1000}));
$('volume').onchange = () => task(() => control('volume', {value: Number($('volume').value) / 100}));
$('shuffle').onclick = () => task(() => control('shuffle'));
$('repeat').onchange = () => task(() => control('repeat', {mode: $('repeat').value}));
$('playlists').onclick = () => task(() => library({operation: 'playlists'}));
$('local').onclick = () => task(() => library({operation: 'local'}));
$('more').onclick = () => task(() => library(libraryQuery, true));
$('search-form').onsubmit = event => { event.preventDefault(); task(() => library({operation: 'search', query: $('query').value.trim()})); };
$('profile').onclick = () => task(async () => {
  notice('请在 Lazer 中确认账号信息授权。');
  const profile = await client.request('user', {operation: 'profile'});
  const platforms = await client.request('user', {operation: 'platforms'});
  $('user-data').textContent = JSON.stringify({profile, platforms}, null, 2);
});
$('statistics').onclick = () => task(async () => {
  notice('请在 Lazer 中确认播放记录授权。');
  $('user-data').textContent = JSON.stringify(await client.request('user', {operation: 'statistics', range: 'allTime'}), null, 2);
});
$('permissions').onclick = () => task(async () => { $('user-data').textContent = JSON.stringify(await client.request('permissions'), null, 2); });
$('clear-data').onclick = () => { $('user-data').replaceChildren(); $('library').replaceChildren(); $('more').hidden = true; };
setInterval(() => {
  if (!connected || busy || document.hidden) return;
  if (!client.socket) { reset(); notice('连接已断开，请重新启动桥并连接。'); return; }
  task(refresh);
}, 1000);
window.addEventListener('pagehide', () => client.close());
