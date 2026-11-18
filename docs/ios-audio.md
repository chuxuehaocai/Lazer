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

## 重签名与安装

CI 交付未签名 IPA。签名需要自己的证书与有效 provisioning profile；应用和
Widget 使用显式 App ID 时，分别提供覆盖各自 bundle identifier 的 profile。
两者必须属于同一签名团队。App Group 只有在所有目标的 profile 都授权同一个组时才启用；
未授权时 Widget 显示未启用共享容器。

Windows 使用 Python 3 和 `apple-codesign` 的 `rcodesign` 0.29 或更新版本：

```powershell
pwsh ci/resign-ios-ipa.ps1 -Ipa dist/Lazer-iOS-aarch64.ipa `
  -P12 dev-cert.p12 -P12Password (Read-Host -AsSecureString) `
  -Profile app.mobileprovision `
  -ExtensionProfiles @{ 'dev.naominet.lazer.PlayCountWidget' = 'widget.mobileprovision' } `
  -AppGroup group.com.example.lazer -Out dist/Lazer-signed.ipa
```

macOS 使用 Xcode command-line tools：

```sh
bash ci/resign-ios-ipa.sh --ipa dist/Lazer-iOS-aarch64.ipa \
  --profile app.mobileprovision --identity 'Apple Development: ...' \
  --extension-profile dev.naominet.lazer.PlayCountWidget=widget.mobileprovision \
  --app-group group.com.example.lazer --out dist/Lazer-signed.ipa
```

如果一个 wildcard profile 确实覆盖全部目标，可以省略 extension profile；
App Group 可省略。脚本按目标展开 application-identifier 和 keychain 通配符，
嵌入各自 profile，先签内部代码再签应用，并从最终 Mach-O 读回 entitlements。
密码只存于独立临时目录，最终 IPA 只打包 `Payload/`。签名、权限读回或包校验失败
均不替换已有输出文件。

自动回归使用可执行签名器替身生成 Mach-O 签名夹具，覆盖逐目标权限、二进制 plist、
profile 嵌入和密码文件清理。这不能证明真实开发者证书或物理设备安装已经验收；
`rcodesign verify` 也不能替代 Apple 的安装验证。

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

### 严格 USB 版本构建记录

