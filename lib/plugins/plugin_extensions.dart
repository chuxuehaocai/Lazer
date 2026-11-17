import 'package:flutter/material.dart';

/// The small, data-only controls a Lua plugin may add to the Settings page.
///
/// Plugins describe controls with JSON-shaped tables. The host validates those
/// tables before they reach Flutter, so a plugin can add useful controls
/// without being able to construct widgets or execute UI code.
enum LuaPluginSettingType { toggle, select, text, number, action }

extension LuaPluginSettingTypeParsing on LuaPluginSettingType {
  static LuaPluginSettingType parse(Object? value) {
    switch ('$value'.toLowerCase()) {
      case 'toggle':
      case 'switch':
      case 'boolean':
        return LuaPluginSettingType.toggle;
      case 'select':
      case 'choice':
        return LuaPluginSettingType.select;
      case 'text':
      case 'string':
        return LuaPluginSettingType.text;
      case 'number':
      case 'slider':
        return LuaPluginSettingType.number;
      case 'action':
      case 'button':
        return LuaPluginSettingType.action;
      default:
        throw const FormatException('Invalid plugin setting type');
    }
  }

  String get wireName => switch (this) {
    LuaPluginSettingType.toggle => 'toggle',
    LuaPluginSettingType.select => 'select',
    LuaPluginSettingType.text => 'text',
    LuaPluginSettingType.number => 'number',
    LuaPluginSettingType.action => 'action',
  };
}

class LuaPluginSettingOption {
  const LuaPluginSettingOption({required this.value, required this.label});

  final String value;
  final String label;
}

class LuaPluginSetting {
  LuaPluginSetting({
    required this.pluginId,
    required this.pluginName,
    required this.id,
    required this.title,
    required this.subtitle,
    required this.type,
    required this.defaultValue,
    required this.value,
    this.options = const <LuaPluginSettingOption>[],
    this.min = 0,
    this.max = 100,
    this.step = 1,
    this.enabled = true,
  });

  final String pluginId;
  final String pluginName;
  final String id;
  final String title;
  final String subtitle;
  final LuaPluginSettingType type;
  final Object? defaultValue;
  final Object? value;
  final List<LuaPluginSettingOption> options;
  final double min;
  final double max;
  final double step;
  final bool enabled;

  static final RegExp _idPattern = RegExp(r'^[a-zA-Z0-9_.-]{1,64}$');

  factory LuaPluginSetting.fromSpec({
    required String pluginId,
    required String pluginName,
    required Map<String, dynamic> spec,
    Object? persistedValue,
  }) {
    final id = spec['id'];
    if (id is! String || !_idPattern.hasMatch(id)) {
      throw const FormatException('Invalid plugin setting id');
    }
    final title = spec['title'] ?? spec['label'];
    if (title is! String || title.trim().isEmpty || title.length > 120) {
      throw const FormatException('Invalid plugin setting title');
    }
    final subtitle = spec['subtitle'] ?? spec['description'] ?? '';
    if (subtitle is! String || subtitle.length > 240) {
      throw const FormatException('Invalid plugin setting subtitle');
    }
    final type = LuaPluginSettingTypeParsing.parse(spec['type'] ?? 'toggle');
    final enabled = spec['enabled'] is bool ? spec['enabled'] as bool : true;

    final options = <LuaPluginSettingOption>[];
    if (type == LuaPluginSettingType.select) {
      final rawOptions = spec['options'];
      if (rawOptions is! List || rawOptions.isEmpty || rawOptions.length > 32) {
        throw const FormatException('Plugin select setting needs options');
      }
      for (final raw in rawOptions) {
        if (raw is! Map) {
          throw const FormatException('Invalid plugin setting option');
        }
        final value = raw['value'];
        final label = raw['label'] ?? raw['title'];
        if (value is! String ||
            value.length > 128 ||
            label is! String ||
            label.trim().isEmpty ||
            label.length > 120 ||
            options.any((option) => option.value == value)) {
          throw const FormatException('Invalid plugin setting option');
        }
        options.add(LuaPluginSettingOption(value: value, label: label));
      }
    }

    double min = 0;
    double max = 100;
    double step = 1;
    if (type == LuaPluginSettingType.number) {
      min = _finiteNumber(spec['min'], fallback: 0);
      max = _finiteNumber(spec['max'], fallback: 100);
      step = _finiteNumber(spec['step'], fallback: 1);
      if (max <= min || step <= 0 || step > max - min) {
        throw const FormatException('Invalid plugin number range');
      }
    }

    Object? defaultValue = spec.containsKey('default')
        ? spec['default']
        : switch (type) {
            LuaPluginSettingType.toggle => false,
            LuaPluginSettingType.select => options.first.value,
            LuaPluginSettingType.text => '',
            LuaPluginSettingType.number => min,
            LuaPluginSettingType.action => null,
          };
    if (!_accepts(type, defaultValue, options, min, max)) {
      throw const FormatException('Invalid plugin setting default');
    }
    if (type == LuaPluginSettingType.text &&
        (defaultValue as String).length > 2048) {
      throw const FormatException('Plugin setting text is too long');
    }
    final value =
        persistedValue != null &&
            _accepts(type, persistedValue, options, min, max)
        ? persistedValue
        : defaultValue;
    return LuaPluginSetting(
      pluginId: pluginId,
      pluginName: pluginName,
      id: id,
      title: title,
      subtitle: subtitle,
      type: type,
      defaultValue: defaultValue,
      value: value,
      options: List.unmodifiable(options),
      min: min,
      max: max,
      step: step,
      enabled: enabled,
    );
  }

