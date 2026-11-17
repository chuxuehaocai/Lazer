# iOS 重签名与 App Groups

## 为什么小部件会空

iOS 小组件只能读 **App Group 共享容器**。App Groups 是**按开发者团队注册**的：

- `group.dev.naominet.lazer` 属于 Lazer 团队；
- 换一个团队签名时，这个 group **无法被创建、也无法被加入**；
- 于是 App 和扩展里的 `containerURL(forSecurityApplicationGroupIdentifier:)`
  都返回 `nil`，App 写不进、扩展读不到，首页卡片永远是空的。

免费 Apple ID 的 profile **完全不能携带 App Groups 权限**，任何代码都无法绕过。
这种情况下小组件会显示「小组件未启用 + 需要包含 App Groups 权限」，而不是假装没有歌。

## 三种安装方式

| 方式 | 小部件 | 说明 |
| --- | --- | --- |
| TrollStore（部分 iOS 版本） | 可用 | 原样安装原始签名，entitlements 完整保留 |
| 付费开发者账号 + 重签 | 可用 | 需要把 App Group 换成**你自己团队**的，见下 |
| 免费 Apple ID（AltStore / SideStore） | 不可用 | profile 无法携带 App Groups，系统层面限制 |

## 重签：换 group 而不重编

仓库把 App Group 做成了**构建设置**，不是 Swift 字面量：

| 位置 | 作用 |
| --- | --- |
| `ios/Flutter/LazerAppGroup.xcconfig` | 定义 `LAZER_APP_GROUP_IDENTIFIER` |
| `ios/Runner/Info.plist` | `LazerAppGroupIdentifier = $(LAZER_APP_GROUP_IDENTIFIER)` |
| `ios/Widget/Info.plist` | 同上 |
| `ios/Runner/Runner.entitlements` | `com.apple.security.application-groups = [$(...)]` |
| `ios/Widget/Widget.entitlements` | 同上 |
| `ios/Shared/LazerAppGroup.swift` | 运行时从 Info.plist 读，缺失时回落到原值 |

因此**改一个 plist 字符串就够了**，不需要 Xcode、不需要重编 Swift。

### 用脚本重签

```bash
bash ci/resign-ios-ipa.sh \
    --ipa dist/Lazer-v2.0.210-iOS-aarch64.ipa \
    --profile ~/Library/MobileDevice/Provisioning\ Profiles/lazer.mobileprovision \
    --identity "Apple Development: you@example.com (TEAMID)" \
    --app-group group.com.yourname.lazer \
    --out dist/Lazer-resigned.ipa
```

脚本依次做这些事，每一步失败都会明确报错：

1. 校验 `--app-group` 以 `group.` 开头；
2. 从 profile 解出 `application-identifier` 与 `TeamIdentifier`；
3. **校验 profile 确实携带这个 group**——否则 `codesign` 会静默丢弃该权限，
   装到设备上才会发现小部件是空的；
4. 校验 profile 的 App ID 覆盖包内所有 bundle id（通配符 profile 全覆盖）；
5. 改写两个 `Info.plist` 的 `LazerAppGroupIdentifier`；
6. **从原签名里抽出 entitlements**，只替换 group 与团队派生字段，其余原样保留；
7. 先签扩展、再签 App，并写入 `embedded.mobileprovision`；
8. 用 `codesign --verify --deep --strict` 复核，再回读 group 确认没有被丢弃。

### 手动重签要点

不想用脚本时，最小步骤：

```bash
unzip -q Lazer.ipa -d stage
app=stage/Payload/Runner.app

# 1. 换 group（App 和每个 .appex 都要改）
/usr/libexec/PlistBuddy -c "Set :LazerAppGroupIdentifier group.com.yourname.lazer" \
    "$app/Info.plist"
for e in "$app"/PlugIns/*.appex; do
  /usr/libexec/PlistBuddy -c "Set :LazerAppGroupIdentifier group.com.yourname.lazer" \
      "$e/Info.plist"
done

# 2. 导出原始 entitlements，只改 group
codesign -d --entitlements :- "$app" > app.ent.plist
/usr/libexec/PlistBuddy -c "Set :com.apple.security.application-groups:0 group.com.yourname.lazer" \
    app.ent.plist

# 3. 先扩展后 App，并写入 profile
for e in "$app"/PlugIns/*.appex; do
  codesign -d --entitlements :- "$e" > ext.ent.plist
  /usr/libexec/PlistBuddy -c "Set :com.apple.security.application-groups:0 group.com.yourname.lazer" \
      ext.ent.plist
  cp you.mobileprovision "$e/embedded.mobileprovision"
  codesign -f -s "$IDENTITY" --entitlements ext.ent.plist --generate-entitlement-der "$e"
done
cp you.mobileprovision "$app/embedded.mobileprovision"
codesign -f -s "$IDENTITY" --entitlements app.ent.plist --generate-entitlement-der "$app"

# 4. 复核：必须打印出你的 group
codesign -d --entitlements :- "$app" | plutil -p -
```

