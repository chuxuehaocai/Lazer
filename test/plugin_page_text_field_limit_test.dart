import 'package:flutter_test/flutter_test.dart';

import 'package:lazer_nextgen/plugins/plugin_extensions.dart';

String _text(int length) => List<String>.filled(length, 'x').join();

Map<String, dynamic> _elementSpec({String value = ''}) => <String, dynamic>{
  'type': 'text_field',
  'id': 'payload',
  'title': 'Payload',
  'value': value,
};

LuaPluginPageElement _element({String value = ''}) =>
    LuaPluginPageElement.fromSpec(
      pluginId: 'fixture',
      pluginName: 'Fixture',
      pageId: 'page',
      spec: _elementSpec(value: value),
    );

LuaPluginPage _page({String value = ''}) => LuaPluginPage.fromSpec(
  pluginId: 'fixture',
  pluginName: 'Fixture',
  spec: <String, dynamic>{
    'id': 'page',
    'title': 'Page',
    'elements': [_elementSpec(value: value)],
  },
);

void main() {
  test('text_field value accepts 16384 and rejects 16385 at parse time', () {
    final accepted = _element(value: _text(16384));
    expect(accepted.value, hasLength(16384));
    expect(
      () => _element(value: _text(16385)),
      throwsA(isA<FormatException>()),
    );
  });

  test('text_field runtime values use the same 16384 boundary', () {
    final element = _element();
    final accepted = _text(kMaxPluginPageTextFieldChars);
    final rejected = _text(kMaxPluginPageTextFieldChars + 1);

    expect(element.accepts(accepted), isTrue);
    expect(element.accepts(rejected), isFalse);
    expect(element.patch({'value': accepted}).value, hasLength(16384));
    expect(
      () => element.patch({'value': rejected}),
      throwsA(isA<FormatException>()),
    );
  });

  test('page editor validates runtime text_field replacement values', () {
    final pages = <LuaPluginPage>[_page()];
    final accepted = _text(kMaxPluginPageTextFieldChars);
    final rejected = _text(kMaxPluginPageTextFieldChars + 1);

    LuaPluginPageEditor.apply(
      pages: pages,
      pluginId: 'fixture',
      pluginName: 'Fixture',
      spec: <String, dynamic>{
        'operation': 'update_element',
        'page': 'page',
        'element': 'payload',
        'value': accepted,
      },
    );
    expect(pages.single.elements.single.value, hasLength(16384));

    expect(
      () => LuaPluginPageEditor.apply(
        pages: pages,
        pluginId: 'fixture',
        pluginName: 'Fixture',
        spec: <String, dynamic>{
          'operation': 'update_element',
          'page': 'page',
          'element': 'payload',
          'value': rejected,
        },
      ),
      throwsA(isA<FormatException>()),
    );
    expect(pages.single.elements.single.value, hasLength(16384));
  });
}