  LuaPluginSetting copyWithValue(Object? next) => LuaPluginSetting(
    pluginId: pluginId,
    pluginName: pluginName,
    id: id,
    title: title,
    subtitle: subtitle,
    type: type,
    defaultValue: defaultValue,
    value: next,
    options: options,
    min: min,
    max: max,
    step: step,
    enabled: enabled,
  );

  bool accepts(Object? candidate) =>
      _accepts(type, candidate, options, min, max) &&
      (type != LuaPluginSettingType.text ||
          (candidate is String && candidate.length <= 2048));

  static bool _accepts(
    LuaPluginSettingType type,
    Object? value,
    List<LuaPluginSettingOption> options,
    double min,
    double max,
  ) {
    switch (type) {
      case LuaPluginSettingType.toggle:
        return value is bool;
      case LuaPluginSettingType.select:
        return value is String &&
            options.any((option) => option.value == value);
      case LuaPluginSettingType.text:
        return value is String;
      case LuaPluginSettingType.number:
        return value is num && value.isFinite && value >= min && value <= max;
      case LuaPluginSettingType.action:
        return value == null;
    }
  }

  static double _finiteNumber(Object? value, {required double fallback}) {
    if (value is num && value.isFinite) return value.toDouble();
    return fallback;
  }
}

class LuaPlayerMenuItem {
  const LuaPlayerMenuItem({
    required this.pluginId,
    required this.pluginName,
    required this.id,
    required this.label,
    this.subtitle = '',
    this.icon = 'extension',
    this.enabled = true,
  });

  final String pluginId;
  final String pluginName;
  final String id;
  final String label;
  final String subtitle;
  final String icon;
  final bool enabled;

  static final RegExp _idPattern = RegExp(r'^[a-zA-Z0-9_.-]{1,64}$');

  factory LuaPlayerMenuItem.fromSpec({
    required String pluginId,
    required String pluginName,
    required Map<String, dynamic> spec,
  }) {
    final id = spec['id'];
    final label = spec['label'] ?? spec['title'];
    final subtitle = spec['subtitle'] ?? spec['description'] ?? '';
    final icon = spec['icon'] ?? 'extension';
    if (id is! String ||
        !_idPattern.hasMatch(id) ||
        label is! String ||
        label.trim().isEmpty ||
        label.length > 120 ||
        subtitle is! String ||
        subtitle.length > 180 ||
        icon is! String ||
        icon.length > 40) {
      throw const FormatException('Invalid plugin player menu item');
    }
    return LuaPlayerMenuItem(
      pluginId: pluginId,
      pluginName: pluginName,
      id: id,
      label: label,
      subtitle: subtitle,
      icon: icon,
      enabled: spec['enabled'] is bool ? spec['enabled'] as bool : true,
    );
  }
}

/// A bounded, data-only element rendered by the Flutter host on a plugin page.
///
/// Lua supplies JSON-shaped data only. The host owns the widget tree and sends
/// user interaction back as a `page_event` operation.
enum LuaPluginPageElementType {
  text,
  section,
  divider,
  spacer,
  button,
  toggle,
  select,
  slider,
  textField,
}

extension LuaPluginPageElementTypeParsing on LuaPluginPageElementType {
  static LuaPluginPageElementType parse(Object? value) {
    switch ('$value'.toLowerCase()) {
      case 'text':
      case 'label':
        return LuaPluginPageElementType.text;
      case 'section':
      case 'heading':
        return LuaPluginPageElementType.section;
      case 'divider':
        return LuaPluginPageElementType.divider;
      case 'spacer':
        return LuaPluginPageElementType.spacer;
      case 'button':
      case 'action':
        return LuaPluginPageElementType.button;
      case 'toggle':
      case 'switch':
      case 'boolean':
        return LuaPluginPageElementType.toggle;
      case 'select':
      case 'choice':
        return LuaPluginPageElementType.select;
      case 'slider':
      case 'number':
        return LuaPluginPageElementType.slider;
      case 'text_field':
      case 'textfield':
      case 'input':
        return LuaPluginPageElementType.textField;
      default:
        throw const FormatException('Invalid plugin page element type');
    }
  }

  String get wireName => switch (this) {
    LuaPluginPageElementType.text => 'text',
    LuaPluginPageElementType.section => 'section',
    LuaPluginPageElementType.divider => 'divider',
    LuaPluginPageElementType.spacer => 'spacer',
    LuaPluginPageElementType.button => 'button',
    LuaPluginPageElementType.toggle => 'toggle',
    LuaPluginPageElementType.select => 'select',
    LuaPluginPageElementType.slider => 'slider',
    LuaPluginPageElementType.textField => 'text_field',
  };
}

class LuaPluginPageElementOption {
  const LuaPluginPageElementOption({required this.value, required this.label});

  final String value;
  final String label;
}

