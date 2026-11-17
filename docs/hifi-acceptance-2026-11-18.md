# HiFi 验收与 Android USB 整合记录（2026-11-18）

本记录把 `Lazer-hifi-android-test` 本地快照中的 Android USB 直出、打包检查和验收方法整合到当前 UI 分支。
快照本身不是 Git 仓库，基线为 `d599a918a556e04a3918ace64fab197c6acc9a62` 加当时未提交修改，
不能当作当前分支的构建结果。下面分开记录历史证据、本轮检查和需要真实设备的项目。

## 已有证据与边界

| 对象 | 已查看的证据 | 可以确认 | 仍不能确认 |
| --- | --- | --- | --- |
| 2026-11-17 Android 测试 APK | 快照的 `dist/build-manifest.json`、`dist/verification.txt`、实际 APK SHA-256；`build/apk-release.log` 与最后 ARM 封装日志均成功 | 完整 FFmpeg/USB 引擎和桥接库已装入 ARM64、ARMv7 APK；本地 debug 证书 v2 签名；ABI 29；ELF 导出、系统依赖、16 KiB ELF/ZIP 对齐、ZIP CRC、完整 ARM 载荷检查通过 | 手机安装、真实 USB 权限、OTG、DAC 输出及长时播放 |
| 快照 Flutter 测试 | `build/usb-flutter-tests.log`，15 项通过 | 4 项 USB 通道、6 项 HiFi 设备目录、5 项队列行为的测试替身契约 | 真实 Android USB 服务和硬件行为 |
| 快照原生主机测试 | `build/uac2-contract/Testing/Temporary/LastTest.log`、`build/uac2-packetizer/Testing/Temporary/LastTest.log`、`build/aaudio-contract/Testing/Temporary/LastTest.log` | 传输/输出 2 项、分包器 1 项、AAudio/日志 2 项通过；生产代码与假设备检查精确 PCM 字节、时钟控制、取消、FD 所有权及有界关闭 | USB 总线时序、真实驱动/DAC 兼容性和听感 |
| 历史 Windows NICEHCK 验收 | `docs/audit-2026-11-17.md` 记载 15 种格式通过 | 文档记录了 WASAPI 独占、无 DSP、源格式一致和短时零欠载 | 其 `dac-release.json` 未包含在 Android 快照内；本轮没有重新运行，不能用它证明 Android、物理逐位透明或模拟性能 |

历史 APK：`Lazer-HiFi-Android-Test.apk`，91,428,598 字节，版本 `2.0.300+300`，
包名 `dev.naominet.lazer.hifitest`，Android API 26+，目标 API 36。
SHA-256 为 `0253c3392c692efef8237f3b6ad8906100c349eed152997a0de28d35b48b12f1`；
本轮只读重新计算后与清单一致。准备该 APK 时没有 ADB 设备，`hardwareTested=false`。
它使用独立包名和测试名称隔离已安装应用的数据，是本地 debug 签名的测试产物。

小型来源摘要保存在 [历史证据 JSON](validation/hifi-android-2026-11-17.json)。APK、归档和构建缓存没有复制进源码。
旧的 `docs/audit-2026-11-17.md` 中“完整 Android APK 尚未完成”描述的是更早时点，已被上述隔离 APK 的构建记录补充；
手机/DAC 未验收的边界仍成立。`docs/audio-engine-hardware-verification.md` 面向旧桌面验证流程，
其中“开启 EQ 后 bit-perfect 熄灭”的段落与后面“bit-perfect 下保留但旁路 DSP 设置”相互矛盾；
本次 Android 验收按实际信号路径与下面的明确矩阵判定。

## 本轮新代码验证

本轮补入的 CI 门禁要求随包引擎导出 `lazer_audio_android_usb_backend_version`，
保留原来的引擎/桥接导出、依赖、FFmpeg 符号和 16 KiB 检查。
重新链接包现在包含实际构建使用的 libusb 静态库、对应源代码、许可证、CMake 配方及清单哈希，
并把 libusb 加入重新链接命令；源路径以构建生成的 `android-usb-relink.json` 为准，支持源码覆盖。

