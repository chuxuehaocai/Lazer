# Lazer `nextgen` 代码审查（2026-11-04）

对象：`chuxuehaocai/Lazer` @ `nextgen`，HEAD `7c56023`（共 192 个提交，首提交 2026-10-15）。
本次审查只读，不改任何业务代码；下列每条结论都回读过对应源码，纯推断项已剔除。

## 1. 项目定位

Flutter 手写的第三方网易云音乐客户端：WEAPI/EAPI 协议在应用内实现（不挂第三方网关），
桌面/手机/平板/车机/Android TV/Android 手表共用一套 Apple 风格界面与状态。
仓库同时带一个 FFmpeg + WASAPI/CoreAudio/ALSA/AAudio 的原生 Hi-Fi 引擎（DSD/DoP、gapless、EQ/limiter）。

| 指标 | 数值 |
| --- | --- |
| Dart 实现 | `lib/` 208 文件 / 71,989 行 |
| 测试 | `test/` 156 文件 / 40,841 行；静态扫描约 936 个 `test()`/`testWidgets()` 调用点，实际执行 1056 个用例（含 variant 展开） |
| 原生引擎 | `native/lazer-audio/` 91 个 C/C++/ObjC++ 文件 / 30,770 行；单个 `CMakeLists.txt` 883 行 |
| 文档 | `docs/` 根目录 23 篇 / 3,877 行（另有 `docs/releases/` 4 篇） |
| CI | `.github/workflows/build.yml` 9 个 job，产出 6 种产物 |
| 版本 | `pubspec.yaml` `2.0.0-beta.5.hotfix+7`（README 徽章写 v2.0.0） |
| 工具链 | Flutter **3.47.0** stable（revision `4cf2416426`）/ Dart **3.13.0** |

## 2. 架构地图

| 层 | 关键文件 | 职责 |
| --- | --- | --- |
| 启动 | `lib/main.dart`（399 行） | zone 过滤 mpv 噪声日志 → 并行启动窗口/偏好/TV/watch 探测 → 选音频引擎 → 构造 `AppState`/`PlaybackSession`/`SystemMediaController` → `runApp`；`bootstrap()` 在 `main.dart:266` 被 unawaited 调用 |
| 状态 | `lib/state/app_state.dart`（3,720 行） | 单一 `ChangeNotifier`（`app_state.dart:136`）：账号、目录、播放、歌词、下载、更新、全部 UI 偏好；100 处 `notifyListeners()`、55 处 `SharedPreferences.getInstance()`；反向 import UI（`app_state.dart:33`） |
| 网络 | `lib/gateway/`（13 文件） | 协议无关 `MusicGateway` 接口 + `GatewayRegistry`（按 `provider:connection` 注册）；`crypto.dart` 实现 weapi/eapi/api 三种编码；`routes.dart` 59 个别名 case；12 名单的 cookie 规范化；`navidrome_*` 为实验性 Subsonic 后端 |
| 目录 | `lib/data/catalog.dart`（1,776 行） | TTL 缓存（首页 20 min、专辑 1 h、歌词 7 天）+ 32 项 LRU + 磁盘 JSON + epoch 失效；歌单 500 首一页、4 并发 |
| 音频 | `lib/audio/`（24 文件）+ `native/lazer-audio/` | `AudioEngine` 接口；原生引擎经 `dart:ffi`（ABI **29**）跑在独立 isolate；失败回落 just_audio/media_kit；WASAPI/CoreAudio/ALSA/AAudio 后端 |
| 界面 | `lib/ui/`（19 文件 13,849 行）+ `lib/widgets/`（43 文件 9,889 行） | `AppShell` 自建导航（无 router）：8 层自定义历史 + `PopScope`；Apple 语义色/字阶/弹簧；桌面 236 dp 侧栏 vs 手机 tab |
| 平台外设 | `tv/`、`watch/`、`accessibility/`、`updates/`、`l10n/` | D-pad 几何遍历、LAN 遥控 HTTP 服务、手表壳、桌面语义树事务化、4 语言 774 键 JSON |
| 原生构建 | `ci/`、`tool/` | Android/iOS 引擎 staging、AppImage/EXE 打包、签名校验、i18n 检查器 |

### 三条关键数据流

