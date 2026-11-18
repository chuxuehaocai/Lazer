// i18n:data — country labels are translated by the settings view.
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Client-IP hints understood by some upstream services, not network routes.
/// CN preserves the existing default. Other choices cover the countries and
/// territories in https://vercel.com/docs/regions (reviewed 2026-11-18).
enum WebEgressCountry {
  cn('CN', '中国大陆'),
  hk('HK', '中国香港'),
  jp('JP', '日本'),
  kr('KR', '韩国'),
  sg('SG', '新加坡'),
  ind('IN', '印度'),
  au('AU', '澳大利亚'),
  us('US', '美国'),
  ca('CA', '加拿大'),
  br('BR', '巴西'),
  gb('GB', '英国'),
  ie('IE', '爱尔兰'),
  fr('FR', '法国'),
  de('DE', '德国'),
  se('SE', '瑞典'),
  za('ZA', '南非');

  const WebEgressCountry(this.code, this.label);
  final String code;
  final String label;

  static WebEgressCountry restore(String? code) =>
      values.firstWhere((country) => country.code == code, orElse: () => cn);
}

/// Independent of the desktop system/HTTP/SOCKS proxy preference. Read at each
/// request so already-running Lua plugins immediately use a changed selection.
class WebEgressPreferences extends ChangeNotifier {
  static final shared = WebEgressPreferences();
  static const preferenceKey = 'lazer_web_egress_country';

  WebEgressCountry _country = WebEgressCountry.cn;
  WebEgressCountry get country => _country;

  void initFromPreferences(SharedPreferences preferences) {
    _country = WebEgressCountry.restore(preferences.getString(preferenceKey));
  }

  Future<void> setCountry(WebEgressCountry country) async {
    if (country == _country) return;
    _country = country;
    notifyListeners();
    final preferences = await SharedPreferences.getInstance();
    // Read the latest choice after the async boundary so rapid changes cannot
    // leave an older country persisted for the next browser session.
    await preferences.setString(preferenceKey, _country.code);
  }
}
