# HiFi 多平台验收与后端重构交接手册

**交接时间：** 2026-11-19（Asia/Shanghai）  
**仓库：** `D:\Lazer\Lazer`  
**工作分支：** `codex/hifi-multiplatform-acceptance-20261119`  
**目标上游：** `origin/nextgen`  
**当前状态：** **PAUSED。除非用户明确要求恢复，否则不要继续修改代码、运行长测试、提交、推送、创建 PR 或合并。**

## 0. 一句话交接

这条分支已经有一个针对原生库导入失败的修复和三次上游同步提交，但本轮 HiFi 验收、竞态修复、三轮审计、后端重构、PR 和 CI/合并都还没有完成。工作区还有 11 个未验证的 WIP 文件，不能把当前工作区当作可合并成果。

当前最重要的未解决问题是 **native queue reader 的准备线程生命周期**：准备线程可能在 `queue_reader` 返回后仍在使用 reader，而 Dart 侧已经允许释放它。必须先解决这个所有权问题，再继续任何验收或重构。

---

## 1. 目标与完成定义

用户要求的总目标是：验收除 iOS、macOS 以外所有平台上的 HiFi 能力；修复验收中发现的问题；完成三轮审计；随后对后端能力做优化重构；最后提交中文 PR，持续跟随 `origin/nextgen`，在本地和 CI 全绿后合并。

本任务的验收范围：

- Windows
- Linux
- Android
- Web

明确排除：

- iOS
- macOS

“完成”必须同时满足以下条件，不能只看单项测试通过：

1. 每个平台区分“软件构建/测试证据”和“真实硬件证据”，并写清边界。
2. Windows 至少用当前分支产物和真实音频端点生成可复核的 HiFi 验收报告。
3. 发现的问题有复现步骤、根因、修复和回归测试。
4. 完成三轮审计，审计记录使用中文，包含发现、证据、修复和残余风险。
5. 后端代次模型和 preparation 生命周期完成收敛；不得借重构顺手改无关功能。
6. 提交信息、PR 描述和审计记录使用中文；PR 包含验收边界、测试结果和未验证项。
7. `origin/nextgen` 的最新提交已合并；无已知问题；必要 CI 全绿后才合并。

当前距离上述完成条件还很远，不能宣称硬件验收通过或 CI 全绿。

---

## 2. 当前 Git 快照

以下只是交接时的快照。恢复工作前必须重新执行 `git fetch` 并重新核对，不能把旧快照当成实时状态。

| 项目 | 值 |
| --- | --- |
| 分支 | `codex/hifi-multiplatform-acceptance-20261119` |
| HEAD | `99c19bc9e66ca799227db8973a6ec79b87fb0102` |
| 上游 | `origin/nextgen` |
| 上游快照 | `5143381b201c292385722a1b2eb1a4415237b476` |
| 相对上游 | `ahead 4 / behind 0` |
| 工作区 | 11 个已修改文件，约 `+997/-163`，全部未提交、未验证 |
| PR | 尚未创建 |
| CI | 尚未基于本分支最终产物完成验证 |
| 合并 | 尚未进行 |
| 硬件验收 | 尚未形成当前分支的真实设备日志 |

领先上游的提交中，只有一个非合并提交：

- `d67de01 fix(audio): fall back from unusable engine imports`

另外三个是同步 `origin/nextgen` 的合并提交。它们不代表 HiFi 功能已经完成。

### 恢复前的第一条命令

```powershell
git status --short --branch
git log --oneline --decorate -10
git rev-parse HEAD
git rev-parse origin/nextgen
```

若上游已经前进：

```powershell
git fetch origin nextgen
git merge origin/nextgen
```

合并冲突必须逐项分析后手工解决，保留本轮 WIP 与上游改动，禁止用回滚、重置或清理命令“解决”冲突。

---

## 3. 工作区 WIP 清单

下面 11 个文件目前都是未验证 WIP。恢复时先读完整 diff，不要直接 `git add -A`，也不要把它们当成已经正确的实现。