1. **播放**：`playTrackAt`（`app_state.dart:2588`）→ 本地库优先取文件，否则 `catalog.audioUrlFor(quality)`（`:2617`）→ `setQueue([url])`/`setUrl`（`:2652-2668`）→ 非本地先攒 10 s（`startupBuffer` `:2701`，25 s 上限 `:2706`）→ `play`（`:3035`）。
2. **目录**：`Catalog._cached(key, ttl)`（`catalog.dart:179`）先内存 LRU 再磁盘 JSON，失败回退过期副本；`_expire` bump epoch（`:156-163`）防止在途响应回填。
3. **登录**：QR 走明文 `/api/` 面（`docs/login-qr.md:45-51`）→ cookie 经 12 名单规范化（`transport.dart:84-113`）→ 明文写入 `SharedPreferences`（`app_state.dart:1922`，读回 `:1667`）→ 目录用 cookie 的 sha256 做缓存 scope（`catalog.dart:166-172`）。

## 3. 审查发现

严重度定义：P0 = 影响发布/可复现性；P1 = 正确性、安全或维护性风险；P2 = 一致性与卫生问题。
本次只记录，不修复。

### P0

1. **许可冲突。** `LICENSE:1` 是 MIT，但 `lib/lyrics/viewport.dart:4`、`spring.dart:1`、`word_motion.dart:1`、`timed_line.dart:1` 标 `AGPL-3.0-or-later`；`lib/easter_egg/still_alive_score.dart:1`、`still_alive_data.dart:1` 标 `GPL-3.0-or-later`。AGPL 全文随包分发（`licenses/lyric_animation/AGPL-3.0.txt`）并在应用内展示（`main.dart:83-91`）。README 只写"歌词动画参考 AMLL/Apple Music Like Lyrics"。是否可这样发布是维护者/法务决定。**（已按 AGPL-3.0 处理，见 §7）**
2. **Android UAC2 是死代码。** `native/lazer-audio/CMakeLists.txt:67-77` 建 `lazer-uac2`（libusb + JNI），但 `ci/build-android-audio.sh:29-36` 只 stage `liblazer-audio.so` 与 bridge；Kotlin/Dart 侧零引用（`grep -rn "uac2\|UAC2" lib android` 无结果）。该分支默认 `OFF`，打包路径也不会进入，**初稿中"每次 Android 构建引入 libusb FetchContent 网络依赖"的说法有误**，已在 §7 更正并降级为 P2。
3. **本地不可复现构建。** 仓库不含 SDK；`README.md` 只给 `pub get/analyze/test/run`；Linux 依赖只在 CI 里（`build.yml:332-340`）；原生引擎需现场编 FFmpeg（`native/lazer-audio/tools/build_dsd_ffmpeg.sh`）。本机 WSL 初始无 flutter/dart/cmake/clang/ninja/pkg-config/GTK/unzip。**（已处理，见 §7）**

### P1

4. **单例上帝对象。** `AppState` 3,720 行、111 个 `Future` 方法、100 处通知，域与视觉偏好全耦合；外壳在每次结构通知时重建整棵页面体（`ui/shell.dart:227-258`），正在播放页整页 `AnimatedBuilder(state)`（`player/now_playing_page.dart:706-708`），设置页干脆不监听（`ui/settings_page.dart:49-74`）。
5. **传输层无重试/退避/429 处理。** `gateway/transport.dart` 单次请求即返回，`requestTimeout` 只包住连接与 `close()`；body 读取 `await response.transform(utf8.decoder).join()`（`transport.dart:453`）没有超时，半开连接可无限挂起。目录层反而有 4 路歌单并发（`catalog.dart:1152-1157`）与 8 路一批的榜单搜索（`:896-912`），代码注释自述曾把搜索主机打到拒整版（`:928-931`）。
6. **会话 cookie 明文落盘。** 整条 Cookie 写进 `SharedPreferences`（键 `lazer_gateway_cookie`，`app_state.dart:442`/`:1922`，读回 `:1667`），无 secure storage；备份/同机读取即可重放账号。
7. **输出设备选择无效。** 设备 token 一路传到 worker，但 `lazer_audio_worker.dart:111-116` 明确说明它只作诊断，`_writeDevice`（`:532-541`）把 `deviceId` 硬写 `nullptr`；engine 实际接受宽字符 `device_id`（`engine.cpp:196-201`）。
8. **设置改动静默失效。** `Engine::setDevice` 只在 Idle/Stopped/Failed 接受（`engine.cpp:1166-1168`），Dart 丢弃返回码（`lazer_audio_engine.dart:474-483`），播放中改独占/bit-perfect/DSD 只改了 UI。
9. **`last_error` 指针竞态。** `api.cpp:175-178` 返回另一线程会重写的 `std::string::c_str()`，Dart 逐字节遍历（`lazer_audio_abi.dart:629-638`），可能读到撕裂内容。
10. **无路由/深链/状态恢复。** `MaterialApp` 只有 `home`（`main.dart:316`），进程被杀丢位置；启动失败没有用户可见面（`bootstrap()` unawaited）。
11. **测试闸门部分空转。** `test/goldens/` 3 张 PNG 零 `matchesGoldenFile`；`integration_test/ios_native_engine_test.dart` 从未被 workflow 调用；`tool/check_i18n.py` 未接入 CI（只在 `docs/i18n.md` 出现）。

