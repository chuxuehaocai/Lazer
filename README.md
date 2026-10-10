<p align="center">
  <img src="./newicon.png" alt="Lazer icon" width="128" height="128">
</p>

<h1 align="center">Lazer</h1>

<p align="center">一个安静、专注的跨平台音乐播放器。</p>

<p align="center">
  <strong>Android</strong> · <strong>iOS</strong> · <strong>Desktop</strong>
</p>

## 项目简介

Lazer 是一个基于 Kotlin Multiplatform 和 Compose Multiplatform 构建的音乐客户端。项目将界面与核心 Gateway 数据模型放在共享模块中，再通过 Android、iOS 和 JVM Desktop 平台实现播放、持久化和系统集成。

API Gateway 已内置于共享模块中，直接与音乐服务通信，无需部署或配置额外的云端 Gateway 服务。

## Screenshot

### 移动端

<p align="center">
  <img src="./pics/mobile-home.jpg" alt="Lazer 移动端主页" width="240">
  <img src="./pics/mobile-lyrics.jpg" alt="Lazer 移动端歌词" width="240">
  <img src="./pics/mobile-cover.jpg" alt="Lazer 移动端大封面" width="240">
</p>

### 桌面端

<p align="center">
  <img src="./pics/desktop-home.png" alt="Lazer 桌面端主页" width="420">
  <img src="./pics/desktop-lyrics.png" alt="Lazer 桌面端歌词" width="420">
  <img src="./pics/desktop-settings.png" alt="Lazer 桌面端设置" width="420">
</p>

<p align="center">
  <img src="./pics/windows-taskbar-thumbnail.png" alt="Windows 任务栏媒体控制预览" width="230">
  <img src="./pics/windows-taskbar-menu.png" alt="Windows 任务栏右键菜单" width="280">
</p>

## 功能

- 音乐搜索、热门发现和推荐内容浏览
- 歌单浏览，支持登录后同步个人歌单
- 歌曲播放、暂停、上一首、下一首、进度跳转和音量控制
- Android 前台播放服务与通知栏媒体控制
- Desktop 系统媒体会话与媒体按键控制
- LRC 歌词解析、翻译歌词合并和播放进度跟随
- QR 登录、手机号验证码登录、手机号密码登录和邮箱登录
- 登录状态持久化，退出登录时清理本地会话
- 歌单、歌曲和音频缓存，优先恢复本地内容再刷新网络数据
- 浅色/深色主题、Material 3 与 MIUIX 主题引擎切换
- Desktop 支持 Windows ARM64、Windows x64，以及 macOS/Linux 原生分发格式

## 技术栈

