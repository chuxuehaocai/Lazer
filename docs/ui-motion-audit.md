# Lazer UI 动画审计报告（三轮）

- 分支：`audit/ui-three-round`（基于 `dev/pr-36-39-40` @ `522636c`）
- 审计对象：`lib/` 下全部界面层 —— `ui/`、`widgets/`、`player/`、`lyrics/`、`animation/`、`navigation/`、`tv/`、`watch/`、`theme/`、`screens/`、`local/`、`easter_egg/`、`downloads/`
- 审计方式：静态阅读 + 自建机械扫描器 + 属性测试/回归测试实证 + 7 路并行深审
- 交付：6 个修复提交、3 个新增测试文件（1213 个测试全绿，`flutter analyze` 零问题）

---

## 0. 基线事实（决定了后面每一条发现的性质）

| 项目 | 结果 |
| --- | --- |
| `flutter analyze` | **No issues found**（清洗前即零问题） |
| 审计前测试 | **1203 通过 / 0 失败** |
| 审计后测试 | **1213 通过 / 0 失败** |
| `lib/` Dart 文件 | 215 个，界面层约 1.6 MB |

结论：**所有缺陷都不被现有 lint 和测试覆盖**。1203 个测试里没有一个是「动画在中途被打断/条件变化」的场景，这正是缺陷藏身之处。

---

## 第一轮：机械层（生命周期 / 资源 / 反模式）

自建扫描器 `diag/ui_audit_scan.py`（注释与字符串感知的词法切分 + 大括号配对 + 方法体提取），第一版产出 53 条，**逐条人工复验后收敛到 3 条**——过程中修掉了 4 类扫描器自身误报（`?.` 空安全调用、`..` 级联、`itemBuilder` 内局部变量被当字段、`onEnter: (_) => setState(...)` 闭包被当 build 期变更）。

最终 3 条全部复验为**良性**：

- `_AlbumFlowTicker._wake`（`ui/background.dart:110`）——由基类 `unscheduleTick()` 取消，`dispose` 后 `scheduleTick` 有断言保护。
- `LazerMediaHandler._clock`（`audio/system_media_handler.dart:170`）——`_syncClock()` 与 `setEnabled(false)` 双向取消。
- `AutoMixAudioEngine` 的 40 ms 混音时钟——`dispose()` 里 `_clock.cancel()`。

**结论：这套代码的资源卫生是干净的**（控制器/Ticker/Timer/订阅全部成对释放，无 `setState` after dispose，无 `addListener` 泄漏，无 `MediaQuery` 读在 `initState`）。因此后续把火力全部转向语义层。

---

## 第二轮：语义层（弹簧重定向 / 打断续接 / 帧调度 / 重绘）

### ✅ 已修复 1 — `AppleSpringCurve` 采样窗口硬编码 1 秒，非 1× 速度下曲线形状就是错的

**位置**：`lib/animation/apple_spring.dart:100`

**机制**：曲线注释写着「两个感知时长」，代码却把窗口硬编码成 1 秒：

```dart
static final SpringSimulation _unit = AppleSpring.smooth.simulation(0, 1);
static final double _end = _unit.x(1);
```

`AppleSpring.smooth` 的时长是 `MotionTiming.scale(500ms)`，**只在 1× 时** `2 × 500ms` 恰好等于 1 秒。2× 时弹簧在 0.25 s 就基本稳定，而 `_end = x(1s)` 已经取到 1.0，于是曲线在前 1/10 的行程里就冲到 72%（正确值 36%）；0.5× 时反过来滞后。又因为是 `static final`，形状被**冻结在首次采样时的速度**上。

**实测**（`test/apple_spring_curve_shape_test.dart`，还原修复后运行）：

```
2× 时 transform(0.05)：期望 0.1313，实际 0.3577   ← 2.7 倍畸变
```

**影响面**：`AppleSpringCurve` 在 **81 处**被使用——`LazerTokens.*Curve`、`main.dart` 的 `themeAnimationCurve`、页面转场 `ViewMotion.curve`，以及所有 `AnimatedContainer` / `AnimatedSwitcher` / `animateTo(curve:)`。