新增的 4 项设备无关 CI 回归已通过（修复前 3 项失败）：缺 USB 能力导出会拒绝；原有引擎/桥接导出仍检查；
重新链接包包含实际 libusb 源和一致哈希；静态库缺失会停止打包。它们使用小型 ELF/归档夹具，
没有编译 Android 引擎，也没有把夹具当作可播放引擎。
本轮日志为 `build/hifi-ci-before.log`、`build/hifi-ci-after.log`。
后续补入发布 ABI 修复：仅 `lazerRequireNativeAudio=true` 时，在 AGP `finalizeDsl` 阶段将 fat APK
收口为双 ARM；ABI split 则收口 split 列表并清除冲突的 NDK filters。普通模拟器/debug 构建保持 Flutter 行为。
门禁新增 4 项 ZIP 回归，拒绝只有插件库的额外架构及任一架构缺 Flutter/app 核心载荷，支持显式单 ABI split 验证；
累计 **8/8** CI 回归通过，红/绿日志为 `build/hifi-abi-before.log` 与 `build/hifi-abi-after.log`。
这部分 Gradle 配置和最终封装以本轮新 APK 的结果为准。
本轮还用整合后的原生封装门禁重新只读检查了上述历史 APK：双 ABI 的四个引擎/桥接库通过，
FFmpeg 打包排除检查也通过；日志为 `build/hifi-historical-apk-gate.log` 和
`build/hifi-historical-apk-contents.log`。这是新检查器对旧产物的复核，没有生成新 APK。

本轮还修复了 Android 权限回调的生命周期问题：请求带独立 nonce，取消后重开同一设备时，旧回调不会消费新请求；
各 Flutter engine 使用独立权限 action。容器上限为 **8 个待授权设备、每设备 32 个等待者、8 个打开连接**，
超过上限明确返回 `usb_busy`，不会驱逐正在使用的连接。无效 FD 会先关闭，不能进入缓存；
关闭某个连接异常也不会阻止其余连接清理。该状态管理已拆入 `UsbAudioSessionState.kt`，独立 Kotlin 契约 **9/9 通过**。
实际插件与状态模块还使用 Android 36 SDK、Flutter embedding、JVM 17 和 `-Werror` 编译通过。

以下软件验证针对 UI 提交 `2efead48ffb836d54f4e10c1114e9f0496ad604c` 加本次整合文件。
独立验证树排除了工作区中另一项窗口 UI 任务的未提交文件。

| 验证 | 本轮结果与证据 |
| --- | --- |
| 独立源码 Flutter 全量测试 | 381 通过、2 跳过；`build/hifi-clean-tests.jsonl`。跳过项依赖未提供的外部网易云插件 checkout |
| 当前完整工作区 Flutter 全量测试 | 404 通过、2 跳过；`build/hifi-workspace-tests.jsonl` |
| 静态分析与翻译 | 独立树和工作区分析通过；翻译完整性通过；`build/hifi-clean-analyze.log`、`build/hifi-workspace-analyze.log`、`build/hifi-clean-i18n.log` |
| CI / Kotlin 契约 | CI 8/8、Kotlin 9/9；`build/hifi-clean-ci-tests.log`、`build/usb-audio-session-contract/result.log` |
| 原生主机契约 | USB 传输/输出 2、分包器 1、AAudio/日志 2，合计 5/5 通过 |
| Android 原生编译 | 输出后端 ARM64、ARMv7、x86_64 编译/链接探针通过；完整引擎与桥接库重新构建双 ARM，四个库导出、依赖与 16 KiB 对齐通过；`build/hifi-usb-integration/integration-manifest.json` |
| 重新链接归档 | 双 ARM 各 193 项内部哈希通过；每包 16 个对象、5 个静态库、165 个 libusb 源文件。实际解包执行 `relink.sh` 成功，新生成库再次通过封装门禁；`build/hifi-usb-integration/dist/relink-package-audit.json` |
| Windows / Web | Windows Release 和 Web JavaScript Release 构建通过；`build/hifi-clean-windows-build.log`、`build/hifi-clean-web-build.log`。原生编译警告和 Web Wasm dry-run 的 FFI 不支持提示仍存在 |
| Android APK | 独立树 `assembleRelease` 成功（3 分 41 秒），实际 Gradle/Kotlin 插件编译、资源与 lintVitalRelease 通过；`build/hifi-apk-build.log` |
| APK 完整性 | 双 ARM 完整载荷、四个音频库导出/依赖、ELF/ZIP 16 KiB 对齐、签名 v2、ZIP CRC 和 FFmpeg 打包排除全部通过；`build/hifi-current-apk-*.log` |

