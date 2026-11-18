import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../utils/web_egress_preferences.dart';
import '../widgets/apple_ui.dart';
import '../widgets/settings_choice.dart';
import '../widgets/settings_row.dart';

class WebEgressSettingsSection extends StatelessWidget {
  const WebEgressSettingsSection({super.key, this.preferences});

  final WebEgressPreferences? preferences;

  @override
  Widget build(BuildContext context) {
    final settings = preferences ?? WebEgressPreferences.shared;
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) => AppleGroupedCard(
        margin: EdgeInsets.zero,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SettingsRow(
              label: 'Web 出口 IP',
              subtitle: '音乐服务识别的客户端 IP 所属国家或地区，默认中国大陆',
              expandControl: true,
              trailing: SettingsChoice<WebEgressCountry>(
                key: const ValueKey('web-egress-country'),
                value: settings.country,
                items: [
                  for (final country in WebEgressCountry.values)
                    DropdownMenuItem(
                      value: country,
                      child: Text(context.tr(country.label)),
                    ),
                ],
                onChanged: (country) {
                  if (country != null) unawaited(settings.setCountry(country));
                },
              ),
            ),
            Padding(
              padding: SettingsSpacing.rowPadding,
              child: Text(
                context.tr(
                  '仅对采用客户端 IP 请求头的服务生效，不改变真实网络出口。Vercel 没有中国大陆节点；此设置仅影响 Web 插件请求，切换后下次请求立即生效。',
                ),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
