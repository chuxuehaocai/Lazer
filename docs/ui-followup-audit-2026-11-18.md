# UI 后续审计与 PR #72 渲染整合（2026-11-18）

工作区 `Lazer-ui-refresh`，保留窗口 chrome 与播放页并行未提交修改。
本记录补充 `ui-interaction-audit-2026-11-18.md` 未覆盖的问题。

## 已修复

| 场景 | 问题 | 实际修复与验证 |
| --- | --- | --- |
| 收藏专辑加载时切账号 | `_loading` 直接忽略账号通知，旧响应仅比对本地 serial，可能把旧账号收藏展示在新账号下 | 立即使旧请求失效，以 AppState、平台来源、账号、代次共同核验；4 项回归覆盖加载中切账号、同 UID 切平台、登出后原账号重登、替换 AppState |
| 收藏专辑重载与来源变更 | GlobalKey 映射保留已不在集合中的封面标识 | 重置集合时清理映射，键的生命周期跟随当前集合 |
| 插件文本编辑取消、保存或系统返回 | `showAppleDialog` 在 route popped 时完成，但退场 TextField 仍挂载；调用方立即释放 controller，引发框架断言 | 共享 `AppTextInputDialog` 在自己的 State 中持有 controller，退出卸载后才释放；6 项回归分别覆盖设置行与插件页面的三种退出 |
| 小窗口文本编辑与重复关闭 | 文本输入弹窗内容不可滚动，退出动画期间重复操作可能继续 pop | 共享弹窗可滚动，关闭使用单次标记及当前路由检查；Discord 设置由并行修复复用该组件 |
| Issue #70 / PR #72 歌词渲染 | 模糊采样模式未显式指定；极小 fade 仍创建退化的多段渐变 | 5 个 Dart 渲染文件按 PR #72 使用透明边缘采样 `TileMode.decal`，极小 fade 返回不透明遮罩，渐变 stops 夹入有效区间 |

## 定向证据

- `test/lyric_filter_regression_test.dart`：3 项通过；修复前极小 fade 的像素检查、实际歌词滤镜采样模式 2 项失败，正常 fade 回归保持通过。
- `test/saved_albums_session_test.dart`：4 项通过，均在修复前暴露来源/生命周期错误。
- `test/plugin_text_dialog_lifecycle_test.dart`：6 项通过；检查退场时控件仍挂载且 controller 可用、卸载后释放、保存只写入一次。
- 日志：`build/lyric-filter-{before,after}.log`、`build/remaining-ui-before.log`、`build/remaining-ui-after.jsonl`。

PR #72 的 Linux 音频原生部分由另一项审阅处理，本文件只记录 Dart 渲染行为。
Windows 上的 Flutter 主机测试能证明遮罩像素和显式采样契约，不能证明真实 Linux/Wayland GPU 的噪点问题已消失。
没有以主机测试替代 Wayland、触屏或读屏器的设备验证。

## 后续线索

收藏专辑搜索首批命中后缺少后页入口：已由并行修复加入 300 ms debounce、自动最多 8 页搜索预算与明确的“加载更多专辑”入口；收藏专辑专项现为 6 项回归。
一起听结束等待期间关闭弹窗导致迟到 pop：已由并行修复加入请求/路由生命周期保护及 widget 回归。具体一起听验证见其专项报告，本文件的 46 项定向测试不包含该模块。

## 悬浮歌词与桌面歌词重构

主控制器将原来的 Future 链替换为一个运行中操作及合并的最新更新，位置轮询只在窗口 ready 且播放中运行。慢 IPC 不再按每次通知保留一个等待闭包；瞬时失败使用一个延迟重试定时器恢复，避免丢失一次性的 ready 握手后永久冻结。

窗口边界提取为 `overlay_window_host.dart`。创建期间关闭、禁用或切换模式会接管并关闭迟到的窗口；关闭始终使用 overlay 的命名 channel。`window_manager.close` 在 Windows 仅投递 SC_CLOSE，因此收到方法成功响应后仍检查窗口清单，确认旧引擎已销毁再允许创建下一个。关闭无法确认时保留所有权，不叠加新引擎。dispose 解除 ready handler、状态监听与定时器。

`overlay_motion.dart` 只保留可见行及两侧进入行，最多 7 个 motion 对象；移出绘制范围的 spring 立即释放。自定义主题的非焦点 scale 与绘制强调度使用相同数值。纯文本、暂停且动画已稳定、隐藏或减少动画状态不保留逐帧 ticker；逐字歌词及间奏只在需要时逐帧绘制，减少动画时随位置消息更新。播放时钟按曲目时长夹取。