/// Cross-axis placement of a plugin page's content column.
enum LuaPluginPageAlign { start, center, end, stretch }

extension LuaPluginPageAlignParsing on LuaPluginPageAlign {
  static LuaPluginPageAlign parse(Object? value) {
    switch ('$value'.toLowerCase()) {
      case 'start':
      case 'leading':
      case 'left':
        return LuaPluginPageAlign.start;
      case 'center':
      case 'middle':
        return LuaPluginPageAlign.center;
      case 'end':
      case 'trailing':
      case 'right':
        return LuaPluginPageAlign.end;
      case 'stretch':
      case 'fill':
      case 'full':
        return LuaPluginPageAlign.stretch;
      default:
        throw const FormatException('Invalid plugin page alignment');
    }
  }

  String get wireName => switch (this) {
    LuaPluginPageAlign.start => 'start',
    LuaPluginPageAlign.center => 'center',
    LuaPluginPageAlign.end => 'end',
    LuaPluginPageAlign.stretch => 'stretch',
  };
}

/// How a plugin page stacks its elements.
enum LuaPluginPageDirection { vertical, horizontal, grid }

extension LuaPluginPageDirectionParsing on LuaPluginPageDirection {
  static LuaPluginPageDirection parse(Object? value) {
    switch ('$value'.toLowerCase()) {
      case 'vertical':
      case 'column':
        return LuaPluginPageDirection.vertical;
      case 'horizontal':
      case 'row':
        return LuaPluginPageDirection.horizontal;
      case 'grid':
      case 'wrap':
        return LuaPluginPageDirection.grid;
      default:
        throw const FormatException('Invalid plugin page direction');
    }
  }

  String get wireName => switch (this) {
    LuaPluginPageDirection.vertical => 'vertical',
    LuaPluginPageDirection.horizontal => 'horizontal',
    LuaPluginPageDirection.grid => 'grid',
  };
}

/// Bounded geometry for one plugin page.
///
/// A plugin may restyle spacing and flow, but every number is clamped here and
/// the Flutter host still owns the widget tree.
@immutable
class LuaPluginPageLayout {
  const LuaPluginPageLayout({
    this.gap = 0,
    this.inset = 20,
    this.maxWidth = 0,
    this.align = LuaPluginPageAlign.stretch,
    this.direction = LuaPluginPageDirection.vertical,
    this.columns = 1,
    this.card = true,
    this.header = true,
  });

  /// Space inserted between two neighbouring elements, in logical pixels.
  final double gap;

  /// Horizontal page inset; the default mirrors the built-in settings spacing.
  final double inset;

  /// Content width ceiling; `0` follows the host layout.
  final double maxWidth;
  final LuaPluginPageAlign align;
  final LuaPluginPageDirection direction;

  /// Column count used by [LuaPluginPageDirection.grid].
  final int columns;

  /// Whether elements stay on the grouped card surface.
  final bool card;

  /// Whether the page keeps its title and subtitle header.
  final bool header;

  /// Every key a page spec, or a layout edit, may use for geometry.
  static const Set<String> keys = <String>{
    'gap',
    'spacing',
    'inset',
    'padding',
    'maxWidth',
    'width',
    'align',
    'direction',
    'columns',
    'card',
    'header',
  };

  /// Reads the geometry keys a page spec carries next to its own fields.
  static Map<String, Object?> flattenFrom(Map spec) => <String, Object?>{
    for (final key in keys)
      if (spec.containsKey(key)) key: spec[key],
  };

  /// Merges a partial layout description onto [base].
  ///
  /// Unknown keys are ignored and numbers are clamped, so a stale plugin can
  /// never push a page off screen; a malformed enum still fails loudly.
  factory LuaPluginPageLayout.fromSpec(
    Map spec, {
    LuaPluginPageLayout base = const LuaPluginPageLayout(),
  }) {
    double number(Object? value, double fallback, double min, double max) {
      if (value is! num || !value.isFinite) return fallback;
      return value.toDouble().clamp(min, max).toDouble();
    }

    final gap = number(
      spec.containsKey('gap') ? spec['gap'] : spec['spacing'],
      base.gap,
      0,
      96,
    );
    final inset = number(
      spec.containsKey('inset') ? spec['inset'] : spec['padding'],
      base.inset,
      0,
      96,
    );
    final maxWidth = number(
      spec.containsKey('maxWidth') ? spec['maxWidth'] : spec['width'],
      base.maxWidth,
      0,
      2400,
    );
    return LuaPluginPageLayout(
      gap: gap,
      inset: inset,
      maxWidth: maxWidth,
      align: spec.containsKey('align')
          ? LuaPluginPageAlignParsing.parse(spec['align'])
          : base.align,
      direction: spec.containsKey('direction')
          ? LuaPluginPageDirectionParsing.parse(spec['direction'])
          : base.direction,
      columns: spec['columns'] is num
          ? (spec['columns']! as num).toInt().clamp(1, 4)
          : base.columns,
      card: spec['card'] is bool ? spec['card']! as bool : base.card,
      header: spec['header'] is bool ? spec['header']! as bool : base.header,
    );
  }

