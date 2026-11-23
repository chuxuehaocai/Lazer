# Atelier — 声明式主题示例

一个只改外观、不改行为的 Lazer 皮肤插件。它演示主题契约的两半：`describe` 里声明 `theme = true`，随后由宿主调用 `theme` 操作取回主题令牌与布局令牌。

- 插件 ID：`example.theme-atelier`
- 主题 ID：`example.theme-atelier`
- 布局 ID：`example.layout.atelier`
- 清单 API：1
- 权限：无（不声明网络、存储、文件或数据权限）

完整开发文档：**<https://lazer.naominet.dev/docs>**

## 它是什么，不是什么

是：一组 JSON 形状的数值令牌，交给宿主去改变圆角、行高、标题字号、字重、玻璃模糊、页面边距、内容宽度和歌词动效。

不是：Flutter Widget、任意 UI 代码、颜色主题、图标包、页面模板，或替换整个应用进程的补丁。宿主仍然创建所有 Widget、焦点、语义树和导航；令牌只影响宿主已经暴露的参数。未知字段会被忽略，越界数值会被夹到允许范围，主题加载失败也不会影响同一插件或其它网关的启动。

## 工作原理

```text
插件启动
  → call("describe") 返回 { providers = {}, theme = true }
  → LuaThemeEngine.load() 看到 theme == true
  → call("theme") 返回 { theme = {...}, layout = {...} }
  → LazerThemeTokens.fromJson / LazerLayoutDefinition.fromJson 解码
  → PluginManager.activeTheme / activeLayout 生效
```

`providers = {}` 很重要：主题插件不提供音乐平台，所以不会在音源列表里出现一个空平台。

也可以把令牌直接内联在 `describe` 的 `theme` 字段里，省掉第二次调用；本示例选择 `theme` 操作，让令牌表留在独立模块中，便于阅读和替换。

## 文件

```text
theme-plugin/
├─ manifest.json   # 清单：id、provider、apiVersion，无任何权限
├─ main.lua        # describe + theme/skin 操作
├─ theme.lua       # 主题令牌与布局令牌
├─ README.md
└─ LICENSE
```

## 安装与启用

1. 在仓库根目录运行 `build.ps1`，得到 `dist/example.theme-atelier-1.0.0.zip`。
2. Lazer → 设置 → 插件管理 → 导入 ZIP → 启用。
3. 皮肤立即生效，无需重启。

同一时间只有一个已启用插件能提供主题：`PluginManager.activeTheme` 取第一个启动成功且带主题的插件。想切回内置外观，禁用本插件即可；禁用不会影响已经登录的网关、播放队列或本地文件。

修改 `theme.lua` 后需要重新打包并更新插件（或禁用再启用），宿主只在插件启动时读取一次皮肤。

## 主题令牌

`theme.lua` 当前值、宿主默认值与允许范围：

| 令牌 | 本示例 | 默认 | 范围 |
| --- | --- | --- | --- |
| `groupedCardRadius` | 22 | 14 | 0–40 |
| `listTileMinHeight` | 56 | 50 | 0–160 |
| `listTileVerticalPadding` | 10 | 11 | 0–48 |
| `pageTitleCompactSize` | 40 | 34 | 0–72 |
| `pageTitleRegularSize` | 38 | 32 | 0–72 |
| `sectionHeaderSize` | 22 | 20 | 0–48 |
| `displayWeight` | 800 | 700 | 100–900 |
| `headingWeight` | 700 | 700 | 100–900 |
| `titleWeight` | 700 | 600 | 100–900 |
| `bodyWeight` | 400 | 400 | 100–900 |
| `labelWeight` | 600 | 500 | 100–900 |
| `lyricWeight` | 600 | 继承 | 100–900 |
| `lyricTranslationWeight` | 400 | 继承 | 100–900 |
| `lyricFontScale` | 1.05 | 1 | 0.5–2 |
| `lyricTranslationScale` | 0.78 | 0.727 | 0.4–1.5 |
| `lyricLineHeight` | 1.6 | 1.5 | 0.8–3 |
| `lyricTranslationLineHeight` | 1.5 | 1.45 | 0.8–3 |
| `lyricTranslationGap` | 8 | 5 | 0–48 |
| `lyricDimAlpha` | 0.42 | 0.48 | 0–1 |
| `lyricTranslationAlpha` | 0.62 | 0.58 | 0–1 |
| `lyricTextAlign` | `center` | `start` | `start`/`center`/`end`/`justify` |
| `lyricSpringMassScale` | 0.9 | 1 | 0.25–4 |
| `lyricSpringStiffnessScale` | 1.15 | 1 | 0.25–4 |
| `lyricSpringDampingScale` | 0.92 | 1 | 0.25–4 |
| `lyricStaggerDelay` | 0.06 | 0.05 | 宿主限制 |
| `lyricStaggerDecay` | 1.04 | 1.05 | 宿主限制 |
| `lyricFocusScaleDelta` | 4 | 3 | 宿主限制 |
| `controlRadius` | 16 | 12 | 0–200 |
| `glassBlurSigma` | 22 | 16 | 0–48 |

