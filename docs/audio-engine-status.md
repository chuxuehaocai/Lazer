# 原生音频引擎事实基线（阶段 0）

本文档是阶段 0 的交付物：在改任何代码之前，先把"当前代码到底做了什么"固定下来，
并逐项对照阶段 1–4 的目标，标出真实差距。

约定：

* 每条结论后面给出依据，形式为 `路径:行号`（代码）或 `[日志]`（本机构建 / 运行输出）。
* 本文档只描述**已核实**的事实。文档与代码冲突时以代码为准，冲突记在第 7 节。
* 快照：分支 `nextgen`，提交 `2592602`，核实时间 2026-10-31，宿主 Windows x64。
* 本机环境：Flutter 3.47.8（`D:\flutter`）、VS 2022 Community、Windows 开发者模式=1、
  非管理员账号、DSD-capable FFmpeg 前缀 `build/third_party/ffmpeg`。

---

## 0. 摘要

| 目标（任务书） | 现状 | 判定 |
| --- | --- | --- |
| 原生引擎必须是默认输出路径 | 桌面端**已经是**默认路径（引擎存在时），代码默认值 + 运行日志双重确认 | 已成立，缺"证明它在 CI 里被断言" |
| just_audio 只能作为显式降级回退且 UI 可见告知 | 回退逻辑存在，但原因可能丢失；只有设置页有"兼容引擎"字样，播放器/全局无提示；运行期设备丢失不降级 | 部分成立，阶段 1 主要工作量 |
| Bit-Perfect 必须可观测（独占 + 无 DSP + 格式一致） | `bit_perfect_active` 是**打开时的一次性宣称**，DSP 可被静默忽略，三个条件未拆开暴露 | 未成立，阶段 2 主要工作量 |
| 输出侧时钟驱动消费 + 无锁环形缓冲 | 环形缓冲与设备时钟驱动**已实现**；但实时消费线程仍有取互斥量、堆分配两处违反 | 部分成立，阶段 3 是收敛工作 |
| DSP 是显式有序链（可排序/开关/旁路） | 固定顺序链，模块契约与排序不存在 | 未成立，阶段 4 |
| 可观测性先于优化 | 引擎侧已产出欠载/水位等原始数据，Dart 侧**完全没读** | 未成立，阶段 2/3 |

一句话：**这个引擎比任务书假设的成熟得多**（环形缓冲、设备时钟、逐 bit 直通路径、
离线逐字节探针都已存在），真正的缺口集中在**可观测性、状态语义与 UI 暴露**上，
而不是"把引擎从零建起来"。

---

## 1. 构建开关与产物

### 1.1 CMake 开关

| 开关 | 默认 | 定义位置 | 作用 |
| --- | --- | --- | --- |
| `LAZER_AUDIO_NATIVE_ENGINE` | `ON` | `native/CMakeLists.txt:27` | 是否构建 `lazer-audio` 引擎 |
| `LAZER_AUDIO_NATIVE_PROBES` | `OFF` | `native/CMakeLists.txt:29` | 是否构建 17 个离线 CTest 探针 |
| `LAZER_FFMPEG_ROOT` | 未设置 | `native/CMakeLists.txt:36-71` | DSD-capable FFmpeg 前缀 |

`LAZER_FFMPEG_ROOT` 的解析顺序（`native/CMakeLists.txt:36-71`）：
CMake 变量 → 环境变量 `LAZER_FFMPEG_ROOT` → 环境变量 `FFMPEG_ROOT` →
`third_party/ffmpeg` → `native/ffmpeg` → Windows 缓存
`build/native-ffmpeg/windows-<platform>` / `build/windows-ffmpeg-local`。

找不到前缀时的行为是**显式跳过引擎并打印状态**，不是报错：

```
native/CMakeLists.txt:78-81
"lazer-audio: no DSD-capable FFmpeg found (set LAZER_FFMPEG_ROOT), so the
 native engine is not built. The app will use just_audio."
```

| 运行时变量 | 位置 | 作用 |
| --- | --- | --- |
| `LAZER_AUDIO_LIBRARY` | `lib/audio/native/lazer_audio_library.dart:587` | 单进程覆盖引擎库路径 |
| `LAZER_AUDIO_BRIDGE_LIBRARY` | `lib/audio/native/lazer_audio_library.dart:588` | 单进程覆盖桥接库路径 |

引擎选择**不经过 `dart-define`**，只经过 `SharedPreferences` 的 `hifi_native_engine`
（默认 `true`，`lib/state/hifi_settings.dart:523`、`612`）。

### 1.2 平台接入

| 平台 | 构建接入 | 证据 |
| --- | --- | --- |
| Windows | `windows/CMakeLists.txt:65-68` 把 `native/` 加进 Flutter 构建；`:118-120` 把引擎与 FFmpeg DLL 安装到 exe 目录 | 代码 |
| Linux | `linux/CMakeLists.txt:79-80`、`:116` 安装到 `bundle/lib/` | 代码 |
| macOS | **没有任何构建接入**：`macos/` 下无 CMake 步骤、Xcode 工程不引用引擎；只能手动或 CI 拷贝 `.dylib` 进 `.app/Contents/MacOS` | `macos/` 目录 + `.github/workflows/build.yml:231-256` |
| Android | `ci/build-android-audio.sh:16-32` 为 `arm64-v8a`/`armeabi-v7a`/`x86_64` 三个 ABI 构建并暂存到 `jniLibs` | 代码 |

### 1.3 CI 启用情况

| Job | 构建原生引擎 | 关键变量 / 命令 | 运行原生测试 |
| --- | --- | --- | --- |
| `check` (ubuntu-22.04) | 否 | `build.yml:41-47` 只跑 `flutter analyze`/`test` 与 AAudio **契约**测试 | 仅 AAudio 契约（`build.yml:47`） |
| `windows` | 是 | `build.yml:58-60` 设 `LAZER_FFMPEG_ROOT`；`:75-84` 自建 DSD FFmpeg；`:84` `flutter build windows --release`（经 `windows/CMakeLists.txt` 自动带引擎）；`:85-94` 再拷 `build/native-audio` 的 DLL；`:98-112` `native-bundle-check` 验证产物能加载 | 否 |
| `linux` | 是 | `build.yml:314-321` 把 `LAZER_FFMPEG_ROOT` 写入 `GITHUB_ENV`；`:322-331` 构建 + 拷 `.so` 进 bundle | 否 |
| `macos-native` + `macos` | 是 | `build.yml:149-166` 构建 dylib；`:209-256` 按架构 `lipo` 后放进 `.app` | 否 |
| `android` | 是 | `build.yml:392` `ci/build-android-audio.sh`；`:429` APK 校验 | 否 |
| `ios` | 不适用 | `build.yml:465-500` | 否 |

**关键缺口：整个 CI 没有任何 job 打开 `LAZER_AUDIO_NATIVE_PROBES`，也没有 job 运行引擎的
17 个 CTest 探针。** `LAZER_AUDIO_NATIVE_PROBES` 只出现在 `docs/`、本机脚本与 `native/` 内部
（`grep -rn NATIVE_PROBES .github/ ci/` 无结果）。这意味着逐 bit 的 PCM 矩阵探针
（阶段 2 的核心证据来源）目前**不在任何自动化门禁内**。

---

## 2. 本机验证记录（2026-10-31）

### 2.1 构建（默认产物）

```powershell
$env:LAZER_FFMPEG_ROOT='D:\Lazer\build\third_party\ffmpeg'
flutter build windows --release --no-pub
```

[日志]

```
Building Windows application...  64.6s
√ Built build\windows\x64\runner\Release\lazer_nextgen.exe
```

产物目录中同时出现引擎与它的依赖：

```
build/windows/x64/runner/Release/
  lazer-audio.dll  lazer-audio-bridge.dll
  avcodec-63.dll avformat-63.dll avutil-61.dll swresample-7.dll ...
```

### 2.2 产物内的引擎确实可加载

把 `tool/native_bundle_check.dart` 编译进 bundle，**从无关工作目录**运行（与 CI 相同的检查）：

