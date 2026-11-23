# Mockwave — 离线音乐网关示例

一个完整但**完全离线**的 Lazer 音乐网关插件。它用确定性的 fixture 曲库演示网关契约的每一层：平台描述、登录、会话恢复、搜索、首页、专辑、歌手、歌单、收藏、歌词、电台、排行榜，以及真正能播放的音频流。

- 插件 ID：`example.gateway-mock`
- 平台 ID：`mockwave`
- 清单 API：1
- 权限：`storage`、`socketServer: ["127.0.0.1:0"]`
- 不声明：`network`、`filesystem`、`websocket`、数据权限

完整开发文档：**<https://lazer.naominet.dev/docs>**

## 它演示了什么

| 能力 | 对应操作 | 说明 |
| --- | --- | --- |
| 平台与登录方式 | `describe` | 返回 `providers`，声明 `password` 登录与 `loginHint` |
| 会话 | `session` / `loginPassword` / `logout` | 会话写入 `host.storage_*`，重启后自动恢复 |
| 搜索 | `search` | 按标题、译名、专辑、歌手、歌单描述做本地子串匹配 |
| 首页 | `homeFeed` | featured、featuredSongs、quick、daily、recommended、playlists、albums、editorialPlaylists |
| 专辑浏览 | `albums` / `album` / `albumSongs` | `sort=newest` 或 `random` |
| 歌手 | `artist` / `artistSongs` / `artistAlbums` | 含跨专辑的合辑曲目 |
| 歌单 | `playlists` / `playlist` / `playlistSongs` | 收藏歌单 + 四个公开歌单 |
| 收藏 | `favorites` / `setFavorite` | 收藏 ID 列表持久化到插件存储 |
| 歌词 | `lyrics` | 逐行 LRC 时间轴 + 翻译 + 拼音罗马音 |
| 播放 | `stream` | `http://127.0.0.1:<port>/tone/N.wav`，支持 Range |
| 电台 | `radio` | `personal` / `heart` / `artist` |
| 排行榜 | `charts` | 两个榜单歌单，歌曲通过 `playlistSongs` 分页取得 |
| 单曲 | `song` | 播放器刷新元数据时使用 |

`quality` 参数会被接受但忽略：fixture 只有一个 128 kbps 的 WAV。

## 文件

```text
gateway-mock/
├─ manifest.json     # 清单：provider、capabilities、auth、permissions
├─ main.lua          # describe、登录、全部网关操作、timer 回调
├─ catalog.lua       # 12 首曲目、4 张专辑、3 位歌手、歌单、榜单、歌词
├─ tone.lua          # 纯 Lua 合成 WAV，按 2048 样本分块，可随机访问
├─ tone_server.lua   # 127.0.0.1 上的迷你 HTTP/1.1 + Range 服务
├─ README.md
└─ LICENSE
```

`require("catalog")`、`require("tone")`、`require("tone_server")` 使用宿主提供的模块加载器；所有 Lua 文件都放在 ZIP 根目录。
## 安装与使用

1. 在仓库根目录运行 `build.ps1`，得到 `dist/example.gateway-mock-1.0.0.zip`。
2. Lazer → 设置 → 插件管理 → 导入 ZIP → 启用。
3. 选择音源 **Mockwave 模拟音源**。
4. 登录：账号 1–32 个字符，密码任意非空。账号只写入本机插件存储；首次登录会预置 `s01`、`s07`、`s11` 三首收藏，方便查看收藏歌单。
5. 点任意曲目播放。第一次播放会弹出「允许服务端（本机回环）」权限申请，允许后才能建立音频服务。

退出登录只清除会话，本地收藏保留。重新登录任意账号会复用同一份收藏（这个示例刻意把它当作单用户 fixture）。

## 网关契约明细

所有操作都返回普通 Lua table（数组/字符串键表），不会返回函数、线程或用户数据。

| 操作 | 参数 | 返回 |
| --- | --- | --- |
| `describe` | — | `{providers={{id,name,auth,capabilities,loginHint,experimental}}}` |
| `session` | — | `{id,name,signature,membership}` 或 `nil` |
| `loginPassword` | `account`, `password` | 用户表；校验失败返回 `{error={code=401,...}}` |
| `logout` | — | `true` |
| `search` | `query`, `limit`, `offset` | `{songs,albums,artists,playlists}` |
| `homeFeed` | — | 见上表 |
| `albums` | `sort`, `limit`, `offset` | 专辑数组 |
| `album` | `id` | 专辑模型 |
| `albumSongs` | `id`, `limit`, `offset` | 歌曲数组 |
| `artist` | `id` | 歌手模型 |
| `artistSongs` | `id`, `limit`, `offset` | 歌曲数组 |
| `artistAlbums` | `id`, `limit`, `offset` | 专辑数组 |
| `song` | `id` | 歌曲模型 |
| `playlists` | `limit`, `offset` | 歌单数组（收藏 + 公开歌单） |
| `playlist` | `id` | 歌单模型；`liked` 是收藏歌单 |
| `playlistSongs` | `id`, `limit`, `offset` | 歌曲数组；支持 `liked` 与榜单 ID |
| `favorites` | `limit`, `offset` | 收藏歌曲数组 |
| `setFavorite` | `id`, `favorite` | `true` |
| `lyrics` | `id` | `{{synced=true, lines={{text,startMs,translation,romanization}}}}` |
| `stream` | `id`, `quality` | `{url,contentType,suffix,bitRate,size}` |
| `radio` | `kind`, `seed`, `limit` | 歌曲数组 |
| `charts` | — | 榜单歌单数组 |
| `timer` | `id`（宿主回调） | 驱动音频服务的泵 |
歌曲模型包含 `id`、`title`、`translatedTitle`、`artists`、`albumId`、`albumName`、`durationMs`、`bitRate`、`suffix`、`contentType`；没有 `coverUrl`，客户端会使用自己的占位封面。