2026-11-18，版本 `2.0.301+301` 的构建提交为
`59ee5b2aa31f706c161d5960b889bf739d0a4a8f`，
[CI 44243421544](https://github.com/chuxuehaocai/Lazer/actions/runs/44243421544)
使用 `macos-26` 执行 iOS 原生、Flutter 集成和 IPA 任务。真机/模拟器原生构建与
模拟器播放已通过，原生播放记录为 `PASS file=330ms reader=330ms ABI=29`。
Flutter iOS 集成日志以 `+7: All tests passed!` 结束，全部 7 项执行通过，无跳过项。
其中两个新增用例确认严格 USB PCM 和强制 DoP 在非 USB 路由上明确拒绝打开、不自动回退，
并在显式关闭严格输出后恢复普通 PCM 播放。整个 CI 已成功完成，真机 IPA 构建、
引擎动态导出、应用/Widget 元数据及最终包内容检查均通过。

本轮最终本地检查已通过：Flutter 全量测试 727 项（另 2 项因缺少外部插件 checkout
跳过）、Flutter 静态分析、本地化检查、Python CI 测试 106 项，以及 RemoteIO 假
AudioUnit 契约（约 6.2 秒）。本轮验证包括严格 USB 条件拒绝、16/24-bit 样本的精确
Float32 桥接、DoP marker/idle、条件变化后回调静音与状态失效，以及退出严格输出后在
下一次打开前恢复保存的 DSP。会话激活后验证失败会释放会话。这些检查不能替代真机输出验证。

后续界面补充明确了应用/系统音量条件、手动应用音量滑块、实际混音设置路径及重开提示；
相关 21 项 iOS 设置/输出路径测试、定向静态分析和本地化检查通过。

本地日志：`build/ios-usb-final-flutter-tests.log`、`build/ios-usb-final-analyze.log`、
`build/ios-usb-ci-tests.log`、
`build/ios-usb-remoteio-contract/Testing/Temporary/LastTest.log`。

本轮 CI 的检查任务也已通过：Flutter 727 项（另 2 项跳过）、Chrome 4 项、Python
106 项、静态分析、本地化检查，以及 AAudio/RemoteIO 契约；CI 中 RemoteIO 契约耗时
6.12 秒。已下载的证据在 `build/ios-usb-validation/check.log`、
`build/ios-usb-validation/native/` 和 `build/ios-usb-validation/flutter/`。
全量 Flutter 测试中的 2 项跳过不属于上述 7 项 iOS 集成测试。

- 新 IPA：`dist/ios-usb-direct-59ee5b2/Lazer-iOS-aarch64.ipa`，
  51,942,200 字节，版本 `2.0.301+301`；
  [CI artifact 14400824937](https://github.com/chuxuehaocai/Lazer/actions/runs/44243421544/artifacts/14400824937)。
- SHA-256：`3ab253c6c7b18431e0fe37d6eb68669120ee0c853fa6165d7fb86a4f7bbecd86`，
  与 CI sidecar 一致。本地复核通过 ZIP CRC、应用和 Widget 元数据、包内容检查，
  并确认新严格 USB 原生代码及本地化资源存在；记录在 `build/ios-usb-validation/delivery.json`。
  IPA 未签名，安装仍需用户自行签名。
- NK1 实机 PCM、兼容 DAC 的 DoP、USB 位流验证：待实机验收。

尚未进行 USB DAC 或 NK1 物理设备测试，也未验证锁屏、来电/Siri、物理路由插拔或长时播放。
模拟器拒绝路径通过不代表 USB 严格输出或 DAC 的 DoP 已经验收。操作步骤见
[真机验收第 11 节](audio-engine-hardware-verification.md#11-ios模拟器已有基础播放证据真机待验证)。

## 2.0.302 整合审计（2026-11-18）

本轮以 `b18ad0c` 的 `nextgen` 为基础，合入 `59ee5b2` 的 USB 分支；后者完整包含
`655e816` 的 Native HiFi 分支。最新歌词修复也在这次整合的代码中。
版本更新为 `2.0.302+302`，以区分此前生成的 `2.0.301+301` IPA。

审计修复：

- 原生替换播放失败时释放保留的输出和 AVAudioSession；非法源、ReplayGain、
  设备打开失败与不支持的 Native DSD/严格 PCM 请求均有回归。
- 严格输出的打开决策与音量、AutoMix、DSP、设备控制串行；拒绝正在打开时改变策略，
  通过可控并发 gate 和 Ready 回调重入验证。Dart 和 C++ 都在 clamp 前拒绝非有限音量。
- 固定 period 输出也进行有界启动预填等待，避免解码首帧尚未到达就先写整包静音；
  使用真实 reader 和 endpoint 双 gate 复现并验证，保留原有精确字节断言。
- Dart 检查 stop、DSP 和音量返回码；失败或新一代 source 请求清除旧信号路径。
  异步终端回调须匹配当前 native snapshot，防止旧失败误清新源。
- 启动时强制同步已保存设置、controller 与 DSP；输出条件拒绝不再触发 queue fallback
  或 CDN 重试，提供四语恢复提示，普通源/解码错误的既有重试行为保持覆盖。
- IPA 元数据门禁覆盖 extension identifier、缺失扩展文件、重复或歧义 ZIP 路径。
  重签名修复密码入包、profile 缺失及目标权限错误，新增实际执行包装器与签名器替身的回归。

本地验证日志位于 `build/ios-integrated-audit/`：Flutter 790 项通过，另 2 项因缺少
外部插件 checkout 跳过；静态分析、本地化与 Python 98 项检查通过。RemoteIO 使用
Clang 23、`-Wall -Wextra -Werror` 构建并通过契约检查；原生 probe 全量及本轮 Apple CI
结果另行记录。Windows Chrome 检查因 Flutter 3.47 的测试资源路径在本机返回
CanvasKit 404 而未执行，浏览器边界改由 Linux CI 验证；未修改系统 Flutter SDK。

上述软件审计没有增加 USB DAC、NK1、真实 Apple 证书安装或物理位流的验收证据。
