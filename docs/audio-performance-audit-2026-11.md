# 音频引擎与项目性能审计（2026-11-07）

## 结论

手动切歌时短暂变响已定位为新 PCM 会话首块没有继承用户增益。旧实现把 DSP 音量重置为 100%，随后才按 200 ms 斜坡降到设置值；Native 引擎在打开来源时已经开始解码并预填输出环，因此过渡样本会先以接近满音量输出。

根因先由同一份 Engine 假输出探针在基线和修复版两边确认：基线静音时首样本为 `-8192`（预期 `0`）；修复版在 0%、1%、10%、50%、100% 五档都从第一帧符合目标增益。打开后、播放前调音量及 100 帧短音源预缓冲刷新也通过。假输出探针捕获 DSP 后、设备写入前的 PCM；Windows 实际系统输出另由下方 WASAPI loopback 探针测量。

同一 Engine 停止并打开下一首的手动切歌路径也做了跨格式验证：从 44.1 kHz/16-bit 切到 96 kHz/24-bit，基线首样本是 `-2097152`，而 10% 增益期望 `-209715`；修复版首样本符合期望，说明重新配置格式后增益从第一帧生效。

此外，Windows 生产 WASAPI 共享模式通过 loopback 直接捕获到实际提交给系统音频端点的输出。10% 软件增益下，默认“耳机 (Realtek USB Audio)”端点跨格式切歌时首 200 ms 与 500–900 ms 稳态峰值均为 `0.025000`（比值 1.000）；同一 Engine 再切到“Realtek Digital Output (Realtek USB Audio)”后，两段峰值均为 `0.000817`（比值 1.000）。该实测覆盖了格式重开和 Windows 输出路由变化；loopback 位于系统渲染路径，不代表 DAC 模拟输出或扬声器声压。

这轮只修改有代码依据或实测收益的路径：初始化与 Ready 状态的音量屏障、音量错误回报、DSP 阶段配置并发和逐块开销，以及一个存在截止时间竞态的桥接测试。其他已检查的状态、缓存、曲库和 UI 路径没有证据支持扩大重构。

## 发现与修复

| 严重度 | 当前代码依据 | 发现及影响 | 修复与验证 |
| --- | --- | --- | --- |
| 高 | `native/lazer-audio/src/dsp_chain.cpp:355`、`native/lazer-audio/src/engine.cpp:734`、`lib/state/app_state.dart:3141` | `configureFormat()` 曾将音量清为 unity；Native 打开流程同时启动生产者。状态层原先在 `setUrl`／`setQueue` 之后才传入用户音量，首块 PCM 有机会以默认增益入环。跨格式重新打开同一 Engine 也会重配 DSP。 | `configureFormat()` 接收当前增益；AppState 在打开来源前应用音量、打开后再核对。相同 PCM 探针在基线 `8b86234` 上静音首样本为 `-8192`（预期 0），并在 44.1/16 → 96/24 的 10% 切歌首样本输出 `-2097152`（预期 `-209715`）；修复版五档首帧、加载后调音量、短音源和跨格式重开用例通过。 |
| 高 | `native/lazer-audio/src/engine.cpp:1189`、`native/lazer-audio/src/engine.cpp:1409`、`lib/state/app_state.dart:599` | Ready 状态下改变音量时，旧增益 PCM 已在输出环中；若只改 DSP 目标值，旧样本仍会成为播放首帧。并发拖动音量也可能让陈旧请求覆盖最新值。 | Ready 状态的变化会保留位置、请求真实 seek、清空旧预缓冲并立即设置新增益；`play()` 等待新增益 PCM 入环后再启动。AppState 将音量调用串行化、跳过过期请求，并在失败时恢复最后一个实际生效值。原生首样本探针及 12 项 Native successor、反馈状态测试通过。 |
| 审计通过 | `lib/audio/automix_audio_engine.dart:246`、`lib/audio/automix_audio_engine.dart:265`、`lib/audio/automix_audio_engine.dart:590` | 兼容 AutoMix 双播放器涉及活跃播放器加载、静音预载 successor 和手动／自动交接；若先启动新播放器再设置增益，会有首帧过大风险。 | 活跃源在 `play()` 前先应用用户增益；预载播放器在加载前设为 0；晋升时先设为当前用户增益，再启动新播放器并停止旧播放器。generation 检查和串行队列丢弃过期加载。现有 AutoMix 测试覆盖等功率增益、准备 successor、手动／自动 handoff；静态顺序审计未发现需修改的缺陷。 |
| 中 | `native/lazer-audio/src/engine.cpp:1721`、`native/lazer-audio/src/engine.cpp:1728`、`native/lazer-audio/src/engine.cpp:2036` | seek 确认来自预读线程时，输出环清理必须仍由唯一的生产者线程完成；跨线程直接清环会与当前 PCM 写入竞争。 | seek 回调只发布“已应用”信号，泵线程在块边界执行清环、时间线重置和确认事件。gapless、seek 后暂停恢复、PCM 重开与环形缓冲压力测试通过。 |
| 中 | `native/lazer-audio/src/dsp_chain.cpp:449`、`native/lazer-audio/src/dsp_chain.cpp:524` | DSP 配置曾在释放配置锁后读取待处理阶段顺序，存在与设置线程并发修改向量的数据竞争；每块处理还会复制阶段向量，默认顺序需要临时分配。 | 顺序与其他待处理参数在锁内一并快照；无配置更新时通过原子脏标志跳过设置锁。处理热路径直接遍历已安装顺序或静态默认顺序。DSP 并发探针通过；同机固定块微基准从 30,000 次分配降为 0。 |
| 中 | `lib/audio/native/lazer_audio_engine.dart:667`、`lib/audio/native/lazer_audio_engine.dart:688`、`lib/state/app_state.dart:611` | 原生音量状态码曾被忽略；Bit-Perfect、DoP、Native DSD 拒绝软件音量时，界面可能保留没有实际生效的值。 | 检查 worker 返回状态并保留原生错误详情；直通能力拒绝会报告有效增益 100%，状态层同步恢复该值。新增拒绝、错误恢复与加载前应用顺序测试通过。 |
| 测试稳健性 | `tool/native_bridge_check.dart`、`native/lazer-audio-bridge/src/growing_reader.cpp:32` | Dart 桥接检查原先等待 150 ms 后才写入数据，与原生每次读取 150 ms 的让出窗口相同；调度稍慢时读调用先返回 0，随后游标断言连锁失败。原生桥接 CTest 本身通过。 | 工作 isolate 现在会明确通知“即将进入原生 read”，主 isolate 在 50 ms 内追加数据；避免把两个独立事件绑定在同一截止点。`dart analyze` 无问题，桥接端到端检查连续 3 次通过。 |