```
$ dart compile exe tool/native_bundle_check.dart -o build/windows/x64/runner/Release/native-bundle-check.exe
$ cd $env:RUNNER_TEMP && ./native-bundle-check.exe
FFmpeg avformat 63.17.100, avcodec 63.25.101, swresample 7.7.100
Native engine and reader bridge load in both isolates.
exit=0
```

### 2.3 默认产物实际走哪条路径

直接运行 release 产物并抓 stdout（runner 会 attach 父控制台，`windows/runner/main.cpp:12`）：

```
package:media_kit_libs_windows_audio registered.
Audio engine: FFmpeg avformat 63.17.100, avcodec 63.25.101, swresample 7.7.100
Audio engine: native (lazer-audio)
```

`Audio engine: native (lazer-audio)` 来自 `lib/main.dart:117`，即 `AudioEngineSelection.description`
（`lib/audio/engine_factory.dart:39-41`）。**默认产物走原生引擎**。

### 2.4 引擎缺失时的降级路径

把 `lazer-audio.dll` 等移走后重跑同一个产物：

```
lazer-audio unavailable: lazer-audio.dll was not found in the app bundle, configured override, or development checkout
Audio engine: falling back to just_audio (lazer-audio.dll was not found in the app bundle, configured override, or development checkout)
Audio engine: just_audio (lazer-audio.dll was not found in the app bundle, configured override, or development checkout)
```

降级本身正确、原因明确（`lib/audio/engine_factory.dart:75-80`），但**只出现在日志里**；
用户可见的只有设置页的一行（见 3.1）。

### 2.5 引擎离线探针套件

```
$ build\ctest_probes.bat
100% tests passed out of 17
Total Test time (real) = 47.76 sec
```

17/17 通过（`docs/audio-engine.md:230` 记的是 16/16，交叉馈送探针加入后变成 17——
**文档数字已过期**，见第 7 节）。

### 2.6 与文档冲突的环境结论

`docs/audio-engine.md:252-257` 断言"这台机器不能构建 Flutter 应用（需要开发者模式/管理员）"。
实测**不成立**：开发者模式已启用（`AllowDevelopmentWithoutDevLicense=1`），
`flutter build windows --release` 与 `flutter test` 所需条件均满足，2.1 已完成一次完整 release 构建。
这条断言必须作废，见第 7 节。

---

## 3. 逐项对照阶段 1–4

### 3.1 阶段 1：让原生引擎成为默认路径

| 目标项 | 现状 | 依据 | 差距 |
| --- | --- | --- | --- |
| 引擎是默认路径 | **已成立**（宿主与产物层面） | `lib/main.dart:112`（`preferNative` 默认 true）、`lib/state/hifi_settings.dart:523,612`、[2.3 日志] | 缺"CI 中可自动断言的证据" |
| CI 保证发布产物含引擎 | **已成立** | `build.yml:60,88-94,321,326-331,392`、[2.1 构建] | 无 |
| 初始化失败回退 just_audio | **已成立** | `lib/audio/engine_factory.dart:59-81`、[2.4 日志] | 见下一行 |
| 回退原因必须准确上报 | **有缺陷**：`engine_factory.dart:75` 用 `LazerAudioLoader.load().reason` 当原因；当**库能加载但 `lazer_audio_create` 失败**（无可用设备、被其它独占程序占用）时该值为 `null`，UI 只会显示裸 `just_audio` 而没有任何原因。`_nativeUnavailableReason` 还是静态可变字段（`:43`），跨调用残留 | 代码 | 需要区分"库不可用"与"设备初始化失败"两类原因 |
| UI 可见"当前非 HiFi 路径" | **部分成立**：仅设置页 `lib/widgets/hifi_settings_section.dart:96-118` 显示"原生引擎/兼容引擎"+原因，`lib/widgets/hifi_settings_section.dart:362` 另有"当前使用 just_audio / media_kit，没有独占与 DSP 能力"；**播放器页与全局没有任何指示** | 代码 | 需要最小全局标识 |
| 运行期设备丢失的降级与上报 | **上报有、降级无**：设备丢失 → `failures` → `AppState._onEngineFailure` → `_failPlayback`，只停播并显示错误文案（`lib/state/app_state.dart:2938-2941`、`2924-2932`）。引擎"每次启动只选一次"（`lib/main.dart:102-115` 注释），运行期不会切到 just_audio | 代码 | 阶段 1 需要明确：降级策略 + UI 标识 |
| 结构化日志（初始化/设备枚举/格式协商：采样率/位深/声道/独占） | **部分成立**：引擎日志经 `lazer_audio_read_log` 每秒 drain 到 Dart（`lib/audio/native/lazer_audio_engine.dart:113-118`）后走 `debugPrint`；格式协商结果可从 `stream_info` 读到（`lib/audio/native/lazer_stream_info.dart`）。但**没有统一的字段化日志**，设备枚举日志散在 `native/lazer-audio/src/device_catalog_*.cpp` | 代码 | 需要三条结构化日志 |
| 最小集成测试播放已知 WAV 验证选中原生引擎 | **工具已有、不在 CI**：`tool/native_engine_smoke.dart`、`tool/native_bundle_check.dart`、样例 `build/native-audio/testdata/tone441.wav` 等 | 代码 | 应把 bundle 检查纳入门禁 |

### 3.2 阶段 2：Bit-Perfect 状态与可观测性

| 目标项 | 现状 | 依据 |
| --- | --- | --- |
| `OutputPathState{exclusive, dspActive, formatMatchesSource, actualSampleRate, actualBitDepth, channels}` | **不存在**。最接近的是 `LazerAudioStreamInfo`（`native/lazer-audio/include/lazer_audio_api.h:201-241`）：已有 `output_exclusive`(:211)、`bit_perfect_active`(:213)、`output_sample_rate`(:208)、`output_bits_per_sample`(:210)、`output_channels`(:209)、`source_*`(:203-206)。**缺 `dspActive` 与 `formatMatchesSource` 两个独立事实** | 代码 |
| 三条件同时为真才报告 bit-perfect | **未成立**：`native/lazer-audio/src/engine.cpp:578` `dspBypassed_ = device_.bit_perfect != 0 && outputSession_.exclusive && exactPcmFormat;`，`:629` 一次性写入 `bitPerfectActive_`。这是**打开时的宣称**，不是每块可复核的状态 | 代码 |
| DSP 启用必须使 bit-perfect 失效 | **未成立**：`Engine::setDsp` 在 bit-perfect 会话中**不报错也不改状态**（`engine.cpp:1086-1097` 只在 DoP/Native DSD 时拒绝）；泵线程因 `dspBypassed_` 恒真而继续直通（`engine.cpp:1326-1331`）→ 用户在引擎侧加 EQ 会被**静默忽略**，而 UI 仍显示 bit-perfect=是 | 代码 |
| 其他直通模式的一致性 | **成立**：非单位软件音量在直通模式下被拒绝（`engine.cpp:1072-1084`）；`setDevice` 会清零位完美标志（`engine.cpp:1117`） | 代码 |
| 逐 bit 回环验证 | **已有离线证据**：`native/lazer-audio/tools/lazer_audio_engine_pcm_matrix_probe.cpp:1376-1416` 用假固定周期端点抓取引擎**实际写出的字节**，与 WAV 数据块逐字节比较（`exclusive=1, bit_perfect=1`，断言 `actual != expected` 即失败）。本机 CTest 通过 | 代码 + [2.5] |
| 回环证据接入 UI / CI | **未成立**：探针不在 CI（1.3），UI 不显示任何逐 bit 结论 | 代码 |
| UI 指示器 | **已有雏形**：`lib/widgets/hifi_settings_section.dart:925-931` 显示"独占 / Bit-perfect：是/否"，数据来自 `bitPerfectActive`（`lib/audio/native/lazer_stream_info.dart:55,91`） | 代码 |
| 缓冲区水位 / 欠载 / 过载计数可观测 | **原始数据已有，Dart 侧零消费**：`LazerAudioSnapshot.underrun_active`/`underrun_frames`（`lazer_audio_api.h:254-258`）已镜像为 `lib/audio/native/lazer_audio_abi.dart:306,310`，但 `grep -rn underrun lib/` 只命中 ABI 镜像本身；`buffered_percent`(:252) 同样未被读取（原生引擎的 `bufferedPosition` 用的是下载缓存进度，`lazer_audio_engine.dart:255-264`）。"过载"侧只有 `output_clipped_sample_count`(:232) 经遥测行显示（`hifi_settings_section.dart:932-938`）。**环形缓冲水位完全没有暴露** | 代码 |

