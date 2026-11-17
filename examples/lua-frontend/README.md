# 独立浏览器前端示例

这里的音乐界面完全由 `frontend/index.html`、`app.css`、`app.js` 渲染。
Lazer 只运行音频、资料库和 Lua 后端；不使用 WebView，也不在宿主内执行 JavaScript。
浏览器通过 `client.js` → 本地 WebSocket → `main.lua` → `host.*` 调用后端。
Lazer 应用需要保持运行。这个示例不是新增的音乐平台，需要先在 Lazer 选择已有平台或本地音乐。

## 启动

1. 在仓库根目录运行 `dart run tool/package_lua_frontend.dart`，生成
   `build/lua-frontend-example.zip`。它与普通 Lua 插件使用相同 ZIP 格式。
2. 在 Lazer「设置 → 账户与扩展 → 插件」导入 ZIP。
3. 点击插件设置中的「启动独立前端桥」，同意申请的 WebSocket 服务端权限。
4. 打开该插件的「独立前端连接」页面，复制 WebSocket 地址与本次连接令牌。
5. 在浏览器直接打开仓库中的 `frontend/index.html`，或者先解压 ZIP 再打开该文件。
   输入地址和令牌，点击连接。页面使用相对路径加载本地 CSS / JS，不需要 Node、npm、
   HTTP 服务器、构建器或外部 CDN。浏览器如提示本地网络访问权限，需要允许访问本机。
6. 当前歌曲、队列、歌词和播放控制立即可用。音乐库、账号与平台、播放统计分别在点击
   后申请 `library`、`profile`、`history` 权限，授权对话框出现在 Lazer 内。

默认仅监听 `127.0.0.1:11445`，路径为 `/lazer`。若端口占用，停止占用端口的旧示例，
或同时修改 `bridge.json` 的 `port` 与 `manifest.json` 中的监听声明后重新打包导入。
`ws://` 地址只接受 WebSocket 升级请求，不能作为网页 URL 打开。
原生桌面版可以提供监听服务；Lazer Web 版受浏览器限制，不能启动服务端。

点击「停止独立前端桥」会断开连接；停用、卸载、升级插件或撤销监听权限也会关闭端口。
再次启动会生成新的随机令牌，旧令牌失效。页面断开后需要重新连接。

## 前端功能

- 当前歌曲、封面、进度、音量、播放 / 暂停 / 停止、上一首 / 下一首、随机与循环。
- 队列查看与选曲；逐行歌词和译文高亮。
- 用户歌单、指定歌单歌曲、本地音乐、搜索与歌曲播放；分页加载。
- 账号标识、平台信息、本机播放次数等统计；查看已授权范围、清空页面数据。

前端没有从 Dart 页面取数据，也不依赖 Flutter 控件。`main.lua` 的 RPC 白名单可以作为
其他前端框架的起点。音乐源解析、播放重试、队列、歌词和权限仍使用同一套宿主后端。

## 通信与权限边界

客户端连接后，先发送 `{id:1,method:"hello",args:{token:"…"}}`。
后续请求仍是 `{id,method,args}`；响应为 `{id,ok:true,result}` 或
`{id,ok:false,error}`。用同一连接上的 `id` 匹配响应。允许的方法：

| 方法 | 参数 | 权限 |
| --- | --- | --- |
| `state` / `queue` / `lyrics` | 无 | 当前播放公共状态 |
| `player` | `command` 及相应控制参数 | 播放控制白名单 |
| `library` | `operation=playlists/tracks/album/local/search/play` | `data.library` |
| `user` | `operation=profile/platforms` | `data.profile` |
| `user` | `operation=statistics` | `data.history` |
| `permissions` | 无 | 仅本插件授权状态 |
| `permission` | `scope=library/profile/history` | 宿主用户同意 |

完整参数见 [Lua 插件 API](../../docs/lua-plugins.md)。RPC 不提供 Lua 求值、任意 host 方法、
文件访问或凭证读取。令牌是每次启动生成的 256 位随机值，不放在 URL、日志、磁盘或浏览器存储。
只有通过握手的连接才能访问当前播放信息及控制；10 秒未认证的连接会关闭。
每条应用请求不超过 64 KiB，每个 tick 最多接受 8 个连接、处理 16 条消息，每连接每 tick
最多一条。宿主另有连接数和缓冲区上限。服务仅绑定 IPv4 回环，不能通过局域网连接。
不要将令牌交给不受信任的页面；仅知道回环端口不构成授权。

隐私权限由宿主对每次调用独立校验，而非由页面或 Lua 自行声明已经获准。
撤权会拒绝后续访问，读取过程中撤权的结果也不会返回，播放提交前再次校验原授权。
撤权不能收回已经传给外部前端的数据；示例不持久化这些数据，可点击「清空展示」或关闭页面。
账号接口只提供允许公开给已授权插件的标识与名称，不提供 Cookie、令牌或 provider storage。
Lua 的空 table 经 JSON 编码可能是 `{}`；页面对数组字段统一进行空列表归一化，不把空队列
或尚未加载的歌词当作错误。

## 实现与测试

`host.timer({id="frontend-pump",intervalMs=100})` 触发短 `call("timer",{id=...})`
回调，在没有播放事件时也能处理请求。`accept` / `receive` 使用 `timeoutMs=0`；
不能用永久 `while` 循环占用串行 VM。一个 timer 最多有一个正在运行或等待的 tick。
插件关闭、重置时由宿主清理全部 timer。回调与普通 Lua 调用使用相同串行队列和运行预算。

从仓库根目录执行（测试需要 Node.js 22 或以上的内置 WebSocket，运行页面本身不需要）：

```sh
flutter pub get
dart run tool/patch_lua_dardo_plus.dart
flutter test --no-pub test/plugin_event_scheduler_test.dart test/lua_frontend_example_test.dart test/plugin_frontend_test.dart
flutter test --no-pub --platform chrome test/lua_frontend_timer_web_test.dart
```

端到端测试打包本目录的真实插件、导入 PluginManager，并用相同 `client.js` 在 Node 中连接
真实 TCP / WebSocket / Lua VM，最终访问 AppState。测试替换音乐平台和音频设备，不访问第三方
账号或播放真实音频。覆盖停播连接、错误令牌、RPC 白名单、授权拒绝/同意/撤销、歌单、账号、
统计、队列、歌词、播放/进度/音量控制、令牌轮换、停用释放端口。计时器测试另验证频率与数量
上限、慢 VM 不堆积回调以及关闭后不再唤醒；Chrome 测试验证 Web VM 超出对外超时后仍保持
背压。Node 测试还用最小 DOM 替身执行真实 `app.js`，检查空状态与播放状态的渲染数据。