## 全项目检查与实测

检查了 Native engine / worker / FFI、播放状态与调度、AutoMix 和 ReplayGain、DspChain 与 PCM 环形缓冲、网络响应解析、本地曲库读写、扫描、播放通知和帧统计。已确认的边界包括：本地清单与网关 JSON 超过 64 KiB 后交给 isolate（`lib/local/local_library.dart:193`、`lib/gateway/response_decoder.dart:8`）；曲库扫描最多处理 5,000 首（`lib/local/local_music_scanner.dart:48`）；扫描进度按 100 ms 合并（`lib/local/local_music_scan.dart:99`）；播放状态心跳 100 ms（`lib/state/app_state.dart:535`）；帧统计最多保留 150 帧并每 250 ms 通知（`lib/diagnostics/frame_stats.dart:27`）。这些路径通过了现有检查或本轮合成 profile，没有出现足以支持进一步改动的回归证据。

所有 UI / 曲库数据来自既有 profile 工具生成的合成素材。下面是 Windows 主机上 Flutter Profile / Release 构建各运行三次的结果；未将合成结果解释为实体设备或真实用户库指标。

| 工具 / 场景 | 三次中位数 | 三次范围 | 样本条件 |
| --- | ---: | ---: | --- |
| `queue_switch_profile.dart`：切换调用 p95 | 0.156 ms | 0.154–0.163 ms | 5,000 首队列，40 次切换 |
| 队列切换：build / raster p95 | 0.491 / 1.508 ms | 0.478–0.519 / 1.502–1.528 ms | 同上；每次 0–2 帧间隔超过 16.7 ms |
| `player_lifecycle_profile.dart`：活动歌词页 build / raster p95 | 0.456 / 2.492 ms | 0.454–0.459 / 2.429–2.629 ms | 200 行合成歌词 |
| `local_library_profile.dart`：5,000 首清单载入 p95 | 49.820 ms | 49.190–52.148 ms | 文件 1,929,489 bytes；vsync p99 6.067 ms，未出现 >16.7 ms 间隔 |
| `local_library_write_profile.dart`：12 次写入 p95 | 29.509 ms | 28.591–30.912 ms | 文件约 1.62 MB；vsync p99 6.067 ms，未出现 >16.7 ms 间隔 |
| `resource_usage_profile.dart`：165 Hz 显示刷新动画 | CPU 10.311% / 1 核 | 8.435–13.433% / 1 核 | Release；build p95 0.117–0.125 ms，raster p95 0.177–0.181 ms |

队列切换还使用 `HEAD` 提交 `8b86234` 的独立 worktree，在同一 Windows 主机、Flutter Profile、同一脚本与 5,000 首合成队列下配对运行三次。基线与当前的调用 p95 中位数分别为 0.166 ms（0.164–0.173）和 0.156 ms（0.154–0.163）；build p95 为 0.620 ms（0.475–0.648）和 0.491 ms（0.478–0.519）；raster p95 为 1.522 ms（1.497–1.553）和 1.508 ms（1.502–1.528）。区间有重叠，帧间隔计数也相近，因此仅作为“没有明显回退”的证据；调用耗时是队列调度调用，不等同于解码完成或实际出声延迟，也不足以证明全应用性能提升。