  LuaPluginPageLayout copyWith({
    double? gap,
    double? inset,
    double? maxWidth,
    LuaPluginPageAlign? align,
    LuaPluginPageDirection? direction,
    int? columns,
    bool? card,
    bool? header,
  }) => LuaPluginPageLayout(
    gap: gap ?? this.gap,
    inset: inset ?? this.inset,
    maxWidth: maxWidth ?? this.maxWidth,
    align: align ?? this.align,
    direction: direction ?? this.direction,
    columns: columns ?? this.columns,
    card: card ?? this.card,
    header: header ?? this.header,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'gap': gap,
    'inset': inset,
    'maxWidth': maxWidth,
    'align': align.wireName,
    'direction': direction.wireName,
    'columns': columns,
    'card': card,
    'header': header,
  };
}

class LuaPluginPageElement {
  LuaPluginPageElement({
    required this.pluginId,
    required this.pluginName,
    required this.pageId,
    required this.type,
    required this.id,
    required this.title,
    required this.subtitle,
    required this.text,
    required this.value,
    required this.options,
    required this.min,
    required this.max,
    required this.step,
    required this.enabled,
    required this.icon,
    required this.placeholder,
    required this.maxLines,
    this.gap = 0,
    this.padding = 0,
  });

  final String pluginId;
  final String pluginName;
  final String pageId;
  final LuaPluginPageElementType type;
  final String? id;
  final String title;
  final String subtitle;
  final String text;
  final Object? value;
  final List<LuaPluginPageElementOption> options;
  final double min;
  final double max;
  final double step;
  final bool enabled;
  final String icon;
  final String placeholder;
  final int maxLines;

  /// Extra space the host inserts before this element, in logical pixels.
  final double gap;

  /// Horizontal inset applied around this element, in logical pixels.
  final double padding;

  static final RegExp _idPattern = RegExp(r'^[a-zA-Z0-9_.-]{1,64}$');

  /// The largest spacing one element may request.
  static const double maxSpacing = 96;

  factory LuaPluginPageElement.fromSpec({
    required String pluginId,
    required String pluginName,
    required String pageId,
    required Map<String, dynamic> spec,
  }) {
    final type = LuaPluginPageElementTypeParsing.parse(spec['type'] ?? 'text');
    final interactive = {
      LuaPluginPageElementType.button,
      LuaPluginPageElementType.toggle,
      LuaPluginPageElementType.select,
      LuaPluginPageElementType.slider,
      LuaPluginPageElementType.textField,
    }.contains(type);
    final rawId = spec['id'];
    final id = rawId == null && !interactive ? null : rawId;
    if (interactive && (id is! String || !_idPattern.hasMatch(id))) {
      throw const FormatException('Invalid plugin page element id');
    }
    if (id != null && (id is! String || !_idPattern.hasMatch(id))) {
      throw const FormatException('Invalid plugin page element id');
    }
    final rawTitle = spec['title'] ?? spec['label'];
    final title = rawTitle is String ? rawTitle : '';
    if (title.length > 120 || (interactive && title.trim().isEmpty)) {
      throw const FormatException('Invalid plugin page element title');
    }
    final subtitle = spec['subtitle'] ?? spec['description'] ?? '';
    if (subtitle is! String || subtitle.length > 240) {
      throw const FormatException('Invalid plugin page element subtitle');
    }
    final rawText = spec['text'] ?? spec['content'] ?? title;
    if (rawText is! String || rawText.length > 4000) {
      throw const FormatException('Invalid plugin page element text');
    }
    final icon = spec['icon'] ?? 'extension';
    final placeholder = spec['placeholder'] ?? '';
    if (icon is! String ||
        icon.length > 40 ||
        placeholder is! String ||
        placeholder.length > 120) {
      throw const FormatException('Invalid plugin page element decoration');
    }
    final enabled = spec['enabled'] is bool ? spec['enabled'] as bool : true;
    final options = <LuaPluginPageElementOption>[];
    if (type == LuaPluginPageElementType.select) {
      final rawOptions = spec['options'];
      if (rawOptions is! List || rawOptions.isEmpty || rawOptions.length > 32) {
        throw const FormatException('Plugin page select needs options');
      }
      for (final raw in rawOptions) {
        if (raw is! Map) throw const FormatException('Invalid page option');
        final value = raw['value'];
        final label = raw['label'] ?? raw['title'];
        if (value is! String ||
            value.length > 128 ||
            label is! String ||
            label.trim().isEmpty ||
            label.length > 120 ||
            options.any((option) => option.value == value)) {
          throw const FormatException('Invalid page option');
        }
        options.add(LuaPluginPageElementOption(value: value, label: label));
      }
    }
    var min = 0.0;
    var max = 100.0;
    var step = 1.0;
    if (type == LuaPluginPageElementType.slider) {
      min = _finiteNumber(spec['min'], fallback: 0);
      max = _finiteNumber(spec['max'], fallback: 100);
      step = _finiteNumber(spec['step'], fallback: 1);
      if (max <= min || step <= 0 || step > max - min) {
        throw const FormatException('Invalid plugin page slider range');
      }
    }
    final value = spec.containsKey('value')
        ? spec['value']
        : switch (type) {
            LuaPluginPageElementType.toggle => false,
            LuaPluginPageElementType.select => options.first.value,
            LuaPluginPageElementType.slider => min,
            LuaPluginPageElementType.textField => '',
            _ => null,
          };
    if (!_accepts(type, value, options, min, max)) {
      throw const FormatException('Invalid plugin page element value');
    }
    if (type == LuaPluginPageElementType.textField &&
        (value as String).length > 2048) {
      throw const FormatException('Plugin page text is too long');
    }
    final maxLines = spec['maxLines'] is num
        ? (spec['maxLines'] as num).toInt()
        : 4;
    if (maxLines < 1 || maxLines > 12) {
      throw const FormatException('Invalid plugin page text lines');
    }
    return LuaPluginPageElement(
      pluginId: pluginId,
      pluginName: pluginName,
      pageId: pageId,
      type: type,
      id: id as String?,
      title: title,
      subtitle: subtitle,
      text: rawText,
      value: value,
      options: List.unmodifiable(options),
      min: min,
      max: max,
      step: step,
      enabled: enabled,
      icon: icon,
      placeholder: placeholder,
      maxLines: maxLines,
      gap: _spacing(spec['gap'] ?? spec['spacing']),
      padding: _spacing(spec['padding'] ?? spec['inset']),
    );
  }

