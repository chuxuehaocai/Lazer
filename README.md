<p align="center">
  <img src="docs/images/mascot.png" width="220" alt="The Lazer mascot">
</p>

<h1 align="center">Lazer</h1>

<h3 align="center">
  交流群：<a href="https://qm.qq.com/q/JJJfE0QV00">神秘交流群 · 1063238023</a>
</h3>

<p align="center">
  <a href="https://qm.qq.com/q/JJJfE0QV00"><img alt="QQ 群：1063238023" src="https://img.shields.io/badge/QQ%E7%BE%A4-1063238023-12B7F5?style=for-the-badge&logo=tencentqq&logoColor=white"></a>
</p>

<p align="center">
  <a href="https://github.com/chuxuehaocai/Lazer/actions/workflows/build.yml"><img alt="build" src="https://img.shields.io/badge/build-GitHub%20Actions-6C8EBF"></a>
  <img alt="Flutter" src="https://img.shields.io/badge/Flutter-3.47.0-54C5F8?logo=flutter&logoColor=white">
  <img alt="version" src="https://img.shields.io/badge/Lazer-v2.0.0-8E7CC3">
  <img alt="platforms" src="https://img.shields.io/badge/Windows%20%C2%B7%20macOS%20%C2%B7%20Linux%20%C2%B7%20Android%20%C2%B7%20iOS-7FB6A4">
  <img alt="web demo" src="https://img.shields.io/badge/Web%20Demo-Vercel-000000">
  <a href="LICENSE"><img alt="license" src="https://img.shields.io/badge/license-AGPL--3.0--or--later-4C9A7A"></a>
</p>

<p align="center">
  <b>一个用 Flutter 手写的音乐客户端。</b><br>
</p>

<p align="center">简体中文 | <a href="README.en.md">English</a></p>

---

## 它都会些什么

**听歌这件事**

- 真实曲库、搜索、推荐歌单、私人雷达、账号与收藏。
- 歌手主页有热门歌曲和分页专辑；专辑详情带简介与完整曲目，点名字就钻进去了。
- 收藏的专辑在资料库单独成页：封面墙随滚动续页，按专辑名、歌手一筛就找到想听的那张。
- 热门 / 最新评论、分页加载、点赞与取消点赞。游客可以看，想说话就先登录。
- 网络源：WebDAV、SMB、SFTP、FTP 直接连 NAS，浏览、整目录播放、扫描入库；网络电台和 RSS 播客订阅在同一页，播客记得每一集听到哪。
- 系统媒体控件：Windows、macOS、Linux、Android、iOS 都认得它；通知、锁屏与灵动岛会跟着唱到哪一句。

**歌词这件小事**

- LRC / YRC 解析、逐字 emphasized 弹簧、35% 焦点带、渐进遮罩与距离模糊。
- 字号、字重随手调，改完立刻预览；多选复制、导出成 PNG 也可以。
- 跟着音乐滚，手动翻过歌词后会平滑地回到跟随。

**界面这件事**

- 全平台共用一套 Apple 风格界面、主题与弹簧动画：语义化系统色与字阶、玻璃导航、分组列表，还有从封面取色的主题。
- 桌面是侧边栏 + 完整播放条，手机是底部标签栏 + 迷你播放器——同一套页面与状态，换个姿势陪你听。
- 布局可以强制桌面 / 移动，DPI 80–175%，车机形态自动放大到 135%。
- 大屏幕模式：电视和投影自动进入，遥控器方向键在封面货架、资料库网格与播放条之间按位置移动。
- 简体中文、繁体中文、日语、英语四种界面。

**细节这件事**

- 滚动惯性与加速度可调，进度条刻度带触感反馈。
- 没缓存的歌先攒够十秒再开口，开头不再一顿一顿；已下载和已缓存的歌照旧秒开。
- 页面、弹窗和控件采用可中途打断、反向衔接的弹簧动画；拖动直接跟手，松手后延续当前速度，支持减少动态效果。
- 浏览背景默认限制为 30fps，播放背景默认跟随屏幕刷新率，帧率和渲染精度分别设置；隐藏页面和静态背景停止持续绘制。设置里能打开实时帧率浮层。
- 正在播放页有 AMLL 网格背景、封面与歌词互切、队列与评论面板，还有 M / L / Q / C / F 一把快捷键。
- 定时停止支持多个每天重复的时间点。到点暂停一次并保留队列和进度，之后可手动继续。

## 开始折腾

需要 **Flutter 3.47.0 stable**。

