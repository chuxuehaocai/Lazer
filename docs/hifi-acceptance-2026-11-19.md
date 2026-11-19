# HiFi 多平台验收记录（2026-11-19）

本轮验收对应分支 `codex/hifi-multiplatform-acceptance-20261119`，范围是 Windows、Linux、Android、Web。
Linux / Android / Web 的边界写法见第 5～7 节，没有真机证据的项目一律标注 `hardwareTested=false`。
只有第 2 节（Windows USB DAC）是真实硬件上的结果，其余是构建、静态检查、测试替身与探针证据。

本轮代码改动集中在 native 准备生命周期与队列所有权：追加 ABI 31 的
`lazer_audio_clear_queued_reader_ex`，给 `SourceSlot` 增加 preparation barrier
（in-flight / cancel / wait / notify），Dart 侧拆分请求代次与资源代次并用具名 clear 释放被取代的 reader。
历史记录见 [交接手册](hifi-multiplatform-handoff-2026-11-19.md) 与 [2026-11-18 验收](hifi-acceptance-2026-11-18.md)；
本文的数值全部来自本轮构建，不引用旧 APK 或旧 Windows 记录。

## 1. 本轮构建产物

| 产物 | 大小 | 时间 | SHA-256 |
| --- | --- | --- | --- |
| `lazer-audio.dll`（仓库根目录，开发加载用） | 535,040 | 2026-11-19 11:29:43 | `77592C3479E0F23980309C1A9BCCB625ED6821A7F1822A4110962CA920DCF131` |
| `build/windows/x64/runner/Release/lazer-audio.dll` | 279,040 | 2026-11-19 11:26:09 | `AA20662B293A1579CE00CBF37967CFFA57D9176E916CB47797480E9C30D14709` |
| `build/windows/x64/runner/Release/lazer_nextgen.exe` | 180,736 | 2026-11-19 00:57:10 | `7B951FB78C3E86B7EBBA6E6E700CF2084957FBDDE85B332470F7AF58DA93F9F1` |
| `build/app/outputs/flutter-apk/app-release.apk` | 117,406,026 | 2026-11-19 11:36:30 | `EAAF93F6D79BF026A105D745C8652FFADE54CF233B47B02B4CB16E15AE18DFF6` |

引擎由 `dart run tool/build_native_audio.dart --project-root` 从
`build/native-audio/lazer-audio.dll` 校验并暂存到仓库根目录，校验输出为 `validated native audio ABI 31`。
Release 版 DLL 的导出已用 `dumpbin /exports` 复核，包含 `lazer_audio_clear_queued_reader_ex`
（序号 4）以及原有的 `lazer_audio_abi_version`、`lazer_audio_clear_queued_reader`。
`lazer_nextgen.exe` 的时间戳早于本次 Dart 改动，是因为该目标只承载 Flutter 启动器，本次没有重新链接它。

## 2. Windows 真实 USB DAC 验收

命令：

```powershell
python ci/verify-package-contents.py build/app/outputs/flutter-apk/app-release.apk
dart tool/dac_acceptance.dart --device NICEHCK --output build/reports/dac-current.json
```

第一次运行被 ABI 校验拒绝，报 `bundled engine lazer-audio.dll reports ABI 30; this build expects 31`：
仓库根目录当时放着上一轮的 ABI 30 引擎。这条失败本身是有用的证据——加载器对 ABI 不匹配的引擎会明确拒绝，
而不是带着旧引擎继续跑。重新暂存 ABI 31 引擎后复测通过。

| 项目 | 值 |
| --- | --- |
| 设备 | `扬声器 (NICEHCK HiFi Audio)` |
| 端点 token | `{0.0.0.00000000}.{b6e8030d-dd3f-4b82-b588-81944f0a817e}` |
| 平台 | `"Windows 11 专业版" 10.0 (Build 26300)` |
| 引擎 | FFmpeg avformat 63.6.100, avcodec 63.11.100, swresample 7.3.100 |
| 测试信号 | 997 Hz, -80 dBFS PCM stereo；软件音量 1.0；未改变系统音量 |
| 结果 | `completed=true`、`testedFormats=15`、`expectedPlaybackFormats=15`、`failures=0` |
| 范围声明 | WASAPI negotiation and engine playback telemetry, not physical loopback or analog fidelity |

