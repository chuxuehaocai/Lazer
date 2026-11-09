// ignore_for_file: deprecated_member_use, avoid_web_libraries_in_flutter
import 'dart:html' as html;

/// Opens a validated http(s) link in a new browser tab.
bool openUrlOnWeb(String url) {
  html.window.open(url, '_blank', 'noopener,noreferrer');
  return true;
}