### 关键约束

- **两个 bundle 必须用同一个 group**。不一致时 `ci/verify-ios-bundle.py` 会直接
  让构建失败，因为这是「所有检查都通过、小部件却永远空白」的那类故障。
- entitlements 里只能有一个 group：运行时只从 Info.plist 读一个标识符，
  多写的条目会被静默忽略。
- 先签 `.appex` 再签 `.app`，顺序反了外层签名会把内层改动作废。

## Windows 上自签（iLoader 等工具）

**能不能在 Windows 签名：能。能不能在 Windows 构建 IPA：不能。**

构建需要 macOS 与 Xcode（`ci/build-ios-audio.sh` 会编 iOS 静态库），CI 在
`macos-26` 上产出**未签名** IPA。你下载它，然后在 Windows 上签名——签名本身不需要
Mac，`rcodesign`（`apple-codesign`，纯 Rust）就能跑。

### App Group 不是必须的，但必须"不要声明"

这是最容易踩的坑：**iOS 要求二进制的 entitlements 是 profile 的子集**。仓库自带的
`Runner.entitlements` 声明了 `com.apple.security.application-groups`，而免费
Apple ID 的 profile 不能携带 App Groups——多声明这个权限，**安装会直接失败**
（entitlements 与 profile 不匹配）。

所以正确做法不是"删掉 plist 里的字"，而是**从 profile 派生 entitlements**：

```
profile 给什么，就签什么
```

这样免费账号签名装得上去，代价只是小部件显示"小组件未启用"——这是上一轮加的诚实文案，
不是假装没歌。

### 用仓库脚本

```powershell
cargo install apple-codesign

pwsh ci/resign-ios-ipa.ps1 `
    -Ipa dist\Lazer-v2.0.210-iOS-aarch64.ipa `
    -P12 dev-cert.p12 `
    -P12Password (Read-Host -AsSecureString) `
    -Profile dev.mobileprovision `
    -Out dist\Lazer-signed.ipa
```

脚本做的事：

1. 从 `.mobileprovision` 里切出 XML plist（profile 是 CMS 信封，正文是明文 XML，
   不需要 macOS 的 `security cms -D`）；
2. **读取 profile 的 `Entitlements` 字典**，原样作为签名依据——这是"不必须 app group"
   能成立的关键；
3. 报告 profile 是否携带 App Group，让你知道小部件会不会工作；
4. 校验 `application-identifier` 存在（否则这个 profile 根本不能签 App）；
5. 先签 `*.appex` / `*.framework` / `*.dylib`，最后签 `Runner.app`；
6. `rcodesign print-signature-info` 回读，确认 `com.apple.developer.team-identifier`
   真的进了签名；
7. 复用仓库已有的 `python ci/verify-ios-bundle.py --ipa` 校验产物。

`-AppGroup` 是可选参数，只有在你的 profile **确实携带**该 group 时才用；带上它会同时
改写两个 bundle 的 `LazerAppGroupIdentifier`（这是个 plist 字面量，不用重编）。

### 关于 bundle ID

免费账号的 profile 是通配符 `TEAMID.*`，能同时覆盖
`dev.naominet.lazer` 和 `dev.naominet.lazer.PlayCountWidget`。若你的 profile
不是通配符，只能覆盖其中一个是**装不上**的——要用通配符 profile。

### 工具说明

iLoader、AltStore、SideStore 这类工具在 Windows 上做的也是同一件事：拿证书 + profile
重新签名。它们**不会**因为你的账号支持与否而改变 iOS 的 entitlement 校验规则。所以：

- 工具报"签名成功"但装不上 → 大概率是 entitlements 超出 profile 范围（就是 App Group）；
- 工具用自己的默认 entitlements 而不是你 profile 的 → 同样会超范围。

用 `ci/resign-ios-ipa.ps1` 的好处是它**从 profile 派生**，且签完会回读验证。

## 验证

```bash
python ci/verify-ios-bundle.py --app build/ios/iphoneos/Runner.app
python -m unittest ci.tests.test_ios_app_group ci.tests.test_verify_ios_bundle
```

构建期还会检查扩展的 `NSExtensionPointIdentifier` 必须是
`com.apple.widgetkit-extension`——不是的话会装得上但不出现在小组件库里。
