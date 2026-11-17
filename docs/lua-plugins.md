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
    "socket": ["127.0.0.1:9000"],
    "socketServer": ["127.0.0.1:9001"],
    "websocket": ["socket.example.com"],
    "websocketServer": ["127.0.0.1:11444"],
    "storage": true,
    "filesystem": true,
    "data": ["library", "profile", "history"]
  }
}
```

`id`、`provider` 和版本号必须符合规范；入口与 Lua 模块路径只能使用正斜杠，不能包含 `..`。网络权限只允许 HTTPS，并且请求的主机必须精确匹配 `permissions.network`，或匹配以 `*.` 开头的子域规则。`host.http` 和 `host.http_json` 在真正发出请求前都必须获得网络权限；插件第一次访问声明的网络域名时，客户端会向用户申请网络权限，拒绝后请求不会发出。TCP Socket、WebSocket 连接和服务端监听分别使用各自的权限范围，也必须在建立连接或开始监听前获得用户授权。文件管理权限只允许访问插件自己的文件沙箱，首次读写前单独申请；沙箱禁止路径穿越和符号链接，并限制单文件 4 MB、总量 16 MB。插件 ZIP 最大 16 MB，解压后最大 8 MB，单个文件最大 2 MB。

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
失败的登录尝试应保留之前有效的凭据。`qrUrl` 可直接返回二维码 URL 字符串，亦可返回包含
`{url, code, hint, actionUrl}` 的 table（适用于 OAuth 设备授权码流，可在 UI 展示验证码、
自定义扫码引导文案与浏览器直达链接）。客户端不解析二维码 URL 中的服务特定参数。

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
| `host.http({url, method, headers, body})` / `host.http_json(spec)` | 访问清单声明的 HTTPS 域名；后者直接解析 JSON 响应 |
| `host.socket({operation, id, host, port, data, timeoutMs})` | 原生客户端建立 TCP 连接；需要声明主机并由用户授予连接权限 |
| `host.socket_server({operation, id, host, port, clientId, data, timeoutMs})` | 原生客户端监听 TCP 端口；需要声明地址并由用户授予服务端权限 |
| `host.websocket({operation, id, url, data, timeoutMs})` | 打开、发送、接收或关闭 WebSocket；需要用户授予 WebSocket 连接权限 |
| `host.websocket_server({operation, id, host, port, path, clientId, data, timeoutMs})` | 原生客户端监听 WebSocket 服务；需要声明监听地址并由用户独立授予服务端权限 |
| `host.crypto({operation=..., ...})` | `md5`、`sha1`、`sha256`、`hmac`、`base64`、`base64_decode`、`xor`、`zlib_inflate`、`zlib_deflate`、`krc_decode`、`aes`、`rsa_modpow` |
| `host.json_encode(value)` / `host.json_decode(text)` | JSON 编解码 |
| `host.url_encode(text)` / `host.url_decode(text)` | URL 百分号编码与解码 |
| `host.cookie_compact(text)` / `host.cookie_field(text, name)` | 规范化通用 Cookie Header、读取字段 |
| `host.cookie_merge(previous, setCookieHeaders)` | 合并响应 Cookie，保留没有被覆盖的凭据字段 |
| `host.random_hex(count)` / `host.now()` | 随机数和 Unix 毫秒时间 |
| `host.storage_get(key)` / `host.storage_set(key, value)` | 清单申请存储权限时使用；总量最多 1 MB |
| `host.storage_keys()` / `host.storage_clear()` | 枚举或清空插件自己的持久化空间 |
| `host.file({operation, path, data, encoding, recursive})` / `host.files(spec)` | 申请文件管理权限后访问插件专属文件沙箱；支持 `read`、`write`、`append`、`list`、`mkdir`、`stat`、`exists`、`delete` |
| `host.info()` / `host.plugin_info()` | 读取插件清单、宿主运行端和可用 host 特性 |
| `host.resource(path)` / `host.read_resource(path)` / `host.resource_keys()` | 读取或枚举 ZIP 中的 JSON、TXT、Markdown、HTML、CSS、JS、SVG 文本资源；不能访问宿主文件系统 |
| `host.log(level, message, data)` | 写入经过脱敏和长度限制的宿主诊断日志 |
| `host.sleep(milliseconds)` | 在 Lua 异步挂起一小段时间，最长 60 秒；适合轮询和限流 |
| `host.add_setting(spec)` | 向设置页注册一个受宿主约束的设置项；返回当前值 |
| `host.add_page(spec)` | 向设置页注册一个由 Flutter 宿主渲染的插件页面；返回 `true` |
| `host.page(id)` / `host.pages()` | 读取本插件已注册页面的当前描述或概要列表 |
| `host.update_page(spec)` / `host.set_page_elements(spec)` | 改写页面标题与布局，或整体替换控件列表；返回编辑后的页面 |
| `host.add_page_element(spec)` / `host.update_page_element(spec)` | 新建控件（可用 `at`、`before`、`after` 定位）或局部改写控件属性 |
| `host.remove_page_element(spec)` / `host.move_page_element(spec)` | 删除控件或调整控件顺序 |
| `host.add_player_menu_item(spec)` | 向正在播放页右上角的“三个点”菜单注册一个项目；返回 `true` |
| `host.player_control(spec)` | 控制播放器播放、暂停、上下首、进度跳转或调节音量；返回执行结果 |
| `host.player_state()` / `host.player_status()` / `host.player_queue()` / `host.player_track()` | 查询当前歌曲、进度、音量、缓冲、队列索引和播放模式 |
| `host.player_lyrics()` / `host.player_recent()` | 查询当前歌词和最近播放歌曲；最近播放需要 `history` 隐私权限 |
| `host.permissions()` / `host.request_permission(scope)` | 查看本插件声明/已获准的数据权限，或主动请求一个权限；未声明的权限返回 `false` |
| `host.library(spec)` / `host.search(spec)` | 在 `library` 权限下读取歌单、指定歌单/专辑曲目、本地音乐、搜索及按目录 ID 播放 |
| `host.user(spec)` | 在 `profile` / `history` 权限下读取平台与账号基本资料或本机收听统计 |

### 独立前端与隐私资料

独立前端插件可以组合宿主页面编辑 API、主题/布局描述、播放事件与后端资料 API，
也可以通过已授权的 TCP / WebSocket 服务连接自己实现的外部前端。ZIP 现在允许随包携带
HTML、CSS、JavaScript 与 SVG，使用 `host.resource("frontend/index.html")` 读取。
它们是受包大小与路径限制的只读文本资源，宿主不会执行 JavaScript，也不会赋予宿主文件系统访问能力。
Flutter 内的页面仍由宿主渲染；本版本没有任意 Widget 注入或替换整个应用进程的接口。

隐私权限必须在 `permissions.data` 中声明，并在实际读取前由用户同意。三个权限互相独立：

| scope | 可读取的内容 |
| --- | --- |
| `library` | 当前资料库歌单、指定歌单/专辑曲目、本地音乐条目、音乐搜索；按宿主目录 ID 开始播放 |
| `profile` | 已连接平台与能力、当前平台、账号原始 ID、昵称、头像 |
| `history` | 最近播放，以及本机记录的播放次数、跳过次数和收听时长 |

声明并不等于授权。插件可先调用 `host.request_permission("library")`，用户拒绝时返回
`false`；直接调用受保护的数据 API 时也会先触发授权申请，拒绝则抛出 Lua 错误，可用 `pcall` 处理。
未声明的数据权限不会弹窗，也不会触达后端。`host.permissions()` 返回
`{declared={...}, granted={...}}`。授权按插件存储，用户可在插件详情里逐项撤销，
撤销无需重启插件，正在加载但尚未返回 Lua 的私密数据也会被丢弃。插件更新会重新申请权限。
旧 `host.player_recent()` 和 `player_control` 的 `recent` / `recent_tracks` / `recenttracks`
别名同样需要 `history`，旧插件需要补充声明。

```lua
-- 不要在插件入口初始化中申请资料：安装探测阶段没有宿主资料接口。
-- 在用户点击页面按钮、播放器菜单或外部前端发来明确请求之后调用：
if not host.request_permission("library") then
  return {error = "library permission declined"}