渲染与点击区域测量提取到 `overlay_presentation.dart`。窗口尺寸更新串行处理并合并最新尺寸，在 native 操作实际成功后记录尺寸；已卸载窗口不再继续后续定位。文档、主题、字号、字体、行距、显示原文/翻译设置改变后重新测量；只切换锁定/模糊等设置会复用全文宽度与行高。动态主题和异步字体注册完成都重新布局，避免沿用启动主题或 fallback 字体的几何。

Windows 原生点击区域限制为 16 个，校验非有限及退化矩形；100%/150%/200% DPI 使用相同逻辑像素契约。锁定、隐藏或空区域时停止 32 ms 鼠标轮询，显示及 DPI 改变后刷新穿透状态；显示器变化时重新夹取桌面位置。DPI 改变不在拖动过程中恢复旧保存位置，避免跨 DPI 屏幕拖动被拉回。

## 字体加载资源预算

Flutter FontLoader 无法单独卸载已注册 family，所以缓存 Set 的大小限制本身不足以回收 native 字体资源。

- overlay 首个自定义 family/path 可使用已有引擎，随后切到不同自定义字体前确认销毁旧引擎并建立新窗口；相同字体、字号、锁定及内置字体切换不引发无谓重建。加载器额外执行最多 4 个 family/path、累计原始字体文件 64 MiB 硬预算并共享进行中的读取。
- 主引擎每次启动最多注册 8 个自定义 family，且累计原始字体文件不超过 64 MiB；进行中读取/注册和已完成的加载共同计入，先 stat 并预留再分配，失败释放预留。达到任一上限明确提示“本次启动已达到自定义字体加载上限，请重新启动后继续切换字体。”，保持当前及持久化设置。内置和系统字体不占此预算。
- 自定义文件最大 64 MiB，读取前 stat、按受限长度读取；已有 file_selector.openFile 返回懒加载 XFile，优先读取本地路径，浏览器/内存选择保留大小检查后的 fallback。未引入 FilePicker 或新依赖。

选择文件先以流式哈希识别已加载 family，预算用完时仍可复用已注册的相同文件。AppState 的选择代次/卸载检查涵盖异步导入，重复点击由页面 busy 标记挡住。

这些是容器、注册数量及累计原始文件预算，不能当成进程实际堆内存的上限；字体解码后的内存仍取决于所选文件。

## 本次补充验证

- `test/desktop_lyrics_controller_lifecycle_test.dart`：10 项，包含迟到创建、慢 IPC 合并、瞬时失败恢复、关闭确认、字体预算回收及 ready 前字体切换替换窗口。
- `test/lyrics_overlay_lifecycle_test.dart`：8 项，包含 plain/reduced/hidden ticker、锁定目标、resize 顺序、实时主题、迟到字体重测量与卸载后的零窗口操作。前三项在修复前失败，锁定契约保持通过。
- `test/overlay_motion_test.dart`：2 项，包含 10,000 次跳转后的最多 7 个 motion。
- `test/overlay_font_loader_test.dart`：3 项，包含注册预算、失败重试与超大文件拒绝。
- `test/imported_font_budget_test.dart`：6 项，包含 8 个并发注册预算、失败释放、读取前拒绝、设置持久化保留及两种明确错误提示。
- `test/font_session_bytes_test.dart`：2 项，以 40 MiB sparse 字体文件验证主引擎和 overlay 的并发累计额度、注册失败后归还、已加载 family 复用不重复收费。
- 与前述渲染/插件弹窗及收藏专辑专项一起运行：46 项通过、0 失败；日志 `build/ui-followup-final-tests.jsonl`。定向 analyzer 日志 `build/ui-followup-final-analyze.log`。
- Windows 插件使用本机 clang++ C++17、`-Wall -Wextra -Werror -fsyntax-only` 检查通过；`tool/validation/desktop_lyrics_geometry_test.cpp` 的独立 DPI/穿透计时策略契约运行通过，日志 `build/desktop-lyrics-native-{syntax,contract}.log`。

原生语法检查与纯几何契约不等同于完整 Windows 构建或真实 Explorer、混合 DPI 显示器拖动、Wayland 透明窗口验证；这些设备/桌面会话行为仍需实际运行检查。本子任务未执行新的整包构建，未声称已证明全部平台视觉结果。
