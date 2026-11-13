import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wxyy/core/models/plugin_config.dart';
import 'package:wxyy/core/services/site_backup_service.dart';
import 'package:wxyy/core/services/source_repository.dart';
import 'package:wxyy/core/spider/py_source_store.dart';

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.supportPath);

  final String supportPath;

  @override
  Future<String?> getApplicationSupportPath() async => supportPath;
}

const String _pyCodeFile =
    'class Spider:\n    def getName(self):\n        return "py_demo"\n';
const String _pyCodeAsset =
    'class Spider:\n    def getName(self):\n        return "py_asset_demo"\n';

PluginConfig _jsonConfig({
  String id = 'json_demo',
  String name = '演示站',
  int version = 1,
}) =>
    PluginConfig.fromJson(<String, dynamic>{
      'id': id,
      'name': name,
      'type': 'animeSource',
      'version': version,
      'site': <String, dynamic>{
        'domain': 'example.com',
        'baseUrl': 'https://example.com',
      },
      'parser': <String, dynamic>{'type': 'builtin'},
      'routes': <String, dynamic>{
        'latest': 'https://example.com/latest?page={page}',
      },
    });

PluginConfig _pyFileConfig({
  String id = 'py_demo',
  String name = 'py 演示站',
}) =>
    PluginConfig.fromJson(<String, dynamic>{
      'id': id,
      'name': name,
      'type': 'animeSource',
      'version': 1,
      'site': <String, dynamic>{'domain': '', 'baseUrl': ''},
      'parser': <String, dynamic>{'type': 'py'},
      'spiderEngine': <String, dynamic>{
        'kind': 'py',
        'sourceRef': 'file:$id',
      },
    });

PluginConfig _pyAssetConfig({
  String id = 'py_asset_demo',
  String name = '内置 py 演示站',
}) =>
    PluginConfig.fromJson(<String, dynamic>{
      'id': id,
      'name': name,
      'type': 'animeSource',
      'version': 1,
      'site': <String, dynamic>{'domain': '', 'baseUrl': ''},
      'parser': <String, dynamic>{'type': 'py'},
      'spiderEngine': <String, dynamic>{
        'kind': 'py',
        'asset': 'assets/py_spiders/demo.py',
        'sourceRef': 'asset:assets/py_spiders/demo.py',
      },
    });

PluginConfig _jarConfig({
  String id = 'jar_demo',
  String name = 'jar 演示站',
}) =>
    PluginConfig.fromJson(<String, dynamic>{
      'id': id,
      'name': name,
      'type': 'animeSource',
      'version': 1,
      'site': <String, dynamic>{'domain': '', 'baseUrl': ''},
      'parser': <String, dynamic>{'type': 'jar'},
      'spiderEngine': <String, dynamic>{
        'kind': 'jar',
        'asset': 'assets/jars/zakatv.jar',
        'api': 'csp_Demo',
        'ext': '{}',
      },
    });

/// 假 py 源码库：file: 引用按 id 查，asset: 引用按完整 sourceRef 查。
Future<String?> _fakeRead(Map<String, String> store, PluginConfig c) async {
  final ref = c.spiderEngine?.sourceRef ?? '';
  if (ref.startsWith('file:')) return store[ref.substring('file:'.length)];
  if (ref.startsWith('asset:')) return store[ref];
  final asset = c.spiderEngine?.asset;
  if (asset != null) return store['asset:$asset'];
  return store[c.id];
}

SiteBackupService _service({
  required Map<String, String> pyStore,
  Set<String> assets = const <String>{},
}) =>
    SiteBackupService(
      readPySource: (c) => _fakeRead(pyStore, c),
      savePySource: (id, code) async {
        pyStore[id] = code;
        return 'file:$id';
      },
      assetExists: (path) async => assets.contains(path),
    );