| 文件 | 作用 | 交接注意事项 |
| --- | --- | --- |
| `integration_test/windows_native_engine_test.dart` | Windows 原生引擎集成测试 | 需要确认是否能在当前 Windows/FFmpeg/音频端点环境复现；不能只编译通过就当作硬件验收 |
| `lib/audio/hifi_controller_io.dart` | HiFi 设置应用、引擎协商与结果回传 | 检查错误路径是否会把设备的拒绝静默降级；与 ABI/Dart 状态机保持一致 |
| `lib/audio/native/lazer_audio_engine.dart` | native 引擎主状态机、代次和 reader 所有权 | **最高风险文件**；当前代次语义和 reader 释放仍有已知缺陷，不能直接沿用 |
| `lib/audio/native/lazer_audio_library_io.dart` | FFI 库加载、导出解析和调用绑定 | 当前 WIP 改动较大；ABI 31 新导出尚未同步完整，需要逐段审查 |
| `lib/state/hifi_settings.dart` | HiFi 设置模型 | 检查默认值、持久化迁移、无效值处理和 bit-perfect 约束 |
| `lib/widgets/hifi_settings_section_io.dart` | HiFi 设置 UI | 验证 UI 显示的是实际信号路径，不是仅凭开关推断 |
| `native/lazer-audio/src/engine.cpp` | native 队列、reader、退休和输出会话 | 目前存在准备线程与 stop/open/clear 的并发竞态；需要准备屏障 |
| `native/lazer-audio/src/engine.h` | native 引擎状态声明 | WIP 已有内部 `clearQueuedReaderEx` 和代次字段，但公共 ABI 还没有配套 |
| `test/hifi_dsp_replay_test.dart` | DSP/播放路径回归 | 需要确认测试覆盖的是实际路径，而不只是 mock 状态 |
| `test/native_audio_paths_test.dart` | native 路径和加载选择测试 | 需要扩展到 ABI 31、导出缺失、旧库拒绝和平台回退 |
| `test/native_queue_lifecycle_test.dart` | 队列 reader 生命周期契约 | 当前 fake 把 `lazerAudioErrorState` 当成“可安全释放”，语义错误；必须重写 |

### 当前 WIP 的已知不一致

- 公共头文件仍是 **ABI 30**：`native/lazer-audio/include/lazer_audio_api.h:35`。
- `engine.h` / `engine.cpp` 已出现内部精确清理方法，但 `lazer_audio_api.h`、`api.cpp`、Web/Android 导出、Dart FFI、worker 和镜像测试尚未同步。
- 这类“内部实现了、外部契约没实现”的状态不能提交，也不能用局部编译成功证明兼容性。

### WIP 审查方法

```powershell
git diff --check
git diff --stat
git diff -- <单个文件>
```

按以下顺序审查：

1. 先看 native `engine.h` / `engine.cpp` 的生命周期改动。
2. 再看 `lazer_audio_engine.dart` 的代次、reader 归属和错误处理。
3. 最后看设置、UI、测试和 Windows integration test。
4. 对每个修改标注“保留”“重写”“删除”“待验证”；不要为了减少 diff 而保留语义错误的代码。

---

## 4. 已确认的事实与验收边界

### 4.1 不能用旧记录替代当前证据

- `docs/hifi-acceptance-2026-11-18.md` 记录的是历史快照和当时的 APK/测试结果。
- 历史 Windows NICEHCK 记录不能继承为当前分支、当前 DLL 或当前 DAC 的证据。
- 历史上 Android 验收时没有 ADB 设备，`hardwareTested=false`；不能写成“Android 硬件通过”。
- 当前仓库没有本轮真实 DAC/HiFi 耳机验收报告，不能因为机器上接了耳机就宣称硬件验收完成。
- 音频引擎、ABI、FFmpeg 版本或构建产物变化后，必须重新生成证据。

### 4.2 平台证据边界