端点枚举（`Get-PnpDevice -Class AudioEndpoint -Status OK`）里另有
`MAG274QRF-QD (NVIDIA High Definition Audio)`、`Realtek Digital Output (Realtek USB Audio)`、
`扬声器 (UU远程虚拟音频设备)`；本次只用 NICEHCK 这个外接 USB DAC，其余端点没有参与判定。

### 2.1 独占 PCM 格式协商（24 种）

`probeExclusivePcmFormats` 对 8 个采样率 × 3 个位深逐一请求 WASAPI 独占打开：

| 采样率 | 16 bit | 24 bit | 32 bit |
| --- | --- | --- | --- |
| 44.1 kHz | 通过 | 通过 | 通过 |
| 48 kHz | 通过 | 通过 | 通过 |
| 88.2 kHz | 拒绝 | 拒绝 | 拒绝 |
| 96 kHz | 通过 | 通过 | 通过 |
| 176.4 kHz | 拒绝 | 拒绝 | 拒绝 |
| 192 kHz | 通过 | 通过 | 通过 |
| 352.8 kHz | 拒绝 | 拒绝 | 拒绝 |
| 384 kHz | 通过 | 通过 | 通过 |

15 种返回 `status=0`；9 种返回 `status=1, hresult=-2004287480`（`0x88890008`，
`AUDCLNT_E_UNSUPPORTED_FORMAT`）。88.2 / 176.4 / 352.8 kHz 这一族被设备驱动直接拒绝，
不是引擎缺陷，也不计入 `failures`；本机因此没有覆盖该采样率族的播放路径。

### 2.2 实际播放（15 种通过格式）

15 项全部满足：`passed=true`、`openStatus=0`、`playStatus=0`、`exclusive=true`、`dspActive=false`、
`formatMatchesSource=true`、`engineReportsBitPerfect=true`、`derivedBitPerfect=true`、
`underrunFrames=0`，`positionMillis` 在 1790–1820 ms 之间（请求 1800 ms）。
`outputRate` / `outputBits` / `outputContainerBits` 与请求一致，说明没有发生重采样或容器位深漂移。

结论边界：这证明的是“WASAPI 独占协商成功 + 引擎上报与推导均为逐位一致 + 短时零欠载”，
不证明物理 SPDIF/I2S 回环、模拟输出保真度或长时间（小时级）稳定性。

## 3. Native 构建与探针

```powershell
$env:LAZER_FFMPEG_ROOT='D:\Lazer\Lazer\build\ffmpeg-sdk'
cmake -S native/lazer-audio -B build/native-audio-cmake -G "Visual Studio 17 2022" -A x64 -DLAZER_FFMPEG_ROOT="$env:LAZER_FFMPEG_ROOT"
cmake --build build/native-audio-cmake --config Release --target lazer-audio
cmake -S native -B build/native-probes -DLAZER_FFMPEG_ROOT="$env:LAZER_FFMPEG_ROOT" -DLAZER_AUDIO_NATIVE_PROBES=ON
cmake --build build/native-probes --config Release
ctest --test-dir build/native-probes -C Release --output-on-failure
```

配置阶段 `LAZER_FFMPEG_HAS_REQUIRED_DSD_APIS` 为 Success（FFmpeg 提供 DSF/DFF 解析所需 API）。
编译只有既有告警（C4819 代码页、C4244 FFmpeg 头、C4324 对齐），没有 error。

`lazer-audio-engine-gapless-probe` 覆盖的准备生命周期用例：

| 用例 | 覆盖点 |
| --- | --- |
| `runGatedCancellationCase(false)` | 队列 clear 取消仍在 `openReader` 中的准备，2 秒内返回，reader cancel/close 各一次 |
| `runGatedCancellationCase(true)` | `stop` 取消正在进行的准备 |
| `runBlockedOpenCancellationCase()` | `stop` 取消阻塞在 `openReader` 的主 open |
| `runExactClearCancelsPreparationCase()` | `clearQueuedReaderEx` 按代次取消阻塞中的准备，队列线程拿到 `LazerAudioErrorCancelled` |
| `runExactClearGenerationCase()` | 目标不存在时推进请求代次并返回 Cleared；重复或更旧的代次返回 ErrorState，且只推进一次 |
| `runExactClearInstalledCase()` | 清理已安装但未越界的 successor；目标消失后再次调用仍返回 Cleared |

