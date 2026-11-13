# Lua Plugin 开发说明

Lazer 的音乐平台和扩展功能以 ZIP 插件安装。插件包必须把 `manifest.json`、入口 Lua 文件和依赖源码放在 ZIP 根目录：

```text
manifest.json
main.lua
netease.lua
README.md
```

清单使用 API 版本 1：

```json
{
  "id": "example.provider",
  "name": "Example Music",
  "version": "1.0.0",
  "description": "A music provider",
  "author": "Your name",
  "entry": "main.lua",
  "apiVersion": 1,
  "provider": "example",
  "capabilities": ["search", "lyrics", "scrobble"],
  "auth": ["cookie"],
  "permissions": {
    "network": ["api.example.com"],
    "storage": true
  }
}
```

`id`、`provider` 和版本号必须符合规范；入口与 Lua 模块路径只能使用正斜杠，不能包含 `..`。网络权限只允许 HTTPS，并且请求的主机必须精确匹配 `permissions.network`，或匹配以 `*.` 开头的子域规则。插件 ZIP 最大 16 MB，解压后最大 8 MB，单个文件最大 2 MB。

入口文件返回一个带 `call(operation, args)` 的表。`args` 和返回值只能是 `nil`、布尔值、数字、字符串、数组或字符串键表：

```lua
local api = require("api")

return {
  call = function(operation, args)
    if operation == "search" then
      return api.search(args.query, args.limit or 30, args.offset or 0)
    end
    error("unsupported operation: " .. tostring(operation))
  end
}
```

客户端启动插件后会调用 `describe`。平台列表、名称、能力与登录方式以 Lua 返回值为准；一个插件可以提供多个平台：

```lua
if operation == "describe" then
  return { providers = {
    { id="example", name="Example Music",
      auth={"qr", "cookie"},
      capabilities={"search", "playlists", "lyrics"},
      loginHint="使用 Example Music 登录",
      cookieHint="粘贴 Example Music Cookie" }
  } }
end
```

后续调用的 `args.platform` 是该平台的 `id`。多平台插件应按这个 ID 分开存储会话。
`auth` 可取 `qr`、`sms`、`password`、`cookie`，客户端只显示已声明的登录方式；
`loginHint`、`cookieHint` 和 `forgotPasswordUrl` 是可选字段。旧单平台插件可以使用
清单内的 provider、capabilities 和 auth 作为兼容描述；新插件应实现 `describe`。

登录操作包括 `session`、`loginCookie({cookie})`、`loginPassword({account,password})`、
`loginCaptcha({phone,captcha})`、`sendCaptcha({phone})`、`qrKey`、`qrUrl({key})`、
`qrCheck({key})` 和 `logout`。认证成功返回 `{id,name,avatarUrl}`，未登录返回 nil；
失败的登录尝试应保留之前有效的凭据。客户端不解析二维码 URL 中的服务特定参数。

登录会话与当前浏览音源相互独立。选择本地音乐不会调用 `logout`，切换平台也不会清空
其他平台的会话或正在播放的队列。`logout` 只清除当前 `args.platform` 的凭据；
多平台插件必须按平台分别存储凭据，不能使用一个全局 Cookie 覆盖所有账号。
每首歌曲的播放、收藏与上报会继续路由给它所属的平台。

歌单返回 `id`、`name`、`description`、`coverUrl`、`songCount`、`owner`（账号 ID）、
`writable` 和 `isFavorites`。当前账号自己的喜欢歌单应设置 `isFavorites=true`，并
保留服务返回的名称，例如 `<用户名>喜欢的音乐`。客户端会将它作为唯一的喜欢歌单，
不再额外生成一份同内容的歌单。分页必须正确处理 `limit` 和 `offset`，只返回当前页；
歌单列表和完整歌曲列表由客户端按平台、连接及账号缓存，插件不需要另写一套歌单缓存。

宿主提供的 `host` 接口如下：

| 接口 | 用途 |
| --- | --- |
| `host.http({url, method, headers, body})` | 访问清单声明的 HTTPS 域名；禁止重定向，响应最多 8 MB |
| `host.crypto({operation=..., ...})` | `md5`、`sha256`、`base64`、`base64_decode`、`aes`、`rsa_modpow` |
| `host.json_encode(value)` / `host.json_decode(text)` | JSON 编解码 |
| `host.url_encode(text)` | URL 百分号编码 |
| `host.cookie_compact(text)` / `host.cookie_field(text, name)` | 规范化通用 Cookie Header、读取字段 |
| `host.cookie_merge(previous, setCookieHeaders)` | 合并响应 Cookie，保留没有被覆盖的凭据字段 |
| `host.random_hex(count)` / `host.now()` | 随机数和 Unix 毫秒时间 |
| `host.storage_get(key)` / `host.storage_set(key, value)` | 清单申请存储权限时使用；总量最多 1 MB |