| 平台 | 当前可做的证据 | 不能宣称的内容 |
| --- | --- | --- |
| Windows | 当前分支 release 构建、原生探针、bundle 检查、WASAPI 端点验收、真实 DAC 手工矩阵 | 仅凭 `bit_perfect_active` 不能证明 DAC 收到的位流逐位一致 |
| Linux | CI/本机构建、离线探针、导出检查和静态分析 | 没有真实 ALSA/DSD 设备时不能写“硬件通过”；不能把 Windows 探针结果外推 |
| Android | CI 构建、APK 导出/对齐/依赖检查、Kotlin 契约、设备无关回归 | 没有 ADB/USB DAC 时只能写 `hardwareTested=false`；不能宣称真实 UAC2/DoP/bit-perfect |
| Web | Web 构建、静态检查、降级/加载路径验证 | Web 没有可用的 native FFI 引擎时不能把普通 Web 播放当作 HiFi 直通 |

### 4.3 Windows 合成验收工具的能力边界

`tool/dac_acceptance.dart` 只支持 Windows WASAPI，测试 44.1/48/88.2/96/176.4/192/352.8/384 kHz、16/24/32 位立体声。每个夹具约 4 秒、997 Hz、−80 dBFS 整数 PCM，检查：

- 进度是否推进；
- 是否为零欠载；
- 输出是否为整数 PCM；
- 源采样率/有效位数是否一致；
- 引擎与派生 bit-perfect 判定是否一致。

它不代表模拟音质，也不严格证明数字位流完全一致。数字透明度应有外部数字录音或等效测量；模拟回环不能证明逐位一致。

---

## 5. 已知关键缺陷

以下问题必须在继续验收和重构前处理。行号是交接时工作区的大致位置，代码变化后应重新定位。

### 5.1 Native 准备线程与 reader 生命周期

1. `QueueReader` 路径释放 `lifecycleMutex_` 后执行阻塞的 `openReader()`。当前 `stop`、`open`、`retire` 和 `clear` 主要只是 cancel，没有等待准备线程真正退出。
2. 因此存在以下窗口：
   - native 的 `queue_reader` 已返回；
   - Dart 认为 reader 可以释放；
   - 准备线程仍在调用 reader/context；
   - 产生 use-after-free、double close 或设备/源状态错乱。
3. `Engine::open()` 在主源准备期间释放 `lifecycleMutex_`。并发 `stop`/`open` 可能提前退休当前 source；重新加锁后必须校验 `sessionGeneration_`，否则旧准备会发布到新会话。
4. `clearQueuedReader()` 当前委托给 `clearQueuedReaderEx()`，破坏旧 API 语义。旧实现应从基线恢复并独立保留，不能顺手改变已有调用方的行为。
5. `pendingTrackChangedQueueGeneration_` 只有写入没有读取，是冗余状态；清理安装代次模型时删除。
6. 安装代次不应再额外保存一份模糊状态；应按 `source_`、`nextSource_` 和 `preparingSource_->queueGeneration` 精确匹配目标。
7. exact clear 对不存在的目标当前返回 `LazerAudioErrorState`，但设计要求是推进请求代次后返回 `Ok`。

### 5.2 Dart 代次与 reader 归属

重点文件：`lib/audio/native/lazer_audio_engine.dart`。

- `_queueGeneration` 同时承担“请求代次”和“资源代次”，语义混合。
- `_successorRequestGeneration` 没有和资源代次清晰分离。
- `_queuedSourceGeneration`、`_queuedQueueGeneration` 已声明，但成功路径没有写入，导致精确清理缺少绑定信息。
- `_settleSupersededReader()` 使用新申请的全局代次，而不是被淘汰 reader 自己的目标代次；可能清错目标。
- `_retainQueuedReader()` 先覆盖 `_queuedUrl`，随后才用新 URL 给旧 reader 建延迟退休记录；旧 reader 的归属会错。
- `_clearQueued()` 在 `_queuedReader == null` 时完全跳过 native clear，无法取消 worker 中正在准备的 reader。
- `test/native_queue_lifecycle_test.dart` 的 fake 把 `lazerAudioErrorState` 当作“安全释放”，会掩盖真实的所有权错误。

### 5.3 ABI 与导出一致性

当前公共 ABI 仍为 30。恢复后必须整体升级到 **ABI 31**，新增：

```c
int32_t LAZER_AUDIO_CALL lazer_audio_clear_queued_reader_ex(
    LazerAudioEngine engine,
    uint64_t target_queue_generation,
    uint64_t request_queue_generation,
    int32_t preserve_audible);
```

