# Issues、播放资源与 Lua Native 整合审计

工作分支：`codex/desktop-tv-refresh`，目标分支：`nextgen`。
本次修改在 `Lazer-ui-refresh` 完成，并接续已整合的 Android HiFi 验收。
最终验证使用从分支 HEAD 创建的独立工作树，仅包含本次提交内容。

## Issue / PR 对应

| 来源 | 整合结果 | 回归入口 |
| --- | --- | --- |
| #67 / PR #68 | 改变随机、循环和切歌模式时只替换尚未发声的后继；已经开始混音的后继保留绑定，不重开当前音源 | `gapless_queue_test.dart`、原生 gapless probe |
| PR #69 | 三种切歌模式、1–13 秒 AutoMix 时长、持久化、设置界面；配置请求串行且只保留最新待处理项 | `track_transition_settings_test.dart`、`gapless_queue_test.dart` |
| #70 / PR #72 | 歌词模糊显式采用透明边界采样，极小淡出范围避免退化渐变 | `lyric_filter_regression_test.dart` |
| #71 / PR #72 | Linux 默认普通播放使用 ALSA default 共享路由；明确硬件选择、独占、bit-perfect 和直接 DSD 保持严格请求，不静默降级 | `alsa_route_probe` |
| #53 | 保留插件能力驱动的创建、邀请和加入一起听，无匹配步骤；修复账号切换、迟到响应、重复开房、远端暂停与队列同步 | `listen_together_session_test.dart`、`listen_together_commands_test.dart` |

PR #68、#69、#72 的原始贡献来自 VincentZyu233 和 gemini-code-assist。
整合保留其设计意图，并针对当前分支的播放状态机和 HiFi 路径重新实现、复审。
一起听仍依赖音乐平台插件提供房间服务；没有添加跨平台房间服务器。

## 拆分与资源边界

| 资源 | 边界与生命周期 |
| --- | --- |
| 音频操作 | 独立 `AudioOperationQueue`；打开、定位、配置保留有界最新请求，停止可以取消待执行项 |
| Worker RPC | 普通在途消息最多 256，另留 2 个停止/销毁槽位；worker 退出会结束 pending，关闭需实际退出确认 |
| 网络音源 | 缓存管理与单次下载拆分；磁盘写入异步且有背压；取消同时终止响应正文与连接；完成信号等到写入句柄关闭 |
| 下载缓存 | 默认 8 个文件，跨启动也计算旧文件；活跃读者持有 lease，LRU 不淘汰正在播放或已准备的音源；全被占用时拒绝预取 |
| 歌词持久化 | 同歌曲、同音源路径共用一个 Future；同时最多 32 个任务，满载跳过可选持久化；前台歌词读取不受此预算影响 |
| 电台 | 独立 `StationSession` 与队列扩展；历史最多 256 首、去重记录 1024 条、单批 30 首；普通歌单不截断 |
| 电台异步请求 | 一个 provider 请求、一个完成监听器；20 秒等待超时后复用未完成请求；换会话或退出立即使旧结果失效 |
| 一起听 | 成员与共享队列各最多 200；命令、发布、远端歌曲查询各一个执行中及一个最新待执行项；状态与队列拉取复用在途请求 |
| 原生 PCM | 输出 ring、后继 PCM、AutoMix 延迟数据各 32 MiB 预算；重采样提交缓存按块使用 |
| 音乐分析 | 六秒分析窗口最多 48 kHz 单声道；48–768 kHz、8 声道输入实测窗口均为 1,152,000 字节；播放样本不经过该分析降采样 |
| 悬浮歌词 | 单个窗口所有者；关闭确认后才允许新窗口；慢 IPC 合并状态；关闭、暂停、纯逐行歌词和减少动态效果各自停止不需要的轮询或帧时钟 |
| 自定义字体 | 主引擎每次启动最多 8 个 family、累计原始字体 64 MiB，读取前预留并包含在途任务；overlay 换自定义字体前回收旧引擎，另设累计 64 MiB 防御限额 |

原生解码在 `send_packet(EAGAIN)` 时先取出已解码帧，再重送未消费包，避免丢样本。
缓存收尾等待已登记的流写入、串行 JSON、文件访问及后续维护全部完成；上游歌词任务可明确 join 后再 drain，播放返回不等待扫描或歌词持久化。
Seek 清理使用消费端确认，避免生产端释放消费者仍在复制的 ring 存储。
原生 clear/stop RPC 异常不会立即释放 native 仍可能引用的 reader。只有确认 worker 已退出且从未提交 destroy，才能同步兜底销毁；destroy 已提交但回复丢失时不重试同一指针。无法确认清理时保留一个有界 owner（含回调、USB 连接及最多 4 个 reader）、停止轮询并拒绝再建 native 引擎，显示重启提示，避免释放后访问或重复销毁。此异常策略不代表仍可继续正常播放。
电台裁剪保留当前、混音来源及已准备后继，再一起平移索引；随机模式下位于旧历史的后继也不会被删除。等待中的手动切歌按歌曲和选择代次验证，不把索引平移误判成另一首歌。
绝对定位允许回到零，等待音源打开的定位不会穿透到同 ID 的另一播放会话。
混音期间按比例定位先跟随引擎回到原曲，再以原曲时长计算目标；不同曲长不会产生越界定位。
心动模式初始推荐的迟到响应也校验账号、选择代次、当前歌曲及播放状态，不覆盖等待期间的新队列或暂停操作。
心动推荐种子由首曲及上一批末曲传到实际 gateway，保留完整歌曲标识；其他平台或账号的歌曲不会被误当作当前账号种子。