`host.http` 是异步函数，插件调用时可以直接使用返回值；嵌套函数、循环和 `pcall` 均支持等待 HTTP。
返回 `{status,headers,body}`，其中 body 是字符串，多个 Set-Cookie 用换行分隔。
`host.crypto` 的 RSA 运算支持 `inputEncoding="utf8"` 和 `reverse=true`，用于原始 RSA
模幂输入；默认输入为十六进制字符串。AES 支持 CBC/ECB 和 PKCS7 填充。
所有插件调用在自己的 Lua VM 中串行执行，并有时间上限；异常、超时和重启不会让插件访问 Dart 对象、Flutter Widget、文件路径、进程、动态库或其他插件。

音乐平台插件应返回客户端模型需要的字段：歌曲使用 `id`、`title`、`artists`、`albumId`、`albumName`、`coverUrl`、`durationMs`；音频流使用 `url`、`contentType`、`suffix`、`bitRate`、`size`；歌词使用 `lines`（每行包含 `text` 和可选 `startMs`）、`lrc`、`translation`、`wordByWord` 和 `offsetMs`。`id` 只在插件内部使用，客户端会将 provider、连接和实体类型编码进 `MusicId`。

导入流程会先验证路径、大小、清单和 Lua 入口，再在临时目录启动 VM。启动成功后才替换旧版本；失败会保留旧版本。停用、更新或卸载前客户端会停止该插件的请求和关联播放会话。插件不应把 Cookie、令牌或签名音频 URL 写入日志、返回错误文本或长期缓存；会话凭据只能放在 `host.storage_*` 中。

网易云 Gateway 的完整示例位于 `E:\projects\lazer_ncm\netease-cloud`。本地开发时可自行打包后导入；插件 ZIP 只用于本地验证，暂不随客户端仓库或插件市场上传。Navidrome 暂不随插件包提供实现。

## 扩展的平台接口

客户端没有内置流媒体网关。API 路径、签名、响应解析、账号规则和平台文案均应由 Lua 提供。
新增能力均为可选；只有实现后才在 `capabilities` 中声明。

| 能力 | 操作和返回值 |
| --- | --- |
| `homeFeed` | `homeFeed` 返回 `{featured,featuredSongs,quick,daily,recommended,playlists,albums,editorialPlaylists}`；歌曲、专辑和歌单均使用通用模型 |
| `savedAlbums` | `savedAlbums({limit,offset})` 返回收藏的专辑当前页 |
| `radio` | `radio({kind,seed,playlist,limit})`；kind 为 `personal`、`heart` 或 `artist`，返回歌曲数组 |
| `charts` | `charts` 返回排行榜的歌单模型，歌曲通过 `playlistSongs` 分页取得 |
| `comments` | `comments({id,limit,offset})` 返回 `{hot,latest,total,hasMore}`；`setCommentLiked({id,commentId,liked})` 设置点赞 |
| `listenTogether` | `listenTogether({operation,...})` 支持 `create/createMulti/join/status/leave/heartbeat/command`，以及可选的 `syncPlaylist/syncList`；返回 `{roomId,inviterId,members}` |

### 主题与页面布局

客户端的通用 UI 已经通过内置主题和布局定义集中提供。当前默认主题是
`builtin.apple`，默认布局是 `builtin.adaptive`，电视使用 `builtin.television`。
卡片圆角、列表行高度、页面标题字号、玻璃模糊强度、页面边距和内容最大宽度等值由
声明式令牌控制；页面仍由宿主负责创建 Widget、焦点、语义树和平台交互。

Lua 皮肤复用同一组 JSON 形状的令牌，而不是返回 Flutter Widget 或执行任意 UI
代码。皮肤可以覆盖主题令牌和布局令牌，未知字段会被忽略，越界数值会回退到宿主允许的
范围。这样同一套页面可以换皮，插件也不能绕过宿主的权限、无障碍和输入安全边界。

插件可以在 `describe` 顶层声明 `theme=true`，客户端随后调用 `theme` 操作；也可以直接
把令牌放在 `theme` 字段中。操作返回值示例：

```lua
if operation == "theme" then
  return {
    theme = {
      id = "example.dark",
      name = "Example Dark",
      elements = {
        pageTitleCompactSize = 36,
        groupedCardRadius = 18,
        displayWeight = 800,
        titleWeight = 700,
        bodyWeight = 400,
        labelWeight = 600,
      }
    },
    layout = {
      id = "example.compact",
      name = "Example Compact",
      compactInset = 18,
      regularInset = 28,
      maxContentWidth = 1080,
    }
  }
end
```