分页遵守宿主的 `limit` / `offset` 约定：`offset` 从 0 开始，`limit` 限制在 1–200，返回当前页。

## 音频是怎么来的

示例不携带任何音频文件，也不访问网络。播放链路是：

```text
stream 操作
  → tone_server.serve(trackId, variant)
  → 监听 127.0.0.1:0（系统分配端口）+ 每 100 ms 一次 host.timer
  → 返回 http://127.0.0.1:<port>/tone/<variant>.wav?track=<id>

客户端 HTTP 请求
  → pump 接受连接、解析请求行与 Range
  → tone.read() 按块合成 PCM，tone_server 每 tick 最多发送 4 KB
  → 200 / 206 响应，Connection: close
```

关键约束和取舍：

- **指令预算**：宿主给每次插件调用 250,000 条 VM 指令。一次合成 24 秒（192,000 样本）会超限并触发 408，因此 `tone.lua` 只按 2,048 样本（4 KB）一块合成，`tone_server.lua` 每个 tick 最多新建一块，已生成的块会缓存。
- **格式**：8 kHz、单声道、16-bit PCM，24 秒，共 384,000 字节 PCM + 44 字节 WAV 头 = **384,044 字节**。四套移调旋律按曲目 ID 确定性地选择。
- **HTTP 子集**：`GET`、`HEAD`、`OPTIONS`；`Range: bytes=a-b`、`bytes=a-`、`bytes=-n`；越界返回 `416`。不支持 keep-alive、多段 Range、压缩或并发复用连接。
- **并发**：每个服务端最多 8 个客户端；同一 tick 只允许新建一个 PCM 块，其他客户端下一 tick 继续。客户端断开后自动回收。
- **生命周期**：`stream` 首次调用时监听并启动 timer；无客户端 50 秒后停止 timer，但监听保留，下一次 `stream` 会重启 timer。禁用、更新或卸载插件时宿主关闭监听和连接。
- **平台差异**：浏览器运行时不能监听 TCP，`stream` 返回 `503`；移动端若禁用明文 HTTP，回环地址也可能被系统拦截。桌面端是主要验证目标。
- **权限提示**：`socketServer` 是独立权限，用户拒绝后 `stream` 返回 503，浏览、搜索、歌词仍可用。
`tone_server.lua` 刻意使用 `string.find(..., true)`、`string.byte` 和手写解析，而不是 Lua 模式类。当前 Lua VM 没有实现 `%a`/`%d`/`%s`/`%.` 等模式类，`#` 作用于字符串也会抛错；示例里的写法可以直接复用。

## 数据与持久化

- `mockwave.session`：`{account, hash, signedInAt}`，`hash` 是账号 MD5 的前 12 位，只用于生成稳定的用户 ID。
- `mockwave.liked`：收藏曲目 ID 数组。
- 存储上限由宿主控制（1 MB），示例只写入两个小 JSON 字符串。
- 没有 `network` 权限，因此不存在 Cookie、令牌、签名 URL 或远端请求；`describe` 里也没有需要下载的封面。

## 错误语义

- 未知操作：`{error={code=400,message="unsupported operation: ..."}}`
- 未找到实体：`{error={code=404,...}}`
- 登录校验失败：`{error={code=401,...}}`
- 音频服务不可用（权限被拒、Web 运行时、timer 不可用）：`{error={code=503,...}}`

网关适配器会把带 `error` 的对象转成 `MusicGatewayException`，UI 会显示为一次失败的请求或播放，而不是静默空数据。
## 已知限制

- fixture 数据是虚构的，不与任何真实平台、艺人或曲库对应。
- 四套旋律按曲目 ID 选择，听感上只有移调差异；24 秒的时长与歌词时间轴一致，但不代表真实歌曲。
- 没有封面、评论、一起听、MV 或音质切换；`quality` 参数被忽略。
- 收藏是单用户本地列表，不区分账号。
- 回环 HTTP 仅用于本地演示：它不是生产级流媒体服务，也没有 TLS、鉴权或限流。
- 音频完整下载约需 10 秒（4 KB / 100 ms）；播放器通常会先缓冲再开始，属预期行为。

## 改成真实平台时

把 `catalog.lua` 的 fixture 换成接口响应映射，并在 `manifest.json` 中声明 `permissions.network`，用 `host.http` / `host.crypto` 完成签名与解析；`main.lua` 的操作分发和错误语义可以原样保留。音频服务部分可以删掉，改成返回平台签名的 HTTPS 流地址。细节见文档的「扩展的平台接口」和「市场源」章节。

## 许可

WTFPL v2，全文见 [`LICENSE`](../LICENSE)。