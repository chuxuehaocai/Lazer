# 硬件验证交接（给拿到设备的人）

这份文档写给**手上真有 DAC / DSD 播放环境的人**。引擎里能离线证明的部分已经在探针里证明了；
这里只列**必须有硬件才能回答**的问题，以及每一步的预期输出与判读方法。

现状一句话：**默认路径、逐 bit 判定、实时线程、DSP 链都已落地并有离线证据；缺的是"某台真实设备
上这些结论是否成立"，包括 DSP 与 DSD 的物理层。**

---

## 0. 先决条件

| 项目 | 要求 |
| --- | --- |
| 分支 | `nextgen`（已合入 iOS RemoteIO、卷积和会话修复） |
| 构建 | 必须能找到 DSD-capable FFmpeg：设置 `LAZER_FFMPEG_ROOT`，或把 SDK 放在 `third_party/ffmpeg` |
| 引擎版本 | 源码与 Dart 镜像同为 **ABI 29**。构建会同时重编引擎；**不要**直接跑旧的 `build/` 产物 |
| 平台 | Windows 已验证构建；Linux 的构建链路在 CI 里，但播放行为未验证；macOS / iOS 目前不在范围内 |

构建（PowerShell）：

```powershell
$env:LAZER_FFMPEG_ROOT='D:\path\to\ffmpeg'
flutter build windows --release --no-pub
```

产物目录里应出现 `lazer-audio.dll` 与 `lazer-audio-bridge.dll`。没有就说明 FFmpeg 前缀没找到，
应用会回退到 `just_audio`，实际引擎与能力可在高保真设置和诊断日志中检查。

---

## 1. 默认路径：这个包会不会选原生引擎

```powershell
dart compile exe tool/native_path_check.dart -o build\windows\x64\runner\Release\native-path-check.exe
cd $env:TEMP
& D:\Lazer\build\windows\x64\runner\Release\native-path-check.exe --expect-native
```

**预期**：`decision=native`，两行 `ok`，退出码 0。

**判读**：如果出现 `library unavailable` 且原因是 `reports ABI 25; this build expects 29`，那是旧产物，
重新构建即可；如果是 `not found`，是引擎没被打进包。

---

## 2. Bit-perfect：独占 + 无 DSP + 格式一致

```powershell
cd $env:TEMP
& ...\native-path-check.exe --play --bit-perfect
```

**预期**（真能做到的端点）：

```
audio.path event=check.format ... exclusive=1 dsp_active=0 format_matches_source=1 bit_perfect=1
ok   an exclusive bit-perfect request produced a bit-perfect path
ok   the engine flag agrees with the derived state
```

**判读表**：

| 你看到的 | 含义 |
| --- | --- |
| `exclusive=1 dsp_active=0 format_matches_source=1` | 端点接受了源格式的独占会话——这是 bit-perfect 的前提 |
| `format_matches_source=0`，`output=` 采样率与源的 `44100` 不同 | 端点只支持它的混音格式（很常见：48 kHz）。换一个支持 44.1 kHz 独占的端点，或用 48 kHz 素材 |
| `open: refused` + 错误文本 | 端点拒绝独占（被别的程序占用），或拒绝该格式 |
| `exclusive=1` 但 `dsp_active=1` | 会话不是直通路径（共享模式或被协商成 float），说明 bit-perfect 条件之一不满足 |

> 注意：`bit_perfect=1` 只说明**端点接受了精确格式且引擎没有处理**。它不证明 DAC 收到的位与文件
> 完全一致——那需要下面第 6 节的测量。

---

## 3. 拔掉 DAC：降级必须可见

播放中用一首曲目，然后物理拔掉 USB DAC。

**预期**：
1. 播放停止，播放器出现错误提示（设备丢失）；
2. 高保真设置和诊断日志保留本次会话的引擎状态与失败原因；播放器底部不再显示常驻路径标识；
3. 日志里有 `audio.path event=metrics` 或设备丢失事件。

**要确认的**：设备错误会停止播放并保留失败记录。重新打开输出后需检查实际会话格式，
不能仅凭设置开关推断音频路径已恢复。

---