新增导出必须同步到所有契约面，不能只改 native 实现。

---

## 6. 已确定的设计决策

这一节是恢复工作时的约束，不要在没有新证据的情况下重新发明另一套语义。

### 6.1 ABI 31

将 `LAZER_AUDIO_ABI_VERSION` 从 30 升到 31，并把新函数追加到 ABI 末尾，保持已有函数、结构布局和返回值定义不变。ABI 版本升级是语义变化，不是可选优化。

### 6.2 准备屏障

在 `SourceSlot` 增加准备屏障，建议字段：

```cpp
std::mutex preparationMutex;
std::condition_variable preparationChanged;
bool preparationInFlight = false;
bool preparationCancelRequested = false;
```

不变量：

- 准备结束必须先清除 in-flight 并 `notify_all()`，之后才允许关闭 reader/source。
- `stop`、`open`、`retire`、exact clear 和 destroy 必须 cancel + wait。
- 等待期间不能持有 `lifecycleMutex_` 或 `sourceMutex_`。
- exact clear 返回 `Ok` 时，reader 必须已经没有 native 回调；Dart 才能释放。
- 取消不能只唤醒读操作，还要保证准备线程不会在返回后再发布 source。

### 6.3 Exact clear 语义

固定如下：

1. `requestGeneration <= queueRequestGeneration_`：返回 `LazerAudioErrorState`，不碰 reader，不推进代次。
2. 目标代次不存在：推进请求代次并返回 `LazerAudioOk`。
3. 目标是 preparing：取消并等待 `openReader()` 完整退出，阻止发布；reader 关闭完成后再返回 `Ok`。
4. 目标是 installed：
   - `preserveAudible && overlapStarted`：返回 `LazerAudioQueueAlreadyAudible`。
   - 否则取消 overlap gain、退休、join/close，返回 `LazerAudioOk`。
5. 目标是 active：返回 `LazerAudioQueueAlreadyActive`；返回前等待 `sourceRetirementPending_` 完成。
6. 绝不能清理比目标更新的后继源。
7. 请求通过 stale 检查后即推进请求代次，包括返回 `AlreadyActive`/`AlreadyAudible`；stale 请求不推进。

旧 `clearQueuedReader` 的语义必须独立保留：旧接口不能因为新 exact clear 的存在而改变，也不能误清新后继。

### 6.4 Dart 结果映射

| native 结果 | Dart 动作 |
| --- | --- |
| `LazerAudioOk` | 确认 native 已无回调，释放 reader |
| `LazerAudioQueueAlreadyActive` | 接管为 active；native 已等待退休完成 |
| `LazerAudioQueueAlreadyAudible` | 保留 reader，更新精确绑定，不释放 |
| `LazerAudioErrorState` | 请求过期或不可清理；不能释放，保留并等待后续 stop/open/transition 确认 |

Dart 必须分别跟踪：

- source generation；
- queue request generation；
- queue resource generation；
- “已提交 worker、尚未回包或尚未写入 `_queuedReader`”的 reader 及其目标代次。

陈旧或已提交 reader 只有在 exact clear 返回可释放结果，或 stop/open/destroy 已确认 native 放弃它之后才能释放。

### 6.5 清理与销毁

- 不允许为了“让测试通过”而提前释放 reader。
- `_clearQueued()` 即使 `_queuedReader == null` 也必须考虑 worker 中尚未回包的准备请求。
- destroy/stop 必须覆盖正在准备、已安装、已可听和已接管四种状态。
- 任何 native handle 关闭前都要有一次串行化的确认路径。

---

## 7. ABI 31 同步清单

恢复实现时至少检查以下契约面。缺一项都可能导致“本机通过、打包后拒绝”或 CI 只在某个平台失败。

### Native

- `native/lazer-audio/include/lazer_audio_api.h`
- `native/lazer-audio/src/api.cpp`
- `native/lazer-audio/src/engine.h`
- `native/lazer-audio/src/engine.cpp`
- `native/lazer-audio/src/exports_android.map`
- Android 打包/导出检查脚本
- `ci/verify-ios-audio.py` 的 `ABI_SYMBOLS`（即使 iOS 不在功能验收范围，导出镜像仍需保持契约一致）
- `ci/verify-android-audio.py`