本轮 APK 位于 `build/hifi-clean-verification/build/app/outputs/flutter-apk/app-release.apk`，
**91,724,514 字节**，SHA-256 为 `43afb866a3946f2a2c147b494cd37a3f30d5b8f08a114ec9fa13a85ce0514178`。
包身份保持当前项目的 `dev.naominet.lazer` / `Lazer`，版本 `2.0.300+300`、最低 API 26、目标 API 36，
仅包含 ARM64 与 ARMv7。使用本地 Android Debug 证书签名，不是生产签名；未安装到设备。
本轮新编库经 NDK `--strip-unneeded` 后与包内四个音频库逐字节对应，未混入历史 APK 的播放库。
构建使用目标分支源码和锁定依赖；只读复用了快照的 FFmpeg/libusb 构建依赖及 Maven 缓存，
Maven 构建在独立 `build` 目录以本地文件镜像离线完成，没有复制历史快照的包名、签名或全局 Gradle 配置。
可核对的小型产物记录见 [本轮验收 JSON](validation/hifi-integration-2026-11-18.json)。

**当前 ADB 无设备，硬件状态仍为 `hardwareTested=false`。** 尚不能断言真实 DAC 位透明、模拟音质，
或高规格音源长时播放的 CPU/RSS、温度、欠载与卡顿表现。
更换分支、二进制或引擎后，应为新产物重新生成证据，不能继承历史 APK 的通过状态。

## 功能入口与默认设置

入口是正常的「设置 → 高保真播放 → 播放引擎 / 输出设备 / 独占输出 / Bit-perfect 输出 / 信号路径」。
没有单独的 HiFi `dart-define`、测试模式或一键硬件验收开关。
独立测试 APK 的身份来自包名和应用名，相关播放功能不是通过测试开关临时开启。

新配置默认优先原生引擎、使用系统默认设备、关闭独占与 bit-perfect、DSD 自动策略并允许 PCM 回退；
响度归一化关闭，EQ/串扰默认关闭，缓冲为 small。选择 USB 设备后会请求其独占路径，bit-perfect 仍需明确开启；
目录刷新不会提前申请 USB 权限。实际权限在打开设备时请求。
权限拒绝、格式/时钟不支持、设备断开必须明确失败，不允许偷偷改为系统输出。

bit-perfect 要求软件音量为 100%，会旁路软件音量及 DSP；设置开关不能代替实际路径状态。
先把 DAC 的物理音量调低，使用明确的低幅度素材；不要依赖应用滑块作为直通模式下的衰减器。
按“直出/独占”显示并不能证明样本位内容、模拟失真、噪声或动态范围。

## 可复用的 Windows 低幅度验收

`tool/dac_acceptance.dart` 只支持 Windows WASAPI，不是 Android USB 验收程序。
它要求 `--device` 唯一匹配一个活动端点，对 44.1/48/88.2/96/176.4/192/352.8/384 kHz 的
16/24/32 位立体声组合先探测，再对被端点接受的组合播放。
每个夹具为 4 秒、997 Hz、−80 dBFS 整数 PCM；观察约 1.8 秒，要求进度至少 1 秒、零欠载、
整数输出、源采样率/有效位数一致，以及引擎与派生 bit-perfect 判定一致。
不支持的格式单独记录状态，不降采样伪装通过；没有可播放格式也会失败。
它不会改变 OS 音量或默认端点，也不写入应用 HiFi 偏好。