```sh
flutter pub get
flutter analyze
flutter test
flutter run
```

### Web 版与 Vercel 部署

Web 版直接由本仓库的 `lib/main.dart` 编译，和桌面、移动端共用同一套 Dart UI、插件运行时与状态层。线上地址是 [player.naominet.dev](https://player.naominet.dev)。

> 中国大陆访问：Flutter Web 默认从 `www.gstatic.com` 加载 CanvasKit，该域名在大陆不可达，首次打开会一直停在加载页。构建时必须加 `--no-web-resources-cdn`，让 CanvasKit 跟随站点一起部署到 `build/web/canvaskit/`。

```sh
# 1. 在本仓库构建静态站点
flutter pub get
flutter build web --release --no-web-resources-cdn

# 2. 用 lazer_demo 壳工程打包 Vercel 预构建产物
#    （它提供 /api/plugin-http 同源转发函数）
cd ../lazer_ncm/lazer_demo
node tool/prepare-vercel-output.js

# 3. 部署到 Vercel（CLI 已登录）
vercel deploy --prebuilt --prod --project lazer_demo
```

首次在新账号部署需要先建项目并关闭 SSO 保护，否则公开域名会被登录页挡住：

```sh
vercel project create lazer_demo --non-interactive
vercel project protection disable lazer_demo --sso --yes
```

说明：

- 静态产物来自本仓库的 `build/web`；`lazer_demo` 只保留 Vercel Function 和打包脚本。打包脚本会给 CanvasKit 目录和 `main.dart.js` 生成内容哈希文件名，并配置 `immutable` 缓存，回访不再重复下载这几 MB 资源。
- `api/plugin-http.js` 只接受调用方插件清单声明的 HTTPS 域名，拒绝 loopback、私网、链路本地和 metadata 地址；转发时附加从 api-enhanced 国内网段生成的 `X-Real-IP` / `X-Forwarded-For`，浏览器不能自行覆盖这两个头。
- 上传的 Lua 插件按不受信任代码处理；生产环境仍应配置域名白名单、限流和日志脱敏。

## 自动构建

向 `nextgen` 推送代码后，[GitHub Actions](https://github.com/chuxuehaocai/Lazer/actions/workflows/build.yml)
会先检查代码，再构建下面的产物。推送 `v*` 版本标签会在所有构建成功后自动创建 GitHub Release；
带 `-beta.1` 等后缀的版本会标为预发布。文件名统一为 `Lazer-<系统>-<架构>`。

| 产物 | 说明 |
| --- | --- |
| `Lazer-Windows-x86_64.zip` | EXE、依赖库、资源与 Visual C++ 运行库 |
| `Lazer-macOS-aarch64.zip` | Apple Silicon App |
| `Lazer-Linux-x86_64.AppImage` | Linux x86_64，包含 GTK 与 libmpv |
| `Lazer-Linux-aarch64.AppImage` | Linux ARM64，使用原生 ARM runner 构建 |
| `Lazer-Android-universal.apk` | 通用 APK，使用仓库密钥库中的发布签名（详见[构建说明](docs/builds.md#android-release-signing)） |
| `Lazer-iOS-aarch64.ipa` | 未签名的 iOS 真机 IPA |

构建完成后，在对应运行页面的 **Artifacts** 中下载，需登录 GitHub，保留 30 天。
Windows 请完整解压后运行；AppImage 下载后先 `chmod +x`；
macOS 包使用 ad-hoc 签名，IPA 需要自行签名后安装。

更多说明书：[构建说明](docs/builds.md) · [系统媒体控件](docs/system-media.md) · [正在播放](docs/now-playing.md) · [定时停止](docs/scheduled-pause.md) · [车机形态](docs/car-head-unit.md) · [大屏幕模式（Android TV）](docs/android-tv.md) · [Lua 插件开发](docs/lua-plugins.md) · [音乐平台架构](docs/music-gateways.md) · [网络源](docs/network-sources.md) · [统一界面](docs/ui.md) · [第三方声明](THIRD-PARTY-NOTICES.md)

## 参考与致谢

- 正在播放页版式参考 [AMLL Player](https://github.com/amll-dev/amll-player)。
- 歌词动画参考 [Apple Music Like Lyrics](https://github.com/amll-dev/applemusic-like-lyrics)。
- 还有屏幕前的你

<p align="center">
  <img src="docs/images/mark.png" width="44" alt="Lazer">
  <br>
  <sub>AGPL-3.0-or-later · 第三方组件与素材见 THIRD-PARTY-NOTICES.md</sub>
</p>