### Dart

- `lib/audio/native/lazer_audio_abi.dart`
- `lib/audio/native/lazer_audio_library_io.dart`
- `lib/audio/native/lazer_audio_worker.dart`
- `lib/audio/native/lazer_audio_engine.dart`
- `test/native_audio_loader_test.dart`
- `test/native_audio_paths_test.dart`
- `test/native_queue_lifecycle_test.dart`
- 若仓库存在 ABI 镜像测试，也要同步

### 文档和探针

- `docs/audio-engine.md`
- `docs/audio-engine-status.md`
- `docs/audio-engine-hardware-verification.md`
- `native/lazer-audio/tools/lazer_audio_engine_gapless_probe.cpp`
- 相关 CTest 注册、探针期望和 ABI 版本说明

### 导出确认

```powershell
dumpbin /exports build\windows\x64\runner\Release\lazer-audio.dll |
  Select-String lazer_audio_clear_queued_reader_ex
```

同时检查 Android 导出映射和 iOS 校验脚本中的符号列表；不能只检查 Windows DLL。

---

## 8. 恢复后的执行顺序

### 第一步：冻结当前状态

1. 获取用户恢复授权。
2. `git fetch origin nextgen`，必要时合并上游。
3. 记录 `git status --short --branch`、`git diff --stat`、HEAD 和上游哈希。
4. 完整读一遍 11 个 WIP 文件的 diff。
5. 保留合理的 HiFi 设置、Windows 集成测试和已有修复；删除无关改动。

### 第二步：完成 native 修复

1. 实现 ABI 31、公共头文件、`api.cpp` 和 Android 导出。
2. 在 `SourceSlot` 加入 preparation barrier。
3. 修复 `Engine::open()` 的 `sessionGeneration_` 复核。
4. 恢复独立旧 `clearQueuedReader`。
5. 重写 `clearQueuedReaderEx`，严格实现第 6.3 节语义。
6. 删除 `pendingTrackChangedQueueGeneration_`，收敛安装代次模型。
7. 保证所有 wait 都在相关互斥量之外执行。

### 第三步：同步 Dart

1. ABI 30 → 31，补齐 FFI 函数签名和 worker op 14。
2. 补齐 loader、`requiredEngineSymbols`、路径测试和 ABI 镜像测试。
3. 将 source/request/resource generation 分离。
4. 修复延迟回包、URL 绑定、精确清理和 destroy/stop 释放路径。
5. 把 `ErrorState` 从“可释放”改为“保留并等待确认”。

### 第四步：重写队列生命周期测试

`test/native_queue_lifecycle_test.dart` 至少覆盖：

- stale 请求；
- 目标不存在；
- preparing 阻塞清理；
- 旧 API 不清理新后继；
- `AlreadyActive`；
- `AlreadyAudible`；
- `Ok` 返回之前 reader 仍被持有；
- 请求代次推进；
- `ErrorState` 不释放；
- worker 延迟回包；
- stop/open 并发；
- destroy 时仍在准备的 reader。

测试 fake 不能再用 `lazerAudioErrorState` 表示“可以安全释放”。

### 第五步：扩展 native 探针

`native/lazer-audio/tools/lazer_audio_engine_gapless_probe.cpp` 至少加入：

- 阻塞准备；
- stop/open 并发；
- exact clear；
- reader close 顺序和 close 之后是否还有回调；
- active/audible/已消失目标的返回值；
- 清理请求代次推进。

探针应使用可控阻塞，而不是依赖真实网络时序。

### 第六步：更新文档

所有文档中的 ABI 版本、导出列表、测试数量和“已验证”边界必须与当前产物一致。历史记录保留日期和范围，不可改写成当前通过。

### 第七步：验证

先跑与修改最相关的测试，再扩大范围：

```powershell
dart format <修改的 Dart 文件>
flutter analyze --no-pub
flutter test --no-pub test/native_queue_lifecycle_test.dart test/native_audio_paths_test.dart test/native_audio_loader_test.dart
flutter test --no-pub
```

再跑 native 和集成检查：