  /// The element as a data-only table, so a plugin can read back what it built.
  Map<String, Object?> toSpec() => <String, Object?>{
    'type': type.wireName,
    if (id != null) 'id': id,
    'title': title,
    'subtitle': subtitle,
    'text': text,
    'value': value,
    if (options.isNotEmpty)
      'options': <Map<String, Object?>>[
        for (final option in options)
          <String, Object?>{'value': option.value, 'label': option.label},
      ],
    'min': min,
    'max': max,
    'step': step,
    'enabled': enabled,
    'icon': icon,
    'placeholder': placeholder,
    'maxLines': maxLines,
    'gap': gap,
    'padding': padding,
  };

  LuaPluginPageElement copyWithValue(Object? next) => LuaPluginPageElement(
    pluginId: pluginId,
    pluginName: pluginName,
    pageId: pageId,
    type: type,
    id: id,
    title: title,
    subtitle: subtitle,
    text: text,
    value: next,
    options: options,
    min: min,
    max: max,
    step: step,
    enabled: enabled,
    icon: icon,
    placeholder: placeholder,
    maxLines: maxLines,
    gap: gap,
    padding: padding,
  );

  /// Rebuilds the element from its own data plus [changes].
  ///
  /// Partial edits stay declarative: the merged table goes through the same
  /// validation as a freshly declared element, so a bad patch is rejected
  /// instead of reaching Flutter.
  LuaPluginPageElement patch(Map<String, dynamic> changes) {
    final spec = Map<String, dynamic>.from(toSpec());
    var retitles = false;
    changes.forEach((key, value) {
      switch (key) {
        case 'label':
        case 'name':
          spec['title'] = value;
          retitles = true;
        case 'description':
          spec['subtitle'] = value;
        case 'content':
          spec['text'] = value;
        default:
          spec[key] = value;
      }
    });
    if (retitles &&
        changes['text'] == null &&
        changes['content'] == null &&
        type == LuaPluginPageElementType.text) {
      spec['text'] = spec['title'];
    }
    return LuaPluginPageElement.fromSpec(
      pluginId: pluginId,
      pluginName: pluginName,
      pageId: pageId,
      spec: spec,
    );
  }

  bool accepts(Object? candidate) =>
      _accepts(type, candidate, options, min, max) &&
      (type != LuaPluginPageElementType.textField ||
          (candidate is String && candidate.length <= 2048));

  static bool _accepts(
    LuaPluginPageElementType type,
    Object? value,
    List<LuaPluginPageElementOption> options,
    double min,
    double max,
  ) {
    switch (type) {
      case LuaPluginPageElementType.toggle:
        return value is bool;
      case LuaPluginPageElementType.select:
        return value is String &&
            options.any((option) => option.value == value);
      case LuaPluginPageElementType.slider:
        return value is num && value.isFinite && value >= min && value <= max;
      case LuaPluginPageElementType.textField:
        return value is String;
      case LuaPluginPageElementType.button:
      case LuaPluginPageElementType.text:
      case LuaPluginPageElementType.section:
      case LuaPluginPageElementType.divider:
      case LuaPluginPageElementType.spacer:
        return value == null;
    }
  }

  static double _finiteNumber(Object? value, {required double fallback}) {
    if (value is num && value.isFinite) return value.toDouble();
    return fallback;
  }

  static double _spacing(Object? value) {
    if (value is! num || !value.isFinite) return 0;
    return value.toDouble().clamp(0, maxSpacing).toDouble();
  }
}

class LuaPluginPage {
  LuaPluginPage({
    required this.pluginId,
    required this.pluginName,
    required this.id,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.elements,
    this.layout = const LuaPluginPageLayout(),
  });

  final String pluginId;
  final String pluginName;
  final String id;
  final String title;
  final String subtitle;
  final String icon;
  final List<LuaPluginPageElement> elements;
  final LuaPluginPageLayout layout;

  static final RegExp _idPattern = RegExp(r'^[a-zA-Z0-9_.-]{1,64}$');