从仓库根目录运行，使用该分支刚构建的同一组引擎与桥接库；下面库路径只是明确选择二进制的示例：

```powershell
$env:LAZER_AUDIO_LIBRARY = (Resolve-Path build/windows/x64/runner/Release/lazer-audio.dll).Path
$env:LAZER_AUDIO_BRIDGE_LIBRARY = (Resolve-Path build/windows/x64/runner/Release/lazer-audio-bridge.dll).Path
dart tool/dac_acceptance.dart --device "NICEHCK" --output build/reports/dac-current.json
```

输出 `build/reports/dac-fixtures/` 的合成 WAV 和指定 JSON；报告需保留 `engineBuild`、设备、支持/拒绝格式、
`completed`、`testedFormats`、`failures` 和每项播放结果，不能只截取“通过”行。
枚举/加载阶段就失败时可能尚未写报告，应同时保存终端错误与退出码。
短时协商/遥测不涵盖暂停、seek、拔插、长时热稳定性；数字位透明需要外部数字录波逐样本比较，
模拟音质需要独立测量。
`tool/native_path_check.dart --play` 默认是幅度 0.25（约 −12 dBFS）的另一条合成音流程，
不能视为上述 −80 dBFS 低幅度入口。

## Android 手机 / DAC 手工矩阵

先记录 APK 哈希、应用版本、引擎 build/ABI、手机型号/Android 版本、DAC 型号/固件/VID/PID、
OTG/供电方式与素材哈希。选择测试应用，先低物理音量，使用本地 PCM 排除网络变量。
每项保留实际「信号路径」截图、应用诊断日志和 DAC 显示；失败也要保留。

| 项目 | 操作与素材 | 验收条件 |
| --- | --- | --- |
| 正常系统输出 | 不选 USB，播放 44.1/48 kHz PCM | 显示 AAudio 共享 PCM；不能宣称 USB 独占或 bit-perfect |
| 发现与权限 | 插入 DAC，刷新并选择；分别允许和拒绝权限 | 刷新不先弹权限；打开才请求；拒绝明确报错，无系统输出替代 |
| PCM 格式 | 依 DAC 能力测试 44.1/48/96/192 kHz、16/24/32 位及其声明支持的更高格式 | 实际速率/精度/容器/声道与素材对应，DAC 正常出声且无变速/爆音；拒绝格式应明确失败 |
| bit-perfect | 使用受支持整数 PCM、100% 软件音量、启用 bit-perfect | 实际独占、DSP 不在路径、源格式一致，派生与引擎标志一致；数字录波另列结果 |
| DSP | 先关闭 bit-perfect，再启用 EQ/串扰；之后开启 bit-perfect | DSP 进入时不得宣称 bit-perfect；bit-perfect 期间保存的 DSP 设置应旁路，不能同时声称生效 |
| 播放控制 | 暂停/恢复、连续 seek、切歌、重复歌曲和队列衔接 | 进度/声音对应，界面不锁死；无爆音和持续欠载；记录间隙及错误 |
| 拔插与权限恢复 | 播放/暂停中拔出，再插回；另试取消权限 | 明确记录设备丢失，不静默退到系统；重连路径可能变更，重新选择并重新检查实际格式 |
| DSD 转 PCM | bit-perfect 关闭，使用 DSD64/128/256；保持默认 auto/允许 PCM 回退设置 | 显示 converted PCM，实际协商 44.1 kHz 家族；不得显示 native DSD、DoP 或 DSD bit-perfect |
| 强制直通 DSD | UI 可要求 DSD bit-perfect；requireNative/requireDoP 通过原生契约或测试设置注入，Android 普通 UI 不提供该策略选择 | Android USB 当前路由明确拒绝，不能改为 PCM 后宣称满足请求 |
| 中断与生命周期 | 来电/音频焦点抢占、前后台、锁屏、活动重建 | 行为可恢复或明确失败，不从错误位置播放，不泄漏权限连接；恢复后重查路径 |
| 长时及资源 | 受支持高规格素材连续播放至少 1 小时，并多次拔插/切歌 | 记录欠载、CPU、RSS、温度和连接数趋势；不能仅凭 short test 推断通过 |