```powershell
$env:LAZER_FFMPEG_ROOT = '<FFmpeg 路径>'
flutter build windows --release --no-pub

cmake -S native -B build/native-probes -DLAZER_FFMPEG_ROOT="$env:LAZER_FFMPEG_ROOT" -DLAZER_AUDIO_NATIVE_PROBES=ON
cmake --build build/native-probes --config Release
ctest --test-dir build/native-probes -C Release --output-on-failure
```

可选检查：

```powershell
dart tool/native_abi_check.dart
dart tool/native_engine_check.dart
dart tool/native_cache_check.dart
dart tool/native_hifi_check.dart
flutter test test/audio/
flutter build web --release --no-pub
```

如果仓库脚本需要 Python，请使用当前仓库/CI 支持的 Windows Python 调用方式；不要使用 WSL。当前环境 WSL 不可用。

---

## 9. Windows 真实 DAC 验收

### 9.1 自动化夹具

使用当前分支刚构建的 DLL，不要复用旧 `build/` 产物：

```powershell
$env:LAZER_AUDIO_LIBRARY = (Resolve-Path build/windows/x64/runner/Release/lazer-audio.dll).Path
$env:LAZER_AUDIO_BRIDGE_LIBRARY = (Resolve-Path build/windows/x64/runner/Release/lazer-audio-bridge.dll).Path
dart tool/dac_acceptance.dart --device "<实际端点匹配文本>" --output build/reports/dac-current.json
```

报告必须保留：

- `engineBuild`；
- 设备端点名称；
- 接受/拒绝的格式；
- `completed`、`testedFormats`、`failures`；
- 每项播放的进度、欠载、格式和 bit-perfect 判定。

若枚举或加载阶段失败，也要保存终端错误、退出码和当时的 DLL 哈希。

### 9.2 Windows 手工矩阵

至少覆盖：

- 独占模式；
- 源采样率切换；
- bit-perfect、无 DSP、格式一致三项同时成立；
- 信号路径/格式遥测；
- Gapless A→B 衔接；
- AutoMix；
- 暂停/恢复；
- seek；
- 设备断开和重新打开；
- 支持时测试 DSD/DoP；
- 低幅度素材和物理音量安全。

每项记录：

- 产物 hash、应用版本、引擎 ABI；
- DAC 型号、驱动、固件；
- WASAPI 端点名和端点格式；
- 测试文件 hash；
- 实际信号路径/格式；
- 通过、失败或未支持；
- 失败时的复现步骤、日志和截图。

耳机连接本身不等于 DAC/端点验收；必须确认音频实际经过哪个端点。

---

## 10. Linux、Android、Web 的验收策略

### Linux

优先收集：

- CI 构建结果；
- native probe/CTest；
- ELF 导出和依赖；
- Flutter 测试和静态分析；
- 若有条件，再补真实 ALSA/独占/DSD 设备记录。

没有真实设备时，报告明确写 `hardwareTested=false`，不要把 Windows 结果当作 Linux 结果。

### Android

- 记录 APK 路径、大小、SHA-256、版本、ABI、签名和导出检查结果。
- 按 `docs/android-audio.md` 和 `docs/hifi-acceptance-2026-11-18.md` 中的矩阵执行。
- 有 ADB 设备时再验证 USB 权限、UAC2、采样率/位深、拔插、后台/焦点和长时资源。
- 无设备时明确写 `hardwareTested=false`。
- 不要把历史 APK 的测试结果复制到当前 APK。

APK 相关门禁示例：

```powershell
python ci/verify-android-audio.py --apk build/app/outputs/flutter-apk/app-release.apk
python ci/verify-package-contents.py build/app/outputs/flutter-apk/app-release.apk
```

### Web

- 验证 Web release 构建不因 native FFI/ABI 改动失败。
- 验证 native 库不可用时能明确回退，不出现启动崩溃。
- Web 的普通播放不能被报告成 native 独占、bit-perfect 或真实 DAC 直通。

---

## 11. 三轮审计

三轮审计要在修复和第一轮测试之后执行，不能只写“已审计”。

### 第一轮：native 所有权与并发

检查：