end
local lists = host.library({operation="playlists", offset=0, limit=50})
local tracks = host.library({operation="tracks", id=lists.items[1].id,
  offset=0, limit=100})
host.library({operation="play", kind="playlist", id=lists.items[1].id,
  index=0})
local search = host.search({query="Miku", offset=0, limit=30})
local info = host.user({operation="profile"}) -- 单独申请 profile
local stats = host.user({operation="statistics", range="last7Days"}) -- history
```

`host.library` 的 `operation`：

- `playlists`：当前平台的个人歌单；本地离线平台返回空列表。
- `tracks`：`id` 指定的歌单曲目；`album`：`id` 指定的专辑曲目。
- `local`：本地音乐库中可播放的条目，不包含文件路径。
- `search`：`query` 为 1–256 字符，返回 `tracks`、`albums`、`artists`、`playlists` 四个分页结果。
- `play`：`kind` 为 `song` / `album` / `playlist`（默认）；`id` 使用前述查询返回的
  完整宿主 ID，`index` 为从零开始的起播位置。此操作只接受目录身份，不接受任意 URL 或文件路径。

分页结果为 `{items, offset, limit, total, hasMore}`；`offset` 从零开始，`limit` 默认 50，
限制为 1–200。宿主复用目录缓存，然后切出响应分页；大型远端歌单的首次加载仍取决于平台后端。
歌单返回 `{id,name,description,coverUrl,trackCount}`，歌曲保持播放器 `track` 的通用结构。
本地文件封面不会导出绝对路径；只返回无 URL 用户名/密码的 HTTP(S) 封面地址。

`host.user` 的 `operation`：

- `profile`（默认）：返回 `{activePlatform,activeConnection,accounts}`；每个账号只含
  `{connection,platform,id,name,handle,avatarUrl}`，`id` 保留平台的原始字符串身份。
- `platforms`：返回平台 `{id,name,connection,active,signedIn,capabilities}` 列表。
- `statistics`：`range` 可为 `today` / `last7Days` / `last30Days` / `allTime`（默认），
  返回 `{source="device",range,playCount,skipCount,durationMs,mostPlayed,mostSkipped}`。
  两个歌曲排行采用相同分页结构，条目为 `{track,playCount,skipCount,durationMs}`。
  这些是本机记录，不冒充平台账号的跨设备历史总量。

账号 Cookie、密码、令牌、认证详情、插件私有存储、可播放音源 URL 及本地文件路径均不通过这些接口导出。
外部前端应对客户端连接进行认证，只转发它真正需要的响应；网络/监听权限仍按原有清单单独申请。
同一个 Lua VM 不能在正在执行的操作中等待宿主再次调用自身目录后端；这类重入会立即失败。
音乐平台插件自己的前端应直接调用其 Lua 目录函数，独立前端插件可以调用其他平台后端。

插件可以在入口文件执行时注册设置、插件页面和正在播放菜单项目。注册是幂等的，同一个插件内重复使用
相同的 `id` 会更新项目。设置值由宿主持久化，插件通过 `setting_changed` 操作接收变化；
页面控件变化通过 `page_event` 操作接收，菜单项目点击后通过 `player_menu` 操作接收当前歌曲的通用
`track` 对象。页面布局和控件始终由 Flutter 宿主创建，Lua 只提供数据描述，不能传入 Widget 或执行
Flutter 代码。
宿主还会在切歌、队列变化、歌词更新与播放状态变化时向所有激活插件派发 `player_event` 操作（支持外部推流与挂件联动）。

```lua
-- 播放控制示例：
host.player_control({ command = "play" })
host.player_control({ command = "seek", positionMs = 30000 })
host.player_control({ command = "volume", volume = 0.8 })
local state = host.player_state()
local queue = host.player_control({ command = "queue" })
if queue.length > 0 and queue.currentIndex < queue.length - 1 then
  host.player_control({ command = "play_index", index = queue.currentIndex + 1 })