### 3.3 阶段 3：时钟所有权与环形缓冲

| 目标项 | 现状 | 依据 |
| --- | --- | --- |
| 无锁环形缓冲（生产者=解码/DSP，消费者=实时回调） | **已实现** | `native/lazer-audio/src/ring_buffer.h:1-7`（SPSC、按整帧、仅原子游标）、`native/lazer-audio/src/engine.h:1-4`（两线程一环） |
| 消费节奏跟随设备时钟 | **成立** | 固定周期模式每次等设备周期再提交（`engine.cpp:1656-1674`，`waitForOutput`）；WASAPI 用事件回调 `AUDCLNT_STREAMFLAGS_EVENTCALLBACK`（`output_wasapi.cpp:290`）+ `SetEventHandle`（`:541`）；独占=FixedPeriod、共享=Variable（`:574-576`） |
| 回调线程禁止 I/O / 分配 / 锁 | **有两处违反 + 一处存疑** | ① `engine.cpp:1581`（`publishTrackChanged` 内 `std::lock_guard sourceGuard(sourceMutex_)`）与 `:1604`（`activeDurationMillis` 同锁）——**实时线程取互斥量**；② `engine.cpp:1856`（以及 `:1712`）`variableOutputQueue.push_back(...)`，`std::deque` **可能堆分配**，仅在 Variable 模式；③ `engine.cpp:1760` 在队列边界 `sleep_for(1ms)` 自旋等待。另 `setError()` 会构造 `std::string`（错误分支，罕见） |
| 低/高水位驱动工作线程加速/休眠 | **不存在**。环容量由 `buffer_millis` 反推（`engine.cpp:609-613`），泵线程只看 `writableFrames()` 决定写多少（`engine.cpp:1324-1331`），没有水位策略 | 代码 |
| 欠载时计数并静音填充、不阻塞回调 | **成立** | 补静音 `engine.cpp:1787-1791`、`:1813-1816`；计数 `:1836-1846`（排除干净 EOF、队列边界与 seek flush） |
| 压力测试验证欠载为 0 或可解释 | **不存在** | — |

### 3.4 阶段 4：DSP 链显式化

| 目标项 | 现状 | 依据 |
| --- | --- | --- |
| 模块契约（输入/输出 float PCM，模块间无隐式状态） | **不存在**。`DspChain` 是一个整体类，内部固定顺序：preamp → EQ 段 → crossfeed → limiter → 音量斜坡 | `native/lazer-audio/src/dsp_chain.h:1-3,147-181` |
| 排序 / 开关 / 逐级参数持久化 | **不存在排序概念**。配置只有单个 `LazerAudioDspConfig`（`lazer_audio_api.h:290-304`：preamp、bands、limiter、crossfeed），Dart 侧持久化的也只有这些参数，没有顺序 | 代码 |
| 链上模块启用使 bit-perfect 失效 | **未成立** | 见 3.2 |
| 重采样默认关闭、仅在源与设备不匹配时启用 | **部分成立**：存在 `LazerAudioResampleMode`（`lazer_audio_api.h:130-134`），但重采样由设备协商路径决定，不是链内可开关模块 | 代码 |

### 3.5 阶段 5（仅记录，不启动）

DSD 路径现状：ABI 已有 DoP（`LazerAudioFormatSelectionDoPCarrier=7`）与 Native DSD
（`:188-193`）选择值，Dart 设置页有 DSD 输出模式与倍率策略
（`lib/widgets/hifi_settings_section.dart:169-190`、`lib/state/hifi_settings.dart`）。
`docs/audio-engine.md:234,238` 明确：**没有 DSD 源、也没有 DoP-capable DAC，全部未经设备验证**。
阶段 1–4 完成前不启动本阶段任何工作。

---

## 4. `lib/audio` 中的实际契约

### 4.1 `QueueAudioEngine`（`lib/audio/audio_engine.dart:39-62`）

> 目标：**平台自己跨曲目继续解码**的队列能力。与 `AudioEngine` 分开，是为了让只做 transport
> 的引擎与测试替身继续有效；`AppState` 在引擎没有该能力时退回"完成事件驱动"的路径。

| 成员 | 签名 | 契约要点 |
| --- | --- | --- |
| `setQueue` | `Future<int> setQueue(List<String> urls, {int startIndex = 0})` | 返回本次装载队列的标识；调用方在 `appendToQueue` 时把它交回，**防止与重载竞争的 append 落进新队列** |
| `appendToQueue` | `Future<bool> appendToQueue(int queueId, String url)` | 返回 `false` 表示该队列已不是当前队列，append 未发生，调用方不得期待交接 |
| `playQueuedNext` | `Future<bool> playQueuedNext()` | 返回 `false` 表示平台队列已无下一项，调用方应改为重新装载，**不能让 UI 跑到音频前面** |
| `indexStream` | `Stream<int>` | **只在平台自行进入下一项时**触发（无缝交接）；seek、load、append 不触发 |

实现者：`NativeAudioEngine`（`lib/audio/native/lazer_audio_engine.dart:45-53`）、
`JustAudioEngine`（`lib/audio/audio_engine.dart:106-113`）。
消费者：`AppState`（订阅 `lib/state/app_state.dart:163`；调用点 `:2501-2588`）。

注意：`indexStream` 是 `Stream<int>`（非空），两个实现都用广播 `StreamController<int>`
（`audio_engine.dart:137`、`lazer_audio_engine.dart:146`）。

### 4.2 `FailureReportingAudioEngine`（`lib/audio/audio_engine.dart:69-72`）

```dart
abstract interface class FailureReportingAudioEngine {
  /// User-facing text for a terminal failure (device lost, decode error).
  Stream<String> get failures;
}
```

| 事实 | 依据 |
| --- | --- |
| 契约**只有**一个 `Stream<String>`，没有结构化原因码、没有"是否已降级"信息 | `audio_engine.dart:69-72` |
| 原生引擎实现它（设备丢失/解码错误经引擎事件送达） | `lazer_audio_engine.dart:52`、`:208`；订阅点 `app_state.dart:167-171` |
| `just_audio` 引擎**不实现**它（失败走 just_audio 自身流） | `audio_engine.dart:106-113` |
| 消费语义：收到即视为终态失败 → `_failPlayback`：停播、清 active、写 `playbackError`、`stop()` | `app_state.dart:2938-2941`、`2924-2932` |
| 与"降级可见性"的关系 | **没有关系**：该接口目前不参与路径标识，也不触发引擎切换 |

阶段 1 要做的"降级必须通过 `FailureReportingAudioEngine` 上报"因此需要**扩展该契约**
（或新增并行的能力接口），而不是复用现有 `failures` 字符串流。

### 4.3 其他可选能力接口的实现矩阵

| 接口 | 定义 | `NativeAudioEngine` | `JustAudioEngine` |
| --- | --- | --- | --- |
| `BufferedAudioEngine` | `audio_engine.dart:11-13` | 是（`lazer_audio_engine.dart:48`；`:255-264` 用下载进度而非引擎 `buffered_percent`） | 是（`:110`；`:200`） |
| `BufferChangeReportingAudioEngine` | `audio_engine.dart:19-21` | 是（`:49`；`:214`） | 是（`:111`；`:214-222`） |
| `SeekBoundaryReportingAudioEngine` | `audio_engine.dart:24-26` | 是（`:50`；`:252` 依据缓存条目是否完整） | 是（`:112`；`:203-208` 依据 http(s) scheme） |
| `QueueAudioEngine` | `audio_engine.dart:39-62` | 是（`:51`） | 是（`:112`） |
| `FailureReportingAudioEngine` | `audio_engine.dart:69-72` | 是（`:52`） | **否** |
| `FocusAwareAudioEngine` | `audio_engine.dart:80-82` | 是（`:53`；`:205`） | 是（`:113`） |

