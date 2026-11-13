import 'package:flutter_test/flutter_test.dart';
import 'package:wxyy/features/shuyuan/shuyuan_source_service.dart';

Map<String, dynamic> _base({Object? type = _absent, Object? enabled = _absent}) {
  final map = <String, dynamic>{
    'bookSourceName': '测试源',
    'bookSourceUrl': 'https://example.com',
    'ruleContent': {'content': '#content@textNodes'},
  };
  if (type != _absent) map['bookSourceType'] = type;
  if (enabled != _absent) map['enabled'] = enabled;
  return map;
}

const _absent = Object();

String _xml({String? typeTag, String? enabledTag}) {
  final buf = StringBuffer()
    ..writeln('<sources>')
    ..writeln('  <bookSource>')
    ..writeln('    <bookSourceName>测试源</bookSourceName>')
    ..writeln('    <bookSourceUrl>https://example.com</bookSourceUrl>');
  if (typeTag != null) buf.writeln('    <bookSourceType>$typeTag</bookSourceType>');
  if (enabledTag != null) buf.writeln('    <enabled>$enabledTag</enabled>');
  buf
    ..writeln('    <ruleContent>{"content": "#content@textNodes"}</ruleContent>')
    ..writeln('  </bookSource>')
    ..writeln('</sources>');
  return buf.toString();
}

void main() {
  group('fromJson 字符串形态', () {
    test('bookSourceType 字符串数字', () {
      expect(ShuyuanSource.fromJson(_base(type: '0')).bookSourceType, 0);
      expect(ShuyuanSource.fromJson(_base(type: '1')).bookSourceType, 1);
      expect(ShuyuanSource.fromJson(_base(type: '2')).bookSourceType, 2);
      expect(ShuyuanSource.fromJson(_base(type: ' 3 ')).bookSourceType, 3);
      expect(ShuyuanSource.fromJson(_base(type: '10')).bookSourceType, 10);
    });

    test('bookSourceType 无法解析的字符串回落默认 0', () {
      expect(ShuyuanSource.fromJson(_base(type: 'abc')).bookSourceType, 0);
      expect(ShuyuanSource.fromJson(_base(type: '')).bookSourceType, 0);
      expect(ShuyuanSource.fromJson(_base(type: '1.5')).bookSourceType, 0);
    });

    test('enabled 字符串布尔各形态', () {
      for (final s in ['true', 'True', 'TRUE', ' true ', 'TrUe']) {
        expect(
          ShuyuanSource.fromJson(_base(enabled: s)).enabled,
          isTrue,
          reason: s,
        );
      }
      for (final s in ['false', 'False', 'FALSE', ' false ', 'FaLsE']) {
        expect(
          ShuyuanSource.fromJson(_base(enabled: s)).enabled,
          isFalse,
          reason: s,
        );
      }
      expect(ShuyuanSource.fromJson(_base(enabled: '1')).enabled, isTrue);
      expect(ShuyuanSource.fromJson(_base(enabled: '0')).enabled, isFalse);
      expect(ShuyuanSource.fromJson(_base(enabled: ' 1 ')).enabled, isTrue);
      expect(ShuyuanSource.fromJson(_base(enabled: ' 0 ')).enabled, isFalse);
    });

    test('enabled 无法解析的字符串回落默认 true', () {
      expect(ShuyuanSource.fromJson(_base(enabled: 'yes')).enabled, isTrue);
      expect(ShuyuanSource.fromJson(_base(enabled: '')).enabled, isTrue);
      expect(ShuyuanSource.fromJson(_base(enabled: '2')).enabled, isTrue);
    });
  });

  group('JSON 路径行为不变', () {
    test('int/bool 值原样解析', () {
      final s = ShuyuanSource.fromJson(_base(type: 2, enabled: false));
      expect(s.bookSourceType, 2);
      expect(s.enabled, isFalse);
      final t = ShuyuanSource.fromJson(_base(type: 0, enabled: true));
      expect(t.bookSourceType, 0);
      expect(t.enabled, isTrue);
    });

    test('缺失字段回落默认 0/true', () {
      final s = ShuyuanSource.fromJson(_base());
      expect(s.bookSourceType, 0);
      expect(s.enabled, isTrue);
    });

    test('null 值回落默认 0/true', () {
      final s = ShuyuanSource.fromJson(_base(type: null, enabled: null));
      expect(s.bookSourceType, 0);
      expect(s.enabled, isTrue);
    });

    test('toJson 往返仍写 int/bool', () {
      final s = ShuyuanSource.fromJson(_base(type: '2', enabled: 'false'));
      final json = s.toJson();
      expect(json['bookSourceType'], 2);
      expect(json['bookSourceType'], isA<int>());
      expect(json['enabled'], isFalse);
      expect(json['enabled'], isA<bool>());
    });
  });

  group('XML 端到端 parseSources', () {
    late ShuyuanSourceService service;

    setUp(() => service = ShuyuanSourceService());
    tearDown(() => service.close());

    test('带两个标签的 XML 解析出正确值', () {
      final sources =
          service.parseSources(_xml(typeTag: '2', enabledTag: 'false'));
      expect(sources.length, 1);
      final s = sources.first;
      expect(s.isValid, isTrue);
      expect(s.bookSourceType, 2);
      expect(s.enabled, isFalse);
      expect(s.bookSourceName, '测试源');
      expect(s.ruleContent?['content'], '#content@textNodes');
    });

    test('XML 标签值含空白与大写', () {
      final sources =
          service.parseSources(_xml(typeTag: ' 1 ', enabledTag: 'FALSE'));
      expect(sources.length, 1);
      expect(sources.first.bookSourceType, 1);
      expect(sources.first.enabled, isFalse);
    });

    test('XML 标签值为 0/1 数字串', () {
      final sources = service.parseSources(_xml(typeTag: '0', enabledTag: '1'));
      expect(sources.length, 1);
      expect(sources.first.bookSourceType, 0);
      expect(sources.first.enabled, isTrue);
    });

    test('XML 不带两个标签时默认 0/true（生成侧现状）', () {
      final sources = service.parseSources(_xml());
      expect(sources.length, 1);
      expect(sources.first.bookSourceType, 0);
      expect(sources.first.enabled, isTrue);
    });

    test('JSON 数组路径仍正常', () {
      const text = '[{"bookSourceName": "测试源", '
          '"bookSourceUrl": "https://example.com", '
          '"bookSourceType": 3, "enabled": false, '
          '"ruleContent": {"content": "#content@textNodes"}}]';
      final sources = service.parseSources(text);
      expect(sources.length, 1);
      expect(sources.first.bookSourceType, 3);
      expect(sources.first.enabled, isFalse);
    });
  });
}