end
host.player_control({ command = "repeat", mode = "all" })
host.player_control({ command = "shuffle", enabled = true })
local lyrics = host.player_lyrics()
local recent = host.player_recent()

-- 接收宿主广播的播放事件：
-- operation == "player_event", args.type 为 "track" | "queue" | "lyric" | "status"
```

```lua
local quality = host.add_setting({
  id = "quality",
  type = "select", -- toggle / select / text / number / action
  title = "音质",
  subtitle = "选择播放音质",
  default = "standard",
  options = {
    {value = "standard", label = "标准"},
    {value = "high", label = "高"},
  },
})

host.add_player_menu_item({
  id = "copy_id",
  label = "复制歌曲 ID",
  icon = "content_copy",
})

host.add_page({
  id = "tools",
  title = "工具",
  subtitle = "插件工具页",
  icon = "settings",
  elements = {
    {type = "section", title = "常用操作"},
    {type = "text", text = "这是由宿主渲染的说明文字。"},
    {type = "toggle", id = "enabled", title = "启用功能", value = true},
    {type = "select", id = "mode", title = "模式", value = "a",
      options = {{value = "a", label = "模式 A"}, {value = "b", label = "模式 B"}}},
    {type = "slider", id = "volume", title = "强度", min = 0, max = 100, step = 5, value = 50},
    {type = "text_field", id = "query", title = "关键词", placeholder = "输入关键词"},
    {type = "button", id = "refresh", title = "刷新", icon = "refresh"},
  },
})

