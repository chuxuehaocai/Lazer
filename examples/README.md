# Lazer Lua 插件示例

两个可以直接导入 Lazer 的 Lua 插件项目，用来演示宿主公开的两类扩展：

| 目录 | 插件类型 | 演示内容 |
| --- | --- | --- |
| [`gateway-mock/`](gateway-mock/README.md) | 音乐网关（provider） | 平台描述、密码登录、会话、搜索、首页、专辑/歌手/歌单、收藏、歌词、电台、排行榜，以及**完全离线**的可播放音频 |
| [`theme-plugin/`](theme-plugin/README.md) | 声明式主题（skin） | `describe` + `theme` 操作、主题令牌、布局令牌、歌词动效参数 |

完整开发文档：**<https://lazer.naominet.dev/docs>**  
（客户端仓库内对应 `docs/lua-plugins.md`，包含清单、权限、`host.*` 接口、主题令牌和网关契约。）

两个插件都使用清单 API 版本 1，不包含原生代码、动态库、远程脚本或第三方依赖。协议：**WTFPL v2**，全文见 [`LICENSE`](LICENSE)。

## 目录结构

```text
examples/
├─ build.bat                     # Windows：打包成可导入的 ZIP
├─ build.sh                      # macOS / Linux：同一件事
├─ build.ps1                     # build.bat 实际调用的打包脚本
├─ LICENSE                       # WTFPL v2
├─ gateway-mock/
│  ├─ manifest.json              # 插件清单（API 1）
│  ├─ main.lua                   # describe / 登录 / 网关操作分发
│  ├─ catalog.lua                # 确定性的 fixture 曲库、歌词、歌单
│  ├─ tone.lua                   # 合成 WAV（按块、可随机访问）
│  ├─ tone_server.lua            # 127.0.0.1 上的 Range HTTP 服务
│  ├─ README.md
│  └─ LICENSE
└─ theme-plugin/
   ├─ manifest.json
   ├─ main.lua                   # describe + theme 操作
   ├─ theme.lua                  # 主题与布局令牌
   ├─ README.md
   └─ LICENSE
```

## 打包

Windows 上直接跑 `build.bat`，它用系统自带的 PowerShell，不依赖 Flutter 或 Lua 解释器：

```bat
cd examples
build.bat
```

macOS / Linux 用 `build.sh`，需要 `python3`：

```sh
cd examples
./build.sh
```

检出后如果 `./build.sh` 提示没有执行权限，先 `chmod +x build.sh`，或者直接 `bash build.sh`。
`build.ps1` 是 `build.bat` 实际调用的脚本，也可以自己跑：
`powershell -ExecutionPolicy Bypass -File build.ps1`。

两个入口打出来的 ZIP 内容一致，也可以指定输出目录（`build.bat out` 或 `./build.sh out`）。

输出：

```text
dist/example.gateway-mock-1.0.0.zip
dist/example.theme-atelier-1.0.0.zip
```

ZIP 根目录就是 `manifest.json`、入口 `main.lua` 和依赖的 Lua 模块，符合插件管理器的安装要求。

## 安装

1. 打开 Lazer → 设置 → 插件管理。
2. 导入 `dist/example.gateway-mock-1.0.0.zip`，启用 **Mockwave 模拟音源**。
3. 在音源选择里选中 Mockwave，用任意账号 + 任意非空密码登录。
4. 导入 `dist/example.theme-atelier-1.0.0.zip` 并启用，皮肤立即生效。

主题插件和网关插件互相独立：禁用主题不会影响已登录的网关，禁用网关也不会移除皮肤。同一时间只有一个已启用插件能提供主题（第一个启动成功的主题生效）。

## 权限

| 插件 | 清单权限 | 触发时机 |
| --- | --- | --- |
| gateway-mock | `storage` | 登录后保存会话、收藏列表 |
| gateway-mock | `socketServer: ["127.0.0.1:0"]` | 第一次点播放时申请；只监听 IPv4 回环，端口由系统分配 |
| theme-plugin | 无 | — |

网关不声明 `network`、`filesystem`、`websocket` 或数据权限，也不会读取曲库、账号资料或播放历史。浏览器版不能监听 TCP，因此网关在 Web 上只能浏览、不能播放；这是宿主的平台限制，插件会返回 `503` 而不是假装成功。

## 验证

这两个示例在宿主运行时里做过契约验证：

- 清单通过 `PluginManifest` 校验，ZIP 由 `PluginManager.importZip` 安装并启动；
- 网关的 `describe`、`loginPassword`、`session`、`search`、`homeFeed`、`lyrics`、`favorites`、`stream`、`logout` 均有真实调用；
- `stream` 返回的 `http://127.0.0.1:<port>/tone/N.wav` 通过原始 TCP 请求验证了 `HEAD`、`Range: bytes=0-1023`、中段 Range、完整 384,044 字节下载，以及 WAV 头字段；
- 主题通过 `LuaThemeEngine` 解码，`activeTheme` / `activeLayout` 在启用后可见，禁用后清除。

这些验证使用宿主运行时里的临时测试脚本完成，不随示例发布；示例本身只依赖文档中的公开契约。

## 许可

```text
DO WHAT THE FUCK YOU WANT TO PUBLIC LICENSE
Version 2, December 2004
```

完整文本见 [`LICENSE`](LICENSE)。你可以任意使用、修改、再发布，无需保留出处。