Android 直出仅支持 UAC2、Type-I 有符号整数单/双声道 PCM、直接 Clock Source、USB 2.0 full/high-speed，
容器组合为 16-in-16、24-in-24、24-in-32、32-in-32；PCM 8–768 kHz 仍受设备和端点带宽限制，保持源速率。
异步端点需显式反馈；同步/自适应端点采用精确分包。
不支持 UAC1/UAC3、SuperSpeed、隐式反馈、Clock Selector/Multiplier、多声道、USB native DSD 或 DoP。
DSD 转换会尝试可用的 44.1 kHz 家族 PCM 率，并始终明确标记转换。
这些描述是实现的支持边界，不是对所有符合描述的真实 DAC 的兼容性保证。

## 复现软件与封装门禁

使用仓库固定 Flutter SDK 和已锁定依赖。主机契约无需连接 DAC：

```sh
flutter test --no-pub test/android_usb_audio_test.dart test/hifi_android_devices_test.dart test/queue_audio_engine_test.dart
python3 -m unittest discover -s ci/tests -p test_android_audio_acceptance.py -v
cmake -S native/lazer-audio/tools/uac2_transport_probe -B build/uac2-contract
cmake --build build/uac2-contract --config Release
ctest --test-dir build/uac2-contract -C Release --output-on-failure
cmake -S native/lazer-audio/tools/uac2_packetizer_probe -B build/uac2-packetizer-contract
cmake --build build/uac2-packetizer-contract --config Release
ctest --test-dir build/uac2-packetizer-contract -C Release --output-on-failure
cmake -S native/lazer-audio/tests/aaudio -B build/aaudio-contract
cmake --build build/aaudio-contract --config Release
ctest --test-dir build/aaudio-contract -C Release --output-on-failure
```

原生和 APK 构建方法见 [Android Audio Engine](android-audio.md)。

Windows 下可独立运行 USB 权限和连接容器契约，`KotlinHome` 指向含 `bin/kotlinc.bat` 的 Kotlin 安装目录，
`JavaHome` 指向 JDK 17 或更新版本：

```powershell
.\tool\usb_audio_session_check.ps1 -KotlinHome <Kotlin安装目录> -JavaHome <JDK安装目录>
```

APK 门禁：

```sh
python3 ci/verify-android-audio.py --apk build/app/outputs/flutter-apk/app-release.apk
python3 ci/verify-package-contents.py build/app/outputs/flutter-apk/app-release.apk
```

发布构建需启用 `lazerRequireNativeAudio=true`（CI 已设置）。使用 `--split-per-abi` 生成的单架构 APK
可分别用 `--apk <split.apk> --abi arm64-v8a` / `--abi armeabi-v7a` 检查。
默认 fat APK 门禁要求双 ARM，并检查所有实际广告架构都具有非空 Flutter、app、engine、bridge 载荷，
避免第三方 x86_64 库让安装包声称支持不完整的 x86_64 应用。

另用 Android SDK 的 `apksigner verify --verbose --print-certs`、`zipalign -c -P 16 -v 4` 检查签名和 ZIP 对齐，
保留包身份/版本/ABI、完整 Flutter/app/engine/bridge 载荷、ZIP CRC 及新 SHA-256。
上述 Python 导出门禁不单独证明实际 ABI 版本函数的返回值、音频可播放或物理质量，仍需构建与运行证据。
