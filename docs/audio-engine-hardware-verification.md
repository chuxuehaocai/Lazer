# 硬件验证交接（给拿到设备的人）

这份文档写给**手上真有 DAC / DSD 播放环境的人**。引擎里能离线证明的部分已经在探针里证明了；
这里只列**必须有硬件才能回答**的问题，以及每一步的预期输出与判读方法。

现状一句话：**默认路径、逐 bit 判定、实时线程、DSP 链都已落地并有离线证据；缺的是"某台真实设备
上这些结论是否成立"，包括 DSP 与 DSD 的物理层。**

---

## 0. 先决条件

| 项目 | 要求 |
| --- | --- |
| 分支 | `phase-5b/convolver-stage`（当前功能最全；`nextgen` 目前只有阶段 0） |
| 构建 | 必须能找到 DSD-capable FFmpeg：设置 `LAZER_FFMPEG_ROOT`，或把 SDK 放在 `third_party/ffmpeg` |
| 引擎版本 | 源码与 Dart 镜像同为 **ABI 29**。构建会同时重编引擎；**不要**直接跑旧的 `build/` 产物 |
| 平台 | Windows 已验证构建；Linux / macOS 的构建链路在 CI 里，但播放行为未验证 |

构建（PowerShell）：

```powershell
$env:LAZER_FFMPEG_ROOT='D:\path\to\ffmpeg'
flutter build windows --release --no-pub
```

产物目录里应出现 `lazer-audio.dll` 与 `lazer-audio-bridge.dll`。没有就说明 FFmpeg 前缀没找到，
应用会（可见地）回退到 `just_audio`。

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
2. 播放器上出现常驻标识 **「非 HiFi 路径 · 音频引擎已中断：…（当前非 HiFi 路径）」**；
3. 日志里有 `audio.path event=metrics` 或设备丢失事件。

**要确认的**：这个标识不会在恢复后自己消失（本次会话内保持"非 HiFi"），重启应用后如果引擎能起来
则恢复正常。

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
[ ] 3 拔 DAC 降级         → 结果：（是否出现「非 HiFi 路径」标识）
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
| 播放器启动时出现"非 HiFi 路径"提示 | 引擎没打进包 / ABI 不匹配 / 用户选择了系统引擎。提示里带具体原因 |
| 拔 DAC 后不能自动切回 just_audio | 当前设计是"上报 + 停播 + 常驻标识"，热切换未实现（见 `docs/audio-engine-status.md` 第 12.2 节） |

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
