# UI 交互复审（2026-11-18）

工作区：`D:\Lazer\Lazer-ui-refresh`。基线：`781272e`，分支：
`codex/desktop-tv-refresh`。本轮覆盖播放控件、搜索、导航、队列、下载、
歌单、登录、评论、快捷键，以及页面和封面过渡的资源生命周期。

此工作区与 `D:\Lazer\Lazer` 内容不同。本记录只描述在本工作区重新验证的
UI 修复，不代表旧工作区的原生音频及下载引擎修复已全部合入。
开始时已有的窗口标题栏、播放页布局改动，以及并行工作产生的窗口改动，
均不纳入本次提交。

## 已复现并修复

| 操作场景 | 原问题与修复 |
| --- | --- |
| 按键同时匹配控件和媒体快捷键 | 原硬件监听器继续执行已被按钮或局部快捷键处理的事件，导致一次按键触发两种动作。改用焦点系统末级处理，继续跳过文本输入、录入弹窗、重复和合成按键；卸载时注销。 |
| 短窗口、大字体录入快捷键 | 弹窗内容底部溢出，操作不可达。内容可滚动，保留底部操作区；冲突快捷键仍不能保存。 |
| 已打开的设置选择器变为禁用 | 菜单仍停留且看起来可操作。禁用后关闭菜单，保留 mounted 与重新启用检查。 |
| 拖动进度后取消、失焦或禁用 | Material 的结束事件会在取消时提交旧预览。增加独立取消路径，取消时恢复显示、不执行 seek。 |
| 拖动时切歌，包括相同歌曲的不同队列位置 | 旧拇指和粗轨残留，释放时可能 seek 新歌曲。用状态对象、曲目 ID、队列位置共同标识交互来源，切换后重置。 |
| 无时长或只有部分缓冲的音源 | 无效 seek 仍可操作、预览超过可 seek 边界。禁用未知时长进度条，统一限制预览和提交值。 |
| 右键拖动和 RTL 滑块 | 额外原始指针处理绕过 Material 轨道几何、按键和 RTL，造成误拖动或重复反向回调。由 Material 统一处理指针几何。 |
| 音量拖动取消 | 临时音量保留，图标不随拖动更新。取消恢复起始音量；预览时只更新控件，结束时保存。 |
| 空曲目、320px 播放控制栏 | 空态仍可执行播放，窄栏溢出。空态禁用传输按钮；窄栏保留上一首、播放、下一首和静音。 |
| 搜索分类与结果 | 固定横排分类在窄屏和大字体下溢出；只命中歌手等分类时停在空歌曲页。分类可换行并可键盘操作，首次结果选择有内容的分类。 |
| 搜索中切换云端、本地或平台 | 原分类或迟到请求留在新来源中。使用来源和请求代次校验，切换到本地时恢复歌曲分类。重复提交、清空、失败重试也有回归覆盖。 |
| 通用搜索框清除 | 未传自定义清除函数时按钮不能工作。提供清除文本、通知上层并恢复输入焦点的默认行为。 |
| 导航、队列、多选 | 胶囊导航无法 Tab/Enter 激活；空队列没有说明；零条目仍可批量操作。补齐键盘及禁用语义、空态和明确的“定位当前歌曲”。切歌不抢用户滚动位置。队列行适应大字体与窄面板；隐藏或减少动画时，播放指示器解除 tick 订阅。 |
| 下载目录验证和确认 | 固定 `.lazer_write_test` 可能覆盖删除同名用户文件；同一帧重复确认可能重复提交。使用原子创建的独立临时目录、重入保护；保存偏好异常恢复按钮并可重试。 |
| 创建歌单成功后加歌失败 | 重试再次创建歌单。保留已创建歌单，重试只加歌，并检查账户、平台是否仍一致。取消后迟到创建结果不会继续加歌。 |
| 登录与评论 | 登录异常可能卡住忙态，登录期间切换表单可能混淆结果；评论可重复打开登录并在换歌后继续旧点赞。增加异常恢复、提交时表单限制、登录单次流程和来源校验。登录可退出，迟到结果不关闭后续页面。 |
| 快速切页和切歌 | 等待动画自然结束才能回收，连续操作会累积页面及封面。页面默认最多九个常驻加一个离场，实际过渡最多两页；封面最多三层，隐藏或减少动画时立即收束为一层。过渡身份缓存最多两个，同页重建后立即返回仍保留前页状态。 |