  /// How many elements one page may hold.
  static const int maxElements = 128;

  factory LuaPluginPage.fromSpec({
    required String pluginId,
    required String pluginName,
    required Map<String, dynamic> spec,
  }) {
    final id = spec['id'];
    final title = spec['title'] ?? spec['label'];
    final subtitle = spec['subtitle'] ?? spec['description'] ?? '';
    final icon = spec['icon'] ?? 'extension';
    final rawElements = spec['elements'] ?? spec['children'];
    if (id is! String ||
        !_idPattern.hasMatch(id) ||
        title is! String ||
        title.trim().isEmpty ||
        title.length > 120 ||
        subtitle is! String ||
        subtitle.length > 240 ||
        icon is! String ||
        icon.length > 40 ||
        rawElements is! List ||
        rawElements.length > maxElements) {
      throw const FormatException('Invalid plugin page');
    }
    final layout = LuaPluginPageLayout.fromSpec(<String, Object?>{
      ...LuaPluginPageLayout.flattenFrom(spec),
      if (spec['layout'] is Map)
        ...Map<String, Object?>.from(spec['layout'] as Map),
    });
    final elements = <LuaPluginPageElement>[];
    final ids = <String>{};
    for (final raw in rawElements) {
      if (raw is! Map) {
        throw const FormatException('Invalid plugin page element');
      }
      final element = LuaPluginPageElement.fromSpec(
        pluginId: pluginId,
        pluginName: pluginName,
        pageId: id,
        spec: Map<String, dynamic>.from(raw),
      );
      if (element.id != null && !ids.add(element.id!)) {
        throw const FormatException('Duplicate plugin page element id');
      }
      elements.add(element);
    }
    return LuaPluginPage(
      pluginId: pluginId,
      pluginName: pluginName,
      id: id,
      title: title,
      subtitle: subtitle,
      icon: icon,
      elements: List.unmodifiable(elements),
      layout: layout,
    );
  }

  /// The page as a data-only table; the same shape `host.add_page` accepts.
  Map<String, Object?> toSpec() => <String, Object?>{
    'id': id,
    'title': title,
    'subtitle': subtitle,
    'icon': icon,
    'layout': layout.toJson(),
    'elements': <Map<String, Object?>>[
      for (final element in elements) element.toSpec(),
    ],
  };

  /// Applies a partial page edit: metadata, geometry and optionally elements.
  ///
  /// Flat geometry keys (`gap`, `inset`, `align`, ...) and a nested `layout`
  /// table are both accepted, so `update_page({ gap = 12 })` stays short.
  LuaPluginPage patch(Map<String, dynamic> changes) {
    final spec = Map<String, dynamic>.from(toSpec());
    final page = <String, dynamic>{};
    final geometry = <String, Object?>{};
    for (final entry in changes.entries) {
      if (LuaPluginPageLayout.keys.contains(entry.key)) {
        geometry[entry.key] = entry.value;
        continue;
      }
      switch (entry.key) {
        case 'label':
        case 'name':
          page['title'] = entry.value;
        case 'description':
          page['subtitle'] = entry.value;
        case 'layout':
          if (entry.value is Map) {
            geometry.addAll(Map<String, Object?>.from(entry.value as Map));
          }
        default:
          page[entry.key] = entry.value;
      }
    }
    spec.addAll(page);
    if (geometry.isNotEmpty) {
      spec['layout'] = LuaPluginPageLayout.fromSpec(
        geometry,
        base: layout,
      ).toJson();
    }
    return LuaPluginPage.fromSpec(
      pluginId: pluginId,
      pluginName: pluginName,
      spec: spec,
    );
  }

  LuaPluginPage copyWith({
    String? title,
    String? subtitle,
    String? icon,
    LuaPluginPageLayout? layout,
    List<LuaPluginPageElement>? elements,
  }) => LuaPluginPage(
    pluginId: pluginId,
    pluginName: pluginName,
    id: id,
    title: title ?? this.title,
    subtitle: subtitle ?? this.subtitle,
    icon: icon ?? this.icon,
    elements: List.unmodifiable(elements ?? this.elements),
    layout: layout ?? this.layout,
  );

  LuaPluginPage copyWithElements(List<LuaPluginPageElement> next) =>
      copyWith(elements: next);
}

/// Host-side owner of the pages a plugin registered through `host.add_page`.
///
/// A Lua script can restyle its own pages and add, edit, reorder or drop
/// elements, but every edit is re-validated here and stays inside that
/// plugin's own page list.
abstract final class LuaPluginPageEditor {
  /// How many pages a single plugin may keep.
  static const int maxPages = 16;

  static const Set<String> _controlKeys = <String>{
    'operation',
    'page',
    'pageId',
    'page_id',
  };

  static const Set<String> _elementKeys = <String>{
    'element',
    'elementId',
    'element_id',
    'item',
    'target',
  };

  static const Set<String> _positionKeys = <String>{
    'at',
    'position',
    'before',
    'after',
    'to',
    'toIndex',
    'to_index',
  };

  /// Registers or replaces a page declared with `host.add_page`.
  static LuaPluginPage register(List<LuaPluginPage> pages, LuaPluginPage page) {
    if (!pages.any((value) => value.id == page.id) &&
        pages.length >= maxPages) {
      throw const FormatException('Too many plugin pages');
    }
    pages.removeWhere((value) => value.id == page.id);
    pages.add(page);
    return page;
  }