### P2

12. **文档漂移。** `docs/audio-engine.md:60` 写 ABI v24，头文件是 29（`native/lazer-audio/include/lazer_audio_api.h:33`）；`docs/audio-engine.md:55` 引用的 `THIRD-PARTY-NOTICES.md` 不存在；`README.md:23` 徽章 v2.0.0 vs `pubspec.yaml:19` 的 `2.0.0-beta.5.hotfix+7`；`pubspec.yaml:2` 仍是模板描述。
13. **死代码/孤儿资产。** `lib/screens/catalog_detail_page.dart` 无任何 import；3 张 golden 未使用。
14. **三套设计词汇并存。** `theme/tokens.dart`（lake-blue `AppTokens`）、`theme/design_tokens.dart` + `theme/paper_widgets.dart`（暖羊皮纸，播放页仍在用）、`theme/apple_design.dart`（Apple 语义色）。
15. **版本约束不一致。** `pubspec.yaml:22` 写 `^3.12.0`，`pubspec.lock` 要求 dart `>=3.13.0` / flutter `>=3.47.0`，而 7 处 CI 用 `--enforce-lockfile`。
16. **Navidrome 会话不可持久化。** `NavidromeSession.toJson` 存在（`gateway/navidrome_transport.dart:98-103`）但从未写入，重启必须重新登录（有意的安全取舍，但接口是个陷阱）。

## 4. 本地验证基线

环境：WSL（Debian 13 trixie），`/home/seele/toolchains/flutter-3.47.0`，不修改 `~/.bashrc`，按需 `export PATH`。

```bash
export PATH=/home/seele/toolchains/flutter-3.47.0/bin:$PATH
cd /home/seele/workspace/Lazer
flutter pub get --enforce-lockfile
flutter analyze --no-pub
flutter test --no-pub --reporter expanded
```

| 步骤 | 结果 |
| --- | --- |
| SDK 校验 | `flutter_linux_3.47.0-stable.tar.xz` 1,572,146,400 B，sha256 `26cd99d3…ab75296` 通过；解压 2.5 GiB；`flutter --version` = 3.47.0 / Dart 3.13.0 / revision `4cf2416426` |
| `pub get --enforce-lockfile` | **通过**，exit 0（约 42 s）；16 个包有更新但受 lock 约束限制 |
| `flutter analyze --no-pub` | **0 issues**（`No issues found!`，约 19 s） |
| `flutter test --no-pub` | **1056 passed / 0 failed**，`All tests passed!`（3 min 24 s） |

日志：`build/review/analyze.log`、`build/review/test.log`（`/build/` 已被 gitignore）。

## 5. 候选修复（只列不修，按 ROI 排序）

1. 文档漂移一次清（§3.12、§3.13），并给 CI 加 `tool/check_i18n.py` 与 golden 断言（§3.11）——零业务风险、立刻可验证。
2. `transport.dart` 给 body 读取加超时与一次重试/退避，给 429 单独分支（§3.5）——小改动，直接改善弱网与限流下的体验。
3. `_writeDevice` 真正转发 `device_id`，并检查 `setDevice` 返回码后回显（§3.7、§3.8）——影响 Hi-Fi 用户的核心承诺。
4. `last_error` 改为调用方提供缓冲区或返回不可变快照（§3.9）——FFI 安全。
5. 会话 cookie 迁移到系统安全存储（§3.6）——需要平台插件，改动面中等。
6. `AppState` 按域拆分 notifier / 引入不可变快照（§3.4）——长期重构，需单独立项。
7. 许可问题（§3.1）已按维护者决定改为 AGPL-3.0（§7）；UAC2 取舍（§3.2）改为文档化（§7），是否接入 API 需要产品决策。