String _canonical(PluginConfig c) =>
    jsonEncode(PluginConfig.fromJson(c.toJson()).toJson());

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmpDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tmpDir = await Directory.systemTemp.createTemp('site_backup_test_');
    PathProviderPlatform.instance = _FakePathProvider(tmpDir.path);
  });

  tearDown(() async {
    if (await tmpDir.exists()) await tmpDir.delete(recursive: true);
  });

  group('备份格式', () {
    test('顶层含 format 与 version，py 内嵌源码、jar 带引用', () async {
      final repo = SourceRepository();
      repo.addSource(_jsonConfig());
      repo.addSource(_pyFileConfig());
      repo.addSource(_jarConfig());
      final pyStore = <String, String>{'py_demo': _pyCodeFile};
      final result = await _service(
        pyStore: pyStore,
        assets: <String>{'assets/jars/zakatv.jar'},
      ).exportBackup(repo);

      final decoded = jsonDecode(result.jsonText) as Map<String, dynamic>;
      expect(decoded['format'], 'wxyy-site-backup');
      expect(decoded['version'], 1);
      expect(decoded['siteCount'], 3);
      final sites = decoded['sites'] as List;
      expect(sites, hasLength(3));
      final byId = <String, Map<String, dynamic>>{
        for (final s in sites)
          (s as Map)['id'] as String: s as Map<String, dynamic>,
      };
      expect(byId['json_demo']!['kind'], 'json');
      expect(byId['json_demo']!['config']['name'], '演示站');
      expect(byId['py_demo']!['kind'], 'py');
      expect(byId['py_demo']!['pySource'], _pyCodeFile);
      expect(byId['jar_demo']!['kind'], 'jar');
      final jarRef = byId['jar_demo']!['jarRef'] as Map<String, dynamic>;
      expect(jarRef['asset'], 'assets/jars/zakatv.jar');
      expect(jarRef['api'], 'csp_Demo');
      expect(jarRef['ext'], '{}');
      expect(result.hasProblems, isFalse);
    });
  });

  group('导出→清空→导入一致', () {
    test('内置 + 导入站全覆盖，配置/py/jar 引用一致、validate 通过', () async {
      final source = SourceRepository();
      source
          .seedBuiltinsForTest(<PluginConfig>[_jsonConfig(id: 'builtin_json')]);
      source.addSource(_pyFileConfig());
      source.addSource(_pyAssetConfig());
      source.addSource(_jarConfig());
      final exportStore = <String, String>{
        'py_demo': _pyCodeFile,
        'asset:assets/py_spiders/demo.py': _pyCodeAsset,
      };
      const assets = <String>{
        'assets/py_spiders/demo.py',
        'assets/jars/zakatv.jar',
      };
      final exported = await _service(
        pyStore: exportStore,
        assets: assets,
      ).exportBackup(source);
      expect(exported.total, 4);
      expect(exported.pyEmbedded, 2);
      expect(exported.pyFailures, isEmpty);
      expect(exported.jarUnverified, isEmpty);

      // 清空：全新空注册表 + 空 py 库，模拟换机恢复。
      final target = SourceRepository();
      final restoreStore = <String, String>{};
      final outcome = await _service(
        pyStore: restoreStore,
        assets: assets,
      ).restoreBackup(target, exported.jsonText);
      expect(outcome.fileError, isNull);
      expect(outcome.added, 4);
      expect(outcome.failed, 0);

      final before = <String, PluginConfig>{
        for (final c in source.all) c.id: c,
      };
      final after = <String, PluginConfig>{
        for (final c in target.all) c.id: c,
      };
      expect(after.keys.toSet(), before.keys.toSet());
      for (final id in before.keys) {
        expect(_canonical(after[id]!), _canonical(before[id]!),
            reason: '$id 配置应一致');
        expect(after[id]!.validate(), isEmpty, reason: '$id 应校验通过');
      }
      // py 源码一致（含内置 py 的落盘副本）。
      expect(restoreStore['py_demo'], _pyCodeFile);
      expect(restoreStore['py_asset_demo'], _pyCodeAsset);
      // jar 引用一致。
      final jar = after['jar_demo']!.spiderEngine!;
      expect(jar.asset, 'assets/jars/zakatv.jar');
      expect(jar.api, 'csp_Demo');
      expect(jar.ext, '{}');
    });

    test('内置 py 资源缺失时改走落盘副本 file: 引用', () async {
      final source = SourceRepository();
      source.addSource(_pyAssetConfig());
      final exportStore = <String, String>{
        'asset:assets/py_spiders/demo.py': _pyCodeAsset,
      };
      final exported = await _service(
        pyStore: exportStore,
        assets: <String>{'assets/py_spiders/demo.py'},
      ).exportBackup(source);

      final target = SourceRepository();
      final restoreStore = <String, String>{};
      final outcome = await _service(
        pyStore: restoreStore,
        assets: <String>{},
      ).restoreBackup(target, exported.jsonText);
      expect(outcome.added, 1);
      final restored = target.getById('py_asset_demo')!;
      expect(restored.spiderEngine!.sourceRef, 'file:py_asset_demo');
      expect(restoreStore['py_asset_demo'], _pyCodeAsset);
      expect(restored.validate(), isEmpty);
    });

    test('默认 PySourceStore 路径替身往返', () async {
      await PySourceStore.saveSource('real_py', _pyCodeFile);
      final source = SourceRepository();
      source.addSource(_pyFileConfig(id: 'real_py'));
      final exported = await SiteBackupService().exportBackup(source);
      expect(exported.pyEmbedded, 1);
      expect(exported.jsonText, contains('real_py'));

      // 删掉落盘文件再恢复，验证恢复会重新写盘。
      await PySourceStore.deleteSource('real_py');
      expect(await PySourceStore.readImported('real_py'), isNull);
      final target = SourceRepository();
      final outcome =
          await SiteBackupService().restoreBackup(target, exported.jsonText);
      expect(outcome.added, 1);
      expect(await PySourceStore.readImported('real_py'), _pyCodeFile);
    });
  });

  group('合并去重', () {
    test('新增 / 已存在跳过 / 内容不同不覆盖', () async {
      final target = SourceRepository();
      target.addSource(_jsonConfig(id: 'a', name: 'A站'));
      target.addSource(_jsonConfig(id: 'b', name: 'B站旧'));

      final source = SourceRepository();
      source.addSource(_jsonConfig(id: 'a', name: 'A站'));
      // 备份里的 B 版本更高、名字不同：仍不得覆盖现有站点。
      source.addSource(_jsonConfig(id: 'b', name: 'B站新', version: 99));
      source.addSource(_jsonConfig(id: 'c', name: 'C站'));
      final exported =
          await _service(pyStore: <String, String>{}).exportBackup(source);

      final outcome = await _service(pyStore: <String, String>{})
          .restoreBackup(target, exported.jsonText);
      expect(outcome.added, 1);
      expect(outcome.skippedExisting, 1);
      expect(outcome.skippedDifferent, 1);
      expect(outcome.failed, 0);
      expect(target.getById('b')!.name, 'B站旧');
      expect(target.getById('b')!.version, 1);
      expect(target.getById('c')!.name, 'C站');
      expect(
        outcome.issues.where((i) => i.siteId == 'b').single.reason,
        contains('未覆盖'),
      );
    });

    test('py 源码不同也算内容不同，不覆盖', () async {
      final target = SourceRepository();
      target.addSource(_pyFileConfig());
      final targetStore = <String, String>{'py_demo': 'old code'};
      final source = SourceRepository();
      source.addSource(_pyFileConfig());
      final exported = await _service(
        pyStore: <String, String>{'py_demo': _pyCodeFile},
      ).exportBackup(source);

      final outcome = await _service(pyStore: targetStore)
          .restoreBackup(target, exported.jsonText);
      expect(outcome.added, 0);
      expect(outcome.skippedDifferent, 1);
      expect(targetStore['py_demo'], 'old code');
    });

    test('备份内重复 id 只处理第一条', () async {
      final payload = <String, dynamic>{
        'format': 'wxyy-site-backup',
        'version': 1,
        'exportedAt': '2026-11-13T00:00:00.000',
        'app': 'wxyy',
        'siteCount': 2,
        'sites': <dynamic>[
          <String, dynamic>{
            'id': 'dup',
            'kind': 'json',
            'config': _jsonConfig(id: 'dup').toJson(),
          },
          <String, dynamic>{
            'id': 'dup',
            'kind': 'json',
            'config': _jsonConfig(id: 'dup').toJson(),
          },
        ],
      };
      final outcome = await _service(pyStore: <String, String>{})
          .restoreBackup(SourceRepository(), jsonEncode(payload));
      expect(outcome.added, 1);
      expect(outcome.skippedExisting, 1);
      expect(outcome.failed, 0);
    });
  });

  group('损坏与缺失如实报失败', () {
    test('损坏备份文件报文件级失败、不崩、不注册', () async {
      const badTexts = <String>[
        'not json{{{',
        '',
        '[]',
        '{"format":"wxyy-site-backup"}',
        '{"format":"other-format","version":1,"sites":[]}',
        '{"format":"wxyy-site-backup","version":99,"sites":[]}',
        '{"format":"wxyy-site-backup","version":1}',
        '{"format":"wxyy-site-backup","version":1,"sites":{}}',
      ];
      for (final text in badTexts) {
        final repo = SourceRepository();
        repo.addSource(_jsonConfig(id: 'keep'));
        final outcome = await _service(pyStore: <String, String>{})
            .restoreBackup(repo, text);
        expect(outcome.fileError, isNotNull, reason: '应报文件级失败：$text');
        expect(outcome.added, 0);
        expect(repo.all, hasLength(1));
        expect(repo.getById('keep'), isNotNull);
      }
    });

    test('py 读不到记失败项，恢复时资源缺失则不注册', () async {
      final source = SourceRepository();
      source.addSource(_pyFileConfig());
      final exported = await _service(
        pyStore: <String, String>{},
        assets: <String>{},
      ).exportBackup(source);
      expect(exported.pyFailures, hasLength(1));
      expect(exported.pyFailures.single.siteId, 'py_demo');
      final decoded = jsonDecode(exported.jsonText) as Map<String, dynamic>;
      final entry = (decoded['sites'] as List).single as Map<String, dynamic>;
      expect(entry['pySource'], isNull);

      final target = SourceRepository();
      final outcome = await _service(
        pyStore: <String, String>{},
        assets: <String>{},
      ).restoreBackup(target, exported.jsonText);
      expect(outcome.added, 0);
      expect(outcome.failed, 1);
      expect(target.all, isEmpty);
      expect(outcome.issues.single.reason, contains('py 源码缺失'));
    });

    test('无内嵌源码但包内资源在，py 站仍可恢复', () async {
      final payload = <String, dynamic>{
        'format': 'wxyy-site-backup',
        'version': 1,
        'sites': <dynamic>[
          <String, dynamic>{
            'id': 'py_asset_demo',
            'kind': 'py',
            'config': _pyAssetConfig().toJson(),
            'pySource': null,
          },
        ],
      };
      final target = SourceRepository();
      final outcome = await _service(
        pyStore: <String, String>{},
        assets: <String>{'assets/py_spiders/demo.py'},
      ).restoreBackup(target, jsonEncode(payload));
      expect(outcome.added, 1);
      expect(outcome.failed, 0);
    });

    test('jar 引用缺失报缺、不注册；引用在则注册', () async {
      final source = SourceRepository();
      source.addSource(_jarConfig());
      final exported = await _service(
        pyStore: <String, String>{},
        assets: <String>{'assets/jars/zakatv.jar'},
      ).exportBackup(source);

      final missing = SourceRepository();
      final failedOutcome = await _service(
        pyStore: <String, String>{},
        assets: <String>{},
      ).restoreBackup(missing, exported.jsonText);
      expect(failedOutcome.added, 0);
      expect(failedOutcome.failed, 1);
      expect(missing.all, isEmpty);
      expect(failedOutcome.issues.single.reason, contains('zakatv.jar'));

      final present = SourceRepository();
      final okOutcome = await _service(
        pyStore: <String, String>{},
        assets: <String>{'assets/jars/zakatv.jar'},
      ).restoreBackup(present, exported.jsonText);
      expect(okOutcome.added, 1);
      expect(present.getById('jar_demo')!.validate(), isEmpty);
    });

    test('校验不通过的站不注册，其余站继续', () async {
      final bad = _jsonConfig(id: 'bad').toJson()..['name'] = '';
      final payload = <String, dynamic>{
        'format': 'wxyy-site-backup',
        'version': 1,
        'sites': <dynamic>[
          <String, dynamic>{
            'id': 'bad',
            'kind': 'json',
            'config': bad,
          },
          <String, dynamic>{
            'id': 'good',
            'kind': 'json',
            'config': _jsonConfig(id: 'good').toJson(),
          },
          'not-an-object',
          <String, dynamic>{'id': 'noconfig'},
        ],
      };
      final repo = SourceRepository();
      final outcome = await _service(pyStore: <String, String>{})
          .restoreBackup(repo, jsonEncode(payload));
      expect(outcome.added, 1);
      expect(outcome.failed, 3);
      expect(repo.getById('good'), isNotNull);
      expect(repo.getById('bad'), isNull);
    });
  });
}
