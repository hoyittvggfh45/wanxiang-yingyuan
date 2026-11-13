import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wxyy/core/models/plugin_config.dart';
import 'package:wxyy/core/services/source_repository.dart';
import 'package:wxyy/features/sources/manual_source_factory.dart';

void main() {
  SharedPreferences.setMockInitialValues(<String, Object>{});

  group('buildManualSource', () {
    test('小说空白源：默认字段为空值且通过同一套校验', () {
      final result = buildManualSource(
        name: '示例小说站',
        baseUrl: 'https://novel.example.com/',
        type: SourceType.novelSource,
      );
      expect(result.isValid, isTrue);
      final config = result.config!;
      expect(config.validate(), isEmpty);
      expect(config.id, 'manual_novel_example_com');
      expect(config.name, '示例小说站');
      expect(config.type, SourceType.novelSource);
      expect(config.version, 1);
      expect(config.site.domain, 'novel.example.com');
      // 末尾斜杠已归一化，不编假地址。
      expect(config.site.baseUrl, 'https://novel.example.com');
      expect(config.parser.type, 'builtin');
      expect(config.parser.script, isNull);
      expect(config.routes, isEmpty);
      expect(config.selectors, isNull);
      expect(config.category.categoryEntries, isEmpty);
      expect(config.homeSections, isEmpty);
      expect(config.enabled, isTrue);
      expect(config.spiderEngine, isNull);
    });

    test('媒体空白源：latest 路由指向本站地址本身，不拼假路径', () {
      final result = buildManualSource(
        name: '示例影视站',
        baseUrl: 'https://media.example.com',
        type: SourceType.animeSource,
      );
      expect(result.isValid, isTrue);
      final config = result.config!;
      expect(config.validate(), isEmpty);
      expect(config.routes.keys, <String>['latest']);
      expect(config.routes['latest']!.url, 'https://media.example.com');
      expect(config.selectors, isNull);
    });

    test('四种类型选择正确落盘且 JSON 往返不丢', () {
      for (final type in SourceType.values) {
        final result = buildManualSource(
          name: '站',
          baseUrl: 'https://example.com',
          type: type,
        );
        expect(result.isValid, isTrue, reason: '$type 应建成功');
        final roundTripped =
            PluginConfig.fromJson(result.config!.toJson());
        expect(roundTripped.type, type);
        expect(roundTripped.name, '站');
        expect(roundTripped.site.baseUrl, 'https://example.com');
        expect(roundTripped.validate(), isEmpty);
      }
    });

    test('站名为空报错且不构造配置', () {
      final result = buildManualSource(
        name: '   ',
        baseUrl: 'https://example.com',
        type: SourceType.novelSource,
      );
      expect(result.isValid, isFalse);
      expect(result.config, isNull);
      expect(result.errors, contains('请填写站名'));
    });

    test('地址非法逐项报错且不构造配置', () {
      const badUrls = <String>[
        '',
        '   ',
        'example.com',
        'ftp://example.com',
        'https://',
        'https://exa mple.com',
        'javascript:alert(1)',
      ];
      for (final url in badUrls) {
        final result = buildManualSource(
          name: '站',
          baseUrl: url,
          type: SourceType.novelSource,
        );
        expect(result.isValid, isFalse, reason: '地址 $url 应被拒');
        expect(result.config, isNull);
        expect(result.errors, isNotEmpty);
      }
    });

    test('带路径与端口的合法地址放行', () {
      final result = buildManualSource(
        name: '站',
        baseUrl: 'http://127.0.0.1:8080/sub/',
        type: SourceType.mangaSource,
      );
      expect(result.isValid, isTrue);
      expect(result.config!.site.baseUrl, 'http://127.0.0.1:8080/sub');
      expect(result.config!.site.domain, '127.0.0.1');
    });

    test('id 冲突时追加后缀，不覆盖已有源', () {
      expect(
        manualSourceIdFor(
          'https://example.com',
          <String>{'manual_example_com'},
        ),
        'manual_example_com_2',
      );
      expect(
        manualSourceIdFor(
          'https://example.com',
          <String>{'manual_example_com', 'manual_example_com_2'},
        ),
        'manual_example_com_3',
      );
      final result = buildManualSource(
        name: '同站二号',
        baseUrl: 'https://example.com',
        type: SourceType.novelSource,
        existingIds: <String>{'manual_example_com'},
      );
      expect(result.config!.id, 'manual_example_com_2');
    });

    test('新建成功经 addSource 注册进仓', () {
      final repo = SourceRepository(<PluginConfig>[]);
      final result = buildManualSource(
        name: '新站',
        baseUrl: 'https://new.example.com',
        type: SourceType.audioSource,
      );
      expect(result.isValid, isTrue);
      repo.addSource(result.config!);
      final stored = repo.getById(result.config!.id);
      expect(stored, isNotNull);
      expect(stored!.name, '新站');
      expect(stored.type, SourceType.audioSource);
    });

    test('校验不过不入库', () {
      final repo = SourceRepository(<PluginConfig>[]);
      final result = buildManualSource(
        name: '',
        baseUrl: 'not-a-url',
        type: SourceType.novelSource,
      );
      expect(result.isValid, isFalse);
      // 调用方只在校验通过时入库：此处模拟该口径，仓里应无新增。
      if (result.isValid) repo.addSource(result.config!);
      expect(repo.all, isEmpty);
    });

    test('新建后可在编辑页口径下改字段并保存', () {
      final repo = SourceRepository(<PluginConfig>[]);
      final created = buildManualSource(
        name: '待补规则站',
        baseUrl: 'https://edit.example.com',
        type: SourceType.animeSource,
      ).config!;
      repo.addSource(created);

      // 模拟编辑页保存：toJson 合并改动 → fromJson → validate → replaceSource。
      final doc = created.toJson();
      doc['name'] = '已改名';
      (doc['routes'] as Map<String, dynamic>)['search'] = <String, dynamic>{
        'url': '/search?q={keyword}',
        'method': 'get',
      };
      final edited = PluginConfig.fromJson(doc);
      expect(edited.validate(), isEmpty);
      repo.replaceSource(edited);

      final stored = repo.getById(created.id)!;
      expect(stored.name, '已改名');
      expect(stored.routes.keys, containsAll(<String>['latest', 'search']));
      expect(stored.routes['search']!.url, '/search?q={keyword}');
    });
  });
}