## 6. 复现本次审查

```bash
git -C /home/seele/workspace/Lazer log --oneline -1       # 7c56023
find lib -name '*.dart' | wc -l                           # 208
find lib -name '*.dart' -exec cat {} + | wc -l            # 71989
grep -rn "SPDX-License-Identifier" lib/                    # 6 处，见 §3.1
grep -c "case '" lib/gateway/routes.dart                   # 59
grep -rn "matchesGoldenFile" test lib                      # 0
grep -rn "uac2\|UAC2" --include='*.kt' --include='*.dart' lib android   # 0
```

## 7. 修复与勘误（2026-11-04，审查后立即执行）

分支 `review/2026-11-04`，只改文档/许可/工具脚本，未改业务代码。

**P0-1 许可 → 已处理。** `LICENSE` 由 MIT 换成 GNU AGPL-3.0（677 行 = 15 行前言 + 空行 + 标准 AGPL-3.0 正文；正文与 `licenses/lyric_animation/AGPL-3.0.txt` 第 6 行起 `cmp` 逐字节一致）。新增 `THIRD-PARTY-NOTICES.md`，六项逐条按仓库实况核对：AMLL 歌词动画（AGPL-3.0-or-later）、Still Alive（GPL-3.0-or-later）、MiSans、Twilight Echo crossfeed（Apache-2.0）、FFmpeg（LGPL-2.1-or-later）、libmpv（仓库未写明，标 see upstream）。README 中英双语徽章、页脚与"参考与致谢"入口同步；`docs/audio-engine.md:55` 引用的 `THIRD-PARTY-NOTICES.md` 至此真实存在。选 AGPL 而非 GPL 的理由：4 个歌词文件是 `AGPL-3.0-or-later`，GPLv3 无法吸收 AGPLv3 代码，整体取 AGPL 才自洽。

**P0-2 → 更正并降级为 P2。** 初稿的"每次 Android 构建引入 libusb FetchContent 网络依赖"**不成立**：`native/lazer-audio/CMakeLists.txt:10` 的 `LAZER_ANDROID_BUILD_UAC2` 默认 `OFF`，且 `native/CMakeLists.txt:122-123` 在 Android + 可用 FFmpeg 时强制 `LAZER_ANDROID_BUILD_ENGINE=ON`，`if(ANDROID AND NOT LAZER_ANDROID_BUILD_ENGINE)`（`:9`）分支根本不会进入；`ci/build-android-audio.sh:25` 只构建 `lazer-audio` 与桥两个目标。真实问题只剩"源码在树上但未接入"，按 P2 记录。已在 `docs/android-audio.md` 新增「USB Audio Class 2 (UAC2) transport (not shipped)」：现状、为何不进 APK（带 `file:line`）、本地构建命令、上线还差什么。

**P0-3 可复现构建 → 已处理。** 新增 `tool/check_toolchain.sh`（校验 Flutter 3.47.0 / Dart 3.13.0 与必需二进制；`--build` 额外检查桌面依赖；硬依赖缺失 exit 1）与 `docs/local-build.md`（SDK 下载 URL/字节数/sha256、WSL 快速开始、基线数字、可选 GTK/FFmpeg、四条排错）；`docs/builds.md` 末尾增加 8 行本地开发入口。

**验收记录（本次实测）。**

| 项 | 结果 |
| --- | --- |
| `tool/check_toolchain.sh`（带 SDK） | `0 failed / 0 warnings / 10 ok`，exit 0 |
| 同上（去掉 SDK） | `2 failed`（flutter、dart），exit 1 |
| 同上 `--build` | `0 failed / 7 warnings`（本机无 clang/cmake/ninja/pkg-config） |
| `bash -n tool/check_toolchain.sh` | 通过 |
| `LICENSE` 完整性 | 677 行；`tail -n +17` 与 AGPL 正本 `cmp` 一致；无 MIT 残留（`grep -nw MIT` 空） |
| 改动后 `flutter analyze --no-pub` | 0 issues |
| 改动后 `flutter test --no-pub` | 1056 passed / 0 failed |