  /// Applies one edit operation and returns a Lua-shaped result.
  ///
  /// Mutations return the page table after the change, so a plugin can keep
  /// working from the host's own state instead of its own copy.
  static Object? apply({
    required List<LuaPluginPage> pages,
    required String pluginId,
    required String pluginName,
    required Map<String, dynamic> spec,
  }) {
    final operation = '${spec['operation'] ?? 'get'}'.trim().toLowerCase();
    if (operation == 'list' || operation == 'pages') {
      return <Map<String, Object?>>[
        for (final page in pages)
          <String, Object?>{
            'id': page.id,
            'title': page.title,
            'subtitle': page.subtitle,
            'icon': page.icon,
            'elements': page.elements.length,
            'layout': page.layout.toJson(),
          },
      ];
    }
    final selector = spec['page'] ?? spec['pageId'] ?? spec['page_id'];
    final usesId = selector is! String || selector.trim().isEmpty;
    if (usesId && !_idSelectsPage(operation)) {
      throw const FormatException('Plugin page is required');
    }
    final pageId = usesId ? '${spec['id'] ?? ''}'.trim() : selector.trim();
    final index = pages.indexWhere((page) => page.id == pageId);
    if (pageId.isEmpty || index < 0) {
      throw const FormatException('Plugin page not found');
    }
    final page = pages[index];
    switch (operation) {
      case 'get':
      case 'read':
        return page.toSpec();
      case 'update':
      case 'patch':
        return _store(pages, index, page.patch(_changes(spec, usesId)));
      case 'set_elements':
      case 'elements':
        final elements = _elements(page, spec['elements'] ?? spec['children']);
        return _store(pages, index, page.copyWith(elements: elements));
      case 'add_element':
      case 'insert_element':
        return _store(pages, index, _insert(page, spec));
      case 'update_element':
      case 'set_element':
        return _store(pages, index, _updateElement(page, spec));
      case 'remove_element':
      case 'delete_element':
        final elements = <LuaPluginPageElement>[...page.elements]
          ..removeAt(_elementIndex(page, spec, allowId: true));
        return _store(pages, index, page.copyWith(elements: elements));
      case 'move_element':
      case 'reorder_element':
        return _store(pages, index, _moveElement(page, spec));
      default:
        throw const FormatException('Unknown plugin page edit operation');
    }
  }

  /// Whether `id` may name the page instead of an element.
  static bool _idSelectsPage(String operation) => const <String>{
    'get',
    'read',
    'update',
    'patch',
    'set_elements',
    'elements',
  }.contains(operation);

  static Map<String, dynamic> _changes(
    Map<String, dynamic> spec,
    bool dropId,
  ) => <String, dynamic>{
    for (final entry in spec.entries)
      if (!_controlKeys.contains(entry.key) && !(dropId && entry.key == 'id'))
        entry.key: entry.value,
  };

  static Map<String, Object?> _store(
    List<LuaPluginPage> pages,
    int index,
    LuaPluginPage page,
  ) {
    if (pages[index].id != page.id &&
        pages.any((value) => value.id == page.id)) {
      throw const FormatException('Duplicate plugin page id');
    }
    pages[index] = page;
    return page.toSpec();
  }

  static LuaPluginPage _insert(LuaPluginPage page, Map<String, dynamic> spec) {
    if (page.elements.length >= LuaPluginPage.maxElements) {
      throw const FormatException('Too many plugin page elements');
    }
    final raw = spec['element'] ?? spec['item'];
    final elementSpec = raw is Map
        ? Map<String, dynamic>.from(raw)
        : <String, dynamic>{
            for (final entry in spec.entries)
              if (!_controlKeys.contains(entry.key) &&
                  !_elementKeys.contains(entry.key) &&
                  !_positionKeys.contains(entry.key))
                entry.key: entry.value,
          };
    if (elementSpec.isEmpty) {
      throw const FormatException('Plugin page element is required');
    }
    final element = LuaPluginPageElement.fromSpec(
      pluginId: page.pluginId,
      pluginName: page.pluginName,
      pageId: page.id,
      spec: elementSpec,
    );
    if (element.id != null &&
        page.elements.any((value) => value.id == element.id)) {
      throw const FormatException('Duplicate plugin page element id');
    }
    final elements = <LuaPluginPageElement>[...page.elements]
      ..insert(_position(page.elements, spec), element);
    return page.copyWith(elements: elements);
  }

  static LuaPluginPage _updateElement(
    LuaPluginPage page,
    Map<String, dynamic> spec,
  ) {
    final index = _elementIndex(page, spec, allowId: true);
    final element = page.elements[index];
    final explicit = _explicitElementSelector(spec);
    final changes = <String, dynamic>{
      for (final entry in spec.entries)
        if (!_controlKeys.contains(entry.key) &&
            !_elementKeys.contains(entry.key) &&
            !_positionKeys.contains(entry.key) &&
            !(entry.key == 'id' && !explicit) &&
            entry.key != 'newId' &&
            entry.key != 'new_id')
          entry.key: entry.value,
    };
    final rename = spec['newId'] ?? spec['new_id'];
    if (rename is String && rename.isNotEmpty) changes['id'] = rename;
    if (changes.isEmpty) return page;
    final next = element.patch(changes);
    if (next.id != null &&
        page.elements.any(
          (value) => !identical(value, element) && value.id == next.id,
        )) {
      throw const FormatException('Duplicate plugin page element id');
    }
    final elements = <LuaPluginPageElement>[...page.elements]..[index] = next;
    return page.copyWith(elements: elements);
  }