| 技术 | 版本 | 说明 |
|:---|:---|:---|
| [![Kotlin](https://img.shields.io/badge/Kotlin-2.4.10-7F52FF?style=flat-square&logo=kotlin&logoColor=white)](https://kotlinlang.org/) | 2.4.10 | 编程语言 |
| [![Kotlin Multiplatform](https://img.shields.io/badge/Kotlin_Multiplatform-7F52FF?style=flat-square&logo=kotlin&logoColor=white)](https://www.jetbrains.com/kotlin-multiplatform/) | — | 跨平台框架 |
| [![Compose Multiplatform](https://img.shields.io/badge/Compose_Multiplatform-1.10.3-0827D5?style=flat-square&logo=jetpackcompose&logoColor=white)](https://www.jetbrains.com/lifecycle/compose-multiplatform/) | 1.10.3 | 声明式 UI 框架 |
| [![Compose Material 3](https://img.shields.io/badge/Compose_Material_3-6750A4?style=flat-square&logo=materialdesign&logoColor=white)](https://m3.material.io/) | — | Material 3 组件库 |
| [![Ktor](https://img.shields.io/badge/Ktor-3.5.2-087CFA?style=flat-square&logo=ktor&logoColor=white)](https://ktor.io/) | 3.5.2 | 网络请求框架 |
| [![Kotlinx Serialization](https://img.shields.io/badge/Kotlinx_Serialization-1.11.0-7F52FF?style=flat-square&logo=kotlin&logoColor=white)](https://github.com/Kotlin/kotlinx.serialization) | 1.11.0 | JSON 数据序列化 |
| [![Coil](https://img.shields.io/badge/Coil-3.4.0-4CAF50?style=flat-square&logo=coil&logoColor=white)](https://coil-kt.github.io/coil/) | 3.4.0 | 图片加载 |
| [![ZXing](https://img.shields.io/badge/ZXing-3.5.4-1665C0?style=flat-square&logoColor=white)](https://github.com/zxing/zxing) | 3.5.4 | Desktop 二维码生成 |
| [![JavaMP3](https://img.shields.io/badge/JavaMP3-1.0.1-00629B?style=flat-square&logoColor=white)](https://github.com/delthas/javamp3) | 1.0.1 | Desktop 音频解码 |
| ![Nucleus Media Control](https://img.shields.io/badge/Nucleus_Media_Control-2.5.0-6E7681?style=flat-square&logoColor=white) | 2.5.0 | Desktop 系统媒体控制 |
| [![Gradle Wrapper](https://img.shields.io/badge/Gradle_Wrapper-02303A?style=flat-square&logo=gradle&logoColor=white)](https://gradle.org/) | — | 构建工具，通常无需单独安装 |

## 项目结构

```text
Lazer/
├── androidApp/                         # Android 应用、播放服务和 Android 平台存储
├── desktopApp/                         # JVM Desktop 应用、音频播放器和系统媒体控制
├── iosApp/                             # iOS SwiftUI 入口与 Xcode 工程
├── shared/                             # 共享 UI、Gateway、数据模型、主题和跨平台逻辑
│   └── src/
│       ├── commonMain/                 # 所有平台共享代码
│       ├── commonTest/                 # 共享单元测试
│       ├── androidMain/                # Android 网络实现
│       ├── iosMain/                    # iOS 网络与 Compose 入口
│       └── jvmMain/                    # Desktop 网络实现
├── gradle/                             # Version Catalog 与 Gradle 配置
├── newicon.png                         # 项目图标
└── run-desktop.bat                     # Windows Desktop 快捷启动脚本
```

## 环境要求

- JDK 11 或更高版本
- Android Studio（Android 开发与构建）
- Xcode（仅 macOS，iOS 开发与构建）

项目使用 Gradle Wrapper，通常不需要单独安装 Gradle。

Windows 桌面端还需要 CMake 和 Visual Studio 2022 的「使用 C++ 的桌面开发」工作负载：`runDesktop`、`run`
与打包任务会先编译 `native/windows-taskbar` 里的任务栏媒体控制桥。CMake 若来自 Visual Studio 安装目录，
需要把它的 `bin` 目录加入 `PATH`，否则构建会停在 `:desktopApp:configureWindowsTaskbarBridge`。
生成器默认是 `Visual Studio 17 2022`，其他工具链用 `-PnativeCmakeGenerator=<生成器>` 覆盖。

## 快速开始

### Android

构建 Debug APK：

```bash
./gradlew :androidApp:assembleDebug
```

Windows PowerShell：

```powershell
.\gradlew.bat :androidApp:assembleDebug
```

生成的构建产物位于 `androidApp/build/outputs/` 下。

### Desktop

标准运行：

```bash
./gradlew :desktopApp:run
```

Windows ARM64 或 IntelliJ IDEA 中运行：

```bash
./gradlew :desktopApp:runDesktop
```

Windows 也可以直接执行：

```bat
run-desktop.bat
```

开发期间启用自动重载：

```bash
./gradlew :desktopApp:hotRun --auto
```

指定 Windows 原生架构：

```bash
./gradlew :desktopApp:runDesktop -PwindowsArch=x64
./gradlew :desktopApp:runDesktop -PwindowsArch=arm64
```

### iOS

iOS 目标仅在 macOS 主机上注册。使用 Xcode 打开 [`iosApp`](./iosApp) 目录，然后选择模拟器或已连接设备运行。

## 测试

运行共享模块的 Android Host 测试：

```bash
./gradlew :shared:testAndroidHostTest
```

运行 Desktop/JVM 测试：

```bash
./gradlew :shared:jvmTest
./gradlew :desktopApp:test
```

在 macOS 上运行 iOS Simulator 测试：

```bash
./gradlew :shared:iosSimulatorArm64Test
```

## Gateway 连接

应用已内置 API Gateway，开箱即用，无需额外配置。登录会话 Cookie 会在各平台的安全存储中持久化，登录后自动生效。

## 发布构建

### Desktop 分发包

Desktop 配置了以下原生分发格式：

- Windows MSI
- macOS DMG
- Linux DEB

构建全部 Desktop 分发包：

```bash
./gradlew :desktopApp:createDistributable
```

Windows 图标资源位于 [`desktopApp/src/main/resources/icon.ico`](./desktopApp/src/main/resources/icon.ico)，Linux 原生分发包与运行时窗口图标使用 [`icon.png`](./desktopApp/src/main/resources/icon.png)。

### Android Release

Release 构建要求签名配置。可以通过环境变量提供：

```text
LAZER_KEYSTORE_FILE
LAZER_KEYSTORE_PASSWORD
LAZER_KEY_ALIAS
LAZER_KEY_PASSWORD
```

也可以在项目根目录创建 `keystore.properties`，字段名对应 `storeFile`、`storePassword`、`keyAlias` 和 `keyPassword`。请勿将真实密钥、密码或签名文件提交到版本库。

### iOS Release (IPA)

CI 会自动为真机设备打包未签名的安装包（`.ipa`）。因未配置开发者证书，真机安装需自行签名：

- 支持使用 [AltStore](https://altstore.io/)、SideStore 或 TrollStore 等侧载工具；
- 每次 Release 发布说明中附有详细的 AltStore 自签名安装操作指引。

## 数据与隐私

- Gateway 登录会话保存在平台私有存储中
- Android 会话使用 Android Keystore 保护
- Desktop 会话保存在用户目录下的 `.lazer/state.properties`
- Desktop 播放日志不会记录音频流 URL、账户信息或凭据
- Gateway 请求失败时会避免在异常信息中暴露会话 Cookie

## 开发约定

- 共享功能优先放入 `shared` 模块，平台专属能力放入对应的 `androidMain`、`iosMain` 或 `jvmMain`
- 颜色、排版、间距和交互优先复用 `LazerTheme.kt` 中的设计令牌
- 用户可见文案使用简洁自然的中文
- 内置 Gateway 的新增路由需同时补充协议编码与传输映射，并在 `shared` 的网关测试中覆盖
- 不要提交 `build/`、本地配置、密钥、密码或发布签名文件

## 许可证

本项目采用 [MIT License](./LICENSE) 开源。 Copyright (c) 2026 Lazer contributors。