**修复**：让采样窗口等于「两个感知时长」，并显式绕开 `MotionTiming`。因为临界阻尼弹簧是时间尺度不变的，这样曲线成为**纯形状**，速度设置继续通过每个调用点自己的 `duration`（读 `AppleSpring.duration` 这个 getter）生效——正好符合 `docs/performance-validation.md` 的表述「scale the perceived duration of every AppleSpring simulation **at its call site**」。

> 注：默认 1× 下形状逐位不变，所以修复对默认用户零视觉变化，只修正非默认速度。

---

### ✅ 已修复 2 — 播放器「下拉返回」时，底层浏览页被当成被关闭的页面一起位移/淡出

**位置**：`lib/widgets/retained_content_switcher.dart:243`

**机制**：`preview` 的判定是

```dart
final preview = backProgress != null && (current || key == widget.backTargetKey);
```

而播放器手势走的是 `shell.dart:742` 的 `_backTarget = _backPlayer ? null : ...`——**没有目标页**，因为关闭的是播放器浮层而不是浏览页。但 `_backProgress` 仍然被传进 switcher（`shell.dart:1699`），于是 `current` 这一项单独就让当前浏览页变成 preview：

- iOS：整页宽度位移（`Offset(backProgress, 0)`）——播放器下拉时浏览页反而横移出屏，窗口露黑；
- Android：缩放到 0.92、前 25% 行程淡到 0、`TickerMode` 被静音、并被涂上不透明 surface；
- 预览结束后再「弹回」。

**实测**（`test/player_back_keeps_browse_page_test.dart`，还原修复后运行）：

```
90% 下拉时底层浏览页 FadeTransition 不透明度 = 0.4（应为 1.0）
FractionalTranslation 同样偏离 Offset.zero
```

**修复**：preview 必须有目的地。

```dart
final preview =
    backProgress != null &&
    widget.backTargetKey != null &&
    (current || key == widget.backTargetKey);
```

浏览页返回手势的 `backTargetKey` 全程非空，所以那条路径行为不变。

---

### ✅ 已修复 3 — 页面切换被「切换器被替换」打断时永不报告结束，环境流光背景永久冻结

**位置**：`lib/widgets/retained_content_switcher.dart`（`dispose`）

**机制**：`onTransitionChanged(true)` 在 `didUpdateWidget` 发出，`false` 只来自 `_motion` 完成回调或两个同步早退分支。当**布局模式切换**（设置→界面模式）或**窗口跨断点缩放**把内容挪到树的另一个位置（`shell.dart` 的 `_content()` 出现在 1015/1077/1174 三处）时，切换器元素被直接替换，`dispose()` 不报告，post-frame 的 `animateWith` 又被 `mounted == false` 丢弃。

于是 shell 的 `_contentSwitching` **永远为 true**（它只有赋值 true 的地方，`shell.dart:813-818`），后果：

1. `TickerMode(enabled: !_contentSwitching)`（`shell.dart:868`）→ **漂移的流光背景永久冻结**，新布局起来后也不恢复；
2. `_canStartSystemBack()`（`shell.dart:729`）→ 内容返回手势失效；
3. `_onAppStateChanged` 的 `if (_contentSwitching && !_nowPlayingOpen) return;`（`shell.dart:289`）→ **所有结构性状态上报被丢弃，shell 不再重建**（例如开始播放后紧凑版迷你播放器不出现）。

直到下一次导航创建新切换器才恢复。

**修复**：`dispose()` 里补报欠下的结束（`_reportedMoving` 跟踪是否已报 true），并放到 post-frame 以免在 unmount 过程中通知监听者。回归测试见 `test/motion_under_changing_conditions_test.dart` 最后一条。

---

### ✅ 已修复 4 — 歌词引擎在「无歌词/加载中」时整首歌保持全速 Ticker

**位置**：`lib/lyrics/viewport.dart:420`

**机制**：`build` 在 `lyricsLoading` / `lyrics.isEmpty` 时提前返回（`:1006`、`:1009`），**永远到不了唯一会刷新曲谱状态的 `_layout`**。于是 `_lines`、`_hasWordTimings`、逐行弹簧全都还在描述**上一首**。而

```dart
var moving = _manual && _velocity.abs() > 5 ||
    widget.state.playing && (_hasWordTimings || _activeInterlude) || interludesMoving;
```