## 4. DSP 链：启用任意模块，bit-perfect 必须熄灭

1. 设置 → 高保真播放：打开 **Bit-perfect**（需同时开独占）；
2. 播放一首与端点格式一致的曲目，确认「信号路径」面板 `Bit-perfect = 是（独占 · 无 DSP · 格式一致）`；
3. 打开 **均衡器**（随便拉一个频段）；
4. 回到「信号路径」：`Bit-perfect` 应变为 `否（…）`，`DSP` 行变为「在信号路径中」；
5. 日志应出现 `audio.path event=format ... dsp_active=1 ... bit_perfect=0`。

同时页面应显示提示：**「Bit-perfect 已开启：均衡器 / 限幅器 / 耳机串扰不会进入信号路径」**——
这是刻意的：bit-perfect 期间引擎拒绝处理请求，DSP 设置被保留但不在路径中。

**听感检查**（可选）：关闭 bit-perfect 后同样的均衡器设置应立刻可闻；开启后应恢复原声。

---

## 5. 卷积（FIR）：目前**应用里没有入口**，只能用探针驱动

卷积是实现好了但**故意不发布**的能力（无设置、无默认 IR、无 UI）。要验证它在真机上跑得动：

```powershell
# 用内置的合成 IR（64 taps 的衰减回声，明显不是原声）
cd $env:TEMP
& ...\native-path-check.exe --play --convolver

# 或用你自己的 IR（WAV：16/24/32-bit PCM 或 32-bit float）
& ...\native-path-check.exe --play --convolver D:\ir\hd650.wav
```

**预期**：

```
audio.path event=check.convolver taps=64 channels=2 status=0 error=-
ok   the convolver accepted the impulse response
ok   the convolver is in the signal path
ok   the path no longer claims bit-perfect
ok   the engine agrees with the derived verdict
```

**要听/要看**：
- 声音应带上明显的回声（合成 IR）或耳机校正的变化（你的 IR）；
- 播放不应断音、不应爆音。**如果爆音或断音，请记录 CPU 型号与 IR 长度**——当前实现是直接型 FIR，
  4096 taps 以内约 0.4 GFLOP/s（44.1 kHz 立体声），更长 IR 会明显吃 CPU。
- **单声道 IR 在立体声会话上会被拒绝**（`status != 0`），这是刻意的：不悄悄混声道。请用立体声 IR。

---

## 6. DSD / DoP

需要：DSD 源文件（DFF/DSF）**和**支持 DoP 的 DAC。

**预期**（设置 → DSD 输出 = `DoP` 或 `auto`）：

```
audio.path event=format codec=dsd_lsbf_planar source=DSD64x output=DoP @ 176400 Hz
                       exclusive=1 dsp_active=0 format_matches_source=1 bit_perfect=1
```

**要确认的**：
1. DAC 自己的面板/指示灯显示 **DSD**（不是 PCM 176.4 kHz）——这是唯一能证明 DoP 被正确解包的证据；
2. 「信号路径」面板 `格式选择 = DoP 载波`，`Bit-perfect = 是`；
3. 若 DAC 只显示 PCM，说明它不解 DoP，此时引擎仍会按载波发送——请在报告里注明 DAC 型号。

> 原生 DSD（ALSA `DSD_U8/U16/U32`）只在 Linux 上存在，Windows 走 DoP。

---

## 7. 到底怎样才算"验证了 bit-perfect"

按可信度从高到低：

1. **数字输出到录音设备**：S/PDIF / USB → 数字录音机或另一台电脑的 USB 输入，录下来的位流与 WAV
   逐字节比对（用 Audacity 的导入原始数据或 `sox --bits`）。这是唯一严格证明。
2. **DAC 自带指示**：显示 "44.1 kHz / 无处理" 或 "Direct"。只能证明"收到什么格式"，不能证明位内容。
3. **模拟回环**（DAC 输出 → ADC 输入）：**不能**证明逐 bit；ADC 自身的噪声/增益就会改变样本。只能
   用来听感与通道/相位检查。

请在你的报告里注明用的是哪一种。

---

## 8. 报告模板

