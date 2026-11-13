import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wxyy/core/services/source_library_loader.dart';
import 'package:wxyy/core/services/source_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('内置源库：清单 47 条、id 唯一、每条规则文件存在且可解析', () {
    final file = File('assets/source_library/index.json');
    expect(file.existsSync(), isTrue, reason: '内置源库清单缺失');
    final decoded = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    final sources = decoded['sources'] as List<dynamic>;
    expect(sources.length, 47);

    final ids = <String>{};
    for (final entry in sources) {
      final m = entry as Map<String, dynamic>;
      final id = m['id'] as String;
      expect(ids.add(id), isTrue, reason: '重复 id：$id');
      final assetUrl = bundledRuleAssetUrl(id);
      expect(assetUrl, isNotNull, reason: '$id 无法定位规则文件');
      final path = assetUrl!.substring('asset:'.length);
      final ruleFile = File(path);
      expect(ruleFile.existsSync(), isTrue, reason: '$id 规则文件缺失：$path');
      final cfgs = SourceRepository.parseMixedSources(
        ruleFile.readAsStringSync(),
      );
      expect(cfgs, isNotEmpty, reason: '$id 规则解析为空');
      for (final cfg in cfgs) {
        expect(cfg.validate(), isEmpty, reason: '${cfg.id} 校验失败');
      }
    }
  });

  test('内置源库：默认订阅地址走包内资源加载', () async {
    expect(isBundledLibraryUrl(bundledLibraryUrl), isTrue);
    final text = await fetchLibraryText(bundledLibraryUrl);
    final decoded = jsonDecode(text) as Map<String, dynamic>;
    expect((decoded['sources'] as List<dynamic>).length, 47);
    // 至少一条规则经资源路径可读。
    final ruleText = await rootBundle.loadString(
      'assets/source_library/sources/manga/manga_baozimh.json',
    );
    expect(
      SourceRepository.parseMixedSources(ruleText),
      isNotEmpty,
    );
    // 非 asset 地址不走资源分支（哨兵判定本身不触发网络）。
    expect(isBundledLibraryUrl('https://example.com/index.json'), isFalse);
    expect(
      bundledRuleAssetUrl('plain_id_without_slash'),
      isNull,
    );
  });

  test('内置源库：无音频类型规则（听书源如实为空，不编假源）', () {
    final decoded = jsonDecode(
      File('assets/source_library/index.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final types = (decoded['sources'] as List<dynamic>)
        .map((e) => (e as Map<String, dynamic>)['type'] as String?)
        .toSet();
    expect(types, containsAll(<String>['media', 'manga', 'novel']));
    expect(
      types.intersection(<String>{'audio', 'audiobook', 'listen'}),
      isEmpty,
    );
  });
}