只要上一首有逐字时间轴，`moving` 每帧都为真，`if (!moving) _ticker?.stop();` 永不执行 → **整首歌每个 vsync 跑一次 `_tick`，每帧读一次原生播放头（FFI）**，遍历一张看不见的旧曲谱，而屏幕上只有「这首歌暂未提供歌词」。

**修复**：曲谱只有被 `_layout` 采用过才算「活」：

```dart
final bool sheetIsLive =
    widget.state.lyrics.isNotEmpty &&
    identical(_sourceLines, widget.state.lyrics);
```

（`isNotEmpty` 是必要的：两首无歌词的歌共享同一个 `const <LyricLine>[]`，`identical` 会误判。）

---

### ✅ 已修复 5 — 歌词甩动惯性用了错误的模型（漏传 `retention`）

**位置**：`lib/lyrics/viewport.dart:1117`

`ScrollMotion.carriedVelocity` 靠 `isNative(retention, acceleration)` 决定是否原样透传。这里只传了 `acceleration`，`retention` 落到默认 0.90；同文件的滑行分支（`:399`）和兄弟实现 `InertiaScrollPhysics.carriedMomentum`（`app_scroll_behavior.dart:75`）都同时传两个。后果：惯性滑块离开 0.90（加速度仍为 1.0）时，接续动量按 100% 透传而不是按自定义模型缩放，**约为应有值的 1.54 倍**。

修复：补上 `retention: widget.state.scrollRetention`。

---

### ✅ 已修复 6 — 播放列表卡片徽章是「死动画」，且悬停时是瞬间弹出而非淡入

**位置**：`lib/ui/widgets.dart:203`

`AnimatedOpacity(opacity: 1, ...)` 且子树被 `if (raised)` 条件挂载——**该动画在数学上永远无法插值**（起止值相同），徽章在第一个悬停帧直接出现。文档注释写的是「the cover raises a play badge」，`duration: 140ms` 也说明本意是淡入。

全库扫描（`diag/ui_audit_dead_animation.py`）确认这是**唯一**一处「所有可动画属性都是字面量」的隐式动画。

修复：徽章常驻 + `opacity: raised ? 1 : 0` + `IgnorePointer`；`AnimatedScale` 补偿减少动效门控。

---

### ✅ 已修复 7 — 三处反馈/无障碍缺陷（同一批提交）

| 位置 | 缺陷 |
| --- | --- |
| `lib/easter_egg/still_alive_page.dart:237` | `_active = state == resumed`。桌面端**点一下别的窗口**就派发 `inactive`（窗口仍完全可见），于是打字、光标闪烁、片尾字幕全部冻结，重新聚焦时又整段跳进——`inactive` 的语义是「可见但无输入焦点」。改为只有 `paused` / `hidden` / `detached` 才暂停视觉。 |
| `lib/interaction/app_haptics.dart:23` | 节流用 `DateTime.now()` 比较，时钟**回拨**（夏令时回退、NTP 校正、手动改时间）时差值为负 → 判定「太快」→ 提前 return 且**不刷新 `_last`** → 之后每次触感都被拒，直到墙钟追上旧时间戳（夏令时回退后可达一小时）。改为负差值视为重置节流。 |
| `lib/widgets/haptic_seek_slider.dart:124` | 焦点环被 `if (tv && _focused)` 门控，但 `FocusableActionDetector` 在任何有键盘的平台都是焦点站（注释自己也这么说）。桌面端 Tab 到进度条、用左右键拨动播放头，**屏幕上没有任何焦点提示**。改为 `if (_focused)`。 |

---

### ✅ 已修复 8 — 两处「移动类」动画忽略减少动效

`lib/widgets/song_comments_view.dart:162`（`AnimatedSize`，高度变化）与 `:509`（`AnimatedSwitcher` + `ScaleTransition`，缩放弹跳）没有门控，而**同一文件下方相邻的 `TweenAnimationBuilder` 是门控的**——说明是遗漏。`docs/ui.md` 承诺「Reduced motion removes decorative travel」。纯颜色/透明度过渡（`ui/shell.dart:1852/2042`、`ui/widgets.dart:352/600`、`window_title_area.dart:185`）**未改**，因为不算 travel。

---

## 第三轮：动态条件（运行中改变条件）

现有动画测试**全部**在动画开始前就固定好减少动效、动画速度与生命周期。新增 `test/motion_under_changing_conditions_test.dart` 覆盖 6 个场景，全部通过：

