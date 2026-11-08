# Lazer 全栈能力审计报告（2026-11，三轮）

- 分支：`audit/full-stack-three-round`（基于 `nextgen` @ `6b340ff`）
- 范围：`lib/`（前端界面 + 状态层 + 数据层 + 音频层）、`native/lazer-audio`（只审 ABI 契约与 Dart 侧调用，不重审 DSP 实现）、`.github/workflows/build.yml` 与 `ci/`
- 方法：按前端 / 后端 / 跨层三个域并行深读代码，逐条用 `file:line` 溯源；只把能从代码路径复现的缺陷计入结论；修复必须带回归测试
- 交付：修复 39 项（其中 8 项为高危），新增/改写 12 个测试文件；`flutter analyze` 无问题，`flutter test` 1219+ 全绿；CI 新增 i18n 门禁并加固下载链路

## 基线

| 项目 | 审计前 | 审计后 |
| --- | --- | --- |
| `flutter analyze` | 0 issue | 0 issue |
| `flutter test` | 1203 通过（本机偶发 1 例超时） | 1219+ 通过 |
| `python -m unittest ci/tests` | 28 通过 | 28 通过 |
| `python tool/check_i18n.py` | 未接入 CI | 通过，已接入 `check` job |
| 最近一次 `nextgen` CI | Linux aarch64 因 mimalloc 下载 504 失败 | 下载链路已加 codeload 首选项、重试预算与校验和 |

---

## 第一轮：前端（界面、交互、可达性）

### 已修复

| # | 严重度 | 问题 | 修复 |
| --- | --- | --- | --- |
| 1 | 高 | 音频焦点/路由中断后按播放会从 0 重新开始：`seek()` 只在 `_realActive` 时作用到引擎，恢复走 `_startAudio()` 无 `resumeAt` | `AppState` 记录 `_resumePositionOnOpen`，中断/失败保留位置，手动播放时 `_startAudio(resumeAt:)`；曲目自然结束会清标志。`test/playback_resume_position_test.dart` |
| 2 | 高 | “我喜欢的音乐”页请求失败后永远转圈：`collectionsError` 无任何读取点 | 失败显示错误与“重试”，触发 `refreshCollections(force: true)` |
| 3 | 高 | 平台切换后“收藏的专辑 / 本地音乐”详情仍显示上一平台内容 | shell 在连接键变化时同时清 `_savedAlbums`、`_localMusic` |
| 4 | 中 | 系统返回手势预览的目标页恒为“发现”，与提交后的实际落点不同 | 用 `_backDestinationKey()` 复算 `_handleBack` 的落点（含歌手子页、库内详情） |
| 5 | 中 | 歌单/专辑头部的随机播放只是个圆圈图标，没有点击处理 | 头部新增 `onShuffle`，按 TV 同款逻辑打乱队列；无障碍按钮带 tooltip |
| 6 | 中 | `itemBuilder` 里 `GlobalKey()`：每次重建都换 key，回程封面会重复显示 | 新增 `StableCoverKey`（按条目身份缓存 key），首页/歌手页 5 处接入 |
| 7 | 中 | 播放器文档与 tooltip 宣传的 Q/F/L/C/M/Esc 快捷键不存在 | `NowPlayingPage` 增加裸键处理（跳过输入框与快捷键录制器）；`test/now_playing_shortcuts_test.dart` |
| 8 | 中 | 队列里同一首歌重复出现时两行都高亮为“正在播放” | 改用 `state.queueIndex` 判定当前行 |
| 9 | 中 | 未登录时播放条的红心可点但静默无效 | 未登录禁用并提示“登录后收藏”，`signedIn` 纳入重建签名 |
| 10 | 中 | 设置页所有开关对读屏器只报“开/关”，没有名称 | `SettingsRow` 外层 `MergeSemantics` |
| 11 | 中 | 下载弹窗在探测目录期间仍可被遮罩/Esc 关闭，关闭后仍写入音质与目录且任务丢失 | `PopScope(canPop: !_busy)`；目录未就绪时禁用“下载”；`mounted` 检查前置 |
| 12 | 中 | TV 搜索：输入新字符后旧请求返回被丢弃，`_searching` 永远为真 | 请求序号；输入即作废旧请求并清 loading |
| 13 | 中 | Linux 电视把设备形态改成“标准”后，局域网遥控器自行关闭，而大屏界面仍在 | `_active` 改为与 `TvScope` 同一判据（`deviceIsTelevision || surface == tv`）；新增测试 |
| 14 | 中 | 下载文件名冲突：不同歌曲 sanitize 后同名时，后来者直接“采用”已有文件，播放到错误音频并覆盖资料库记录 | 只有资料库已登记为同一 track 才复用；否则生成 ` (2)` 唯一名；并发任务先占位。`test/download_manager_test.dart` |
| 15 | 中 | 图表多选取消最后一行后，批量栏留在 0 选中的状态，无法退出 | 选中集为空时自动退出选择模式 |
| 16 | 中 | 字体文件丢失后只回退内存中的字体族，偏好仍指向坏文件，之后每次启动都重试 | 回退时同步写回 `lazer_font_preferences` |
| 17 | 低 | 语言下拉里的“跟随系统”未走翻译（副标题实际已翻译） | 下拉项改 `TrText` |
| 18 | 低 | 定时暂停删掉最后一个时间点后仍显示“已启用”，实际永不触发 | `setScheduledPause` 与 `decode` 都保证空计划即关闭 |
| 19 | 低 | HiFi 信号路径面板的失败原因与格式说明只有中文 | 8 个串补进四语言表；`output_path_state.dart`、`engine_selection.dart`、`hifi_controller.dart` 标 `i18n:data` |
| 20 | 低 | 本机降级到兼容引擎时用户完全看不到提示（`hifiPathNotice` 无消费点） | 壳层首帧后一次性 SnackBar 说明降级原因 |
| 21 | 低 | 启动引导链无兜底：插件通道/引擎/存储抛错会得到空窗口且无日志 | `main()` 捕获后记录 `AppLog` 并 `runApp(_StartupFailureApp)`；失败页也能读语言表 |
| 22 | 低 | 本机“文件已丢失”清理一键不可逆，存储未挂载时可能清空索引 | 清理前确认，并说明“只删记录、不删文件” |
| 23 | 低 | TV 批量栏被底部悬浮播放条盖住，遥控焦点被上层抢走 | 批量栏抬到 `transportHeight + 24 + safeArea` |
| 24 | 低 | TV 歌手页复用了同一 State，慢响应会把 A 歌手资料显示在 B 名下 | 增加请求序号与 artist key 校验 |

