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

网易云 Gateway 的完整示例位于 `E:\projects\lazer_ncm\netease-cloud`，可直接使用 `E:\projects\lazer_ncm\dist\lazer.netease-1.0.1.zip` 导入。Navidrome 暂不随插件包提供实现。