---

## 5. 原生桥接层暴露给 Dart 的接口清单

### 5.1 `lazer-audio`（引擎，ABI v24，`LAZER_AUDIO_ABI_VERSION`=`lazer_audio_api.h:33`）

核心导出（`native/lazer-audio/src/api.cpp`）：

| 符号 | 定义 | Dart 绑定 | 阻塞 |
| --- | --- | --- | --- |
| `lazer_audio_abi_version` | `api.cpp:47` | `lazer_audio_library.dart:61-64` | 否 |
| `lazer_audio_create` | `api.cpp:51` | `:66-70` | 是 |
| `lazer_audio_destroy` | `api.cpp:61` | `:72-76` | 是 |
| `lazer_audio_open_file` | `api.cpp:66` | **未绑定**（宽字符，仅 Windows；Dart 用 utf8 版） | — |
| `lazer_audio_open_file_utf8` | `api.cpp:74` | `:78-95` | 是 |
| `lazer_audio_open_reader` | `api.cpp:88` | `:97-114` | 是 |
| `lazer_audio_queue_reader` | `api.cpp:100` | `:116-136` | 是 |
| `lazer_audio_clear_queued_reader` | `api.cpp:111` | `:138-142` | 是 |
| `lazer_audio_play` | `api.cpp:116` | `:144-148` | 否 |
| `lazer_audio_pause` | `api.cpp:121` | `:150-154` | 否 |
| `lazer_audio_stop` | `api.cpp:126` | `:156-160` | 是 |
| `lazer_audio_seek` | `api.cpp:131` | `:162-166` | 否 |
| `lazer_audio_set_volume` | `api.cpp:136` | `:168-172` | 否 |
| `lazer_audio_set_dsp` | `api.cpp:141` | `:174-178` | 否 |
| `lazer_audio_set_device` | `api.cpp:151` | `:180-185` | 否 |
| `lazer_audio_snapshot` | `api.cpp:161` | `:187-191` | 否 |
| `lazer_audio_stream_info` | `api.cpp:168` | `:193-198` | 否 |
| `lazer_audio_last_error` | `api.cpp:175` | `:200-207` | 否 |
| `lazer_audio_build_information` | `api.cpp:180` | `:209-215` | 否 |
| `lazer_audio_read_log` | `api.cpp:187` | `:219-226`（**可选**：老库没有该符号时为 `null`） | 否 |

平台设备目录（**可选符号**，`_optional()` 包一层，缺失即"此平台不支持"）：

| 符号 | 定义 | 平台 | Dart 绑定 |
| --- | --- | --- | --- |
| `lazer_audio_device_catalog_create` | `device_catalog_wasapi.cpp:267` | Windows | `lazer_audio_library.dart:334-341` |
| `lazer_audio_device_catalog_count` | `:272` | Windows | `:342-349` |
| `lazer_audio_device_catalog_get` | `:280` | Windows（`wchar_t`，UTF-16 缓冲） | `:350-412` |
| `lazer_audio_device_catalog_destroy` | `:339` | Windows | `:413-420` |
| `lazer_audio_output_device_catalog_create` | `device_catalog_alsa.cpp:284` / `device_catalog_coreaudio.cpp:140` | Linux / macOS | `:243-250` |
| `lazer_audio_output_device_catalog_count` | `:289` / `:145` | Linux / macOS | `:251-259` |
| `lazer_audio_output_device_catalog_get` | `:299` / `:156` | Linux / macOS（UTF-8） | `:260-322` |
| `lazer_audio_output_device_catalog_destroy` | `:354` / `:207` | Linux / macOS | `:323-330` |
| `lazer_audio_device_probe_pcm_formats` | `pcm_format_probe_wasapi.cpp:136` | Windows | `:423-453` |
| `lazer_audio_endpoint_volume_get` | `endpoint_volume_wasapi.cpp:128` | Windows | `:456-486` |
| `lazer_audio_endpoint_volume_set` | `:153` | Windows | `:487-512` |

加载与校验流程（`lazer_audio_library.dart:632-742`）：解析路径 → Windows 先预载 FFmpeg
依赖（`:750-788`）→ `DynamicLibrary.open` → 校验 ABI 版本（`:692-697`）→ 校验 17 个必需符号
（`:698-722`）→ 桥接库**可选**（`:726-740`）。

### 5.2 `lazer-audio-bridge`（`native/lazer-audio-bridge/src/growing_reader.cpp`）

| 符号 | 定义 | Dart 绑定 | 说明 |
| --- | --- | --- | --- |
| `lazer_bridge_reader_create` | `growing_reader.cpp:212` | `lazer_audio_library.dart:521-526` | 打开缓存文件 |
| `lazer_bridge_reader_notify` | `:226` | `:528-532` | 下载追加后唤醒阻塞读 |
| `lazer_bridge_reader_finish` | `:237` | `:534-538` | 标记 EOF / 失败 |
| `lazer_bridge_reader_destroy` | `:249` | `:540-544` | 释放 |
| `lazer_bridge_reader_bytes_available` | `:262` | `:546-550` | 已落盘字节 |
| `lazer_bridge_reader_position` | `:269` | **未绑定** | Dart 侧未使用 |
| `lazer_bridge_reader_read` | `:280` | `:557-560`（取**函数地址**给引擎） | 引擎解码线程直接调用 |
| `lazer_bridge_reader_seek` | `:325` | `:562-565` | 同上 |
| `lazer_bridge_reader_length` | `:355` | `:567-570` | 同上 |
| `lazer_bridge_reader_close` | `:364` | `:572-575` | 同上 |
| `lazer_bridge_reader_cancel` | `:374` | `:577-580` | 同上 |

这五个回调是**普通导出的 C 函数地址**，由 Dart 写进 `LazerAudioReader` 结构体，
引擎在自己的解码线程上同步调用——`dart:ffi` 无法服务阻塞回调，所以字节源必须在原生侧
（`docs/audio-engine.md:76-85`、`lib/audio/native/lazer_audio_reader.dart`）。

### 5.3 Dart 已镜像但**从未读取**的原生字段（阶段 2/3 的现成抓手）

| 字段 | 原生定义 | Dart 镜像 | 现状 |
| --- | --- | --- | --- |
| `underrun_active` | `lazer_audio_api.h:256` | `lazer_audio_abi.dart:306` | 无任何读取点 |
| `underrun_frames` | `:258` | `:310` | 无任何读取点 |
| `buffered_percent` | `:252` | `:299` | 无读取点（位置走 `position_millis`，缓冲走下载进度） |
| `terminal_event` / `terminal_detail` / `terminal_position_millis` | `:261-263` | `:314-317` | 无读取点（终态靠事件回调 + `snapshot` 复核） |
| 环形缓冲水位（readable/writable frames） | `ring_buffer.h:30-33` | **无 ABI 出口** | 需要新增出口 |

---

## 6. 反模式清单（阶段 0 视角的自查）

| 反模式 | 现状 |
| --- | --- |
| 在 bit-perfect 状态未实现前新增 DSP 效果 | 本阶段未新增任何 DSP；阶段 2 完成前不新增（阶段 1 也不碰 EQ/limiter/DSD 行为） |
| 在实时回调线程写日志、分配内存、加锁 | **当前代码存在**：`engine.cpp:1581/1604` 加锁、`:1856/:1712` 可能分配 → 阶段 3 处理 |
| 用"音质更好"作为 PR 理由 | 本文档不使用该理由，全部结论附代码路径或日志 |
| 一次性重写 `lib/audio` 或原生层 | 未发生；各阶段独立 PR |
| 把 just_audio 回退路径静默化 | 当前日志不静默，但 **UI 基本静默** → 阶段 1 处理 |
| 在阶段 0 状态文档完成前开始阶段 1 代码改动 | 遵守：本文档即为该门槛，阶段 1 从下一个 PR 开始 |