### 前端未修（已记录）

- 曲目卡片尾部 `⋯` 只是图标，点击即播放；是否接入菜单涉及产品取舍，留待设计确认。
- TV 浮层（队列/音量）没有独立 `FocusScope`，理论上方向键可逃逸到遮罩后的页面；需要先有稳定的焦点回归测试再动。
- 大屏队列面板位于下拉关闭手势的上半区，向下滚动可能触发关闭；属交互策略问题。
- 监听统计历史无上限（见后端 D3）。

---

## 第二轮：后端（音频、网关、存储、更新）

### 已修复

| # | 严重度 | 问题 | 修复 |
| --- | --- | --- | --- |
| 25 | 高 | 选择输出设备只写进偏好与 UI，Dart→native 的 `device_id` 恒为 `nullptr`，实际永远走系统默认设备 | worker 按平台把 token 编码成 `wchar_t*`（Windows UTF-16、其余 UTF-32），创建与 `set_device` 两条路径都传入并释放 |
| 26 | 高 | 第一次打开之后 `set_device` 一直被引擎以 `ErrorState` 拒绝，且返回值被丢弃：独占/缓冲/DSD 策略在换歌后全部失效 | `_applyOutputSettings` 检查状态，遇 `ErrorState` 先 `stop` 再重试一次；仍失败写路径日志 |
| 27 | 高 | bit-perfect/DoP/原生 DSD 下软件音量被拒绝，但 UI 与偏好照旧改小，滑块显示 30% 而实际 100% | 新增 `VolumeConstraintAudioEngine`；按引擎实际 `appliedVolume` 回弹、不持久化，音量控件提示由 DAC 控制 |
| 28 | 中 | 源码切换期间（`!_sourceLoaded`）引擎的 `Failed` / `DeviceLost` 事件被整体丢弃 | 终态事件先于 `_sourceLoaded` 判断处理 |
| 29 | 高 | 插件市场允许无 `sha256` 的条目安装可执行 Lua 包；重定向后的最终 URL 未校验 | 市场条目强制 64 位 sha256；下载后校验实际字节；重定向目标必须仍是 HTTPS 且无 userinfo。测试补齐 |
| 30 | 中 | 卸载插件只删插件目录，`lua_plugin_data/<id>/storage.json`（会话 Cookie/Token）永久保留，重装即复活 | 卸载同时删除数据目录与 `.backup-*`；新增测试 |
| 31 | 中 | 媒体请求规则全局共享：插件可注册任意 host/`*.com`，改写其它平台封面并把 Header 注入其音频请求 | 规则按清单 `permissions.network` 收口；禁止 `cookie/authorization/host/content-length` 等敏感头；公共后缀通配符拒绝；安装列表展示网络与存储权限。`test/media_request_rules_test.dart` |
| 32 | 低 | Lua 插件抛 `HTTP 401/429` 时状态码落在 `code`，登录失效与限流分类失效 | `_call` 将 400–599 的 code 同时映射为 `httpStatus` |
| 33 | 低 | 插件返回非列表/非对象时，一部分静默变成空结果，一部分抛裸 `TypeError` | `_page` 对“非空 Map 或标量”抛 `MusicGatewayException`；空表 `{}` 视为空页；新增 `_mapResult` |
| 34 | 中 | 后台/关闭前队列、收听统计、播放历史均为 fire-and-forget，进程被杀会回退到旧快照 | 新增 `AppState.flushPersistence()`，在 `onPause/onHide/onDetach` 等待；`PlaybackCache.flushHistory()` |
| 35 | 中 | 市场/更新检查并发：自动检查在途时点“检查更新”直接得到“已是最新版本” | `checkForUpdates` 复用在途 Future；手动调用加入同一次请求 |
| 36 | 中 | 同一版本更新弹窗可由自动与设置两条路径叠加 | 版本级互斥挂在 `AppState`（随实例回收） |
| 37 | 低 | `ReleaseVersion`：`2.0.0-` 被解析成正式版；`2.0.0-01` 与 `2.0.0-1` 相等但哈希不同 | 拒绝尾随 `-` 与非规范数字标识符；补测试 |
| 38 | 低 | 数据迁移失败后 pending 键永不清除：一个永远不可写的目标会在每次启动重试 | 记录尝试次数，连续 3 次失败后放弃并保留错误提示；用户重新选择目录会重置预算。`app_storage_test.dart` |
| 39 | 中 | 图表缓存键在 await 后重新读 `activeGateway`，切换平台会把 B 的榜单写进 A 的命名空间；切换时正在加载的刷新被直接丢弃 | 进入时固化 gateway/scope；刷新中再次请求排队，加载完成后补跑；切换后旧响应不再落地 |
| 40 | — | CI：mimalloc 预取只走 github.com，aarch64 runner 连续 504；GTK 插件下载无校验 | mimalloc 先试 codeload、双端点、重试预算 300s 并校验 MD5；GTK 插件固定 sha256 + jsDelivr 兜底；`check` job 增加 `python3 tool/check_i18n.py` |