return {
  call = function(operation, args)
    if operation == "setting_changed" then
      -- args.id 和 args.value 是宿主保存后的值；action 的 value 为 nil
      return true
    end
    if operation == "player_menu" then
      -- args.id 是项目 ID，args.track 是当前播放歌曲的通用模型
      return true
    end
    if operation == "page_event" then
      -- args.page、args.id 和 args.value 是宿主发回的控件事件
      return true
    end
    -- 其余平台操作……
  end
}
```

### 页面编辑

`host.add_page(spec)` 负责首次注册；页面注册之后，Lua 仍可以在运行时改写页面布局、
修改已有控件或新增控件。所有编辑都提交纯数据，由宿主校验后写入 Flutter，并且只作用于
该插件自己注册的页面。

| 接口 | 用途 |
| --- | --- |
| `host.page(id)` | 读取页面当前描述：`{id,title,subtitle,icon,layout,elements}` |
| `host.pages()` | 列出本插件页面概要：`{id,title,subtitle,icon,elements,layout}`，`elements` 为控件数量 |
| `host.update_page({page,...})` | 改写标题、副标题、图标与布局；省略 `page` 时可用 `id` |
| `host.set_page_elements({page,elements})` | 整体替换控件列表；`elements={}` 清空页面 |
| `host.add_page_element({page,...})` | 新建控件；`at`（从 1 起）、`before`、`after` 决定插入位置，缺省追加 |
| `host.update_page_element({page,...})` | 按 `element`（或 `id`、`index`）局部改写控件；未提交的字段保持原样 |
| `host.remove_page_element({page,element})` | 删除控件 |
| `host.move_page_element({page,element,to})` | 调整顺序；`to` 为目标位置（从 1 起），也可直接给目标控件 ID |

```lua
-- 页面布局：控件之间的间隙、页面内边距、宽度上限、对齐与排布方式
host.update_page({
  page = "tools",
  title = "工具箱",
  gap = 18,            -- 相邻控件之间的间隙
  inset = 14,          -- 页面左右内边距
  maxWidth = 720,      -- 内容宽度上限，0 表示跟随应用布局
  align = "center",    -- start / center / end / stretch
  direction = "grid",  -- vertical / horizontal / grid
  columns = 2,         -- grid 列数 1–4
  card = true,         -- 是否保留分组卡片外观
  header = true,       -- 是否保留标题与副标题
})

host.add_page_element({
  page = "tools",
  before = "refresh",
  type = "toggle",
  id = "auto_sync",
  title = "自动同步",
  value = true,
  gap = 6,     -- 该控件之前的额外间隙
  padding = 4, -- 该控件左右的内缩
})

host.update_page_element({page = "tools", id = "auto_sync", title = "自动同步收藏"})
host.move_page_element({page = "tools", element = "auto_sync", to = 1})
host.remove_page_element({page = "tools", element = "auto_sync"})

-- 读取宿主侧的真实状态，再决定下一次编辑
local page = host.page("tools")
local count = #page.elements
```

`add_page` 与 `update_page` 都接受平铺的布局键（`gap`、`inset`、`maxWidth`、`align`、
`direction`、`columns`、`card`、`header`），也可以写成嵌套的 `layout = {...}`。数值会被
限制在宿主允许的范围：`gap`、控件 `gap` 与 `padding` 为 0–96，`inset` 为 0–96，
`maxWidth` 为 0–2400，`columns` 为 1–4；无法识别的 `align`、`direction` 或控件字段会
直接报错，不会被静默忽略。

页面和控件的 `id` 只能使用 `[a-zA-Z0-9_.-]`，长度为 1–64。每个插件最多 16 个页面、
每页最多 128 个控件，同一页内的控件 ID 不能重复：重复的新增或改名会被拒绝。
`host.update_page_element` 只覆盖传入的字段，用户已经选择的开关与滑块值不会因为一次
文案修改而丢失。

### 文件沙箱

清单声明 `permissions.filesystem=true` 后，宿主会在第一次调用文件接口时申请“文件管理”权限。
文件接口只接受相对路径，根目录是插件自己的 `lua_plugin_data/<plugin-id>/files`，不能访问
插件目录、应用目录或其他插件的数据。文本默认使用 UTF-8；`encoding="binary"` 返回或写入
字节数组，`encoding="base64"` 用 Base64 字符串传递二进制内容。

```lua
local spec = {operation="write", path="cache/state.json",
  data=host.json_encode({version=1})}
