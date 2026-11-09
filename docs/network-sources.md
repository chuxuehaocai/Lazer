# 网络源：NAS、网络电台与播客

音乐库里的 **网络源** 把听歌的地方从这台设备扩展到整个局域网：

- **网络存储**：WebDAV、SMB、SFTP、FTP。浏览目录、按文件夹播放、把一首歌或整棵目录索引进资料库。
- **网络电台**：手动添加流地址，或者一次导入 M3U / PLS / ASX / XSPF 列表。
- **播客**：订阅 RSS 2.0 或 Atom，刷新节目、记住每一集的收听位置、标记已听。

所有协议都在应用内直接实现，不需要在系统里挂载共享盘，也不依赖平台的 SMB/SSH 客户端。因此 Windows、macOS、Linux、Android 和 iOS 看到的是同一套功能，凭据也只保存在应用自己的数据目录里。

## 怎么用

1. 音乐库 → **网络源** → **网络存储** → **添加**。
2. 选协议，填服务器地址、端口、起始目录（SMB 填 `共享名/子目录`）和账号密码。
3. **测试连接** 会真的列一次目录，确认地址、凭据和权限都对。
4. 保存后点进这个源：文件夹在上、可播放文件在下。点一首歌就从那里开始播放整个文件夹；**播放全部** 播当前目录；**扫描此文件夹** 把里面所有音频索引进资料库。
5. **已索引** 标签是所有网络歌的播放列表：按最近索引进来的顺序排列，可以播放全部，也可以把某首从索引里移除。

电台和播客在同一页的两个标签里：**添加** 填名称和流地址；**导入列表** 粘贴一个 M3U/PLS 地址；**订阅** 粘贴播客的 RSS 地址。播客页里的 **继续播放** 会从上次停下的位置开始。

## 协议细节

| 协议 | 端口 | 认证 | 说明 |
| --- | --- | --- | --- |
| WebDAV | 80 / 443 | HTTP Basic，可开 HTTPS | `PROPFIND` 列目录，`GET` + `Range` 播放；自签名证书需要显式允许 |
| SMB | 445 | NTLM（用户名/密码/域） | 通过 `smb_connect` 走 SMB2，路径格式为 `共享名/目录` |
| SFTP | 22 | 密码 | 通过 `dartssh2` 走 SSH 的 sftp 子系统，首次连接记住主机密钥 |
| FTP | 21 | USER/PASS | 明文 FTP；`MLSD` 不可用时自动退回 `LIST`，`REST` 支持拖动进度 |

播放链接不是直接交给音频引擎的：应用会在 `127.0.0.1` 上开一个只绑定回环地址的 HTTP 网关，把 `/文件/<源>/<路径>` 映射到对应协议的读取，并把客户端的 `Range` 转发下去。这样：

- 引擎只认识 URL 的问题被一个协议无关的层解决；
- 拖动进度对四种协议都有效（网关返回 206 + `Content-Range`）；
- 每次读取都可以被取消，切歌或离开页面不会留下悬挂连接。

路径在进入适配器前都会做一次词法归一化，`..` 不能越过源配置的根目录。

## 凭据与隐私

- 密码保存在应用数据目录的 `network_credentials.json`，用同一目录下 `network_credentials.key` 里的随机密钥做 AES-GCM 加密。
- 这不是系统钥匙串：能读应用数据目录的人也能读密钥。它的目标是让明文密码不出现在备份、日志和配置导出里。设备本身有多用户时，请依赖操作系统的账户隔离。
- WebDAV 的自签名证书默认拒绝，只有在源设置里显式打开才接受。
- SFTP 首次连接采用 TOFU：记住服务器出示的 SHA256 指纹（与 `ssh-keygen -l` 的显示一致）；之后指纹变化会直接拒绝连接，编辑源里的 **重新信任** 可以清掉旧指纹。
- 回环网关的每个路径都带一个每次启动重新生成的 token，同一个局域网里的其他设备无法访问它。
- 播客附件和电台流不允许指向 `127.0.0.1` / `localhost`：订阅源是外部输入，不能让本地网关变成读取本机服务的工具。自家局域网地址（192.168.x、10.x 等）仍然允许，NAS 电台才能播。
- Android 打开 `usesCleartextTraffic`、iOS 打开 `NSAllowsArbitraryLoads`：电台和 NAS 常常是明文 HTTP，系统播放器会按平台策略拦截；Dart 自己的 socket 不受影响，但回退到平台播放器时需要这两个声明。

## 数据与索引

- 源的配置、索引、电台和播客分别写在应用支持目录下的 `network_sources.json`、`network_library.json`、`network_radio.json`、`network_podcasts.json`。
- 索引条目的 id 是 `network:<base64(源 id + \0 + 路径)>`，播放时由控制器重新解析成当前启动的网关地址；因此重启后队列里的网络歌曲仍然能放。
- 电台和播客分别是 `radio:<id>` 与 `podcast:<id>`，同样不依赖上一次启动的端口或 token。
- 文件名按 `歌手 - 标题` 的约定拆成标题和歌手，父目录当作专辑；网络文件不读取内嵌标签，也不抓取封面，封面仍是资料库生成的插画。

## 已知限制

- 只支持明文 FTP。FTPS 需要第二套 TLS 状态机；需要加密时请用 SFTP。
- WebDAV 只做 Basic 认证，不支持 Digest；NAS 和 Nextcloud 默认都接受 Basic。
- SMB 走 SMB2；只允许 SMB3 且禁用 2.x 协商的服务器会连不上。
- SMB 固定使用 445 端口（`smb_connect` 不支持自定义端口），所以编辑页不显示端口字段。
- 网络文件不解析内嵌标签，所以列表里的时长在播放前显示为 `--:--`，播放开始后由解码器补上。
- 网络电台是直播流：没有总时长，播放条只显示位置，**不会** 等十秒启动缓冲。
- 电台不显示 ICY 的“正在播放”元数据。
- 播客只播放 RSS 里 `enclosure`（或 `media:content`、Atom `rel="enclosure"`）指向的音频，不处理视频、章节和内嵌播放器。

## 实现位置

- `lib/network/remote_source.dart`：协议接口、错误词表、路径与 Range 工具。
- `lib/network/{webdav,ftp,sftp,smb}_source.dart`：四个协议适配器。
- `lib/network/network_stream_gate.dart`：回环 HTTP 网关。
- `lib/network/network_sources_controller.dart`：源、凭据、连接池、索引、电台、播客、播放绑定。
- `lib/network/network_sources_page.dart`：网络源主页与音乐库入口。
- `lib/network/network_browse_page.dart`、`podcast_pages.dart`、`network_source_editor.dart`、`radio_pages.dart`：页面与表单。
- `test/network_*`：协议解析、真实 socket 上的 WebDAV/FTP、网关、控制器、页面测试。

依赖：`dartssh2`（MIT）、`smb_connect`（Apache-2.0）、`xml`（MIT）、`pointycastle`（MIT）。`smb_connect` 仍声明 pointycastle 3.x，但实际使用的 AES/MD4/HMAC 在 4.x 中未变，仓库用 `dependency_overrides` 统一到 4.x，避免打包两份加密实现。