资源 profile 的 10 Hz / 30 Hz / 静态场景三轮都有效且可见。165 Hz 动画场景采样结束 RSS 中位数约 111.3 MB；静态场景 CPU 0–0.312% / 1 核。Windows 未向探针报告初始 Flutter lifecycle 值，但窗口保持可见、未最小化，采样期间无 lifecycle 事件；脚本标记的三轮场景均为 valid。资源结果是 profile 进程值，不包含 GPU 利用率。

DSP 固定块微基准沿用同机、MinGW GCC `-O2`、44.1 kHz 立体声默认链、128 帧、每轮 30,000 块和三轮比较：基线 6.543–7.331 ms（中位数 6.746 ms），修复后 0.475–0.524 ms（中位数 0.494 ms），阶段列表分配从 30,000 次降到 0，处理时间降低约 92.7%。这是隔离 DSP 热路径收益，不代表全应用 CPU 降幅。歌词核心计算的既有三轮基线也已保留在此轮审计的前序数据中；UI 级生命周期结果以上表为准。

## 验证

- `flutter analyze --no-pub`：通过，无问题。
- `flutter test --no-pub --reporter expanded`：1,218 项通过。
- `python -m unittest discover -s ci/tests -p 'test_*.py'`：28 项通过。
- MSVC 2022 x64、Release、DSD 版 FFmpeg 下构建 `native`；完整 CTest 套件 22/22 通过，303.58 秒，覆盖 Bit-Perfect PCM、AutoMix/gapless、ReplayGain、seek、短音源、环形缓冲恢复、DSP/PCM、DoP/DSD，以及 WASAPI 格式策略、CoreAudio 队列/格式策略、ALSA 恢复/打包策略等可移植探针。它们不是在 macOS/Linux 运行 CoreAudio/ALSA 后端。随后将 Engine 音量探针扩展为跨格式重开同一 Engine；该探针完整输出通过，最终目标 CTest 1/1 通过。
- Native ABI 输出与 Dart 镜像：C++ ABI layout probe 完成；`dart tool/native_abi_check.dart` 检查 14 个结构体通过。
- `tool/native_bridge_check.dart` 对构建出的 Windows bridge DLL 连跑 3 次通过。
- Android backend/ABI 交叉检查：本机 NDK `28.2.13676358` 的 AAudio API 26 编译器入口 `aarch64-linux-android26-clang++.cmd`、`armv7a-linux-androideabi26-clang++.cmd`、`x86_64-linux-android26-clang++.cmd` 均以 `-std=c++20 -fsyntax-only` 检查 `native/lazer-audio/src/output_aaudio.cpp` 通过；另用 NDK CMake 将 `lazer-uac2` 及其 libusb 在 `arm64-v8a`、`armeabi-v7a` 编译链接成功，并用 `llvm-readelf`/`llvm-nm` 验证 ELF 架构和 JNI 导出。这些检查不等于带 FFmpeg 的完整 Android engine/package 或设备输出测试。
- Windows 实际共享模式输出：构建 `lazer-audio-wasapi-loopback-probe` 并运行 `build/native-probes/lazer-audio/Release/lazer-audio-wasapi-loopback-probe.exe`。工具播放 25% 满幅的临时合成 WAV，软件增益设为 10%，loopback 捕获首 200 ms / 500–900 ms 峰值；44.1/16 → 96/24 同端点跨格式重开及切到第二活动端点均为 1.000 比值，工具通过。该探针是显式手动工具，不加入自动 CTest，也不读用户媒体。
- `git diff --check` 通过；Flutter lockfile 和 CI 配置没有修改。

## 数据边界与待验证项

原生固定样本探针来自完整 FFmpeg 解码/DSP 加假输出端；Windows 另用生产 WASAPI 共享输出和系统 loopback 做了格式重开、输出端点切换测量。loopback 不测硬件音量控制后的模拟信号，也不测扬声器声压。Windows Release/Profile UI 数据来自合成界面。Android SDK 平台 34–36 与 NDK `28.2.13676358` 已安装，ADB 无连接设备且没有 emulator 可执行文件；AAudio 翻译单元的三 ABI 检查和 UAC2 的 arm64/armv7 构建通过，但 Android DSD FFmpeg SDK 未构建。仓库的完整 Android 音频构建脚本需 Linux/macOS 主机，本机没有 WSL 发行版。Windows 环境没有 Apple Xcode 工具链或 Linux ALSA 主机，因此 iOS RemoteIO 完整构建、macOS/Linux 后端运行和 Android 完整 engine/package 的输出仍待相应工具链与设备；Flutter 设备列表也没有 Android/iOS 实机或模拟器。CoreAudio/ALSA 的可移植格式、队列和恢复探针以及跨平台包校验脚本的 Python 单元测试已通过，但不等同于这些平台的真实音频输出验收。

应用级 profile 在本轮测得当前基线，没有为 queue、lyrics、library 或后台资源报告宣称修复前后的全应用百分比；只有 DSP 热路径具备配对基线与修复后数据。没有证据支持改动网络并发、缓存淘汰、曲库调度或 UI 职责拆分，相关架构保持不变。