---

## 7. 文档与代码的差异记录（以代码为准）

| # | 文档断言 | 实际 | 处理 |
| --- | --- | --- | --- |
| 1 | `docs/audio-engine.md:252-257`：这台机器不能构建 Flutter 应用 | **可以**：开发者模式已启用，release 构建成功（2.1） | 本 PR 更新该段 |
| 2 | `docs/audio-engine.md:230`：Windows **CTest 16/16** | 现在是 **17/17**（新增 crossfeed 探针） | 本 PR 更新 |
| 3 | `docs/audio-engine.md:243-244`："Android/iOS 未接线" | Android **已接线**：CI 构建三 ABI 并打进 APK（`build.yml:392,429`），Dart loader 支持 `androidArm64`/`androidX64`（`lazer_audio_library.dart:611-612`） | 本 PR 更新；iOS 仍不适用 |
| 4 | 未记录 | `armeabi-v7a`（`Abi.androidArm`）**不在** `_engineFileNames` 中（`lazer_audio_library.dart:606-615`），而 CI 会为该 ABI 打包引擎 → 32 位 ARM 上引擎随包发布却永远不会被选用（`isSupportedHost` 为 false） | 记录为已知缺口，阶段 1 处理 |
| 5 | 未记录 | `docs/audio-engine.md:50` 说 `include/lazer_audio_api.h` 是 ABI **v23**，实际 `lazer_audio_api.h:33` 是 **v24**（同文件 `:41-42` 已说明 bump 到 24） | 本 PR 更新 |
| 6 | 任务书假设"原生引擎目前是 opt-in" | 代码默认即原生优先（`main.dart:112`、`hifi_settings.dart:523,612`），且默认产物实测走原生（2.3）。"opt-in"只体现在"引擎二进制必须随包"与用户可手动切回系统引擎 | 记录于本文档 3.1 |
| 7 | 任务书假设 bit-perfect"宣称"需要从头实现 | 引擎侧已有逐字节直通路径与离线逐字节探针；缺的是**状态语义拆分与暴露** | 记录于 3.2 |

---

## 8. 已知限制与未验证项

* **平台验证面**：Windows 一路实测（构建、bundle 加载、真实播放、独占/格式协商见
  `docs/audio-engine.md:233-235`）；Linux / macOS 只到"CI 能构建并打包"，**播放行为未验证**。
* **DSD 全链路**：无 DSD 源、无 DoP-capable DAC，`docs/audio-engine.md:234,238` 明确未经设备验证。
* **物理层**：所有"独占/格式"结论都只到"端点接受了这个格式"，**没有任何数字回环**
  （`docs/audio-engine.md:246-250`）。
* **移动端**：Android 有引擎与 AAudio 后端（`docs/android-audio.md`），但 32 位 ARM 不被 Dart 侧选用（差异 #4）。
* **自动化**：17 个引擎探针不在 CI；`armeabi-v7a` 打包与选用逻辑不一致处无测试覆盖。

---

## 9. 阶段 1–4 的进入条件（基于以上事实）

| 阶段 | 进入条件 | 本阶段结束时必须新增的**可观测证据** |
| --- | --- | --- |
| 1 | 本文档合入 | CI 中断言"默认产物走原生引擎" + 回退原因不丢失 + UI 可见的非 HiFi 标识 |
| 2 | 阶段 1 的证据在 CI 中稳定通过 | `OutputPathState` 三条件拆分 + 逐 bit 回环纳入门禁 + 水位/欠载进调试面板 |
| 3 | 阶段 2 的 bit-perfect 状态可被回环证伪 | 实时线程审查清单通过 + 水位策略 + 压力测试欠载可解释 |
| 4 | 阶段 1–3 完成 | DSP 模块契约 + 排序/开关持久化 + 每次变更反映到 bit-perfect 状态 |
| 5 | 阶段 1–4 完成 | 另行定义 DSD 下的 bit-perfect 语义 |

---

## 10. 阶段 1 落地记录

阶段 1 的目标是"原生引擎成为默认路径，且降级对 UI 可见"。基线（第 3.1 节）显示默认路径
**已经成立**，所以本阶段的实际工作集中在三处缺口：回退原因会丢失、UI 只在设置页可见、
以及"默认产物走原生"没有任何自动化断言。

| 基线缺口 | 处理 | 代码位置 |
| --- | --- | --- |
| 库可加载但会话创建失败时，回退原因为 `null` | 新增决策模型，区分 `libraryUnavailable` 与 `sessionStartupFailed`；`NativeAudioEngine.lastStartupFailure` 保留会话失败文本 | `lib/audio/native/engine_selection.dart`、`lib/audio/native/lazer_audio_engine.dart:68-140`、`lib/audio/engine_factory.dart:60-118` |
| 回退原因存在静态可变字段里，跨调用残留 | 删除静态缓存，原因作为 `AudioEngineSelection.path` 随选择对象传递 | `lib/audio/engine_factory.dart:22-57` |
| 降级只写日志，`FailureReportingAudioEngine` 不参与 | 该契约新增 `pendingFailure`（订阅前就已发生的启动期降级），`JustAudioEngine` 实作它并携带原因；`NativeAudioEngine` 恒为 null | `lib/audio/audio_engine.dart:74-95`、`lib/audio/audio_engine.dart:119-180`、`lib/audio/native/lazer_audio_engine.dart:224` |
| 非 HiFi 路径只在设置页可见 | 新增常驻标识，出现在桌面播放器与移动端播放器；原生路径下不渲染任何东西 | `lib/widgets/audio_path_badge.dart`、`lib/player/desktop_now_playing.dart:679`、`lib/player/now_playing_page.dart:1249`、`lib/state/app_state.dart:1136-1139` |
| 运行期设备丢失只闪一条错误 | 终态失败同时把路径标记为"非 HiFi"并常驻显示 | `lib/state/app_state.dart:2956-2971` |
| 初始化 / 设备枚举 / 格式协商没有统一日志 | 三条结构化 `audio.path` 记录（`select`/`session`、`device_catalog`、`format`） | `lib/audio/native/audio_path_log.dart`、`lib/audio/engine_factory.dart:77-118`、`lib/audio/hifi_controller.dart:324-368`、`lib/audio/native/lazer_audio_engine.dart:895` |
| "默认产物走原生引擎"没有断言 | `tool/native_path_check.dart`：用与 app 相同的决策函数检查打包产物，`--play` 播放自生成的已知 WAV；CI 在 Windows 打包后以 `--expect-native` 运行 | `tool/native_path_check.dart`、`.github/workflows/build.yml:113-131` |

### 10.1 证据

打包产物运行（原生路径）：

```
audio.path event=select path=native fallback=- detail=-
audio.path event=session engine=lazer-audio build="FFmpeg avformat 63.17.100, avcodec 63.25.101, swresample 7.7.100"
Audio engine: native (lazer-audio)
```

同一产物隐藏引擎后运行（降级 → just_audio 并带原因）：

```
audio.path event=select path=just_audio fallback=libraryUnavailable detail="lazer-audio.dll was not found in the app bundle, configured override, or development checkout"
Audio engine: just_audio (lazer-audio.dll was not found in the app bundle, configured override, or development checkout)
```

打包产物内的路径检查（从无关工作目录 `%TEMP%` 运行 `native-path-check.exe`）：

```
（引擎在位）audio.path event=check cwd=C:\Users\...\Temp host_supported=1 library=loaded bridge=loaded decision=native fallback=- detail=- → all checks passed, exit=0
（引擎移走）audio.path event=check cwd=C:\Users\...\Temp host_supported=1 library=unavailable decision=system fallback=libraryUnavailable detail="lazer-audio.dll was not found in the app bundle, configured override, or development checkout" → all checks passed, exit=0
```