把下面这段填好贴回 issue/PR 即可：

```
设备：<DAC 型号 / 驱动版本 / 固件>
平台：Windows <版本>，端点：<WASAPI 名称>
端点混音格式：<例如 48 kHz / 32-bit float>
测试项：
[ ] 1 默认路径            → 结果：
[ ] 2 独占 bit-perfect    → 结果：（贴 audio.path event=check.format 那一行）
[ ] 3 拔 DAC 降级         → 结果：（播放器错误、引擎设置和日志）
[ ] 4 打开 EQ 后熄灭       → 结果：（面板 Bit-perfect 行）
[ ] 5 卷积 64 taps         → 结果：（贴 check.convolver 行；有无爆音/断音）
[ ] 6 DSD/DoP              → 结果：（DAC 显示 DSD 还是 PCM）
测量方式：<数字录波 / DAC 指示 / 模拟回环 / 仅听感>
异常现象与复现步骤：
```

---

## 9. 已知的"不是 bug"

| 现象 | 原因 |
| --- | --- |
| 默认端点总是 48 kHz/32-bit float，bit-perfect 永远 `否` | 端点混音格式被系统设为 48 kHz。要么改系统格式，要么用支持源格式的独占端点 |
| 打开 Bit-perfect 后 EQ 面板提示"不会进入信号路径" | 引擎拒绝在 bit-perfect 会话里处理；设置被保留，关闭后生效 |
| 卷积在应用里找不到入口 | 刻意不发布（见第 5 节），只有探针能驱动 |
| 设置或日志显示系统音频引擎 | 原生引擎没打进包 / ABI 不匹配 / 用户选择了系统引擎；日志保留具体原因 |
| 拔 DAC 后不能自动切回 just_audio | 当前设计是上报并停播，热切换未实现（见 `docs/audio-engine-status.md` 第 12.2 节） |

---

## 10. 已经离线证明、不需要你重复验证的部分

`ctest --test-dir build/native-probes -C Release`（需 `-DLAZER_AUDIO_NATIVE_PROBES=ON` 配置）：

| 探针 | 证明什么 |
| --- | --- |
| `lazer-audio-engine-bit-perfect` | 引擎写出的字节 == 源 PCM 字节；DSP 介入即失效；格式不匹配即失效；bit-perfect 下 DSP 请求被拒 |
| `lazer-audio-dsp-order` | 链顺序真的改变输出（限幅在 EQ 前后差 8172/8192 样本）、旁路生效 |
| `lazer-audio-convolver` | 单位冲激恒等、两点响应与直接卷积逐样本一致、声道不符/超长被拒、旁路清历史 |
| `lazer-audio-ring-stress` | 40 秒素材 0 欠载；注入 800 ms 停顿产生有界且可解释的欠载 |
| `lazer-audio-engine-dop` / `-native-dsd` | DSD 路径按新语义上报三事实 |

这些用假端点，所以**不需要设备**；你的价值在于验证它们的前提在真实端点上成立。

---

## 11. iOS（新增，全部待在真机上验证）

macOS 和 iOS 目前不在范围内，本节保留为技术记录，等有设备时再按此验证。

iOS 的引擎是**静态链接**进 `Runner` 二进制的（`liblazer-audio.a` + reader bridge + 四个 FFmpeg 静态库），
后端是新写的 RemoteIO（`native/lazer-audio/src/output_remoteio.cpp`），会话由 `AVAudioSession` 承担。
CI 能证明的只有：两套契约（AAudio / RemoteIO）在假实现上通过、arm64 静态库导出 18 个 ABI 符号、
`Runner` 的可执行文件导出表里有这些符号且没有多余动态库依赖。**以下每一项都还没有在设备上跑过。**

装机前提：未签名 IPA 需自行签名（Sideloadly / AltStore / 自有证书）。装好后先看
设置 → 高保真播放 → 播放引擎，以及诊断日志：应当显示原生引擎。
若走系统引擎，日志会保留原因（符号找不到 / ABI 不符 / 会话启动失败）。