`displayWeight`、`headingWeight`、`titleWeight`、`bodyWeight` 和 `labelWeight` 会覆盖
对应的 Material 文本层级；宿主会把数值限制在 100–900 并映射到 Flutter 可用字重。
主题操作失败只会忽略皮肤，不会让音乐平台启动失败。

`artistSongs({id,limit,offset})` 返回歌手歌曲当前页。评论使用字符串 ID：
`{id,content,author,authorId,avatarUrl,time,location,liked,likedCount,replies}`，
其中回复为 `{author,content}`，时间为 Unix 毫秒。一起听成员为
`{userId,name,avatarUrl}`，所有远程 ID 都应当视作不透明字符串。

### 一起听

一起听是可选能力，是否支持由插件决定：只有在清单或 `describe` 的 `capabilities` 里声明
`listenTogether` 的平台才会出现「创建一起听」入口，没有声明的旧插件行为完全不变。
客户端只做房间状态与心跳，不解析任何平台字段。

| operation | 参数 | 说明 |
| --- | --- | --- |
| `create` | 无 | 创建房间，返回 `roomId`、`inviterId` |
| `createMulti` | `songId`、`playedTime`、`nextSongIds` | 可选，用当前曲目建房；没有 `songId` 时按 `create` 处理 |
| `join` | `roomId`、`inviterId` | 接受邀请 |
| `status` | `roomId` | 查询房间状态与成员；不带 `roomId` 时取当前账号仍在的房间 |
| `leave` | `roomId` | 结束或退出房间 |
| `heartbeat` | `roomId`、`songId`、`playStatus`、`progress` | 每 5 秒一次；`playStatus` 为 `PLAY`/`PAUSE`，`progress` 为毫秒 |
| `command` | `roomId`、`command` | 播放指令：`{clientSeq,commandType,formerSongId,playStatus,progress,targetSongId,triggerType}` |
| `syncPlaylist` | `roomId` | 可选，读取房间队列 |
| `syncList` | `roomId`、`playlistParam` | 可选，上报房间队列变化 |

返回值使用 `{roomId,inviterId,members}`，成员为 `{userId,name,avatarUrl}`；也可以返回
`users` 或 `participants`，字段名可用 `uid`、`nickname`、`avatar`。返回 `code` 时非 200
表示失败。`command` 里的账号标识由插件补全，客户端只给出通用字段。

兼容性：旧插件可以只实现 `create/join/status/leave/heartbeat/command`，返回值也可以不带
`code`；客户端把缺失的 `code` 当作成功，成员列表为空时保留上一次结果。反过来，新插件
跑在旧客户端上也只会收到这六个操作。能力名不区分大小写与分隔符，`listenTogether`、
`listen_together` 和 `listen-together` 等价；`describe` 没有给出 `capabilities` 时沿用清单。

`session` 和登录结果可附带 `signature`、`membership`，供客户端展示资料与会员名称。
可选认证能力 `exportCookie` 启用用户主动导出入口；对应操作返回当前平台 Cookie 字符串。
没有声明该能力时，客户端不会提供导出入口。

流地址允许返回 `headers` 字符串映射。歌词另可返回 `wordTranslation`，与
`translation` 分别保留逐字和逐行翻译。客户端下载和缓存歌曲时会自动保存完整歌词，
插件不需要复制文件或管理本地音乐库。

`describe` 可在 `providers` 同级提供 `media` 数组，声明素材请求规则：

```lua
media = {
  {host="*.images.example.com",
   headers={["Referer"]="https://example.com/"},
   artworkResize={parameter="size",value="{size}x{size}"},
   fallbackHosts={"images2.example.com"}}
}
```

缩图规则、请求头与备用主机由插件声明，Dart 不识别平台域名。不要把账号 Cookie 放入
公共素材规则。敏感音频请求头应随单次 `stream` 结果返回，不会写入队列快照。

预期错误可返回 `{error={code=40,httpStatus=401}}`。`40/41/44` 或 HTTP 401 表示
认证失败，HTTP 429 表示限流，`code=70` 表示当前歌曲或音质不可用；客户端可据此
提示重新登录、保留重试机会或尝试较低音质。错误中不要包含服务正文或凭据。

## 市场源

默认源为 `https://lazer.naominet.dev/plugin`。目录源追加 `/plugins.json`，也接受直接的
JSON 地址。索引格式为 `{schemaVersion:1,plugins:[...]}`；每项至少包含 `id`、`version`、
`name`、`summary` 和 HTTPS `download`，可以附带 `author`、`platforms`、
`minAppVersion`、`sha256`。`name/summary` 可以是字符串或语言标签到文本的映射。
索引中的 ID、版本必须与 ZIP 内清单严格一致；预发布客户端遵循 SemVer 的兼容性比较。
