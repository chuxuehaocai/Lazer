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
| 普通高采样率/24-bit PCM | 解码源格式，向 AVAudioSession 请求采样率，再采用路由授予的输出时钟 |
| USB 严格 PCM / Bit-perfect 请求 | 保留设置并交给后端检查；要求兼容 USB 路由、16/24-bit 无损整数源、相同实际时钟和不改变样本的输出链；条件不符则失败 |
| DSD 文件 | 默认解码为 PCM；用户明确选择 DoP 后尝试严格 24-bit 载波，拒绝时不暗中转 PCM；原始 Native DSD 仍不可用 |
| EQ、前级、限幅器 | 使用已有原生 DSP 链，可实时应用；拒绝信息回传设置页 |
| 耳机串扰 | 原生 crossfeed，包括 Bauer、BS2B、Meier 和自定义参数 |
| DSP 顺序 | 传入原生链并持久化，重启读取保存的顺序 |
| USB DAC/耳机/AirPlay | 由 iOS 管理当前输出；连接 DAC 或在控制中心切换路由 |
| 硬件独占 | 不提供 macOS Hog Mode；严格 USB 的 nonmixable 会话不等于硬件独占，`outputExclusive` 仍为 false |

上述是实现范围，并非全部真机验收结果。系统授予的采样率可能不同于请求；
普通 PCM 路由恢复时保留现有客户端时钟，避免已排队的样本变调，由 AudioUnit 适配新的硬件时钟。
严格 PCM/DoP 不可用这种重采样恢复掩盖条件变化；USB、格式、音量或会话条件失效时必须停止。
信号路径显示的会话格式不能当作 DAC 的物理位流证明。

## USB 严格输出的边界