- 准备屏障的锁顺序；
- wait 是否持有 `lifecycleMutex_` 或 `sourceMutex_`；
- stop/open/retire/exact clear/destroy 是否完整等待；
- reader callback 是否可能晚于 `Ok`；
- active/installed/preparing 三态转换；
- 旧 API 是否仍保持原语义；
- 是否清理了更新的后继；
- `sessionGeneration_` 是否阻止旧准备发布。

输出格式：

| 发现 | 严重级别 | 证据 | 修复 | 回归测试 | 残余风险 |
| --- | --- | --- | --- | --- | --- |

### 第二轮：Dart 代次状态机

检查：

- source/request/resource generation 是否各司其职；
- worker 回包前、回包后、丢回包、延迟回包；
- `_queuedReader == null` 时的 clear；
- URL/entry/reader 是否绑定到同一目标；
- `Ok`/`AlreadyActive`/`AlreadyAudible`/`ErrorState` 四种返回值；
- stop/open/destroy 是否覆盖所有已提交 reader；
- 失败路径是否会重复释放或泄漏。

### 第三轮：平台、契约、测试与文档

检查：

- ABI 31 是否在头文件、Dart mirror、worker、loader、导出映射和 CI 中一致；
- Windows/Android/Web 构建和导出检查；
- iOS/macOS 是否只做必要的契约同步且没有改变产品范围；
- 真实硬件证据是否与软件证据分开；
- 文档是否还写着过期的 ABI 或“通过”；
- PR 是否误把历史结果当作当前结果；
- 测试是否覆盖失败路径，而不只是 happy path。

三轮审计完成后，才允许进入后端重构。

---

## 12. 后端优化重构范围

重构目标是把代次模型和 preparation 生命周期收敛，不是为了增加功能或改写播放架构。

建议原则：

1. 用一个不可变的“准备请求记录”同时携带 reader、URL、目标 source generation、目标 queue generation 和请求 generation。
2. reader 所有权只能通过明确的状态转移改变：`preparing → submitted → installed → active`，以及 `superseded/dropped`。
3. 清理动作必须指定目标 generation；没有目标就返回可解释的“无匹配”，而不是模糊清理。
4. wait/cancel 由 preparation barrier 负责；业务状态机只处理结果，不直接猜测 native 是否已经停止回调。
5. 旧 API 与新 exact API 分层，避免行为回归。
6. ABI 只做追加；不重排结构、不改已有常量。
7. 重构前后都要保留同一组生命周期测试和探针结果。

不在本次重构范围内：

- 无关 UI 改版；
- 无关播放器功能；
- iOS/macOS 新能力；
- 为“优化”而替换 FFmpeg、WASAPI 或既有输出后端；
- 删除没有完全理解的历史兼容路径。

---

## 13. Git、提交、PR 和合并

### 13.1 同步上游

每次 push/merge 前执行：

```powershell
git fetch origin nextgen
git merge origin/nextgen
git status --short --branch
```

若上游有新提交，继续同步后再重新验证。不要因为上游改动与本任务无关就跳过同步。

### 13.2 提交拆分

建议按以下逻辑拆分，而不是一个大提交：

1. native ABI 31 与 preparation lifecycle；
2. Dart 代次/reader 所有权；
3. 测试与探针；
4. 文档、验收记录和审计记录；
5. 必要的后端重构（独立提交，便于回滚）。

提交信息使用中文说明；可以保留现有风格的 `fix(audio):` 前缀。示例：

```text
fix(audio): 修复原生队列 reader 的准备期竞态
feat(audio): 增加 ABI 31 精确队列清理契约
test(audio): 覆盖延迟回包与 stop/open 并发
refactor(audio): 收敛队列代次与 reader 所有权
docs(audio): 记录多平台 HiFi 验收边界
```

禁止：

- `git reset`；
- `git checkout`；
- `git rebase`；
- `git clean`；
- 把生成物、测试临时文件或无关改动混入提交；
- 在用户未授权时创建新分支或改写历史。

### 13.3 PR 内容

PR 描述必须使用中文，至少包含：