1. 切换途中打开「减少动效」→ 干净收敛，无残留 ticker
2. 切换途中退到后台再回来 → 干净收敛
3. 切换途中两次改「动画速率」→ 干净收敛
4. 六次连续切换、帧间不留空隙 → 落点正确
5. 一开始就减少动效 → 无 ticker
6. **切换被布局替换打断 → 仍补报结束**（这是修复 3 的回归测试，修复前失败）

结论：retained 导航机制在动态条件下的鲁棒性经得起检验；唯一失效路径就是修复 3。

---

## 已确认但**未修复**（附位置、机制、建议改法）

按影响排序。这些是诚实的遗留项，不是没找到。

### A. `itemBuilder` 内创建 `GlobalKey()` → 封面飞行途中源封面「复活」，出现双封面

**位置（6 处，同一缺陷）**：`lib/ui/home_pages.dart:371`、`:805`、`:866`、`:963`；`lib/ui/artist_pages.dart:346`、`:536`

**机制**：`CoverTransitionSource` 的隐藏标记按 **GlobalKey 身份**存放在 `_hiddenSources`（`cover_transition.dart:226/280`），飞行开始时把源隐藏并**一直保持到返回**（`:668`）。但 `GlobalKey()` 建在 `itemBuilder` 里——sliver / `ListView.builder` 在任何重建时都会对每个已挂载子项重跑 builder（`SliverChildBuilderDelegate.shouldRebuild => true`），新 key 使 `Widget.canUpdate` 为 false → 元素重建 → 新 state 的 `_hidden` 初始化为 `false` → **源封面在飞行途中重新可见**，与浮层里同一张封面叠加。

**本仓库自己记录过这个陷阱**：`lib/ui/album_library_page.dart:46-48`

> One cover key per album: a key made inside `itemBuilder` would remount the cover — and re-register its flight source — on every rebuild.

而且该文件在 `:428` 用了正确写法（`_coverKeys.putIfAbsent(id, () => GlobalKey())`）。`lib/ui/widgets.dart:145`、`lib/tv/large_screen_widgets.dart:324/454` 也都是 State 字段（正确）。

**两种建议改法**：
1. **推荐（贴合仓库既有惯例）**：把这 5 个 `StatelessWidget` 货架改成 `StatefulWidget`，在 State 里持有 `Map<String, GlobalKey>`，itemBuilder 改为 `_coverKeys.putIfAbsent('playlist:${album.id}', GlobalKey.new)`。
2. **改动更小**：新增一个只负责「托管稳定 key」的 builder 包装组件，itemBuilder 用 `<album.id>` 作 widget key 包一层。

**未修原因**：两种都要么把 5 个大组件做 `widget.` 前缀重写，要么给 6 处 itemBuilder 包一层并重新缩进；在 10 万字符级文件里做机械改写、且没有 CI 格式校验兜底，风险与收益不匹配。**建议由熟悉这两个文件的维护者执行，并在改动后手工确认一次封面飞行。**

（另有一条更小的替代方案：把 `_hiddenSources` 改成同时按 identity 记录隐藏态。它能一行修好全部 6 处，但一旦漏掉反隐藏就会留下**永久不可见的封面**——比一帧重影更糟，因此不建议在没有针对性测试的情况下采用。）

### B. 调色板交叉淡入让 30fps 上限失效（已实测）

**位置**：`lib/ui/background.dart:248-252`（`AnimationController(vsync: this)`）、`:290-315`、`:375`

**机制**：网格漂移由自定义 `_AlbumFlowTicker` 用 `Timer` 精确限速（文件注释 `:104-105` 明确说这是为了不每帧申请 vsync），但**调色板淡入是一个普通 `AnimationController`**——普通 `Ticker` 每个 vsync 都 `scheduleFrame()`，正好是那段注释要避免的事。`:295` 的节流也补不回来：它用独立的墙钟网格，于是淡入期间存在**两套无效化网格**。

**实测**（60 Hz 测试显示，1 秒窗口；`bumps` = 画笔无效化次数）：

| 配置 | bumps | 说明 |
| --- | --- | --- |
| 30 fps，无淡入 | 30 | 上限精确 |
| 30 fps，淡入中 | **51** | 且 38/60 帧申请了下一帧 |
| 10 fps，无淡入 | 10 | 上限精确 |
| 10 fps，淡入中 | **18** | 且 38/60 帧申请了下一帧 |