## 回归与验证

新增测试：

- `test/media_shortcut_interaction_test.dart`
- `test/player_controls_interaction_test.dart`
- `test/search_queue_navigation_interaction_test.dart`
- `test/dialog_submission_regression_test.dart`
- `test/ui_transition_budget_test.dart`

补充 `test/settings_choice_interaction_test.dart` 的打开后禁用回归。
关键缺陷通过修复前失败、修复后通过的回归验证；同时覆盖已有正确的重试、
清空、键盘、减少动画和卸载行为，避免以修复某个场景破坏另一个。
另修正 `test/audio_quality_test.dart` 的清理竞争：等待磁盘缓存维护完成后再
删除测试临时目录，避免 Windows 偶发“目录非空”。这项只调整测试收尾。

本地证据保存在 `build/*interaction*`、`build/*regression*`、
`build/*shortcut*`、`build/ui-transition-budget-before.log` 等日志。
这些构建目录文件不进入源码提交，清理 build 后需重新运行。

本轮新增 61 项交互回归，包含真实退场动画期间的按钮关闭、系统返回、
二维码启动/轮询完成，以及登录被其他弹窗覆盖的情况。验证使用
Flutter 3.47.0 / Dart 3.13；依赖保持仓库锁定版本，未升级 `pubspec.lock`。

| 验证范围 | 结果 |
| --- | --- |
| 基线 `781272e` 加本轮 29 个文件的独立源码副本 | 367 项通过，2 项跳过 |
| 包含工作区原有窗口改动的完整源码 | 390 项通过，2 项跳过 |
| 独立副本静态分析、四语言键检查 | 无分析问题，遗漏/过期/不一致的翻译键均为 0 |
| Windows Release，要求原生引擎并指定 DSD-capable FFmpeg SDK | 构建成功，包含原生引擎、桥接及 FFmpeg DLL |
| Web JavaScript Release | 构建成功；Wasm dry-run 仍报告现有 FFI 不兼容，未将 Wasm 列为通过 |

两项跳过均为未检出的仓库外 NetEase 插件合约测试。Windows 构建仍存在
原生代码/依赖的类型转换、编码和 CMake 警告；这里没有将其算作零警告构建。
独立副本位于 `build/ui-audit-clean-verification`，只覆盖本轮列出的源码与测试，
用于确认本次提交无需依赖尚未提交的窗口修改。

在目标源码目录可复现的命令（SDK 和 FFmpeg 路径可按环境替换）：

```powershell
$flutter = 'D:\Lazer\Lazer\build\tools\flutter\bin\flutter.bat'
$dart = 'D:\Lazer\Lazer\build\tools\flutter\bin\dart.bat'
& $dart analyze --fatal-infos
& $flutter test --no-pub
python tool/check_i18n.py
& $flutter build web --release --no-pub
$env:LAZER_AUDIO_REQUIRE_ENGINE = 'ON'
$env:LAZER_FFMPEG_ROOT = 'D:/Lazer/Lazer/build/ffmpeg-sdk'
& $flutter build windows --release --no-pub
```

最终证据：`build/ui-audit-clean-tests.jsonl`、
`build/ui-audit-full-tests-final.jsonl`、`build/ui-audit-clean-analyze.log`、
`build/ui-audit-clean-i18n.log`、`build/ui-audit-clean-windows-build.log`、
`build/ui-audit-clean-web-build.log`。

## 验证边界

容器预算不等同于整个进程的内存硬限制；音频解码器、GPU、系统缓存和用户
曲库另有成本。本轮没有降低音频采样率或位深，也没有重新宣称全设备音质、
长时间播放或 RSS/CPU 降幅已完成实测。窄屏、字体、键盘和 TV 行为主要以
真实 Flutter 控件回归验证，不能替代所有触屏、读屏器和电视设备的真机验收。
关闭弹窗会停止后续 UI 操作；已经发出的远端登录、创建或加歌请求本身
仍可能完成，不能据此认为远端请求已经撤销。