## 布局令牌

| 令牌 | 本示例 | 默认 | 范围 |
| --- | --- | --- | --- |
| `compactInset` | 20 | 16 | 0–80 |
| `regularInset` | 32 | 24 | 0–120 |
| `tvInsetFactor` | 0.05 | 0.043 | 0–0.25 |
| `maxContentWidth` | 1240 | 1180 | 0–3000 |
| `tvMaxContentWidth` | 1680 | 1560 | 0–4000 |
| `tabletBreakpoint` | 760 | 700 | 320–1600 |

## 设计说明

- **没有颜色令牌**。主题契约只覆盖几何、排版和歌词运动，颜色与表面留给宿主，避免皮肤破坏对比度、可访问性和平台习惯。
- **字重是数值**。宿主把 100–900 映射到 Flutter 可用字重；`displayWeight = 800` 让大标题更重，`bodyWeight = 400` 保持正文可读。
- **歌词弹簧**。`lyricSpringStiffnessScale` 与 `lyricSpringDampingScale` 控制逐行高亮的回弹；`lyricStaggerDelay` / `lyricStaggerDecay` 控制相邻行的延迟衰减；`lyricFocusScaleDelta` 控制当前行放大。
- **居中歌词**。`lyricTextAlign = "center"` 配合更大的行高和翻译间距，是这套皮肤的辨识点。
- **布局宽度**。`maxContentWidth` 与 `tvMaxContentWidth` 都略高于默认值，桌面和平板上的内容更舒展；`compactInset` / `regularInset` 控制窄屏与宽屏边距。

## 修改建议

- 先只改一个维度（例如只调 `groupedCardRadius` 和 `controlRadius`），重新启用确认效果，再叠加字号和歌词参数。
- 想更紧凑：`compactInset` 14–16、`regularInset` 20–24、`maxContentWidth` 960–1080、`pageTitleRegularSize` 30–32。
- 想更戏剧化：`pageTitleCompactSize` 44–52、`displayWeight` 900、`lyricFocusScaleDelta` 5–6、`glassBlurSigma` 28–32。
- 改 `id` 或 `name` 会让宿主把它当成另一套皮肤；版本号变化会触发插件更新流程。示例保留稳定 ID，方便反复覆盖安装。

## 验证

- 启用后，标题字重、卡片圆角、页面边距和歌词居中应立即变化。
- 禁用后，`activeTheme` / `activeLayout` 变为空，界面回到 `builtin.apple` / `builtin.adaptive`。
- 在宿主测试中，`LuaThemeEngine.decode` 应返回 `example.theme-atelier` 和 `example.layout.atelier`；越界值（例如 `glassBlurSigma = 1000`）会被夹到 48，未知字段被忽略。
- 主题失败只会让宿主忽略皮肤，不会让网关启动失败。

## 已知限制

- 只在插件启动时读取一次；改令牌后需要更新/重新启用插件。
- 不能改颜色、背景图、图标、字体文件、页面结构或任意 Widget 树。
- 数值会被夹到上表范围；未知的 `align` / `direction` / 控件字段会直接报错或被忽略，不会静默生效。
- 同一时间只有一个插件主题生效；多个主题插件同时启用时，先启动成功的那个获胜。

## 许可

WTFPL v2，全文见 [`LICENSE`](../LICENSE)。