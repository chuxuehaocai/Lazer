import 'package:flutter/widgets.dart';

import 'lazer_theme.dart';

/// 单个部件的圆角取自哪里。
///
/// 全局圆角只有「跟随主题 / 自行调节」两档，但窗口胶囊和移动端底边栏这两类
/// 部件是整块的玻璃药丸：它们的圆角上限由自身高度决定（40 dp 的胶囊最多 20 px
/// 就是满圆），直接套全局 px 会在 16 px 以上就顶到上限、看上去「调不动」。
/// 所以它们各自有一个来源选择，多出「跟随全局」这一档。
enum CornerSource {
  /// 皮肤令牌里的 `cornerScale`，乘这个部件自己的满圆半径。
  theme,

  /// 全局圆角设置（[AppleShape.scale]）乘这个部件自己的满圆半径。
  global,

  /// 用户给这个部件的 px 值。
  manual,
}

extension CornerSourceLabels on CornerSource {
  String get label => switch (this) {
    CornerSource.theme => '跟随主题',
    CornerSource.global => '跟随全局',
    CornerSource.manual => '手动设置',
  };

  static CornerSource parse(String? value) => CornerSource.values.firstWhere(
    (source) => source.name == value,
    orElse: () => CornerSource.global,
  );
}

/// 全局圆角大小。
///
/// 两个来源，用户在「设置 → 界面与布局 → 圆角设置」里二选一：
///
/// * **跟随主题设置**：用主题令牌里的 `cornerScale`（皮肤可以给 0 = 全直角，
///   也可以给 1 = 主题原本的圆角）；
/// * **自行调节**：用用户滑块给的 px 值。
///
/// 内部仍然是一个系数：所有 `BorderRadius.circular(x * AppleShape.scaleOf(context))`
/// 都乘上它，所以调一处即可全局生效，不依赖任何 Lua 插件。
///
/// 用户看到的是 px：滑块 0–32 px，[basePx]（16 px）对应该组件原本设计的圆角，
/// 0 px = 全直角，32 px = 加倍。换成 px 是因为「100%」到底是多少没人说得准，
/// 而「16 px」一眼就知道自己调到多圆。
class AppleShape extends InheritedWidget {
  const AppleShape({
    super.key,
    required this.scale,
    required this.cardPx,
    required this.manual,
    this.capsulePx = capsulePxDefault,
    this.navBarPx = navBarPxDefault,
    required super.child,
  });

  /// 滑块上的 px 数值换算成系数时用的基准：16 px = 组件原本的圆角。
  static const double basePx = 16;

  /// 允许的系数范围（0–2，即 0–32 px）。
  static const double min = 0;
  static const double max = 2;

  /// 1 = 主题原本的圆角。
  static const double identity = 1;

  /// 滑块允许的 px 范围。
  static const double minPx = min * basePx;
  static const double maxPx = max * basePx;

  /// Inline 窗口胶囊的满圆半径：胶囊高 40 dp（`kWindowChromeHeight`）。
  static const double capsulePxMax = 20;
  static const double capsulePxDefault = capsulePxMax;

  /// 移动端底边栏的满圆半径：玻璃药丸高 56 dp（44 的内容 + 6×2 内边距）。
  static const double navBarPxMax = 28;
  static const double navBarPxDefault = navBarPxMax;

  /// 组件圆角（按钮、胶囊、头像…）的系数。
  final double scale;

  /// 卡片这一类表面的圆角，单位 px。
  final double cardPx;

  /// Inline 窗口胶囊的实际圆角（px，0–[capsulePxMax]）。
  final double capsulePx;

  /// 移动端底边栏药丸的实际圆角（px，0–[navBarPxMax]）。
  final double navBarPx;

  /// 用户是否选了「自行调节」。手动模式下 [cardPx] 直接压过皮肤的
  /// `groupedCardRadius`，否则皮肤说了算（皮肤给 0 就一直是直角）。
  final bool manual;

  /// px 换成系数。
  static double scaleOfPx(double px) =>
      px.isFinite ? (px / basePx).clamp(min, max) : identity;

  /// 系数换成 px（用于把皮肤令牌显示在滑块上）。
  static double pxOfScale(double scale) =>
      scale.isFinite ? (scale.clamp(min, max)) * basePx : basePx;

  /// 依据用户选择和主题令牌算出最终系数。
  static double resolve({
    required bool followTheme,
    required double customPx,
    required LazerThemeTokens theme,
  }) {
    final double raw = followTheme ? theme.cornerScale : scaleOfPx(customPx);
    if (raw.isNaN) return identity;
    return raw.clamp(min, max);
  }

