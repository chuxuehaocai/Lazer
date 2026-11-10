import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class AppLocalizations {
  AppLocalizations(this.locale, this.messages);
  final Locale locale;
  final Map<String, String> messages;
  late final List<(RegExp, String, List<String>)> _patterns = [
    for (final entry in messages.entries)
      if (entry.key.contains(RegExp(r'\{\w+\}')))
        _pattern(entry.key, entry.value),
  ]..sort((a, b) => b.$1.pattern.length.compareTo(a.$1.pattern.length));
  static const supportedLocales = [
    Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'),
    Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
    Locale('ja'),
    Locale('en'),
  ];
  static const delegate = _AppLocalizationsDelegate();
  static final fallback = AppLocalizations(supportedLocales.first, {});

  static Future<AppLocalizations> loadLocale(Locale? locale) {
    final resolved = resolve(locale);
    final cached = _AppLocalizationsDelegate._loaded[resolved];
    if (cached != null) return SynchronousFuture(cached);
    return const _AppLocalizationsDelegate()._read(resolved);
  }

  static AppLocalizations? cachedLocale(Locale? locale) {
    final resolved = resolve(locale);
    return _AppLocalizationsDelegate._loaded[resolved];
  }
  static Locale resolve(Locale? locale) {
    if (locale?.languageCode == 'zh') {
      if (locale?.scriptCode == 'Hans') return supportedLocales[0];
      if (locale?.scriptCode == 'Hant') return supportedLocales[1];
      final traditional = ['TW', 'HK', 'MO'].contains(locale?.countryCode);
      return supportedLocales[traditional ? 1 : 0];
    }
    return locale?.languageCode == 'ja'
        ? supportedLocales[2]
        : supportedLocales[3];
  }

  static Locale resolveLocales(Iterable<Locale>? locales) {
    for (final locale in locales ?? const <Locale>[]) {
      if (['zh', 'ja', 'en'].contains(locale.languageCode)) {
        return resolve(locale);
      }
    }
    return resolve(null);
  }

  static (RegExp, String, List<String>) _pattern(String source, String target) {
    final names = <String>[];
    final expression = StringBuffer('^');
    var offset = 0;
    for (final match in RegExp(r'\{(\w+)\}').allMatches(source)) {
      expression.write(RegExp.escape(source.substring(offset, match.start)));
      expression.write('(.*?)');
      names.add(match.group(1)!);
      offset = match.end;
    }
    expression.write(RegExp.escape(source.substring(offset)));
    expression.write(r'$');
    return (RegExp(expression.toString(), dotAll: true), target, names);
  }

  String text(String message) {
    final direct = messages[message];
    if (direct != null) return direct;
    for (final pattern in _patterns) {
      final match = pattern.$1.firstMatch(message);
      if (match == null) continue;
      var translated = pattern.$2;
      for (var i = 0; i < pattern.$3.length; i++) {
        translated = translated.replaceAll(
          '{${pattern.$3[i]}}',
          match.group(i + 1)!,
        );
      }
      return translated;
    }
    return message;
  }
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();
  static final _loaded = <Locale, AppLocalizations>{};
  @override
  bool isSupported(Locale locale) =>
      ['zh', 'ja', 'en'].contains(locale.languageCode);
  @override
  Future<AppLocalizations> load(Locale locale) {
    final resolved = AppLocalizations.resolve(locale);
    final cached = _loaded[resolved];
    if (cached != null) return SynchronousFuture(cached);
    return _read(resolved);
  }

  Future<AppLocalizations> _read(Locale resolved) async {
    final tag = resolved.languageCode == 'zh'
        ? 'zh_${resolved.scriptCode}'
        : resolved.languageCode;
    final json =
        jsonDecode(await rootBundle.loadString('assets/l10n/$tag.json'))
            as Map<String, dynamic>;
    final result = AppLocalizations(resolved, json.cast<String, String>());
    _loaded[resolved] = result;
    return result;
  }

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

extension LocalizedContext on BuildContext {
  AppLocalizations get strings =>
      Localizations.of<AppLocalizations>(this, AppLocalizations) ??
      AppLocalizations.fallback;
  String tr(String message) => strings.text(message);
}

/// For interface-owned strings only. Catalogue titles and lyrics use Text.
class TrText extends StatelessWidget {
  const TrText(
    this.data, {
    super.key,
    this.style,
    this.strutStyle,
    this.textAlign,
    this.textDirection,
    this.locale,
    this.softWrap,
    this.overflow,
    this.textScaler,
    this.maxLines,
    this.semanticsLabel,
    this.textWidthBasis,
    this.textHeightBehavior,
  });
  final String data;
  final TextStyle? style;
  final StrutStyle? strutStyle;
  final TextAlign? textAlign;
  final TextDirection? textDirection;
  final Locale? locale;
  final bool? softWrap;
  final TextOverflow? overflow;
  final TextScaler? textScaler;
  final int? maxLines;
  final String? semanticsLabel;
  final TextWidthBasis? textWidthBasis;
  final TextHeightBehavior? textHeightBehavior;
  @override
  Widget build(BuildContext context) => Text(
    context.tr(data),
    style: style,
    strutStyle: strutStyle,
    textAlign: textAlign,
    textDirection: textDirection,
    locale: locale,
    softWrap: softWrap,
    overflow: overflow,
    textScaler: textScaler,
    maxLines: maxLines,
    semanticsLabel: semanticsLabel == null ? null : context.tr(semanticsLabel!),
    textWidthBasis: textWidthBasis,
    textHeightBehavior: textHeightBehavior,
  );
}
