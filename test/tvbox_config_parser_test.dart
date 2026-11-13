import 'package:flutter_test/flutter_test.dart';
import 'package:wxyy/core/models/plugin_config.dart';
import 'package:wxyy/core/sources/tvbox_config_parser.dart';

void main() {
  group('parseTvboxConfig format recognition', () {
    test('bad JSON is not recognized', () {
      expect(parseTvboxConfig('{oops').isRecognized, isFalse);
    });

    test('empty text is not recognized', () {
      expect(parseTvboxConfig('  ').isRecognized, isFalse);
    });

    test('PluginConfig JSON without sites is not recognized', () {
      const text = '{"id":"x","name":"X","type":"animeSource",'
          '"site":{"domain":"a.com","baseUrl":"https://a.com"},'
          '"parser":{"type":"builtin"}}';
      expect(parseTvboxConfig(text).isRecognized, isFalse);
    });

    test('JSON array is not recognized', () {
      expect(parseTvboxConfig('[{"key":"a"}]').isRecognized, isFalse);
    });

    test('sites key marks TVBox flavor', () {
      const text = '{"sites":[]}';
      final result = parseTvboxConfig(text);
      expect(result.isRecognized, isTrue);
      expect(result.flavor, 'tvbox');
    });

    test('BOM-prefixed config is recognized', () {
      const text = '\uFEFF{"sites":[]}';
      expect(parseTvboxConfig(text).isRecognized, isTrue);
    });
  });

  group('collect mapping (type 0/1)', () {
    test('type 1 maps to builtin config with MacCMS routes', () {
      const text = '{"sites":[{"key":"demo","name":"演示站","type":1,'
          '"api":"https://demo.example.com/api.php/provide/vod/"}]}';
      final result = parseTvboxConfig(text);
      expect(result.isRecognized, isTrue);
      expect(result.drafts, hasLength(1));
      final draft = result.drafts.first;
      expect(draft.kind, TvboxSiteKind.collect);
      final config = buildCollectConfig(draft);
      expect(config.id, 'demo');
      expect(config.name, '演示站');
      expect(config.type, SourceType.animeSource);
      expect(config.parser.type, 'builtin');
      expect(config.site.baseUrl, 'https://demo.example.com');
      expect(config.site.domain, 'demo.example.com');
      expect(
        config.routes['latest']!.url,
        'https://demo.example.com/api.php/provide/vod/?ac=list&pg={page}',
      );
      expect(
        config.routes['search']!.url,
        contains('ac=list&wd={keyword}'),
      );
      expect(config.routes['detail']!.url, contains('ac=detail&ids={id}'));
      expect(config.routes['episodes']!.url, contains('ac=detail&ids={id}'));
      expect(config.category.dynamicCategories, isTrue);
      expect(config.validate(), isEmpty);
      // TVBox 格式没有源自带分级信息，不编造 ageRating。
      expect(config.ageRating, SourceAgeRating.general);
    });

    test('type 0 maps the same way as type 1', () {
      const text = '{"sites":[{"key":"xml","name":"XML站","type":0,'
          '"api":"http://xml.example.com:8080/api.php/provide/vod/?ac=list"}]}';
      final result = parseTvboxConfig(text);
      expect(result.drafts.first.kind, TvboxSiteKind.collect);
      final config = buildCollectConfig(result.drafts.first);
      expect(config.site.baseUrl, 'http://xml.example.com:8080');
      expect(config.validate(), isEmpty);
    });

    test('type given as string is coerced', () {
      const text = '{"sites":[{"key":"s","name":"S","type":"1",'
          '"api":"https://s.example.com/api.php/provide/vod/"}]}';
      expect(parseTvboxConfig(text).drafts.first.kind, TvboxSiteKind.collect);
    });

    test('collect api without http scheme fails with reason', () {
      const text = '{"sites":[{"key":"bad","name":"坏站","type":1,'
          '"api":"ftp://bad.example.com/vod"}]}';
      final result = parseTvboxConfig(text);
      expect(result.failures, hasLength(1));
      expect(result.failures.first.reason, contains('http'));
    });

    test('name falls back to key', () {
      const text = '{"sites":[{"key":"onlykey","type":1,'
          '"api":"https://k.example.com/api.php/provide/vod/"}]}';
      final draft = parseTvboxConfig(text).drafts.first;
      expect(draft.name, 'onlykey');
      expect(buildCollectConfig(draft).name, 'onlykey');
    });
  });

  group('jar mapping (type 3 csp_)', () {
    test('csp_ api with jar url is a jar draft', () {
      const text = '{"jar":"https://cdn.example.com/csp.jar","sites":['
          '{"key":"j","name":"J站","type":3,"api":"csp_J","ext":"{}"}]}';
      final result = parseTvboxConfig(text);
      expect(result.jarReference, 'https://cdn.example.com/csp.jar');
      expect(result.drafts.first.kind, TvboxSiteKind.jar);
    });

    test('buildJarConfig keeps api/ext and jar asset', () {
      const text = '{"jar":"https://cdn.example.com/csp.jar","sites":['
          '{"key":"j","name":"J站","type":3,"api":"csp_J",'
          '"ext":{"token":"abc","n":1}}]}';
      final draft = parseTvboxConfig(text).drafts.first;
      final config = buildJarConfig(draft, jarAsset: 'file:/tmp/csp.jar');
      expect(config.parser.type, 'jar');
      expect(config.isJarSource, isTrue);
      expect(config.spiderEngine!.kind, 'jar');
      expect(config.spiderEngine!.asset, 'file:/tmp/csp.jar');
      expect(config.spiderEngine!.api, 'csp_J');
      expect(config.spiderEngine!.ext, '{"token":"abc","n":1}');
      expect(config.validate(), isEmpty);
      expect(config.ageRating, SourceAgeRating.general);
    });

    test('java class name api is a jar draft', () {
      const text = '{"sites":[{"key":"j","name":"J","type":3,'
          '"api":"com.github.catvod.spider.J"}]}';
      expect(
        parseTvboxConfig(text).drafts.first.kind,
        TvboxSiteKind.jar,
      );
    });

    test('buildReadyConfigs excludes jar drafts without jarAsset', () {
      const text = '{"sites":[{"key":"j","name":"J","type":3,"api":"csp_J"}]}';
      final result = parseTvboxConfig(text);
      expect(buildReadyConfigs(result), isEmpty);
    });

    test('buildReadyConfigs includes jar drafts with jarAsset', () {
      const text = '{"sites":[{"key":"j","name":"J","type":3,"api":"csp_J"}]}';
      final result = parseTvboxConfig(text);
      final configs =
          buildReadyConfigs(result, jarAsset: 'assets/jars/zakatv.jar');
      expect(configs, hasLength(1));
      expect(configs.first.spiderEngine!.asset, 'assets/jars/zakatv.jar');
    });
  });

  group('catvod spider mapping', () {
    test('spider field is jar reference and flavor is catvod', () {
      const text = '{"spider":"https://cdn.example.com/catvod.jar","sites":['
          '{"key":"c","name":"C站","type":3,"api":"csp_C"}]}';
      final result = parseTvboxConfig(text);
      expect(result.flavor, 'catvod');
      expect(result.jarReference, 'https://cdn.example.com/catvod.jar');
      expect(result.drafts.first.kind, TvboxSiteKind.jar);
      final config = buildJarConfig(
        result.drafts.first,
        jarAsset: 'file:/tmp/catvod.jar',
      );
      expect(config.note, contains('猫源'));
    });

    test('jar field wins over spider when both present', () {
      const text = '{"jar":"https://a.example.com/a.jar",'
          '"spider":"https://b.example.com/b.jar","sites":[]}';
      final result = parseTvboxConfig(text);
      expect(result.jarReference, 'https://a.example.com/a.jar');
    });
  });

  group('py mapping (type 3 .py)', () {
    test('.py api url is a py draft', () {
      const text = '{"sites":[{"key":"p","name":"P站","type":3,'
          '"api":"https://cdn.example.com/p.py"}]}';
      expect(parseTvboxConfig(text).drafts.first.kind, TvboxSiteKind.py);
    });

    test('.py with query string is a py draft', () {
      const text = '{"sites":[{"key":"p","name":"P","type":3,'
          '"api":"https://cdn.example.com/p.py?v=2"}]}';
      expect(parseTvboxConfig(text).drafts.first.kind, TvboxSiteKind.py);
    });
  });

  group('failures', () {
    test('.js api fails with JS reason', () {
      const text = '{"sites":[{"key":"js","name":"JS站","type":3,'
          '"api":"https://cdn.example.com/s.js"}]}';
      final result = parseTvboxConfig(text);
      expect(result.drafts.first.kind, TvboxSiteKind.unsupported);
      expect(result.failures.first.reason, contains('JS'));
    });

    test('unknown api shape fails with reason', () {
      const text = '{"sites":[{"key":"u","name":"U","type":3,'
          '"api":"mystery_api"}]}';
      final result = parseTvboxConfig(text);
      expect(result.failures, hasLength(1));
      expect(result.failures.first.reason, contains('api'));
    });

    test('missing key fails', () {
      const text = '{"sites":[{"name":"无Key","type":1,'
          '"api":"https://a.example.com/api.php/provide/vod/"}]}';
      final result = parseTvboxConfig(text);
      expect(result.drafts, isEmpty);
      expect(result.failures.first.reason, contains('key'));
    });

    test('duplicate key fails', () {
      const text = '{"sites":['
          '{"key":"d","name":"一","type":1,"api":"https://a.example.com/api.php/provide/vod/"},'
          '{"key":"d","name":"二","type":1,"api":"https://b.example.com/api.php/provide/vod/"}]}';
      final result = parseTvboxConfig(text);
      expect(result.drafts, hasLength(1));
      expect(result.failures, hasLength(1));
      expect(result.failures.first.reason, contains('重复'));
    });

    test('unsupported type fails', () {
      const text = '{"sites":[{"key":"t","name":"T","type":4,'
          '"api":"https://t.example.com/"}]}';
      final result = parseTvboxConfig(text);
      expect(result.failures.first.reason, contains('type 4'));
    });

    test('missing type fails', () {
      const text = '{"sites":[{"key":"t","name":"T",'
          '"api":"https://t.example.com/"}]}';
      expect(parseTvboxConfig(text).failures, hasLength(1));
    });

    test('non-object site entry fails', () {
      const text = '{"sites":["oops"]}';
      final result = parseTvboxConfig(text);
      expect(result.drafts, isEmpty);
      expect(result.failures, hasLength(1));
    });

    test('sites not a list fails but still recognized', () {
      final result = parseTvboxConfig('{"sites":"x"}');
      expect(result.isRecognized, isTrue);
      expect(result.failures, hasLength(1));
    });

    test('empty sites fails with reason', () {
      final result = parseTvboxConfig('{"sites":[]}');
      expect(result.failures, hasLength(1));
      expect(result.failures.first.reason, contains('空'));
    });
  });

  group('unsupported sections', () {
    test('parses/rules/lives are listed, not imported', () {
      const text = '{"sites":[],'
          '"parses":[{"name":"p1"},{"name":"p2"}],'
          '"rules":[{"name":"r1"}],'
          '"lives":[{"name":"l1","channels":[]}]}';
      final result = parseTvboxConfig(text);
      expect(result.unsupportedSections, hasLength(3));
      expect(result.unsupportedSections.join('\n'), contains('parses'));
      expect(result.unsupportedSections.join('\n'), contains('rules'));
      expect(result.unsupportedSections.join('\n'), contains('lives'));
      expect(result.unsupportedSections.join('\n'), contains('共 2 项'));
    });
  });

  group('resolveTvboxReference', () {
    test('absolute url passes through', () {
      expect(
        resolveTvboxReference('https://a.example.com/c.jar', null),
        'https://a.example.com/c.jar',
      );
    });

    test('relative resolves against base', () {
      expect(
        resolveTvboxReference(
            './c.jar', 'https://a.example.com/conf/config.json'),
        'https://a.example.com/conf/c.jar',
      );
    });

    test('relative without base returns null', () {
      expect(resolveTvboxReference('./c.jar', null), isNull);
    });

    test('absolute path passes through', () {
      expect(
        resolveTvboxReference('/data/x/c.jar', null),
        '/data/x/c.jar',
      );
    });
  });

  group('tvboxExtToString', () {
    test('string/null/object', () {
      expect(tvboxExtToString('abc'), 'abc');
      expect(tvboxExtToString(null), '');
      expect(tvboxExtToString({'a': 1}), '{"a":1}');
      expect(tvboxExtToString(7), '7');
    });
  });
}