1. **背景与目标**：平台范围，明确排除 iOS/macOS。
2. **修复内容**：native 竞态、ABI 31、Dart 代次、reader 所有权、设置/测试。
3. **验收证据**：Windows 真实端点报告；Linux/Android/Web 的软件证据和 `hardwareTested` 状态。
4. **三轮审计**：每轮发现、修复、测试和残余风险。
5. **后端重构**：为什么改、改了哪些不变量、如何避免回归。
6. **测试结果**：命令、通过数量、跳过项、失败项和日志路径。
7. **风险与回滚**：ABI、旧库、设备拒绝、未验证平台。
8. **明确未完成项**：不得隐藏没有硬件证据的部分。

如果 PR 描述把历史 APK、旧 Windows 记录或旧 ABI 结果当成当前分支证据，必须视为阻塞问题。

### 13.4 合并前门禁

- 当前分支已合并最新 `origin/nextgen`。
- 工作区干净，未提交 WIP 已处理。
- `flutter analyze --no-pub` 通过。
- 相关测试和全量 Flutter 测试通过。
- native 探针通过。
- Windows release 构建和导出检查通过。
- Web/Windows 构建无本改动引入的失败。
- Android 导出/包检查按可用环境通过。
- CI 必须的 job 全绿。
- PR 描述与实际结果一致。
- 没有未解释的已知问题。

全部满足后再合并。合并后再次拉取 `origin/nextgen`，确认最终分支状态和 CI 结果。

---

## 14. 交接时仍需用户提供或确认

恢复工作前，至少需要：

- 用户明确授权恢复任务。
- 当前 Windows DAC/耳机的实际端点名称或可匹配文本。
- 当前可用于验证的 FFmpeg/DSD-capable 路径。
- 如果要做 Android 真机验收，需要 ADB 设备、USB DAC、OTG 条件和安装权限。
- 如果要做 Linux 真机验收，需要对应主机/设备；否则明确只做软件证据。
- 对“硬件验收通过”的定义和可接受证据形式的确认。

没有这些条件时，可以继续软件修复和审计，但不能把未执行的硬件项宣称为通过。

---

## 15. 恢复工作检查表

### 开始前

- [ ] 取得用户恢复授权。
- [ ] 重新 fetch 并检查 `origin/nextgen`。
- [ ] 记录 HEAD、上游哈希和完整 WIP diff。
- [ ] 确认没有无关改动混入。
- [ ] 确认当前任务仍是 HiFi 多平台验收，而不是扩大范围。

### 实现中

- [ ] ABI 31 全部契约面同步。
- [ ] preparation barrier 完成。
- [ ] `Engine::open()` 会话代次复核完成。
- [ ] 旧 clear API 语义保持。
- [ ] exact clear 语义逐条覆盖。
- [ ] Dart 代次拆分为 source/request/resource。
- [ ] 延迟回包和 `_queuedReader == null` 路径覆盖。
- [ ] reader 只在确认放弃后释放。
- [ ] 测试 fake 不再把 `ErrorState` 当作安全释放。

### 验收前

- [ ] `flutter analyze --no-pub` 通过。
- [ ] 相关单测通过。
- [ ] 全量 Flutter 测试通过。
- [ ] native CTest/probe 通过。
- [ ] Windows release 构建通过。
- [ ] 导出符号检查通过。
- [ ] 真实 Windows 端点报告生成并保存。
- [ ] Linux/Android/Web 的 `hardwareTested` 边界写清。

### 审计和交付前

- [ ] 三轮审计记录齐全。
- [ ] 后端重构没有越界。
- [ ] 中文提交信息。
- [ ] 中文 PR 描述。
- [ ] 最新上游已合并。
- [ ] CI 全绿。
- [ ] PR 合并后再次同步上游。

---

## 16. 最后提醒

当前分支不是“差一个测试”的状态，而是一个**尚未完成生命周期契约的 WIP 分支**。最危险的做法是为了尽快跑通测试而提前释放 reader，或者用旧 ABI/旧硬件记录证明当前产物。

正确顺序永远是：

1. 先确认 native 已经不再回调；
2. 再释放 reader；
3. 再用测试和探针证明；
4. 再记录硬件证据；
5. 最后才讨论合并。

如果恢复后只能做一件事，就做 native preparation barrier 和 reader 所有权收敛；其他功能都应排在它之后。