（`dart compile exe` 产物的 `dart.vm.product` 为真，所以它按"已安装构建"只查可执行文件目录，
这正是 CI 想断言的解析方式。）

真实播放（`--play`，自生成的 44.1 kHz/16-bit WAV，走引擎自身文件读取）：

```
ok   engine session created
ok   open known WAV
audio.path event=check.format summary="..." initialized=1 exclusive=0 bit_perfect=0
ok   the output session initialized
ok   the source decoded as the 44.1 kHz/16-bit WAV it is — 44100/16
ok   the engine clock advanced — 1560ms
```

UI：`test/audio/audio_engine_path_test.dart` 断言原生路径下标识不渲染、降级时显示"非 HiFi 路径"
与具体原因；`flutter test` 全量 630 项通过，`flutter analyze` 无问题。

### 10.2 本阶段**没有**做的事（诚实边界）

* 运行期**热切换**到 just_audio 未实现：设备丢失时只上报并停播（`app_state.dart:2950-2967`），
  引擎仍在下次启动时重新选择。热切换要改 `AppState` 持有引擎的方式，留待后续阶段。
* Linux / macOS 的 CI 断言未加：本地只能验证 Windows 产物；Linux 的 AppImage 步骤已有启动
  冒烟，但"选中原生引擎"的断言需要先在本机验证过再上 CI。
* 阶段 1 未改 DSD、EQ、limiter 的任何行为（符合约束）。
* 格式协商日志（`audio.path event=format`）挂在 `_publishStreamInfo`（`lazer_audio_engine.dart:895`），
  由"打开源 / 无缝交接 / DSD 策略重试"触发；本机 GUI 无法在无人登录的状态下装载曲目，因此
  该行的现场证据来自 `native_path_check --play`（同一批字段），而不是 GUI 日志。

---

## 11. 阶段 2 落地记录

阶段 2 的目标是"Bit-Perfect 可观测而非宣称"。基线（第 3.2 节）显示：引擎只发布一个打开时
决定的布尔值 `bit_perfect_active`，DSP 请求在 bit-perfect 会话中被静默丢弃，欠载水位等原始
数据虽在 ABI 里但 Dart 侧从未读取。本阶段把"结论"拆成"可核对的事实"，并让两者必须一致。

| 基线缺口 | 处理 | 代码位置 |
| --- | --- | --- |
| `bit_perfect_active` 无法被核对 | ABI v25 在 `LazerAudioStreamInfo` 追加 `output_dsp_active` 与 `output_format_matches_source`，在 `LazerAudioSnapshot` 追加 `ring_fill_frames` / `ring_capacity_frames` | `native/lazer-audio/include/lazer_audio_api.h:240-251`、`:272-279` |
| 三条件未拆分 | 引擎侧分别计算并发布：`dspInPath()`（DSP 是否真的在信号路径）、`formatMatchesSource_`（是否源格式原样） | `native/lazer-audio/src/engine.cpp:1175-1234`（`streamInfo`）、`:1236-1243`（`dspInPath`）、`:500`、`:633`（`configurePipeline`） |
| 会话语义：无会话时不得残留 | 三个事实只在"输出会话已初始化且未失败"时发布，因此不存在会话时派生结果必然为假，与 `bit_perfect_active` 一致 | `native/lazer-audio/src/engine.cpp:1225-1231` |
| bit-perfect 会静默吃掉 DSP 请求 | `setDsp` 在 bit-perfect 生效时对"会改变样本"的请求（preamp/bands/limiter/crossfeed）**显式返回 `LazerAudioErrorUnsupported`**，不再接受后忽略 | `native/lazer-audio/src/engine.cpp:1092-1121` |
| Dart 侧只是照搬引擎布尔值 | 新增 `OutputPathState`：从三个事实派生 `bitPerfect`，并提供 `agreesWithEngine`、`failingConditions`、实际采样率/位深/声道 | `lib/audio/native/output_path_state.dart`、`lib/audio/native/lazer_stream_info.dart:77-88` |
| 指示器不区分原因 | 信号路径面板拆成"Bit-perfect / 独占 / DSP / 格式与源一致"四行，亮起时给出三项条件，熄灭时列出未满足项 | `lib/widgets/hifi_settings_section.dart:915-975` |
| 欠载/水位从未读取 | `LazerEngineMetrics` 读快照的环形缓冲占用与欠载计数，进入信号路径面板的"输出缓冲"行，并在欠载状态翻转时写一条 `audio.path event=metrics` | `lib/audio/native/engine_metrics.dart`、`lib/audio/native/lazer_audio_engine.dart:311-325`、`lib/audio/hifi_controller.dart:158-183` |
| 逐 bit 回环没有独立门禁 | 新增 CTest `lazer-audio-engine-bit-perfect`，四例：逐字节相等、DSP 介入即失效、格式不匹配即失效、bit-perfect 下 DSP 请求被拒且输出仍逐字节相等 | `native/lazer-audio/tools/lazer_audio_engine_bit_perfect_probe.cpp`、`native/lazer-audio/CMakeLists.txt:323-359` |
| 探针不在 CI | Windows job 新增 `Run the engine's device-free probe suite`（配置 + 构建 + ctest） | `.github/workflows/build.yml:84-101` |
| 设置层会把 DSP 设置送到会被拒绝的引擎 | `HifiSettings.toDspRequest()` 在 bit-perfect 时发送中性请求（不丢设置，关闭后照常生效），页面用 `dspBypassedByBitPerfect` 明说 DSP 未进入信号路径 | `lib/state/hifi_settings.dart:652-676` |

### 11.1 证据

**回环（离线、假端点抓取引擎真实输出字节）**——`ctest -R lazer-audio-engine-bit-perfect`：

```
PASS: bit-perfect exclusive output reproduces the source PCM bytes exactly (51200 bytes) and reports exclusive + no DSP + format match
PASS: DSP in the signal path clears bit-perfect and alters the output (exclusive=1, dsp_active=1, format_matches_source=1)
PASS: a resampled session reports format_matches_source=0 and is not bit-perfect (source 44100 Hz, output 48000 Hz)
PASS: a DSP request during bit-perfect is refused with an error and the output stays byte-exact
```

**真机（本机默认端点）**——同一个打包产物、同一个自生成 44.1 kHz/16-bit WAV：

```
共享模式（默认）:
audio.path event=check.format ... exclusive=0 dsp_active=1 format_matches_source=0 bit_perfect=0 engine_claims_bit_perfect=0
unmet="输出不是独占,DSP 在信号路径中,输出格式与源不一致" ring_fill=8192 ring_capacity=8192

独占 + bit-perfect 请求:
audio.path event=check.format ... exclusive=1 dsp_active=0 format_matches_source=1 bit_perfect=1 engine_claims_bit_perfect=1 unmet=-
ok   an exclusive bit-perfect request produced a bit-perfect path
ok   the engine flag agrees with the derived state
```

即：指示器在"独占 + 无 DSP + 格式一致"时亮起（`bit_perfect=1`），在任一条件不满足时熄灭并
给出未满足项；引擎自己的布尔值与派生结果始终一致（`engine flag agrees with the derived state`）。

**测试**：`flutter analyze` 无问题；`flutter test` 647 项通过（新增 `test/audio/output_path_state_test.dart`
18 项：三条件组合、会话缺失、DSD 路径、陈旧布尔值不可信、指标派生、面板文案、设置层旁路）。
引擎探针 18/18 通过。

### 11.2 本阶段**没有**做的事（诚实边界）

* **不做 DSP 开启时的重新协商**：bit-perfect 生效期间引擎拒绝处理请求；"打开 EQ 后自动关闭
  bit-perfect 并重新协商输出"属于阶段 4（DSP 链显式化）的工作，本阶段只保证状态真实。
* **DSD 路径的 bit-perfect 语义仍未定义**（`failingConditions` 里明确写"语义尚未定义"），
  按任务要求留到阶段 5。