### 后端未修（已记录，需单独立项）

- **Lua VM 内存预算**：只有 40s 墙钟与字节边界，`string.rep` 可在超时前耗尽进程内存；需要给 Lua 状态装分配器/指令预算。
- **监听统计无上限**：按天存储且每次全量重编码；正确做法是 30 天明细 + 归档聚合，涉及 schema 迁移。
- **下载队列不持久化**：重启丢队列，`.part` 残留；属于功能补齐而非缺陷修复。
- **存储目录回退的“双库”**：迁移失败期间继续使用回退目录，根目录恢复后两个目录不会自动合并；本轮只保证失败可见、重试有界，合并需要一次显式迁移设计。
- **AutoMix 重叠窗口的时长/缓冲显示**、**`playQueuedNext` 在已跨界时重复 open**：均有时序窗口，改动需要真机/探针验证，本轮不动。
- **原生 C++ 深层审计**：仅核对了 ABI 结构、符号、版本与 Dart 侧生命周期；DSP/输出后端仍以 CI 的 probe suite 为准。

---

## 第三轮：跨层与验证

### 机制性检查

- 自建扫描器 `tool/ui_audit/ui_audit_scan.py`：224 个 Dart 文件仅 3 条低置信提示，逐条人工复核均为已知安全模式（`MediaHandler.close()` 取消 timer、`_AlbumFlowTicker.unscheduleTick()` 取消 wake、AutoMix 40ms 时钟在 `dispose()` 取消）。
- Lua 插件 ZIP：路径穿越、符号链接、大小/数量上限、暂存回滚均已覆盖；本轮补的是“安装来源可信度”与“权限最小化”。
- 队列快照：原子写、索引夹取、修订号合并已有测试；本轮补的是生命周期冲刷。
- 原生 ABI：Dart 结构体与 `lazer_audio_api.h` 逐字段核对（`LazerAudioStreamInfo` 176B、`Snapshot` 80B、DSP 配置对齐、ABI 29 双端一致），未发现布局错误。

### 新增/改写的测试

`playback_resume_position_test.dart`、`now_playing_shortcuts_test.dart`、`volume_constraint_test.dart`、`media_request_rules_test.dart`、`download_manager_test.dart`（同名冲突、外来文件、并发）、`lyrics_test.dart`（LRC offset）、`lan_remote_test.dart`（电视形态）、`plugin_market_test.dart`（强制校验和、卸载清凭据）、`lua_plugin_test.dart`（公共后缀通配符）、`update_checker_test.dart`（版本解析）。

### 验证命令

```sh
flutter analyze                       # No issues found
flutter test                          # 1219+ 全绿
python -m unittest discover -s ci/tests -p 'test_*.py'
python tool/check_i18n.py
bash -n ci/package-appimage.sh
```

CI 侧还需在真实 runner 上验证：Windows 原生 probe、Linux 两个架构的 AppImage 打包、macOS/iOS 链接与 Android 签名。本轮已针对上一次失败的最小因子（mimalloc 504）做了可复核的加固。
