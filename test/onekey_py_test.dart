import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wxyy/core/pygen/onekey_py_service.dart';
import 'package:wxyy/core/pygen/onekey_templates.dart';
import 'package:wxyy/core/scraper/verification_detector.dart';
import 'package:wxyy/core/services/source_repository.dart';

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.supportPath);

  final String supportPath;

  @override
  Future<String?> getApplicationSupportPath() async => supportPath;
}

const String _fakeTemplate = '''
class Spider:
    def getName(self):
        return "@NAME@"
    def init(self, extend=""):
        pass
    def homeContent(self, filter):
        return {}
    def homeVideoContent(self):
        return {}
    def categoryContent(self, tid, pg, filter, extend):
        return {}
    def detailContent(self, ids):
        return {}
    def searchContent(self, key, quick, pg=1):
        return {}
    def playerContent(self, flag, id, vipFlags):
        return {}
# @BASES@ @API@ @FORCE@ @MODE@ @TS@ @IMGPROXY@ @SITE@
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('域名模板匹配', () {
    test('probe 抠 host 建表，三档匹配', () {
      final map = buildDomainTemplateMap(<Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'apple_cms_v10',
          'detection': <String, dynamic>{
            'probe': <String>[
              'GET https://example.com/api.php/provide/vod?ac=list',
            ],
          },
        },
        <String, dynamic>{
          'id': 'other_site',
          'detection': <String, dynamic>{
            'probe': <String>['GET https://www.foo.bar/index'],
          },
        },
      ]);
      expect(
        matchDomainTemplate('https://example.com/x', map),
        'apple_cms_v10',
      );
      expect(
        matchDomainTemplate('https://www.example.com/x', map),
        'apple_cms_v10',
      );
      expect(matchDomainTemplate('https://foo.bar/x', map), 'other_site');
      expect(matchDomainTemplate('https://unknown.org/', map), isNull);
    });

    test('含占位符的 probe 跳过', () {
      final map = buildDomainTemplateMap(<Map<String, dynamic>>[
        <String, dynamic>{
          'id': 't1',
          'detection': <String, dynamic>{
            'probe': <String>['GET https://{host}/api'],
          },
        },
      ]);
      expect(map, isEmpty);
    });
  });

  group('命名', () {
    test('safeName 去 www 与端口、仅留字母数字汉字', () {
      expect(
        OneKeyPyService.safeName('https://www.example.com:8080/'),
        'examplecom',
      );
      expect(OneKeyPyService.safeName('https://foo-bar.cn/'), 'foobarcn');
    });

    test('sanitizeTitle 去引号反斜杠、空白折叠、截断', () {
      expect(
        OneKeyPyService.sanitizeTitle('A"B\\C   站'),
        'ABC 站',
      );
      expect(OneKeyPyService.sanitizeTitle(null), '');
      expect(OneKeyPyService.sanitizeTitle('   '), '');
      expect(
        OneKeyPyService.sanitizeTitle('一二三四五六七八九十一二三四五六七八九十甲乙丙丁'),
        '一二三四五六七八九十一二三四五六七八九十甲乙丙丁'.substring(0, 24),
      );
    });

    test('pythonReprList', () {
      expect(
        OneKeyPyService.pythonReprList(['https://a.com', 'https://b.com']),
        "['https://a.com', 'https://b.com']",
      );
    });
  });

  group('generateFromScrape 探测链（假网络）', () {
    late Directory tmpDir;

    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      tmpDir = await Directory.systemTemp.createTemp('onekey_test_');
      PathProviderPlatform.instance = _FakePathProvider(tmpDir.path);
    });

    tearDown(() async {
      if (await tmpDir.exists()) await tmpDir.delete(recursive: true);
    });

    test('苹果 CMS 命中 JSON 接口，产出代码但不注册', () async {
      Future<String> fetch(String url) async {
        if (url.contains('/api.php/provide/vod?ac=list')) {
          return jsonEncode(<String, dynamic>{
            'list': [
              <String, dynamic>{'vod_id': '1'},
            ],
          });
        }
        throw const SocketException('not found');
      }

      final service = OneKeyPyService(
        fetch: fetch,
        templateText: () async => _fakeTemplate,
      );
      final repo = SourceRepository();
      final result = await service.generateFromScrape(
        scrapeUrl: 'https://cms.example.com/vod/type/1.html',
        html: '<html><head><title>示例站</title></head></html>',
        pageTitle: '示例站',
      );
      expect(result.templateId, 'apple_cms_v10');
      expect(result.mode, 'apple cms json');
      expect(result.api, 'https://cms.example.com/api.php/provide/vod');
      expect(result.base, 'https://cms.example.com');
      expect(result.siteName, '示例站');
      expect(result.fileName, 'cmsexamplecom.py');
      expect(result.code, contains('https://cms.example.com'));
      // 默认不注册。
      expect(repo.getById('cmsexamplecom'), isNull);
    });

    test('MacCMS 特征由爬取 HTML 命中，首页不重新拉取', () async {
      Future<String> fetch(String url) async {
        if (url == 'https://mac.example.com/') {
          fail('首页不应被重新拉取');
        }
        throw const SocketException('not found');
      }

      final service = OneKeyPyService(
        fetch: fetch,
        templateText: () async => _fakeTemplate,
      );
      final result = await service.generateFromScrape(
        scrapeUrl: 'https://mac.example.com/',
        html: '<html><a href="/vod/detail/1.html">剧</a></html>',
      );
      expect(result.templateId, 'maccms_html');
      expect(result.mode, 'maccms html');
    });

    test('MacCMS 特征由已提取链接佐证命中', () async {
      Future<String> fetch(String url) async {
        throw const SocketException('not found');
      }

      final service = OneKeyPyService(
        fetch: fetch,
        templateText: () async => _fakeTemplate,
      );
      final result = await service.generateFromScrape(
        scrapeUrl: 'https://links.example.com/',
        html: '<html><body>plain</body></html>',
        linkUrls: <String>['https://links.example.com/vod/type/2.html'],
      );
      expect(result.templateId, 'maccms_html');
    });

    test('都未中走通用嗅探兜底，源名取页面标题', () async {
      Future<String> fetch(String url) async {
        throw const SocketException('not found');
      }

      final service = OneKeyPyService(
        fetch: fetch,
        templateText: () async => _fakeTemplate,
      );
      final result = await service.generateFromScrape(
        scrapeUrl: 'https://plain.example.com/list?page=2',
        html: '<html>hello</html>',
        pageTitle: '普通小站',
      );
      expect(result.templateId, 'generic_html');
      expect(result.siteName, '普通小站');
      expect(result.base, 'https://plain.example.com');
    });

    test('无页面内容时诚实报错', () async {
      final service = OneKeyPyService(
        fetch: (_) async => '',
        templateText: () async => _fakeTemplate,
      );
      await expectLater(
        service.generateFromScrape(
          scrapeUrl: 'https://empty.example.com/',
          html: '   ',
        ),
        throwsA(isA<OneKeyException>()),
      );
    });

    test('爬取地址解析不出基址时诚实报错', () async {
      final service = OneKeyPyService(
        fetch: (_) async => '',
        templateText: () async => _fakeTemplate,
      );
      await expectLater(
        service.generateFromScrape(
          scrapeUrl: 'not a url at all',
          html: '<html>x</html>',
        ),
        throwsA(isA<OneKeyException>()),
      );
    });

    test('命中验证页时转为带指引的错误、不绕过', () async {
      Future<String> fetch(String url) async {
        throw const VerificationRequiredException(
          url: 'https://w.example.com/',
        );
      }

      final service = OneKeyPyService(
        fetch: fetch,
        templateText: () async => _fakeTemplate,
      );
      try {
        await service.generateFromScrape(
          scrapeUrl: 'https://w.example.com/',
          html: '<html>x</html>',
        );
        fail('应当抛 OneKeyVerificationException');
      } on OneKeyVerificationException catch (e) {
        expect(e.message, contains('验证'));
      }
    });

    test('registerGenerated 注册进站点列表，重复注册判更新', () async {
      Future<String> fetch(String url) async {
        throw const SocketException('not found');
      }

      final service = OneKeyPyService(
        fetch: fetch,
        templateText: () async => _fakeTemplate,
      );
      final repo = SourceRepository();
      final code = await service.generateFromScrape(
        scrapeUrl: 'https://reg.example.com/',
        html: '<html>hello</html>',
      );
      final first = await service.registerGenerated(
        repo: repo,
        generated: code,
      );
      expect(first.config.id, 'regexamplecom');
      expect(first.updated, isFalse);
      expect(repo.getById('regexamplecom'), isNotNull);
      expect(repo.getById('regexamplecom')!.isPySource, isTrue);

      final second = await service.registerGenerated(
        repo: repo,
        generated: code,
      );
      expect(second.updated, isTrue);
    });
  });
}
