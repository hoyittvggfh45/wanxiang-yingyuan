import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wxyy/core/models/plugin_config.dart';

void main() {
  test('统一内置源包：280 条全部可解析、可校验、id 唯一', () {
    final file = File('plugins/builtin/wxyy_unified_sources.json');
    expect(file.existsSync(), isTrue, reason: '内置源包文件缺失');
    final decoded = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    final sources = decoded['sources'] as List<dynamic>;
    expect(sources.length, 280);

    final ids = <String>{};
    var pyCount = 0;
    var jarCount = 0;
    for (final entry in sources) {
      final config = PluginConfig.fromJson(entry as Map<String, dynamic>);
      expect(ids.add(config.id), isTrue, reason: '重复 id：${config.id}');
      expect(config.validate(), isEmpty, reason: '${config.id} 校验失败');
      expect(config.isSpiderSource, isTrue, reason: '${config.id} 不是蜘蛛源');
      if (config.isPySource) {
        pyCount++;
        expect(config.spiderEngine?.sourceRef, startsWith('asset:'));
        final assetPath = config.spiderEngine!.sourceRef!.substring(
          'asset:'.length,
        );
        expect(
          File(assetPath).existsSync(),
          isTrue,
          reason: 'py 文件缺失：$assetPath',
        );
      } else {
        jarCount++;
        expect(config.spiderEngine?.api, isNotEmpty);
        expect(config.spiderEngine?.asset, startsWith('assets/jars/'));
      }
    }
    expect(pyCount, 129);
    expect(jarCount, 151);
  });

  test('无文件注册项 jinguo_jg 已排除', () {
    final file = File('plugins/builtin/wxyy_unified_sources.json');
    final decoded = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    final ids = (decoded['sources'] as List<dynamic>)
        .map((e) => (e as Map<String, dynamic>)['id'] as String)
        .toSet();
    expect(ids.contains('jinguo_jg'), isFalse);
    expect(ids.contains('youtube_py'), isTrue);
  });
}
