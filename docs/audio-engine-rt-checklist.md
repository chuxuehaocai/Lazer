# 实时输出路径审查清单

适用对象：`native/lazer-audio/src/engine.cpp` 的 `Engine::renderLoop()` 及其在实时线程上调用的一切。
目标：**实时线程只做"从环形缓冲取数 → 交给设备"**。文件 I/O、堆分配、互斥量等待、同步日志写入
都在禁止之列，因为它们都可能让一次提交超过一个设备周期，而迟到的一个周期就是一次可听见的欠载。

这份清单是阶段 3 的产物，也是后续改动的门禁：任何触碰 `renderLoop()` 或其调用链的 PR，
都必须逐条回答下表。

## 1. 禁令与当前实现

| 禁止项 | 为什么 | 现在的做法 | 位置 |
| --- | --- | --- | --- |
| 文件 I/O | 一次磁盘/网络等待 = 数百个设备周期 | 字节源在解码线程（`LazerAudioReader` 回调）与桥接层，实时线程只读环形缓冲 | `ring_buffer.h`、`lazer-audio-bridge` |
| 堆分配 | `malloc` 可能阻塞在分配器锁上，耗时不可预测 | 环形缓冲、块缓冲、DSP scratch、可变模式的记账台账全部在会话建立时一次性分配 | `engine.cpp`（`block`、`convertScratch_`、`variableOutputLedger`） |
| 互斥量等待 | 优先级反转：持锁线程被抢占时实时线程陪等 | 实时线程只读原子量：`renderedFrames_`、`trackStartOutputFrame_`、`activePresentation_*`、`sourceEndedMirror_`、`pumpFinished_`、`pendingTrackChangedFrame_`、环形缓冲游标 | `engine.cpp` `renderLoop()` / `renderPositionMillis()` |
| 同步日志写入 | 日志会格式化、加锁、写文件 | 实时线程不写日志；错误路径先存错误码，由控制线程发布 | `setError()` 只在错误分支，且不写日志文件 |
| 阻塞等待设备之外的东西 | — | 只 `waitForReady()`（设备周期/事件）与 `sleep_for` 的短自旋 | `output_wasapi.cpp`（事件回调）、`renderLoop()` |

## 2. 逐项核对（改动 `renderLoop()` 时逐条回答）

1. **新增的调用是否可能分配？** 任何 `std::vector`/`std::string`/`std::deque`/`std::function` 的构造、
   `push_back`、`resize` 都算。需要可变长容器时，用会话建立阶段预分配 + 固定容量环（见
   `variableOutputLedger`：容量 1024，溢出丢最旧一条并把台账标记为需要重新同步）。
2. **新增的调用是否会取锁？** 包括 `std::lock_guard`、`std::unique_lock`、`std::mutex::try_lock`
   以及任何 `Engine::` 上以 `Locked` 结尾的辅助函数（它们假设调用者已持锁并会断言/死锁）。
   需要跨线程数据时，让生产者写原子量或 `RenderPresentation` 镜像。
3. **是否触碰 `source_` / `nextSource_` / `preparingSource_`？** 这三个 `shared_ptr` 的读写都在
   `sourceMutex_` 下，实时线程一律不碰；需要曲目信息就取 `activePresentation_`。
4. **是否会写日志或构造错误字符串？** 只在 `publishTerminal()` 之前，且必须在 `break` 出循环的分支上
   （会话已经结束，一次分配不再影响音频）。
5. **是否会等待生产者的进度？** 只有"等设备"是允许的。等待环里有数据属于死锁风险：`hasEnough()`
   的边界等待必须同时接受 `pumpFinished_` 与 `sourceEndedMirror_` 作为出口。
6. **水位策略是否会影响它？** 生产者可能在 `ring_.readableFrames() >= ringHighWatermarkFrames_`
   时暂停喂入；实时线程不得依赖"生产者一定会及时填满"这一假设，必须能在环空时补静音并计数。
7. **基准是否仍然成立？** `lazer-audio-ring-stress`（40 秒素材 + 有节奏的假端点）必须报告
   0 欠载；注入的 800 ms 解码停顿必须产生**有界**的欠载计数并恢复。

## 3. 已知的、被明确允许的例外

| 例外 | 范围与理由 |
| --- | --- |
| `snapshot()` / `streamInfo()` 由事件回调**同步**重入 | 两者都会取 `lifecycleMutex_`（`try_lock`）与 `sourceMutex_`。这是既有契约（事件回调内查询快照以确认终态），且**出货路径不会触发**：Dart 侧用 `NativeCallable.listener`，事件回调是异步投递的，UI 线程随后才查询。引擎自身的实时循环不调用它们。若将来需要在回调内同步查询，必须先把这两个入口改成无锁镜像（`RenderPresentation` 已经承担了大部分字段）。 |
| `publishTerminal()` 内的字符串与回调 | 只在终端事件路径（设备丢失、播放结束）执行一次，之后不再提交音频。 |
| `std::shared_ptr` 的引用计数操作 | 实时线程不持有 `shared_ptr` 副本；`SourceSlot` 的生命周期由生产者管理，实时线程只读原子镜像。 |

## 4. 计时基线

`renderLoop()` 每个周期的工作量：一次 `ring_.read()`（`memcpy` 若干帧）、一次或两次
`output_->write()`、以及若干个原子读写与比较。没有循环内的分配、没有取锁、没有系统调用
（除设备等待本身）。`lazer-audio-ring-stress` 把这条路径按约 58 倍实时速度跑满 40 秒素材，
用于暴露任何"每周期一次分配"级别的退化。
