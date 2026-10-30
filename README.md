<p align="center">
  <img src="docs/images/mascot.png" width="220" alt="The Lazer mascot">
</p>

<h1 align="center">Lazer · nextgen</h1>

<h3 align="center">
  交流群：<a href="https://qm.qq.com/q/JJJfE0QV00">神秘交流群 · 1063238023</a>
</h3>

<p align="center">
  <a href="https://qm.qq.com/q/JJJfE0QV00"><img alt="QQ 群：1063238023" src="https://img.shields.io/badge/QQ%E7%BE%A4-1063238023-12B7F5?style=for-the-badge&logo=tencentqq&logoColor=white"></a>
</p>

<p align="center">
  <a href="https://github.com/chuxuehaocai/Lazer/actions/workflows/build.yml"><img alt="build" src="https://img.shields.io/badge/build-GitHub%20Actions-6C8EBF"></a>
  <img alt="Flutter" src="https://img.shields.io/badge/Flutter-3.47.0-54C5F8?logo=flutter&logoColor=white">
  <img alt="version" src="https://img.shields.io/badge/nextgen-v2.0.0-8E7CC3">
  <img alt="platforms" src="https://img.shields.io/badge/Windows%20%C2%B7%20macOS%20%C2%B7%20Linux%20%C2%B7%20Android%20%C2%B7%20iOS-7FB6A4">
  <a href="LICENSE"><img alt="license" src="https://img.shields.io/badge/license-MIT-4C9A7A"></a>
</p>

<p align="center">
  <b>一个用 Flutter 手写的网易云音乐客户端。</b><br>
  WEAPI / EAPI 就住在客户端里，不挂任何第三方网关，<br>
  曲库、歌词、评论、私人雷达，都从服务本身现取。
</p>

<p align="center">简体中文 | <a href="README.en.md">English</a></p>

---

## 它都会些什么

**听歌这件事**

- 真实曲库、搜索、推荐歌单、私人雷达、账号与收藏。
- 歌手主页有热门歌曲和分页专辑；专辑详情带简介与完整曲目，点名字就钻进去了。
- 热门 / 最新评论、分页加载、点赞与取消点赞。游客可以看，想说话就先登录。
- 系统媒体控件：Windows、macOS、Linux、Android、iOS 都认得它。

**歌词这件小事**

- LRC / YRC 解析、逐字 emphasized 弹簧、35% 焦点带、渐进遮罩与距离模糊。
- 字号、字重随手调，改完立刻预览；多选复制、导出成 PNG 也可以。
- 跟着音乐滚，手动翻过歌词后会平滑地回到跟随。

**界面这件事**

- 全页面 Apple 设计语言：语义化系统色与字阶、玻璃导航、分组列表、Apple Music 红，还有从封面取色的主题。
- 桌面是侧边栏 + 完整播放条，手机是底部标签栏 + 迷你播放器——同一套页面与状态，换个姿势陪你听。
- 布局可以强制桌面 / 移动，DPI 80–175%，车机形态自动放大到 135%。
- 大屏幕模式：电视和投影自动进入，遥控器方向键在封面货架、资料库网格与播放条之间按位置移动。
- 简体中文、繁体中文、日语、英语四种界面。

**细节这件事**

- 滚动惯性与加速度可调，进度条刻度带触感反馈。
- 界面动画按 10 ms（100 fps）的帧预算排队，流动背景按设置里的渲染精度分档更新（默认约 21 次/秒）；设置里能打开实时帧率浮层。
- 正在播放页有 AMLL 网格背景、封面与歌词互切、队列与评论面板，还有 M / L / Q / C / F 一把快捷键。

## 长这样

<table>
  <tr>
    <td align="center" width="50%"><img src="docs/images/shot-home.jpg" width="100%" alt="首页：现在就听"></td>
    <td align="center" width="50%"><img src="docs/images/shot-library.jpg" width="100%" alt="曲库：真实曲库"></td>
  </tr>
  <tr>
    <td align="center"><b>现在就听</b><br><sub>推荐歌单、私人雷达与每日推荐，打开就在第一屏。</sub></td>
    <td align="center"><b>真实曲库</b><br><sub>搜索、歌手、专辑与收藏，全部读自服务本身。</sub></td>
  </tr>
  <tr>
    <td align="center"><img src="docs/images/shot-playing.jpg" width="100%" alt="正在播放：沉浸式播放"></td>
    <td align="center"><img src="docs/images/shot-adaptive.jpg" width="100%" alt="自适应：一套页面"></td>
  </tr>
  <tr>
    <td align="center"><b>沉浸式播放</b><br><sub>AMLL 逐字歌词、35% 焦点带，与弹簧跟随滚动。</sub></td>
    <td align="center"><b>一套页面</b><br><sub>桌面侧栏与移动标签栏，共享同一份页面与状态。</sub></td>
  </tr>
</table>

## 开始折腾

需要 **Flutter 3.47.0 stable**。

```sh
flutter pub get
flutter analyze
flutter test
flutter run
```

## 自动构建

向 `nextgen` 推送代码后，[GitHub Actions](https://github.com/chuxuehaocai/Lazer/actions/workflows/build.yml)
会先检查代码，再构建下面的产物。推送 `v*` 版本标签会在所有构建成功后自动创建 GitHub Release；
带 `-beta.1` 等后缀的版本会标为预发布。文件名统一为 `Lazer-<系统>-<架构>`。

| 产物 | 说明 |
| --- | --- |
| `Lazer-Windows-x86_64.zip` | EXE、依赖库、资源与 Visual C++ 运行库 |
| `Lazer-macOS-universal.zip` | Intel / Apple Silicon 通用 App |
| `Lazer-macOS-x86_64.zip` | Intel App，使用原生 Intel runner 构建 |
| `Lazer-Linux-x86_64.AppImage` | Linux x86_64，包含 GTK 与 libmpv |
| `Lazer-Linux-aarch64.AppImage` | Linux ARM64，使用原生 ARM runner 构建 |
| `Lazer-Android-universal.apk` | 通用 APK，使用仓库密钥库中的发布签名（详见[构建说明](docs/builds.md#android-release-signing)） |
| `Lazer-iOS-aarch64.ipa` | 未签名的 iOS 真机 IPA |

构建完成后，在对应运行页面的 **Artifacts** 中下载，需登录 GitHub，保留 30 天。
Windows 请完整解压后运行；AppImage 下载后先 `chmod +x`；
macOS 包使用 ad-hoc 签名，IPA 需要自行签名后安装。

更多说明书：[构建说明](docs/builds.md) · [系统媒体控件](docs/system-media.md) · [正在播放](docs/now-playing.md) · [车机形态](docs/car-head-unit.md) · [大屏幕模式（Android TV）](docs/android-tv.md) · [扫码登录](docs/login-qr.md) · [验证码登录](docs/login-sms.md) · [旧版界面](docs/legacy-ui.md)

## 参考与致谢

- 接口实现参考 [API Enhanced](https://github.com/NeteaseCloudMusicApiEnhanced/api-enhanced)。
- 正在播放页版式参考 [AMLL Player](https://github.com/amll-dev/amll-player)。
- 歌词动画参考 [Apple Music Like Lyrics](https://github.com/amll-dev/applemusic-like-lyrics)。
- 界面字体是小米的 **MiSans**，谢谢你，MiSans。
- 还有屏幕前的你：愿意把它下载下来，认真听完一首歌，就已经很好了。

<p align="center">
  <img src="docs/images/mark.png" width="44" alt="Lazer">
  <br>
  <sub>MIT License · 用 Flutter 和一点点耐心做成</sub>
</p>