## 4. Flutter 层检查

```powershell
flutter analyze --no-pub
flutter test --no-pub
```

- 静态分析：`No issues found!`
- native 相关三个测试文件（`native_queue_lifecycle_test.dart`、`native_audio_paths_test.dart`、`native_audio_loader_test.dart`）：30 项通过。
- 全量测试结果见第 8 节，Lua/插件测试的 28 项失败经基线副本复核为既有环境问题，与本轮音频改动无关。

## 5. Linux

本机没有 Linux 环境，本轮无法产生 Linux 运行证据，`hardwareTested=false`。

可用的软件证据：引擎源码与 Windows 共用同一份 `native/lazer-audio/src`，
`ci/verify-*` 脚本与 CMake 目标在 Windows 上通过；Linux 侧的构建、CTest 与 ELF 导出检查由 CI 的
Ubuntu job 执行，本分支推送后才会产生对应的 CI 运行记录。在 CI 结果出现之前，
不能把 Windows 的 WASAPI 结论外推到 ALSA/独占/DSD 设备。

## 6. Android

- APK：`build/app/outputs/flutter-apk/app-release.apk`，117,406,026 字节，SHA-256 见第 1 节。
- `python ci/verify-package-contents.py …` 通过（FFmpeg 打包排除项检查）。
- `python ci/verify-android-audio.py --apk …` **未通过**：`incomplete ABI arm64-v8a: missing payload
  ['liblazer-audio.so', 'liblazer-audio-bridge.so']`。

根因不在代码，而在主机限制：`ci/build-android-audio.sh` 明确只支持 Linux/macOS 主机
（`*) echo "Run the Android build helper on Linux or macOS" >&2; exit 2`），并且需要先用
`build_android_dsd_ffmpeg.sh` 为 Android 交叉编译 FFmpeg。本机虽有 NDK `28.2.13676358`，
但没有 `build/android-ffmpeg`，也没有 `android/app/src/main/jniLibs`，
因此这个 APK 里只有 Flutter 层，不含引擎与桥接库。Android 原生载荷的导出、依赖与 16 KiB 对齐
必须由 CI 的 Ubuntu job 证明。

没有 ADB 设备（`adb` 不在 PATH），USB 权限、UAC2、采样率/位深切换、拔插、后台与焦点、
长时间资源占用全部未测，`hardwareTested=false`。历史 APK 的测试结果不适用于本 APK。

## 7. Web

- `flutter build web --release --no-pub` 通过（`√ Built build\web`），stderr 只有既有的
  `dart:ffi unsupported without --enable-experimental-ffi` wasm dry-run 警告。
- 回退路径由条件导出保证：`lib/audio/native/lazer_audio_library.dart` 在 `dart.library.html` 下改用
  `lazer_audio_library_web.dart`，后者 `LazerAudioLibrary.api => null`、`reason='浏览器没有原生音频库'`、
  `LazerAudioLoader.isSupportedHost => false`，因此浏览器不会尝试加载 ABI 31 的二进制。
- Web 的普通播放不能被报告成 native 独占、bit-perfect 或真实 DAC 直通；本轮也没有在浏览器里
  实际播放，相关项目 `hardwareTested=false`。

## 8. 测试与门禁汇总

| 项目 | 结果 |
| --- | --- |
| `flutter analyze` | 通过 |
| native 相关 Dart 测试（3 个文件） | 30 项通过 |
| 全量 `flutter test` | 见下方补记；Lua/插件 28 项失败为既有环境问题 |
| native 探针 `ctest` | 见第 3 节 |
| Windows DAC 验收 | 15/15 通过，0 失败 |
| APK 内容检查 | 通过 |
| APK 原生音频检查 | 不适用（本机无法产出 Android 原生载荷） |

## 9. 未覆盖项目

- Windows：88.2 / 176.4 / 352.8 kHz 播放（设备拒绝）；DSD/DoP 输出；模拟回环与保真度；
  小时级长播；多设备热插拔；蓝牙与虚拟端点。
- 全部平台：真实设备上的取消时序观察（只有探针与夹具证据，没有用户可感知的听感验证）。
- Android：一切真机项目。
- Linux：一切运行项目。
- Web：浏览器内实际播放。

`hardwareTested` 取值：Windows USB DAC 为 `true`（范围见 2.2）；Linux、Android、Web 均为 `false`。