此前版本将 iOS 的 Bit-perfect 与 DoP 一并禁用，这属于旧后端的实现限制，
不能作为 iOS 平台不可能实现的结论。公开产品已有 iOS
[Bit-perfect PCM](https://www.neutroncode.com/faq/38-bit-perfect-output) 和
[DoP 输出](https://intl.onkyo.ru/downloads/applications/hf_player.html) 的说明。

本轮通过公开的 AVAudioSession 和 RemoteIO 实现有条件的严格 USB 路径：

- 使用 playback/nonmixable 会话，按源或 DoP 载波请求时钟，并核对激活后的实际值。
  [Apple 明确 preferred 值只是请求](https://developer.apple.com/library/archive/qa/qa1631/_index.html)。
- PCM 保持 16/24-bit 整数样本，绕过重采样、软件音量、EQ、限幅、串扰、归一化和淡变。
  最终回调转成能够精确表示这些样本的 Float32；严格模式拒绝 32-bit 整数和浮点源。
- DoP 保留 DSD 数据与交替 marker；DSD64/128 对应 176.4/352.8 kHz 的 24-bit 载波。
  这是 DSD 装进 PCM 帧传输，不是 DSD 解码为 PCM。
  [DoP 标准](https://dsd-guide.com/sites/default/files/white-papers/DoP_openStandard_1v1.pdf)
  同时要求在发送前确认接收硬件能力。
- App 增益必须为 1，系统音量和输出路由也要满足后端检查；不擅自提高用户系统音量。
  [系统音量只能由用户直接设置](https://developer.apple.com/documentation/avfaudio/avaudiosession/outputvolume)。
- iOS 的自动 DSD 策略使用 PCM；只有用户明确选择 DoP 才发送载波。USB 设备名称、
  高采样率支持或 `outputExclusive=false` 都不能单独判定 DoP 是否可用。

“严格请求被接受”证明应用与系统会话满足所检查的条件；没有 USB 抓取、数字回环或
DAC 自带 bit-test，不能把它写成已经验证 DAC 收到完全相同的位流。
nonmixable 是会话行为，[Apple 说明它会中断其他 nonmixable 会话](https://developer.apple.com/documentation/AVFAudio/AVAudioSession/Category-swift.struct/playback)，
它不是硬件独占锁。

## NICEHCK 原道 NK1

2026-11-18 核对的 [NICEHCK 官方 NK1 页面](https://www.nicehck.cn/en/store/nk1)
列出 Type-C 输入、3.5mm 输出、CX31993，以及 NK1 规格卡上的 32Bit/384kHz；
该卡也出现 CX31993AU/CB1200AU 的型号标注。应记录用户实际设备与固件，不能仅凭产品名
把所有批次当成同一 USB 设备。页面没有明确声明 DSD 或 DoP 支持，也未给出具体 iOS
版本的兼容性保证。384 kHz PCM 能力不等于 DoP 解包能力。

NK1 的优先验收项目是 16/24-bit PCM 严格输出和按源切换采样率；DSD 曲目默认转 PCM。
在厂家确认该批次支持 DoP，或以可控测试验证前，不把 NK1 标为 DoP/Native DSD 兼容设备。
普通音乐出声、显示 176.4 kHz 或接通 USB 都不能替代 DSD 解码能力验证。

## 2026-11-18 基础播放修复

- 读取 RemoteIO 的 `MaximumFramesPerSlice`，为锁屏和采样率转换后的大回调预留缓冲。
  原先仅按普通 IO 周期分配的小缓冲可能在每次回调中持续欠载。恢复路由时保留已排队样本，
  按客户端/硬件时钟比例更新生产线程轮询周期；分配不在实时回调执行。
- 采样率偏好与 `preferredSampleRate` 比较，避免当前路由恰好匹配、旧偏好却影响下一次 USB 路由。
- 清除不属于 iOS 路由的桌面设备 ID 和硬件独占偏好；保留 EQ、串扰、缓冲和 DSP 顺序。
  本轮严格 USB 修订保留 Bit-perfect 和明确的 DoP 请求，不再统一改写成普通 PCM。
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
另增加两项非 USB 路由测试：经 HiFi 控制器请求严格 PCM 和 DoP，要求原生打开明确拒绝、
不偷偷回退；随后用户显式改回 PCM，验证引擎仍能播放。连接 USB 的真机运行时这两项会跳过，
避免在未知 DAC 上发 DoP 载波；CI 模拟器应执行全部 7 项。
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

基础播放修复的 Windows 验证通过：Flutter 全量测试 714 项（另 2 项因缺少外部插件 checkout 跳过）、
Python CI 测试 106 项、Flutter 静态分析、本地化检查、RemoteIO 假 AudioUnit 契约和
CoreAudio 队列探针。日志在 `build/ios-goal-tests.log`、`build/ios-goal-ci-tests.log`、
`build/ios-goal-analyze.log` 和 `build/ios-remoteio-goal-contract/Testing/Temporary/LastTest.log`。
契约覆盖 192 kHz 输出、
16,384/32,768 帧回调、路由恢复时环形队列保留与错误 readback。
这些历史检查不覆盖后来新增的严格 USB 路径，也不能替代 Apple SDK 编译或 iPhone 的实际输出。

基础播放提交 `655e8169df243fb6a4c177b0e63c4fef1da43790` 的
[CI 44236700237](https://github.com/chuxuehaocai/Lazer/actions/runs/44236700237)
已通过本轮真机/模拟器原生归档构建、平台与导出检查、原生模拟器播放
（`PASS file=330ms reader=365ms ABI=29`），以及全部 5 项 Flutter iOS 集成测试。
真实模拟器日志确认 44.1/96 kHz PCM、192 kHz 源转为路由授予的 96 kHz、
DSD64 转 96 kHz PCM、−12 dB 前级效果、EQ/串扰及 HTTP reader 播放。
日志保存在 `build/ios-ipa-validation/native/` 和 `build/ios-ipa-validation/flutter/`。

该基础播放构建的未签名真机 IPA 已生成并下载到
`dist/ios-native-hifi-655e816/Lazer-iOS-aarch64.ipa`（51,929,116 字节，2.0.300+300）。
本地 SHA-256 与 CI sidecar 一致：
`676c86b6e86697f35a15a9c33f4f0834f3b1a6cb423d8aa57fd3750ba98b46b4`。
ZIP CRC、应用/Widget 元数据与包内容检查均通过；安装需要用户签名。
这个历史 IPA 不包含本轮严格 USB PCM/DoP 改动，不能用它验收新增功能。

### 严格 USB 版本构建记录（待生成）

- 提交、CI 运行和新 IPA：待完成本轮实现及构建验证后记录。
- 新 IPA SHA-256：待生成；不复用上面的基础播放包校验值。
- 7 项 iOS 模拟器集成结果：待本轮 CI 执行；静态分析或 Windows 契约通过不代表它已运行。
- NK1 实机 PCM、兼容 DAC 的 DoP、USB 位流验证：待实机验收。

尚未验证真机 USB DAC、锁屏、来电/Siri、物理路由插拔或长时播放。操作步骤见
[真机验收第 11 节](audio-engine-hardware-verification.md#11-ios模拟器已有基础播放证据真机待验证)。