host.file(spec)
local state = host.json_decode(host.file({operation="read", path="cache/state.json"}))
for _, entry in ipairs(host.file({operation="list", path="cache"})) do
  host.log("debug", entry.path, entry)
end
```

`delete` 默认只删除空目录；传入 `recursive=true` 才会删除目录及其内容。文件沙箱单个文件
最多 4 MB、总量最多 16 MB，目录项最多 2048 个。浏览器运行时使用同源的持久化沙箱，接口
和权限语义与原生运行时一致。

设置规格必须包含 `id` 和 `title`（也可用 `label`）。`select` 需要非空 `options`，
每项包含字符串 `value` 和 `label`；`number` 可提供 `min`、`max`、`step`；`text` 最多
保存 2048 个字符；`action` 是一个按钮，不保存值。设置和菜单项目均有数量、长度和类型
限制，越界或无效规格会被拒绝。页面最多 16 个，每页最多 128 个元素；元素类型包括
`text`、`section`、`divider`、`spacer`、`button`、`toggle`、`select`、`slider` 和
`text_field`，交互元素必须提供唯一 `id`。`icon` 使用有限的 Material 图标名称，未知名称
显示扩展图标。插件页面和菜单项目只会在插件启用且运行成功时出现。

`host.http` 是异步函数，插件调用时可以直接使用返回值；嵌套函数、循环和 `pcall` 均支持等待 HTTP。
返回 `{status,headers,body}`，其中 body 是字符串，多个 Set-Cookie 用换行分隔。
`host.crypto` 的 RSA 运算支持 `inputEncoding="utf8"` 和 `reverse=true`，用于原始 RSA
模幂输入；默认输入为十六进制字符串。AES 支持 CBC/ECB 和 PKCS7 填充。
所有插件调用在自己的 Lua VM 中串行执行，并有时间上限；异常、超时和重启不会让插件访问 Dart 对象、Flutter Widget、文件路径、进程、动态库或其他插件。

`host.info()` 返回的数据只描述当前插件和宿主能力，不包含账号 Cookie、令牌、签名 URL 或其他插件的数据。资源路径必须是安全的相对路径；资源在安装时从 ZIP 读入内存，插件不能通过它访问宿主目录。`host.log` 的消息会经过宿主脱敏，插件不应把凭据放进日志。

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
        lyricWeight = 500,
        lyricTranslationWeight = 400,
        lyricLineHeight = 1.55,
        lyricTranslationGap = 6,
        lyricSpringStiffnessScale = 1.1,
        lyricSpringDampingScale = 0.95,
        lyricStaggerDelay = 0.04,
        lyricFocusScaleDelta = 4,
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
| `heartbeat` | `roomId`、`songId`、`playStatus`、`progress`、`playlistVersion` | 每 5 秒一次；`playStatus` 为 `PLAY`/`PAUSE`，`progress` 为毫秒，`playlistVersion` 是上次上报的队列版本 |
| `command` | `roomId`、`command` | 播放指令：`{clientSeq,commandType,formerSongId,playStatus,progress,targetSongId,triggerType}` |
| `syncPlaylist` | `roomId` | 可选，读取房间队列 |
| `syncList` | `roomId`、`playlistVersion`、`playlist` | 可选，上报房间队列与版本 |
| `commands` | `roomId`、`since` | 可选，取两次心跳之间的最新播放指令 |

返回值使用 `{roomId,inviterId,members}`，成员为 `{userId,name,avatarUrl}`；也可以返回
`users` 或 `participants`，字段名可用 `uid`、`nickname`、`avatar`。返回 `code` 时非 200
表示失败。`command` 里的账号标识由插件补全，客户端只给出通用字段。

房间视图还可以携带 `songId`、`playStatus`、`progress`、`playlistVersion`、`playlist`
（`[{id,name,artist,album,coverUrl,durationMs}]`）与 `command`
（`{clientSeq,serverSeq,commandType,formerSongId,targetSongId,playStatus,progress,triggerType,userId}`）。
客户端据此做三件事：心跳带回的曲目变化就是「别人切歌」，版本变化才触发 `syncPlaylist`，
`command` 的 `serverSeq` 单调递增，重复返回的同一条指令不会被执行两次。自己发出去的指令
按 `userId` 忽略，避免两端互相同步。

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


### WebSocket 服务端与权限

`permissions.websocketServer` 是独立于连接权限的监听地址列表。插件管理会列出所申请的
地址和端口，用户必须打开“允许 WebSocket 服务端”后脚本才能监听。默认未授权；仅授予
`websocket` 不会允许创建服务端。撤销权限、停用、升级或卸载插件时关闭其监听端口和连接。
浏览器不能监听 TCP 端口，因此 Web 版的 `host.websocket_server` 返回不支持错误。

地址必须是明确的 IP 地址或 `localhost`，端口为 0–65535；不支持通配域名。
`127.0.0.1:11444` 只授权该回环地址和端口；`0.0.0.0:11444` 才允许监听全部 IPv4
接口。若需要系统分配临时端口，清单声明 `127.0.0.1:0`，调用时也传 `port=0`，
返回值包含实际端口。推荐本地集成使用回环地址。

```lua
-- manifest.json: "permissions": {"websocketServer": ["127.0.0.1:11444"]}
local listener = host.websocket_server({
  operation="listen", id="lyrics", host="127.0.0.1", port=11444, path="/lyrics"
})
-- accept 和 receive 超时返回 nil；timeoutMs=0 只检查已到达的数据。
local client = host.websocket_server({operation="accept", id="lyrics", timeoutMs=0})
if client then
  host.websocket_server({operation="send", id="lyrics",
    clientId=client.clientId, data=host.json_encode({type="hello"})})