## UI 交互

收藏专辑按平台和账号隔离在途请求，清理旧封面键；搜索输入等待 300 毫秒后读取，自动最多再读 8 页。
首批命中或自动搜索预算耗尽后，仍有“加载更多专辑”入口，后页匹配项可达。
文本编辑弹窗由自身 State 持有 controller，退出动画结束前不释放；小窗口可以滚动，重复关闭不会误退出下一层。
一起听的迟到退出只关闭自己的 route，不 pop 覆盖在它上方的新弹窗。
账号退出等待房间 leave 或音频 stop 时，每次恢复都核验队列活动代次、音源代次及当前歌曲；用户期间选择的新歌曲不会被旧队列快照覆盖。发生变化时从最新队列重新移除退出账号的内容。

悬浮歌词的窗口、运动、呈现与字体加载分开管理；字体加载完成重新测量，尺寸请求串行合并。
Windows 点击区域、锁定时钟、DPI 切换和显示器移除处理详见
[UI 后续审计](ui-followup-audit-2026-11-18.md)。

## Lua Native

`host.native()` 提供支持表；`audio.status`、`audio.devices` 使用独立的 `native_audio` 数据权限。
`lyrics.status`、`lyrics.configure` 使用 `native_control` 权限，只读写启用模式、锁定和行数。
每次异步恢复后重新核验授权；撤销或卸载后的迟到配置不会继续改变设置。
设备接口读取缓存目录，不触发扫描、USB 权限申请或设备打开；不导出文件路径、句柄、指针或任意平台通道。
UI 与 Lua 共享歌词设置写入器，避免旧持久化写入覆盖新选择。

协议、错误结果和平台限制见 [Lua 插件文档](lua-plugins.md)，
可导入示例见 [Native diagnostics](../examples/lua-native-diagnostics/README.md)。

## 验证与边界

最终隔离工作树 `flutter analyze --no-pub` 无问题，Flutter 全量测试 561 通过、2 跳过；跳过项依赖外部平台插件 checkout。
CI Python 测试 97 项通过；四语言文本检查无缺失、无过期键。
CI 同时运行 Lua Native 的真实 Web runtime 契约和悬浮歌词 DPI/点击区域的原生几何契约。
Windows Release 原生设备无关测试 24/24 通过，包括 gapless、CUE、ring stress、软件 bit-perfect 和新资源预算合同。
ARM64、ARMv7 原生 engine 编译通过。
两架构可重链接包各验证 193 项材料校验值、16 个 engine object、5 个静态 archive 及 165 个 libusb 源文件；从解包材料执行 `relink.sh` 成功，重生成的 ELF 通过 ABI、依赖及 16 KiB 对齐检查。
Lua Native Chrome 专项通过真实 Web runtime；本机 Flutter 工具的 Windows CanvasKit 路径返回 404，
验证中仅向隔离测试浏览器补供相同 SDK 文件，未修改 SDK 或产品源码。

Windows x64、Android ARM64/ARMv7 与 Web JavaScript Release 构建通过。
Web 的 Wasm dry run 仍报告现有 native FFI 引用不支持 Wasm；此处验收的是 JavaScript 产物。
Windows 包从无关工作目录成功加载 engine、reader bridge 和 FFmpeg，主 isolate 与 worker isolate 均通过；原生路径检查没有回落到备用引擎。
Android APK 的双 ARM 核心载荷、ABI 导出、系统依赖、16 KiB ELF/ZIP 对齐、FFmpeg 打包排除及 v2 签名检查通过；签名使用本地 debug 证书，不是发行密钥。
APK 与 Windows ZIP 均通过完整 CRC 校验。

本地产物位于 `build/issue-pr-integration/dist/`，不提交二进制到源码仓库：

| 产物 | 字节 | SHA-256 |
| --- | ---: | --- |
| `Lazer-Android-ARM.apk` | 91,925,526 | `4ce4bbe33621eb37c1386ea622ae1180d88c234d2907f63842fbdcd6b126af5a` |
| `Lazer-Windows-x86_64.zip` | 61,919,143 | `706e6e64ddc89683a4a61933891cf6dc537544ae5efe19f06bdd604dae96e3b4` |
| `Lazer-Android-Audio-Relink-arm64-v8a.tar.gz` | 3,653,525 | `3ed69e930191ddaa7adb1966098b5d0c6ea1982f3cbbef89b8a055b19fcf5057` |
| `Lazer-Android-Audio-Relink-armeabi-v7a.tar.gz` | 3,530,437 | `012fdf60ab8ddc02e4f03ca69bb6b2d736d19d4c9c6835ded5fad50e9758f538` |

资源预算是可重复的容器与缓冲合同，不是全进程 RSS/CPU 或所有音源零欠载的测量结论。
上述测试不等同于 USB DAC 真机、物理 bit-perfect、真实 Linux/Wayland GPU 或多显示器拖动验收。
这些设备检查的操作和证据标准继续使用 [HiFi 验收](hifi-acceptance-2026-11-18.md)
与 [硬件验证](audio-engine-hardware-verification.md)。