* **水位只有观测、没有策略**：环形缓冲的低/高水位驱动（泵线程加速/休眠）属于阶段 3。
* **物理层未验证**：回环是"引擎写给端点的字节"，不是 DAC 收到的位；真实数字回环仍需硬件。

---

## 12. 阶段 3 落地记录

阶段 3 的目标是"输出侧时钟驱动消费，实时线程只从环形缓冲取数交给设备"。基线（第 3.3 节）显示
无锁环形缓冲与设备时钟驱动**已经存在**，缺口集中在三处：实时线程仍在取互斥量与堆分配、没有
水位策略、没有压力测试与审查清单。

| 基线缺口 | 处理 | 代码位置 |
| --- | --- | --- |
| 实时线程取 `sourceMutex_`（`publishTrackChanged`、`activeDurationMillis`、`currentPositionMillis`、`currentSourceEnded`） | 生产者在准备后继曲目时把可听曲目的标量发布到 `RenderPresentation` 镜像，实时线程在帧缝处用**纯原子写**提交；位置、时长、结束标志都改为读原子镜像 | `native/lazer-audio/src/engine.h:113-165`、`engine.cpp:1254-1290`（`renderPositionMillis`）、`engine.cpp:1700-1765`（提交）、`engine.cpp:1904-1910`（`sourceEndedNow`）、`engine.cpp:1410-1420`（生产者镜像与 codec 提交） |
| 实时线程堆分配（`std::deque` 台账、`push_back`） | 改为会话建立时预分配的定长环形台账（容量 1024，溢出丢最旧一条并触发重新同步），`renderLoop` 内不再有任何分配 | `engine.cpp:1810-1850` |
| 没有低/高水位 | 定义并发布水位：到**高水位（环形缓冲容量）**停止喂入，降到**低水位（容量 25%）**恢复；曲目缝在飞或暂停超过 50 ms 时强制恢复，保证解码不会被消费者卡死 | `engine.cpp:625-650`（计算与发布）、`engine.cpp:1425-1455`（`accept()` 中的迟滞） |
| 水位不可观测 | ABI 26 在快照里发布 `ring_low_watermark_frames` / `ring_high_watermark_frames`，Dart 侧进入"输出缓冲"行（含"已到高水位暂停喂入"） | `include/lazer_audio_api.h:272-284`、`lib/audio/native/engine_metrics.dart:36-90`、`lib/widgets/hifi_settings_section.dart:958` |
| 会话起始的一次静音被算作欠载 | 共享（Variable）模式在提交第一个周期前先等生产者填满一个周期（有界：最多 8 次设备等待），启动抖动不再污染欠载计数 | `engine.cpp:1831-1845` |
| 没有压力测试 | 新增 CTest `lazer-audio-ring-stress`：40 秒素材 + 有节奏的假端点（约 58× 实时）跑满整条 生产者→环→实时线程 路径 | `native/lazer-audio/tools/lazer_audio_ring_stress_probe.cpp`、`CMakeLists.txt` |
| 没有审查清单 | 新增 `docs/audio-engine-rt-checklist.md`：禁令、逐项核对、被明确允许的例外、计时基线 | `docs/audio-engine-rt-checklist.md` |
| 设备时钟驱动未逐平台确认 | 逐后端核对并记录：WASAPI 事件回调、ALSA `poll()` 事件、CoreAudio IOProc 健康/宿主时钟 | 见 12.1 |

### 12.1 证据

**逐平台"消费由设备时钟驱动"核对**：

| 后端 | waitForReady 的等待对象 | 结论 |
| --- | --- | --- |
| WASAPI | `AUDCLNT_STREAMFLAGS_EVENTCALLBACK` + `SetEventHandle` 的事件句柄；独占用 FixedPeriod 每次提交一个周期 | 设备/驱动周期驱动 | 
| ALSA | 对 PCM 的 poll 描述符 `poll()`（`output_alsa.cpp:857-880`） | ALSA period/available 信号驱动 |
| CoreAudio | IOProc 回调健康位与回调序号/宿主时钟（`output_coreaudio.cpp:1078-1105`） | 设备 IOProc 驱动 |

**压力测试**（`ctest -R lazer-audio-ring-stress`）：

```
PASS: 40 s through a paced endpoint with no stall: 0 padded frames, fill peak 16384/16384, watermarks 4096/16384
PASS: a 800 ms stall (ring covers ~371 ms) produced 10752 padded frames, bounded by the stall, and recovered
```

即：生产者跟得上时**欠载为 0**；注入 800 ms 解码停顿时，欠载计数为正、**被停顿长度界定**
（10752 帧 ≈ 244 ms，小于 800 ms 可解释上限），且停顿结束后恢复（会话结束时 `underrun_active = 0`）。

**回归**：引擎探针 **19/19** 通过（含 `lazer-audio-engine-bit-perfect` 逐字节回环与
`lazer-audio-engine-pcm-matrix` 的格式矩阵/无缝/ReplayGain 用例）；`flutter test` 649 项通过；
`flutter analyze` 无问题。

### 12.2 本阶段**没有**做的事（诚实边界）

* `snapshot()` / `streamInfo()` 若被事件回调**同步**重入，仍会取 `lifecycleMutex_`（`try_lock`）与
  `sourceMutex_`；出货路径（Dart 侧 `NativeCallable.listener`，异步投递）不会触发，已在审查清单
  第 3 节列为明确例外。把它们也改成无锁镜像属于后续工作。
* 水位策略只做"停止/恢复喂入"，没有做"加速"（解码速度不由引擎控制）。
* 压力测试是离线假端点：它证明的是引擎内部的行为，不是某台设备上的真实欠载率。
* ALSA/CoreAudio 的核对是**代码级**的，本机没有这两个平台的运行证据。

---

## 13. 阶段 4 落地记录（引擎侧）

阶段 4 的目标是把 DSP 从"固定配置"变成"显式有序链"。基线（第 3.4 节）显示：链的顺序写死在
`DspChain::process()` 里，没有任何排序/旁路概念。本次落地的是**引擎侧契约**：链的顺序由调用方
按 ABI 指定，未列出的级即旁路。

| 基线缺口 | 处理 | 代码位置 |
| --- | --- | --- |
| 顺序写死，不可排序 | `LazerAudioDspConfig` 追加 `stage_count` + `stage_order[8]`（ABI 27，纯追加）；`DspChain` 按该顺序逐级派发，`stage_count == 0` 表示沿用文档化的默认顺序（Preamp→Eq→Crossfeed→Limiter→Volume） | `include/lazer_audio_api.h:305-330`、`src/dsp_chain.h:147-200`、`src/dsp_chain.cpp:305-345`、`:405-470` |
| 级可开关/旁路 | 未列入顺序的级被旁路，并且**释放其状态**（EQ 段清空、limiter 重新配置为关闭、crossfeed 复位），而不是在调用点跳过 | `src/dsp_chain.cpp`（`applyOrder`） |
| 未知级 | 忽略该级，其余照常生效（而不是整条请求失败） | `src/dsp_chain.cpp`（`requestConfig`） |
| 链上模块启用使 bit-perfect 失效 | 阶段 2 的规则不变：bit-perfect 会话里引擎拒绝处理请求（`engine.cpp:1092-1121`），非 bit-perfect 会话里 `dsp_active` 恒为真，派生结果必然为 false | 见第 11 节 |

**证据** — 新增 CTest `lazer-audio-dsp-order`（`native/lazer-audio/tools/lazer_audio_dsp_order_probe.cpp`）：

```
PASS: an empty stage list reproduces the documented default order exactly
PASS: limiter-before-EQ and EQ-before-limiter differ in 8172 of 8192 samples
PASS: omitting the EQ from the order bypasses it (8190 samples differ)
PASS: a disabled limiter is transparent in the same order
PASS: an unknown stage is ignored and the named stages still apply
PASS: the chain reports the 5-stage order it applies
```

引擎探针 **20/20** 通过（含逐 bit 回环、格式矩阵、水位压力测试——DSP 重构不得改变无 DSP 时的逐字节结果）；
`flutter analyze` 无问题；`flutter test` **649 项通过**。