  static LuaPluginPage _moveElement(
    LuaPluginPage page,
    Map<String, dynamic> spec,
  ) {
    final from = _elementIndex(page, spec, allowId: true);
    final element = page.elements[from];
    final remaining = <LuaPluginPageElement>[...page.elements]..removeAt(from);
    final target = spec['to'] ?? spec['toIndex'] ?? spec['to_index'];
    final int resolved;
    if (target is String && target.isNotEmpty) {
      final index = remaining.indexWhere((element) => element.id == target);
      if (index < 0) {
        throw const FormatException('Plugin page element not found');
      }
      resolved = index;
    } else if (target is num && target.isFinite) {
      resolved = _index(target, remaining.length + 1);
    } else {
      resolved = _position(remaining, spec);
    }
    remaining.insert(resolved, element);
    return page.copyWith(elements: remaining);
  }

  static List<LuaPluginPageElement> _elements(LuaPluginPage page, Object? raw) {
    final List<Object?> specs;
    if (raw is List) {
      specs = raw;
    } else if (raw is Map && raw.isEmpty) {
      specs = const <Object?>[];
    } else {
      throw const FormatException('Plugin page elements are required');
    }
    if (specs.length > LuaPluginPage.maxElements) {
      throw const FormatException('Too many plugin page elements');
    }
    final elements = <LuaPluginPageElement>[];
    final ids = <String>{};
    for (final item in specs) {
      if (item is! Map) {
        throw const FormatException('Invalid plugin page element');
      }
      final element = LuaPluginPageElement.fromSpec(
        pluginId: page.pluginId,
        pluginName: page.pluginName,
        pageId: page.id,
        spec: Map<String, dynamic>.from(item),
      );
      if (element.id != null && !ids.add(element.id!)) {
        throw const FormatException('Duplicate plugin page element id');
      }
      elements.add(element);
    }
    return elements;
  }

  static bool _explicitElementSelector(Map spec) => _elementKeys.any(
    (key) => spec[key] is String && '${spec[key]}'.isNotEmpty,
  );

  /// Where a new element lands, as a zero-based insert index.
  static int _position(
    List<LuaPluginPageElement> elements,
    Map spec, {
    bool trailing = true,
  }) {
    int locate(Object? value) {
      if (value is! String || value.isEmpty) {
        throw const FormatException('Plugin page element not found');
      }
      final index = elements.indexWhere((element) => element.id == value);
      if (index < 0) {
        throw const FormatException('Plugin page element not found');
      }
      return index;
    }

    if (spec['before'] != null) return locate(spec['before']);
    if (spec['after'] != null) return locate(spec['after']) + 1;
    final at = spec['at'] ?? spec['position'] ?? spec['to'];
    if (at is num && at.isFinite) return _index(at, elements.length + 1);
    return trailing ? elements.length : 0;
  }

  static int _index(num raw, int length) =>
      raw.round().clamp(1, length < 1 ? 1 : length).toInt() - 1;

  static int _elementIndex(
    LuaPluginPage page,
    Map spec, {
    required bool allowId,
  }) {
    for (final key in _elementKeys) {
      final value = spec[key];
      if (value is String && value.isNotEmpty) {
        final index = page.elements.indexWhere(
          (element) => element.id == value,
        );
        if (index < 0) {
          throw const FormatException('Plugin page element not found');
        }
        return index;
      }
    }
    final id = spec['id'];
    if (allowId && !_explicitElementSelector(spec) && id is String) {
      final index = page.elements.indexWhere((element) => element.id == id);
      if (index < 0) {
        throw const FormatException('Plugin page element not found');
      }
      return index;
    }
    final raw = spec['index'] ?? spec['from'] ?? spec['fromIndex'];
    if (raw is num && raw.isFinite) {
      final position = raw.round();
      if (position < 1 || position > page.elements.length) {
        throw const FormatException('Plugin page element not found');
      }
      return position - 1;
    }
    throw const FormatException('Plugin page element is required');
  }
}

IconData luaPluginIcon(String name) => switch (name) {
  'settings' => Icons.settings_outlined,
  'link' => Icons.link_rounded,
  'open_in_new' => Icons.open_in_new_rounded,
  'favorite' => Icons.favorite_border_rounded,
  'download' => Icons.download_rounded,
  'share' => Icons.share_rounded,
  'content_copy' => Icons.content_copy_rounded,
  'refresh' => Icons.refresh_rounded,
  'info' => Icons.info_outline_rounded,
  'music_note' => Icons.music_note_rounded,
  'lyrics' => Icons.lyrics_outlined,
  'play' => Icons.play_arrow_rounded,
  _ => Icons.extension_rounded,
};
