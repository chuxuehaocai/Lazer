# iOS Native Audio Engine 与 HiFi

## 播放路径

```text
Flutter NativeAudioEngine → Dart worker isolate → 静态链接的 C ABI
    → FFmpeg 解码 / 网络 growing reader → 原生 DSP → RemoteIO → iOS 当前音频路由
```

引擎、reader bridge 和四个 FFmpeg 库随应用静态链接，Dart 通过
`DynamicLibrary.process()` 访问。这样无需运行时加载用户导入的动态库。
设置页在 iOS 说明引擎随应用内置，并隐藏无效的引擎文件导入操作。

| 功能 | 当前实现 |
| --- | --- |
| 本地和网络音乐 | 原生 FFmpeg 与 reader bridge；输出使用 RemoteIO |
| 高采样率/24-bit PCM | 解码源格式，向 AVAudioSession 请求采样率，再采用路由授予的输出时钟 |
| DSD 文件 | 原生解码后转换为 PCM；不发送 DoP 或 Native DSD 位流 |
| EQ、前级、限幅器 | 使用已有原生 DSP 链，可实时应用；拒绝信息回传设置页 |
| 耳机串扰 | 原生 crossfeed，包括 Bauer、BS2B、Meier 和自定义参数 |
| DSP 顺序 | 传入原生链并持久化，重启读取保存的顺序 |
| USB DAC/耳机/AirPlay | 由 iOS 管理当前输出；连接 DAC 或在控制中心切换路由 |
| 独占、Bit-perfect | 此后端未提供，不根据源格式或用户偏好宣称成立 |

上述是实现范围，并非全部真机验收结果。系统授予的采样率可能不同于请求；
路由恢复时保留现有客户端 PCM 时钟，避免已排队的样本变调，由 AudioUnit 适配新的硬件时钟。
信号路径显示的会话格式不能当作 DAC 的物理位流证明。

## 2026-11-18 修复

- 读取 RemoteIO 的 `MaximumFramesPerSlice`，为锁屏和采样率转换后的大回调预留缓冲。
  原先仅按普通 IO 周期分配的小缓冲可能在每次回调中持续欠载。恢复路由时保留已排队样本，
  按客户端/硬件时钟比例更新生产线程轮询周期；分配不在实时回调执行。
- 采样率偏好与 `preferredSampleRate` 比较，避免当前路由恰好匹配、旧偏好却影响下一次 USB 路由。
- 将桌面恢复的设备 ID、独占、Bit-perfect、DSD 直通偏好转为 iOS 可播放策略，
  保留 EQ、串扰、缓冲和 DSP 顺序；设置页面、状态和引擎使用一致配置。
- 原生 DSP/输出拒绝不再被当作设置成功；失败后可重试相同配置。
- iOS 构建覆盖按 SDK 区分 device 和 simulator；检查 Mach-O 平台，避免仅凭 arm64
  将真机归档交给模拟器链接。完整导出检查在原生归档构建阶段执行。
- 增加 Flutter iOS 集成 CI 任务，作为 IPA 产出前置条件。运行器创建独立模拟器，
  保留日志、限制超时并清理其创建的实例；失败不保留旧 PASS 文件。

Apple 文档说明了 [IO 单元最大渲染帧数](https://developer.apple.com/documentation/audiotoolbox/kaudiounitproperty_maximumframesperslice)
和 [音频会话偏好与实际值的区别](https://developer.apple.com/library/archive/qa/qa1631/_index.html)。

## 构建与自动验证

在 macOS/Xcode 上运行：

```sh
flutter pub get --enforce-lockfile
dart tool/patch_lua_dardo_plus.dart
bash ci/build-ios-audio.sh simulator
bash ci/ios-audio-xcconfig.sh build/ios-audio/simulator/stage/lib simulator
python3 ci/run-ios-flutter-audio.py
```

运行器执行 `integration_test/ios_native_engine_test.dart`，覆盖进程内符号解析、
原生引擎选择、worker、24-bit 44.1/96/192 kHz 源、DSD64 转 PCM、实际输出时钟、
前级 −12 dB 的遥测变化、EQ/串扰播放、HTTP reader 与暂停/seek/恢复。
高采样率测试允许路由授予较低速率，不把模拟器当作高采样率 DAC。
DSP 测试信号约为 −66 dBFS，其余播放夹具静音。

日志在 `build/ios-flutter-audio/`；使用已连接设备则直接执行：

```sh
flutter test --no-pub integration_test/ios_native_engine_test.dart -d <device-id>
```

生成真机包采用 [构建说明](builds.md)；真机与模拟器的 arm64 静态库不能互换。

## 证据与待验收项

既有提交 `ce0c24a` 的 [CI 44229836575](https://github.com/chuxuehaocai/Lazer/actions/runs/44229836575)
已经通过 Xcode 26.6 构建、原生模拟器文件/reader 播放与 IPA 导出检查，
原生输出记录为 `PASS file=341ms reader=352ms ABI=29`。它不包含本轮更改。

本轮 Windows 验证通过：Flutter 全量测试 714 项（另 2 项因缺少外部插件 checkout 跳过）、
Python CI 测试 106 项、Flutter 静态分析、本地化检查、RemoteIO 假 AudioUnit 契约和
CoreAudio 队列探针。日志在 `build/ios-goal-tests.log`、`build/ios-goal-ci-tests.log`、
`build/ios-goal-analyze.log` 和 `build/ios-remoteio-goal-contract/Testing/Temporary/LastTest.log`。
契约覆盖 192 kHz 输出、
16,384/32,768 帧回调、路由恢复时环形队列保留与错误 readback。
这些检查不能替代 Apple SDK 编译或 iPhone 的实际输出。

本轮新增 Flutter iOS 集成测试尚待 macOS CI 执行；没有生成本轮 IPA，也未验证真机 USB DAC、
锁屏、来电/Siri、物理路由插拔或长时播放。操作步骤见
[真机验收第 11 节](audio-engine-hardware-verification.md#11-ios模拟器已有基础播放证据真机待验证)。