### 13.1 本阶段**没有**做的事（诚实边界）

* **阶段 4b 已落地**：顺序可持久化（`hifi_dsp_order`，畸形值回落默认且丢弃未知级）、经
  `LazerDspRequest` → `setEqualizer` → worker 写入 `stageCount/stage_order`，设置页有「DSP 链顺序」
  下拉框（引擎默认 / 限幅优先 / 旁路 EQ 与串扰，未知顺序显示为「自定义」而不是断言）。
  仍未做的是**该控件的 widget 测试**：它只在原生引擎运行时可达，而 widget 测试无法构造
  `NativeAudioEngine`，覆盖它需要引入测试接缝。因此「用户可以排序/开关」的依据是引擎侧探针
  （顺序确实改变输出）+ 模型层测试（预设合法性、编码往返、摘要文案）+ 静态检查，不含渲染级断言。
* 重采样仍未作为链内模块存在：它由设备协商路径决定（第 3.4 节的结论未变）。
* 抖动仍与整数量化绑定在输出边界（`pcm_output.cpp`），没有独立成链内一级。

---

## 14. 阶段 5 落地记录（DSD/DoP 的 bit-perfect 语义）

阶段 5 的第一件事是**定义** DSD 路径下"bit-perfect"是什么意思——阶段 2 的结论当时是"语义尚未定义"，
引擎对 DoP / 原生 DSD 一律报 `bit_perfect_active = 0`，那是一个保守占位，不是结论。

**定义**：DoP 会把解码得到的 DSD 位流原样放进 24-bit 载波，原生 DSD 会把位流原样放进端点自己的
DSD 字格式。两种情况下 `configurePipeline` 在开会话时已经**拒绝**了任何不匹配的契约（采样率换算、
声道数、位深/字宽、独占），所以会话一旦打开，"源被原样承载"就已经成立。因此 DSD 路径复用与 PCM
相同的三个事实：

| 事实 | DoP / 原生 DSD 下的含义 |
| --- | --- |
| `output_exclusive` | 独占端点（开会话时强制） |
| `output_dsp_active` | float DSP/音量链不在信号路径中（DSD 路径本来就绕开它，且 `setDsp` 拒绝处理请求） |
| `output_format_matches_source` | 载波 / DSD 字格式与源完全一致（不满足就开不了会话） |

于是 `bit_perfect_active = exclusive && !dsp && matches` 对 DSD 同样成立，ABI 升到 **28**（语义变化，
按头文件规则 bump）。

| 改动 | 位置 |
| --- | --- |
| 引擎：DSD 会话按上述定义发布三个事实 | `native/lazer-audio/src/engine.cpp`（`configurePipeline` 末尾） |
| Dart：`OutputPathState` 不再对 DSD 路径强制"未定义"，并新增 `bitPerfectMeaning` 说明结论的含义 | `lib/audio/native/output_path_state.dart` |
| 探针：`lazer-audio-engine-dop` 断言 DoP 会话 `exclusive=1, dsp_active=0, format_matches=1, bit_perfect=1` | `tools/lazer_audio_engine_dop_probe.cpp` |
| 探针：`lazer-audio-engine-native-dsd` 断言原生 DSD 同样成立，且 `output_telemetry_valid` 仍为 0（PCM 遥测不适用） | `tools/lazer_audio_engine_native_dsd_probe.cpp` |

**验证**：引擎探针 **20/20**；`flutter analyze` 无问题；`flutter test` **655 项通过**；`native_abi_check` 与
`native_engine_check` 通过。

**仍未做**：DSD 的**物理层**验证（没有 DSD 源、没有 DoP-capable DAC，这一点从阶段 0 起就没变过），
以及卷积/VST 等扩展——它们需要先有 DSP 模块契约的第三类实现，不属于本次范围。

---

## 15. 卷积级（阶段 5 的第二件，**不随发布暴露**）

按需求"先确保引擎可用、后期发布不要涉及这些"，卷积只做到**引擎能力 + 探针**：没有设置项、没有默认 IR、
没有 UI 入口，`HifiSettings.decodeDspStageOrder` 仍然只接受 0–4，所以应用无法打开它。

| 内容 | 说明 | 位置 |
| --- | --- | --- |
| `LazerAudioDspStageConvolver` = 5 | 链上的第六级，ABI 29（纯追加） | `include/lazer_audio_api.h` |
| IR 参数 | `impulse_response`（channel-major）、`impulse_response_frames`、`impulse_response_channels`；引擎在 `set_dsp` 返回前复制，调用方保留所有权 | 同上 |
| 实现 | 直接型 FIR，镜像历史缓冲避免环绕判断；会话建立时一次性分配，`renderLoop` 不分配 | `src/dsp_chain.h`（`Convolver`） |
| 护栏 | 超过 4096 taps 拒绝、声道数与会话不符则整段惰性、未列入 `stage_order` 即旁路并清空历史 | 同上 |
| 可观测 | 启用后 `dsp_active=1`，`OutputPathState.bitPerfect` 自动变假，"信号路径"面板显示 DSP 介入 | 阶段 2 的既有规则，无需新 UI |

**验证** — 新增 CTest `lazer-audio-convolver`：

```
PASS: a unit impulse is the identity through the convolver
PASS: a two-tap response matches a direct convolution sample for sample
PASS: an IR left out of the order does not touch the signal
PASS: an IR that does not match the session channels is refused
PASS: an IR longer than 4096 taps is refused and the stage stays inert
PASS: bypassing the stage clears its history
```

引擎探针 **21/21**；`flutter analyze` 无问题；`flutter test` 655 项通过；`native_abi_check` 通过。
（过程中真抓到一个 bug：`requestConfig` 的阶段合法性上界还停在 `Volume`，导致 `Convolver` 被当作未知级静默忽略——探针的"两点响应"用例把它暴露出来，已修。）

**边界**：直接型 FIR 在 4096 taps 时约 0.4 GFLOP/s（44.1 kHz 立体声），更长 IR 需要换成 partitioned FFT；
这一步只证明"接口位置正确"，不证明"性能足够跑房间校正"。发布前若要启用它，还需要：IR 加载与持久化、
FFT 实现、以及至少一台真实设备上的听感与负载验证。

---

## 附：本阶段用到的复现命令

```powershell
# 构建（默认产物）
$env:LAZER_FFMPEG_ROOT='D:\Lazer\build\third_party\ffmpeg'
flutter build windows --release --no-pub

# 产物内引擎可加载性（从无关目录运行）
dart compile exe tool/native_bundle_check.dart -o build/windows/x64/runner/Release/native-bundle-check.exe
cd $env:RUNNER_TEMP; & D:\Lazer\build\windows\x64\runner\Release\native-bundle-check.exe

# 运行默认产物并抓引擎选择日志
& build\windows\x64\runner\Release\lazer_nextgen.exe   # 期望：Audio engine: native (lazer-audio)

# 打包产物是否真的选中原生引擎（从无关目录运行；CI 用的就是这条）
dart compile exe tool/native_path_check.dart -o build/windows/x64/runner/Release/native-path-check.exe
cd $env:RUNNER_TEMP
& D:\Lazer\build\windows\x64\runner\Release\native-path-check.exe --expect-native
& D:\Lazer\build\windows\x64\runner\Release\native-path-check.exe --expect-native --play   # 真实播放自生成的 WAV
& D:\Lazer\build\windows\x64\runner\Release\native-path-check.exe --play --bit-perfect     # 三条件 + 派生结果（阶段 2）

# 引擎离线探针（18 项）
cmake -S native -B build/native-probes -G "Visual Studio 17 2022" -A x64 `
  -DLAZER_FFMPEG_ROOT="D:/Lazer/build/third_party/ffmpeg" -DLAZER_AUDIO_NATIVE_PROBES=ON
cmake --build build/native-probes --config Release --parallel 4
ctest --test-dir build/native-probes -C Release --output-on-failure
ctest --test-dir build/native-probes -C Release -R lazer-audio-engine-bit-perfect --output-on-failure
```
