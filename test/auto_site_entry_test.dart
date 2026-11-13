/// 爬取成功后自动进站点：决策测试。
///
/// 只测 UI 无关的决策层（模式门禁、生成结论判定、去重查找、基址与
/// id 推导）；界面接线（生成→注册→打开浏览页）走同一批手动/自动
/// 共用的服务方法，真机与真站端到端未验。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:wxyy/core/models/plugin_config.dart';
import 'package:wxyy/core/pygen/auto_site_entry.dart';
import 'package:wxyy/core/pygen/onekey_py_service.dart';
import 'package:wxyy/core/scraper/web_scrape_service.dart';
import 'package:wxyy/core/services/source_repository.dart';
import 'package:wxyy/core/spider/py_source_id.dart';
import 'package:wxyy/features/sources/presentation/py_import_sheet.dart';

PluginConfig _pySource({required String id, bool enabled = true}) =>
    PluginConfig(
      id: id,
      name: 'Test $id',
      type: SourceType.animeSource,
      site: const SiteConfig(domain: '', baseUrl: ''),
      parser: const ParserConfig(type: 'py'),
      spiderEngine:
          const SpiderEngineConfig(kind: 'py', sourceRef: 'file:test'),
      version: 1,
      enabled: enabled,
    );

PluginConfig _jsonSource({required String id}) => PluginConfig(
      id: id,
      name: 'JSON $id',
      type: SourceType.animeSource,
      site: const SiteConfig(
        domain: 'https://example.com',
        baseUrl: 'https://example.com',
      ),
      parser: const ParserConfig(type: 'builtin'),
      version: 1,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('isAutoEnterSiteMode', () {
    test('视频与通用模式自动进站', () {
      expect(isAutoEnterSiteMode(ScrapeMode.video), isTrue);
      expect(isAutoEnterSiteMode(ScrapeMode.general), isTrue);
    });

    test('小说/漫画/文章模式不自动进站', () {
      expect(isAutoEnterSiteMode(ScrapeMode.novel), isFalse);
      expect(isAutoEnterSiteMode(ScrapeMode.comic), isFalse);
      expect(isAutoEnterSiteMode(ScrapeMode.article), isFalse);
    });
  });

  group('planAutoSiteEntry', () {
    test('视频模式无已注册源→生成并打开', () {
      expect(
        planAutoSiteEntry(
          mode: ScrapeMode.video,
          existing: const ExistingSiteCheck(),
        ),
        AutoSiteAction.generateAndOpen,
      );
    });

    test('通用模式有活跃已注册源→直接打开', () {
      expect(
        planAutoSiteEntry(
          mode: ScrapeMode.general,
          existing: ExistingSiteCheck(active: _pySource(id: 'examplecom')),
        ),
        AutoSiteAction.openExisting,
      );
    });

    test('视频模式有未激活已注册源→提示启用不跳转', () {
      expect(
        planAutoSiteEntry(
          mode: ScrapeMode.video,
          existing: ExistingSiteCheck(
            inactive: _pySource(id: 'examplecom', enabled: false),
          ),
        ),
        AutoSiteAction.showInactiveNotice,
      );
    });

    test('小说模式即使有已注册源也不进站（模式门禁优先）', () {
      expect(
        planAutoSiteEntry(
          mode: ScrapeMode.novel,
          existing: ExistingSiteCheck(active: _pySource(id: 'examplecom')),
        ),
        AutoSiteAction.skip,
      );
    });
  });

  group('checkExistingSiteForBase', () {
    const String base = 'https://example.com';

    test('空仓库→未找到', () async {
      final ExistingSiteCheck found = await checkExistingSiteForBase(
        SourceRepository(<PluginConfig>[]),
        base,
        readCode: (_) async => 'SITE = "$base"',
      );
      expect(found.found, isFalse);
    });

    test('空基址→未找到且不读源码', () async {
      bool read = false;
      final ExistingSiteCheck found = await checkExistingSiteForBase(
        SourceRepository(<PluginConfig>[_pySource(id: 'examplecom')]),
        '',
        readCode: (_) async {
          read = true;
          return 'x';
        },
      );
      expect(found.found, isFalse);
      expect(read, isFalse);
    });

    test('活跃 py 源且源码含基址→active', () async {
      final ExistingSiteCheck found = await checkExistingSiteForBase(
        SourceRepository(<PluginConfig>[_pySource(id: 'examplecom')]),
        base,
        readCode: (_) async => 'SITE = "$base"\nclass Spider: pass',
      );
      expect(found.active?.id, 'examplecom');
      expect(found.inactive, isNull);
    });

    test('停用 py 源且源码含基址→inactive', () async {
      final ExistingSiteCheck found = await checkExistingSiteForBase(
        SourceRepository(<PluginConfig>[
          _pySource(id: 'examplecom', enabled: false),
        ]),
        base,
        readCode: (_) async => 'SITE = "$base"',
      );
      expect(found.active, isNull);
      expect(found.inactive?.id, 'examplecom');
    });

    test('py 源源码不含基址→未找到（id 碰撞不误认）', () async {
      final ExistingSiteCheck found = await checkExistingSiteForBase(
        SourceRepository(<PluginConfig>[_pySource(id: 'examplecom')]),
        base,
        readCode: (_) async => 'SITE = "https://other.example"',
      );
      expect(found.found, isFalse);
    });

    test('源码读不到→未找到', () async {
      final ExistingSiteCheck found = await checkExistingSiteForBase(
        SourceRepository(<PluginConfig>[_pySource(id: 'examplecom')]),
        base,
        readCode: (_) async => null,
      );
      expect(found.found, isFalse);
    });

    test('同 id 非 py 源 + _py 后缀 py 源→命中 _py 那个', () async {
      final ExistingSiteCheck found = await checkExistingSiteForBase(
        SourceRepository(<PluginConfig>[
          _jsonSource(id: 'examplecom'),
          _pySource(id: 'examplecom_py'),
        ]),
        base,
        readCode: (_) async => 'SITE = "$base"',
      );
      expect(found.active?.id, 'examplecom_py');
    });

    test('仅有同 id 非 py 源→未找到且不读源码', () async {
      bool read = false;
      final ExistingSiteCheck found = await checkExistingSiteForBase(
        SourceRepository(<PluginConfig>[_jsonSource(id: 'examplecom')]),
        base,
        readCode: (_) async {
          read = true;
          return 'SITE = "$base"';
        },
      );
      expect(found.found, isFalse);
      expect(read, isFalse);
    });
  });

  group('isRecognizedGeneration', () {
    OneKeyCodeResult gen(String templateId) => OneKeyCodeResult(
          code: 'x',
          fileName: 'examplecom.py',
          siteName: 'examplecom',
          base: 'https://example.com',
          templateId: templateId,
          mode: 'test',
          api: '',
        );

    test('CMS 模板算认得出结构', () {
      expect(isRecognizedGeneration(gen('apple_cms_v10')), isTrue);
      expect(isRecognizedGeneration(gen('maccms_html')), isTrue);
    });

    test('通用嗅探兜底不算认得出结构', () {
      expect(
        isRecognizedGeneration(
          gen(OneKeyPyService.genericTemplateId),
        ),
        isFalse,
      );
    });
  });

  group('originOf', () {
    test('取 scheme + host + 端口，去路径与查询串', () {
      expect(
        OneKeyPyService.originOf('https://example.com:8080/path?q=1'),
        'https://example.com:8080',
      );
      expect(
        OneKeyPyService.originOf('http://example.com/'),
        'http://example.com',
      );
    });

    test('缺 scheme 但有 host 默认 https', () {
      expect(
        OneKeyPyService.originOf('//example.com/x'),
        'https://example.com',
      );
    });

    test('无 host 返回空', () {
      expect(OneKeyPyService.originOf('not a url'), '');
      expect(OneKeyPyService.originOf('https://'), '');
      expect(OneKeyPyService.originOf(''), '');
      // 无 scheme 的裸 host 会被 Uri 认作 scheme，host 为空。
      expect(OneKeyPyService.originOf('example.com/x'), '');
    });
  });

  group('pySourceIdFromFileName', () {
    test('推导规则与导入侧一致', () {
      expect(pySourceIdFromFileName('MissAV.py'), 'missav');
      expect(pySourceIdFromFileName('my-site v2.py'), 'my_site_v2');
      expect(pySourceIdFromFileName('.py'), 'py_source');
      expect(pySourceIdFromFileName('dir/sub/demo.py'), 'demo');
    });

    test('与 PyImporter.idFromFileName 同一推导', () {
      const List<String> names = <String>[
        'MissAV.py',
        'my-site v2.py',
        '.py',
        'dir/sub/demo.py',
        'examplecom.py',
        'a-b_c.PY',
      ];
      for (final String name in names) {
        expect(
          pySourceIdFromFileName(name),
          PyImporter.idFromFileName(name),
          reason: name,
        );
      }
    });
  });
}