触发器：动态背景模式下**每次切歌**都会持续 650 ms（`paletteTransition`）。

**建议改法**：把淡入改成时钟驱动、只从已限速的回调里发布——`didUpdateWidget` 里记 `_paletteStartUs` 并置 `_palette.value = 0`，在 `_advance`（已经在 `:453` bump `_frames`）里按 `_paletteClock` 推进，随后删除 `_onPaletteFrame` / `_onPaletteStatus` / `_paletteTrailing`。
**注意的坑**：`_rawPalette` 在 `:460` 用 `_palette.value == 0 && !_palette.isAnimating` 判断，改造后需要改用显式的 `_fading` 标志，否则淡入第一帧会跳到 `_to`、下一帧又跳回来。**改完必须重跑像素级调色板测试。**

**未修原因**：这是重构而不是补丁，且触碰已验证的像素精确行为；在有实测数据的前提下，交由维护者决定是否值得。

### C. 页面切换期间，**可见**页面的 Ticker 也被静音

**位置**：`lib/widgets/retained_content_switcher.dart:263` — `TickerMode(enabled: current && !entry.transitioning && !preview)`

`parked = !current && !entry.transitioning && !preview`，而上面这个表达式比 `!parked` 严格得多：切换途中**入场页和出场页都在屏幕上**，两者的 Ticker 却都被禁用。可观察后果是入场页里的 `CircularProgressIndicator` 之类**自持动画会冻结约 420 ms**（`TickerMode` 同样作用于框架自己的 Ticker）。

**未修原因**：存在一个站得住的反向理由——`MotionSnapshot` 在切换期间对整页做栅格快照，页面内部动画每帧都会让快照失效。所以这可能是刻意的性能取舍。**建议由维护者拍板**；若要改，一行即可：`enabled: !parked`（parked 页仍被正确静音，`test/retained_content_switcher_test.dart` 会守住这一点）。

### D. 其余已报告、我未复验的条目

以下来自并行深审，机制在代码里明确，但我**没有**逐条亲手复验，请按线索复核后再改：

| 位置 | 问题 |
| --- | --- |
| `lib/ui/shell.dart:742-746` | 收藏的专辑（`_browseHistory` 为空且 `_section = library`）走系统返回手势时，preview 目标被算成 `section:home`，而提交动作实际落在 `section:library`：拖动时预览的是**错误的页面**，提交时又重放一次 420 ms 过渡（正确做法应跟随 `_handleBack` 的真实去向）。 |
| `lib/widgets/cover_transition.dart:566-574` | 减少动效早退分支没有 `_forgetOrigin()` 也没把 `_flightBlend` 复位为 1；之后关掉减少动效再按返回，返回飞行的 blend 会钉在 0，把卡片捕获的文字/马赛克以全不透明画到详情页尺寸。 |
| `lib/widgets/cover_transition.dart:595-604` | 飞行的素材取自**目标页**的实时子组件，而目标与源用的是不同 CDN 渲染档位（如 270/330 vs 168/190）。冷启动首次打开时飞行体是渐变占位图 → 出现「封面→占位→封面」的顿挫。`morphArtwork: true` 的卡片免疫。 |
| `lib/lyrics/viewport.dart:373-435`、`:987-996` | 逐帧开销随**整张曲谱**而不是可见区增长：每 vsync 遍历全部行做 `text.trim()`、每行分配闭包等。长曲谱会与 120 Hz 目标直接冲突。 |
| `lib/watch/watch_shell.dart:153-159` | Settings 点「发送验证码」后 `Timer.periodic(1s)` 会持续 `setState` 重建整个手表界面；`_navigate`/`_back` 都不取消它，离开页面后最长 60 s 每秒重建一次。 |
| `lib/ui/player_bar.dart:619-631` | `AppThinSeekBar` 的 D-pad 路径实际不可达（TV 下 shell 走 `_largeScreenLayout`），`docs/android-tv.md:198-199` 仍然把它写成 TV 进度条；其中 900 ms 的 `_nudgeTimer` 也不被新手势取消，一旦重新接线就会在拖动中清掉 `_drag`。 |
| `lib/easter_egg/still_alive_page.dart` | 整个 Still Alive 没有任何减少动效门控（33 Hz 打字/字幕 + 300 ms 光标闪烁全速运行），而打开它的 `ApplePageRoute` 是遵循该开关的。 |