  /// 胶囊 / 底边栏这一类「满圆 = 自身高度一半」的部件，按来源算实际 px。
  ///
  /// * **跟随主题**：皮肤可以就这个部件单独给一个 px（`capsuleRadius` /
  ///   `navBarRadius`，负值表示没给）；没给时才退回「组件系数 × 满圆半径」。
  ///   这样皮肤既能说「全直角」（0 px），也能保住老皮肤「就是满圆」的行为。
  /// * **跟随全局**：直接用全局圆角设置里那个 px 数，**不再乘任何东西**。
  ///   全局写 6 px，胶囊就是 6 px、底边栏也是 6 px —— 用户在同两个滑块之间
  ///   对比时看到的是同一个数，不会被「你自己高度一半」悄悄放大。
  /// * **手动设置**：自己的 px。
  ///
  /// 三者都夹在 `[0, maxPx]`：超过满圆半径画不出更圆的药丸，夹取能让滑块上的
  /// 数字和实际形状始终对得上。
  static double resolvePartPx({
    required CornerSource source,
    required double customPx,
    required double maxPx,
    required double themeScale,
    required double globalPx,
    double themePx = -1,
  }) {
    final double px = switch (source) {
      CornerSource.theme => themePx >= 0
          ? (themePx.isFinite ? themePx : maxPx)
          : (themeScale.isFinite ? themeScale : identity) * maxPx,
      CornerSource.global => globalPx.isFinite ? globalPx : maxPx,
      CornerSource.manual => customPx.isFinite ? customPx : maxPx,
    };
    return px.clamp(0.0, maxPx);
  }

  /// 设置页要显示的 px：跟随某种来源时显示真正生效的数，手动时显示用户的滑块。
  static double partPxFor({
    required CornerSource source,
    required double customPx,
    required double maxPx,
    required double themeScale,
    required double globalPx,
    double themePx = -1,
  }) => resolvePartPx(
    source: source,
    customPx: customPx,
    maxPx: maxPx,
    themeScale: themeScale,
    globalPx: globalPx,
    themePx: themePx,
  );

  /// 设置页显示的卡片圆角（px）：跟随主题时是皮肤自己的 `groupedCardRadius`，
  /// 手动时是用户的滑块。这也是「主题里是直角（0）但设置里写着 16 px」那个
  /// 矛盾的解法：显示的必须是真正生效的那个数。
  static double cardPxFor({
    required bool followTheme,
    required double customPx,
    required LazerThemeTokens theme,
  }) => followTheme ? theme.groupedCardRadius : customPx;

  /// 卡片圆角。手动模式直接用用户 px（不再乘系数，否则皮肤给 0 时永远是 0，
  /// 调滑块会「完全没用」）；跟随主题时用皮肤的 `groupedCardRadius`。
  static double cardRadiusOf(BuildContext context, LazerThemeTokens theme) {
    final AppleShape? shape = context
        .dependOnInheritedWidgetOfExactType<AppleShape>();
    if (shape?.manual ?? false) return shape!.cardPx;
    return theme.groupedCardRadius;
  }

  /// Inline 窗口胶囊当前生效的圆角（px）。
  static double capsuleRadiusOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppleShape>()?.capsulePx ??
      capsulePxDefault;

  /// 移动端底边栏当前生效的圆角（px）。
  static double navBarRadiusOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppleShape>()?.navBarPx ??
      navBarPxDefault;

  /// 当前生效的系数；没有 provider 时按 1 处理，保证老代码行为不变。
  static double scaleOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppleShape>()?.scale ??
      identity;

  /// 把主题里写死的圆角值换算成实际值。
  static double r(BuildContext context, double value) =>
      value * scaleOf(context);

  /// 同上，直接给出 [BorderRadius]。
  static BorderRadius radiusOf(BuildContext context, double value) =>
      BorderRadius.circular(r(context, value));

  /// 当前生效的角，按 px 表达（设置页与探针用）。
  static double currentPx(BuildContext context) =>
      pxOfScale(scaleOf(context));

  @override
  bool updateShouldNotify(AppleShape oldWidget) =>
      oldWidget.scale != scale ||
      oldWidget.cardPx != cardPx ||
      oldWidget.manual != manual ||
      oldWidget.capsulePx != capsulePx ||
      oldWidget.navBarPx != navBarPx;
}