end
```

服务端操作：`listen` 返回 `{id, host, port}`；`accept` 返回 `{clientId, address}`；
`clients` 返回客户端 ID 列表；`send` / `receive` 用 `clientId` 选择连接；`broadcast`
返回接收本次发送的在线客户端数量；`close_client` 关闭指定客户端；`close` 关闭服务端
及全部连接。`path` 可限定允许握手的路径。接收到断开的连接后可用 `close_client` 释放
其剩余消息；已断开且消息读取完的连接会自动清理。

客户端仍使用 `host.websocket` 的 `open`、`send`、`receive`、`close`。客户端和服务端
均使用持续订阅，支持多次接收和暂存调用之间到达的消息；超时不会关闭连接。
`timeoutMs` 默认 30000，上限 30000。Lua 调用串行执行，建议后台集成使用短超时或
`timeoutMs=0`，避免长时间阻塞同一插件的播放请求。
每个插件最多 4 个服务端、每个服务端 32 个客户端，以及 16 个主动连接；每条消息最多
1 MB，单个接收队列最多 128 条、4 MB，超限将关闭该连接。文本以字符串表示，二进制
以 0–255 整数数组表示。

### 罗马音 / 音译歌词

歌词返回值可提供 `romanization`（时间轴 LRC）和 `wordRomanization`（LRC 或 YRC）作为
独立音译轨道；兼容别名分别为 `rlyric` / `romanLyric` / `romaji` 和 `yromalrc`。
逐行 `lines` 也可直接返回 `romanization`（或 AMLL 的 `romanLyric`）、`translation`
（或 `translatedLyric`）及 `startMs`。原文、翻译和罗马音会分别匹配并保存到离线缓存。

```lua
return {{synced=true,
  lrc="[00:01.00]君へ",
  translation="[00:01.00]给你",
  romanization="[00:01.00]kimi e"
}}
```

也可返回 `ttml`，使用 [AMLL TTML 约定](https://github.com/amll-dev/applemusic-like-lyrics/blob/main/packages/docs/src/content/docs/en/guides/lyric/ttml.md)
的 `ttm:role="x-roman"` 和 `ttm:role="x-translation"`，或 Apple metadata
`transliterations` / `translations` sidecar 与 `itunes:key` / `for` 关联。用户导入或音频旁的
`.ttml` 文件使用相同解析器。普通 LRC 无明确音译标记时不会凭语言或重复时间戳猜测音译。

设置 → 歌词 → 显示罗马音默认开启，关闭后正在播放、桌面/悬浮歌词及歌词导出均隐藏
音译，保留原文与翻译。没有提供音译的行不占用额外空间，也不会自动生成罗马音。