---

## 已复验为**干净**的部分（供下一位审计者省去重复劳动）

- **弹簧重定向**：`springTo` 一律从当前 `value` + 真实速度出发（`AnimationController.velocity`），中断/反向保持动量——`test/apple_spring_test.dart` 有断言。
- **`_RouteSegment` 反向衔接**：`retarget()` 用旧曲线在 `progress` 处取值作为新的 `_startValue`，入场被打断时不会先跳一下；各阶段手算均连续。
- **`RetainedContentSwitcher` 重定向**：`from = _value(entry)` + `spring.dx(...)` 速度交接正确；post-frame `animateWith` 有 generation 守卫；`parkedView` 缓存不会陈旧（重新可见时立即丢弃）。
- **`MotionSnapshot`**：`allowSnapshotting` 只在实际运动时开启，滚动时关闭，`invalidate` 有 scheduler 阶段守卫。
- **手势与 Navigator 状态机**：`_PageEdgeGesture` / `_SystemEdgeRecognizer` / `_PlayerPullDownRegion` 都先于框架合成的 end 处理 PointerCancel；`ApplePageRoute._finish` 有 generation 守卫，`_releaseVelocity` 恰好消费一次；`_SystemBackGestureState._finish` 的 `_settling` 守卫使重复回调幂等。
- **`app_scroll_behavior.dart` 的滚轮动量**：数学与 `FrictionSimulation` 一致；`scheduleMicrotask` 的竞态被 `GestureBinding.pointerSignalResolver` 的解析时序保护（`before` 已在解析前捕获），默认设置下的手感由 `test/native_scroll_feel_test.dart` 固化——**不是**缺陷。
- **无双重缓动**：弹簧驱动的几何全部原样消费，没有叠加 `Curve`/`CurveTween`；`_AppleSheetRoute` 显式用 `Curves.linear` 避免把拖动坐标缓动两次。
- **无 `shouldRepaint => true`**、无 build 期 `setState`（自建扫描器 40 条候选全部复验为闭包内的合法调用）、无永久 `repeat()`（`lib/` 内 `.repeat(` 零处）。
- **`BuildSafeNotifier`**：把 build 期的 `notifyListeners` 折叠进 post-frame，是 `AnimatedBuilder` 之上正确且必要的保护。
- **`_MovingCoverMosaic`**：30 fps 用 `Timer` + `Stopwatch`（相位由墙钟推导，不漂移），`TickerMode.valuesOf` 作为真正的 inherited 依赖、生命周期与减少动效三重门控，停止时正确重置。
- **`AnimatedTrackCover`**：`_CoverPlate` 的控制器由 State 统一释放，栈序（不透明底在下）与状态监听释放逻辑自洽。

---

## 如何复验

```bash
export PATH="/d/flutter/bin:$PATH"
flutter analyze --no-pub                      # 期待 No issues found
flutter test --no-pub                         # 期待 1213 passed

# 单条缺陷的回归测试（在对应修复提交上通过、在父提交上失败）
flutter test --no-pub test/apple_spring_curve_shape_test.dart
flutter test --no-pub test/player_back_keeps_browse_page_test.dart
flutter test --no-pub test/motion_under_changing_conditions_test.dart

# 机械扫描器（只读，无副作用；随分支一起提交，位于 tool/ui_audit/）
python tool/ui_audit/ui_audit_scan.py lib                 # 生命周期/资源
python tool/ui_audit/ui_audit_dead_animation.py lib       # 死动画（现为 0）
python tool/ui_audit/ui_audit_reduce_motion.py lib        # 减少动效缺口
python tool/ui_audit/ui_audit_stale_media_query.py lib    # initState 里读 MediaQuery（0）
```

提交序列（`522636c..HEAD`）：

```
2c3b46e fix(ui): stop runaway animation work and repair two feedback paths
462aca0 fix(navigation): report the end of a switch the switcher never finished
4aa56fb fix(navigation): a preview needs a destination
b1e1f2f test(motion): cover motion under changing conditions
b050d07 fix(a11y): honour reduced motion for two decorative transitions
8d6b411 fix(animation): sample AppleSpringCurve over two perceived durations
```