此前 CI 已经证明、不必重复的部分（当时在 macOS 上运行的两个 Apple 任务，现已随 Apple 目标一并删除）：
六个 arm64 静态归档同一次构建产出；`Runner` 可执行文件的**动态导出表**里有引擎的 18 个
ABI 符号与 reader bridge 的全部 10 个导出（`dyld_info -exports`，读的是动态加载器真正用的导出
trie，不是被 strip 的符号表），包内没有 FFmpeg 动态库。也就是说 `DynamicLibrary.process()`
在设备上**应当**能解析到引擎；剩下要验证的是解析到之后，声音有没有正确地送出去。

| 检查项 | 怎么做 | 预期 |
| --- | --- | --- |
| 是否真的出声、音高与声道正确 | 播 1 kHz 正弦（或任意立体声曲子） | 无爆音、无变调、左右声道不串 |
| 44.1 kHz 源在 48 kHz 路由上 | 播一首 44.1 kHz 无损，检查设置里的会话格式，再切换路由 | 首次打开使用路由授予的速率；播放中换路由保留已有客户端 PCM 时钟，由 AudioUnit 适配新硬件速率，避免把已排队音频按错误速率播放 |
| 路由变化 | 播放中拔插耳机、切蓝牙 A2DP、切 AirPlay | 不中断崩溃；必要时自动重开会话；速度/音高正常 |
| 中断 | 来电、Siri、闹钟、其它 App 抢占 | 暂停并上报；回来后**不自动从错误位置续播** |
| 后台与锁屏 | 锁屏、切后台、控制中心操作 | 继续播放，控制中心的进度/歌词跟随 |
| 无缝切歌与拖动 | 连续切歌、长按进度条拖动、暂停/恢复 | 无卡顿爆音；无欠载累积 |
| 能力文案 | 设置里看独占 / 位完美 / DSD | 必须显示**不可用**（iOS 没有独占与直通 DSD） |
| 长时稳定性 | 连续播放 ≥ 1 小时，观察发热与欠载 | 无逐渐恶化的爆音；内存不增长 |

已知限制（不是缺陷，是平台事实）：iOS 声音始终经过系统混音；`preferredSampleRate` 只是请求，
路由可以拒绝；蓝牙/AirPlay 会引入额外延迟与重编码。

### 自动验证与真机边界

2026-11-01 至 2026-11-02 的补充检查覆盖了真实旧 ABI 24 库的拒绝与新 ABI 29 库的自动选择、
Windows 原生输出播放、reader bridge 的完整导出门禁，以及 RemoteIO 的离线契约。
新增契约模拟 44.1↔48 kHz 路由、系统停止 AudioUnit、中断结束、耳机移除、
媒体服务丢失/重置和暂时恢复失败，检查 PCM 队列保留、恢复许可、无重建循环以及实时回调
不做会话恢复。Dart 层另验证输出打开前的会话配置、重复中断和替换歌曲后不误恢复。
Objective-C 会话观察器仍需要 macOS/iOS 构建与设备运行验证。
这些结果不能代替上表中的 iPhone 听音、物理路由切换、来电/Siri、后台锁屏和一小时热稳定性。
当前没有可访问的 Mac/iPhone，以上真机项目继续保持未验证；不能据此宣称其已经通过。

### BGA 真实曲库验证

显式运行 `flutter test --no-pub tool/validation/bga_catalog_test.dart` 会从网易云真实歌曲接口
读取 6 首歌的封面，通过应用的实际解码、磁盘缓存和背景绘制路径，检查播放器与浏览页的颜色，
再检查缓存命中和快速切歌。该检查需要网络，未放进要求可离线重现的常规单元测试。

2026-11-02 记录：冷缓存请求 6 次、缓存命中额外请求 0 次、生成 6 个封面缓存文件；
其中 3 首逐首比较的背景像素摘要互不相同，另 3 首在首次加载时插入不同网络延迟并快速切换，
等待迟到的封面解码全部结束后，最终颜色仍与最后一首一致。
本机报告位于 `build/reports/bga-real-catalog.json`。这证明了本次运行的真实封面缓存时序，
不代表所有 CDN、账号和网络状况；断网、延迟和过期回写另由可重复的自动测试覆盖。
