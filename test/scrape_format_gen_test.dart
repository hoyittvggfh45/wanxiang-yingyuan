import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wxyy/core/models/plugin_config.dart';
import 'package:wxyy/core/pygen/scrape_format_gen.dart';
import 'package:wxyy/core/pygen/scrape_structure.dart';
import 'package:wxyy/core/scraper/web_scrape_service.dart';
import 'package:wxyy/core/services/source_repository.dart';
import 'package:wxyy/core/sources/source_text_scanner.dart';
import 'package:wxyy/features/shuyuan/shuyuan_adapter.dart';
import 'package:wxyy/features/shuyuan/shuyuan_source_service.dart';

const _novelHtml = '''
<html><head><title>测试小说网</title></head><body>
<nav class="mainnav">
  <a href="/genre/xuanhuan/">玄幻</a>
  <a href="/genre/xianxia/">仙侠</a>
  <a href="/genre/dushi/">都市</a>
</nav>
<form action="/search.php" method="get">
  <input type="text" name="keyword">
  <input type="submit" value="搜索">
</form>
<h1>第一章 山村少年</h1>
<div id="content">
  <p>这是第一段正文内容，山村少年韩立自幼家贫。</p>
  <p>这是第二段正文内容，内容很长很长很长很长很长很长。</p>
  <p>这是第三段正文内容，内容很长很长很长很长很长很长。</p>
</div>
<div class="chapters">
  <a href="/book/123/1.html">第1章 山村少年</a>
  <a href="/book/123/2.html">第2章 青牛镇</a>
  <a href="/book/123/3.html">第3章 七玄门</a>
  <a href="/book/123/4.html">第4章 初入山门</a>
</div>
<div class="booklist">
  <a href="/book/123/"><img src="/covers/1.jpg"><h3>凡人修仙传</h3></a>
  <a href="/book/456/"><img src="/covers/2.jpg"><h3>遮天</h3></a>
  <a href="/book/789/"><img src="/covers/3.jpg"><h3>斗破苍穹</h3></a>
</div>
<a href="/book/123/2.html">下一章</a>
</body></html>
''';

const _comicHtml = '''
<html><head><title>测试漫画网</title></head><body>
<nav class="topnav">
  <a href="/genre/rexue/">热血</a>
  <a href="/genre/maoxian/">冒险</a>
</nav>
<form action="/s" method="get">
  <input type="text" name="q">
  <input type="submit" value="搜索">
</form>
<h1>海贼王</h1>
<div class="comiclist">
  <a href="/manga/111/"><img src="/c/1.jpg"><h3>海贼王</h3></a>
  <a href="/manga/222/"><img src="/c/2.jpg"><h3>火影忍者</h3></a>
  <a href="/manga/333/"><img src="/c/3.jpg"><h3>死神</h3></a>
  <a href="/manga/444/"><img src="/c/4.jpg"><h3>龙珠</h3></a>
</div>
<div class="chapterlist">
  <a href="/manga/111/1.html">第1话 罗杰的时代</a>
  <a href="/manga/111/2.html">第2话 少年路飞</a>
  <a href="/manga/111/3.html">第3话 出海</a>
</div>
<div class="images">
  <img src="/p/1.jpg"><img src="/p/2.jpg"><img src="/p/3.jpg"><img src="/p/4.jpg">
</div>
</body></html>
''';

const _bareHtml =
    '<html><head><title>空页</title></head><body><div>hello</div></body></html>';

ScrapeResult _result(String url, String html) =>
    ScrapeResult(url: url, pageTitle: '测试页', html: html);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('结构分析', () {
    test('小说页：正文容器 / 章节列表 / 搜索表单 / 卡片规律 / 导航', () {
      final s = analyzeScrapedHtml(
        pageUrl: 'https://www.biqubu3.com/book/123/1.html',
        html: _novelHtml,
      );
      expect(s.base, 'https://www.biqubu3.com');
      expect(s.paragraphCount, 3);
      expect(s.contentSelector, '#content');
      expect(s.chapterLinks.length, 4);
      expect(s.chapterListSelector, contains('chapters'));
      expect(s.chapterListSelector, endsWith(' a'));
      expect(s.searchForm?.actionUrl, 'https://www.biqubu3.com/search.php');
      expect(s.searchForm?.paramName, 'keyword');
      expect(s.cardPattern?.prefix, '/book/');
      expect(s.cardPattern?.count, 3);
      expect(s.cardListSelector, contains('booklist'));
      expect(s.cardTitleSelector, 'h3@text');
      expect(s.navLinks.length, 3);
      expect(s.nextSelector, 'a:contains(下一章)@href');
      expect(s.hasH1, isTrue);
    });

    test('漫画页：卡片规律 / 章节 / 图片聚簇 / 搜索表单', () {
      final s = analyzeScrapedHtml(
        pageUrl: 'https://www.manhuaxi.com/list/',
        html: _comicHtml,
      );
      expect(s.cardPattern?.prefix, '/manga/');
      expect(s.cardPattern?.count, 4);
      expect(s.chapterLinks.length, 3);
      expect(s.chapterListSelector, contains('chapterlist'));
      expect(s.imageClusterSelector, contains('images'));
      expect(s.searchForm?.actionUrl, 'https://www.manhuaxi.com/s');
      expect(s.searchForm?.paramName, 'q');
      expect(s.navLinks.length, 2);
    });

    test('空页：无段落无章节无卡片', () {
      final s = analyzeScrapedHtml(
        pageUrl: 'https://example.com/',
        html: _bareHtml,
      );
      expect(s.hasParagraphs, isFalse);
      expect(s.hasChapters, isFalse);
      expect(s.hasCards, isFalse);
      expect(s.imageClusterSelector, isNull);
    });
  });

  group('格式可用性规划', () {
    test('小说模式：py 与三种书源格式可用，无漫画格式', () {
      final avail = planScrapeFormats(
        mode: ScrapeMode.novel,
        result: _result('https://www.biqubu3.com/book/123/1.html', _novelHtml),
      );
      final byFormat = {for (final a in avail) a.format: a};
      expect(
          byFormat.keys,
          containsAll([
            ScrapeGenFormat.py,
            ScrapeGenFormat.bookJson,
            ScrapeGenFormat.bookXml,
            ScrapeGenFormat.txt
          ]));
      expect(byFormat.containsKey(ScrapeGenFormat.comicJson), isFalse);
      expect(byFormat.values.every((a) => a.available), isTrue);
    });

    test('漫画模式：py 与漫画 JSON、TXT 可用，无书源格式', () {
      final avail = planScrapeFormats(
        mode: ScrapeMode.comic,
        result: _result('https://www.manhuaxi.com/list/', _comicHtml),
      );
      final byFormat = {for (final a in avail) a.format: a};
      expect(
          byFormat.keys,
          containsAll([
            ScrapeGenFormat.py,
            ScrapeGenFormat.comicJson,
            ScrapeGenFormat.txt
          ]));
      expect(byFormat.containsKey(ScrapeGenFormat.bookJson), isFalse);
      expect(byFormat.values.every((a) => a.available), isTrue);
    });

    test('通用模式：只有 py', () {
      final avail = planScrapeFormats(
        mode: ScrapeMode.general,
        result: _result('https://www.biqubu3.com/book/123/1.html', _novelHtml),
      );
      expect(avail.map((a) => a.format), [ScrapeGenFormat.py]);
    });

    test('空页：书源与漫画格式禁用并写明缺项，py 可用', () {
      final novelAvail = planScrapeFormats(
        mode: ScrapeMode.novel,
        result: _result('https://example.com/', _bareHtml),
      );
      final book =
          novelAvail.firstWhere((a) => a.format == ScrapeGenFormat.bookJson);
      expect(book.available, isFalse);
      expect(book.missingReason, contains('正文段落'));
      expect(book.missingReason, contains('章节链接'));

      final comicAvail = planScrapeFormats(
        mode: ScrapeMode.comic,
        result: _result('https://example.com/', _bareHtml),
      );
      final comic =
          comicAvail.firstWhere((a) => a.format == ScrapeGenFormat.comicJson);
      expect(comic.available, isFalse);
      expect(comic.missingReason, contains('卡片'));
      expect(comic.missingReason, contains('图片'));
      expect(comic.missingReason, contains('章节'));
    });

    test('漫画模式遇小说页：缺图片聚簇，漫画格式禁用', () {
      final avail = planScrapeFormats(
        mode: ScrapeMode.comic,
        result: _result('https://www.biqubu3.com/book/123/1.html', _novelHtml),
      );
      final comic =
          avail.firstWhere((a) => a.format == ScrapeGenFormat.comicJson);
      expect(comic.available, isFalse);
      expect(comic.missingReason, contains('图片聚簇'));
    });
  });

  group('JSON 书源生成', () {
    test('生成物过自身解析：parseSources 得 1 条有效文本源', () {
      final artifact = generateScrapeFormat(
        format: ScrapeGenFormat.bookJson,
        mode: ScrapeMode.novel,
        result: _result('https://www.biqubu3.com/book/123/1.html', _novelHtml),
        siteName: '测试小说网',
      );
      expect(artifact.fileName, endsWith('.json'));
      expect(artifact.destination, FormatDestination.bookSources);

      final service = ShuyuanSourceService();
      try {
        final sources = service.parseSources(artifact.content);
        expect(sources.length, 1);
        final source = sources.first;
        expect(source.isValid, isTrue);
        expect(source.bookSourceType, 0);
        expect(source.bookSourceName, '测试小说网');
        expect(source.bookSourceUrl, 'https://www.biqubu3.com');
        expect(source.searchUrl,
            'https://www.biqubu3.com/search.php?keyword={{key}}');
        expect(source.exploreUrl, contains('玄幻::'));
        expect(source.ruleContent?['content'], '#content@textNodes');
        expect(source.ruleToc?['chapterList'], contains('chapters'));
        expect(source.ruleSearch?['bookList'], contains('booklist'));
        expect(source.ruleBookInfo?['name'], 'h1@text');

        final config = ShuyuanAdapter.toPluginConfig(source);
        expect(config.type, SourceType.novelSource);
        expect(config.id, startsWith('xiaoshuo_'));
      } finally {
        service.close();
      }
    });

    test('无搜索表单/无导航时不编搜索与发现规则', () {
      const html = '''
<html><body><h1>书名</h1><div id="content"><p>正文一段很长很长。</p><p>正文二段很长很长。</p></div>
<div class="chapters"><a href="/c/1.html">第1章 甲</a><a href="/c/2.html">第2章 乙</a><a href="/c/3.html">第3章 丙</a></div>
</body></html>''';
      final artifact = generateScrapeFormat(
        format: ScrapeGenFormat.bookJson,
        mode: ScrapeMode.novel,
        result: _result('https://plain.example.com/book/1.html', html),
        siteName: '素站',
      );
      final map = jsonDecode(artifact.content) as Map<String, dynamic>;
      expect(map.containsKey('searchUrl'), isFalse);
      expect(map.containsKey('ruleSearch'), isFalse);
      expect(map.containsKey('exploreUrl'), isFalse);
      expect(map.containsKey('ruleExplore'), isFalse);
      expect(map.containsKey('ruleContent'), isTrue);
      expect(map.containsKey('ruleToc'), isTrue);
    });

    test('数据不足时抛异常报真原因', () {
      expect(
        () => generateScrapeFormat(
          format: ScrapeGenFormat.bookJson,
          mode: ScrapeMode.novel,
          result: _result('https://example.com/', _bareHtml),
          siteName: '空站',
        ),
        throwsA(isA<ScrapeFormatException>()),
      );
    });
  });

  group('XML 书源生成', () {
    test('生成物过 parseSources 且规则与 JSON 版往返一致', () {
      final xmlArtifact = generateScrapeFormat(
        format: ScrapeGenFormat.bookXml,
        mode: ScrapeMode.novel,
        result: _result('https://www.biqubu3.com/book/123/1.html', _novelHtml),
        siteName: '测试小说网',
      );
      expect(xmlArtifact.fileName, endsWith('.xml'));
      // XML 里只写字符串值标签：数值/布尔标签会使 fromJson 强转失败，
      // 省略后默认值恰好是 bookSourceType 0 与 enabled true。
      expect(xmlArtifact.content, isNot(contains('<bookSourceType>')));
      expect(xmlArtifact.content, contains('<bookSource>'));

      final jsonArtifact = generateScrapeFormat(
        format: ScrapeGenFormat.bookJson,
        mode: ScrapeMode.novel,
        result: _result('https://www.biqubu3.com/book/123/1.html', _novelHtml),
        siteName: '测试小说网',
      );

      final service = ShuyuanSourceService();
      try {
        final fromXml = service.parseSources(xmlArtifact.content);
        final fromJson = service.parseSources(jsonArtifact.content);
        expect(fromXml.length, 1);
        expect(fromXml.first.isValid, isTrue);
        expect(fromXml.first.bookSourceType, 0);
        expect(
          jsonEncode(fromXml.first.ruleContent),
          jsonEncode(fromJson.first.ruleContent),
        );
        expect(
          jsonEncode(fromXml.first.ruleToc),
          jsonEncode(fromJson.first.ruleToc),
        );
        expect(
          jsonEncode(fromXml.first.ruleSearch),
          jsonEncode(fromJson.first.ruleSearch),
        );
        expect(fromXml.first.searchUrl, fromJson.first.searchUrl);
        expect(fromXml.first.exploreUrl, fromJson.first.exploreUrl);
      } finally {
        service.close();
      }
    });
  });

  group('JSON 漫画规则生成', () {
    test('生成物过 parseMixedSources：恰好 1 条 mangaSource', () {
      final artifact = generateScrapeFormat(
        format: ScrapeGenFormat.comicJson,
        mode: ScrapeMode.comic,
        result: _result('https://www.manhuaxi.com/list/', _comicHtml),
        siteName: '测试漫画网',
      );
      expect(artifact.fileName, endsWith('.json'));
      expect(artifact.destination, FormatDestination.comicSources);

      final configs = SourceRepository.parseMixedSources(artifact.content);
      expect(configs.length, 1);
      final config = configs.first;
      expect(config.type, SourceType.mangaSource);
      expect(config.id, startsWith('manga_'));
      expect(config.validate(), isEmpty);
      expect(config.site.baseUrl, 'https://www.manhuaxi.com');

      final map = jsonDecode(artifact.content) as Map<String, dynamic>;
      final routes = map['routes'] as Map<String, dynamic>;
      expect((routes['detail'] as Map)['url'], '{id}');
      expect((routes['chapters'] as Map)['url'], '{id}');
      expect((routes['images'] as Map)['url'], '{chapterId}');
      expect((routes['search'] as Map)['url'],
          'https://www.manhuaxi.com/s?q={keyword}');
      final selectors = map['selectors'] as Map<String, dynamic>;
      expect((selectors['chapters'] as Map)['list'], contains('chapterlist'));
      expect((selectors['images'] as Map)['list'], contains('images'));
      final category = map['category'] as Map<String, dynamic>;
      final entries = category['categoryEntries'] as List;
      expect(entries.length, 2);
      expect(entries.first['id'], 'rexue');
    });

    test('数据不足时抛异常报真原因', () {
      expect(
        () => generateScrapeFormat(
          format: ScrapeGenFormat.comicJson,
          mode: ScrapeMode.comic,
          result: _result('https://example.com/', _bareHtml),
          siteName: '空站',
        ),
        throwsA(isA<ScrapeFormatException>()),
      );
    });
  });

  group('TXT 格式', () {
    test('JSON 内容存为 .txt 与 .json 导入结果一致（书源）', () async {
      final artifact = generateScrapeFormat(
        format: ScrapeGenFormat.txt,
        mode: ScrapeMode.novel,
        result: _result('https://www.biqubu3.com/book/123/1.html', _novelHtml),
        siteName: '测试小说网',
      );
      expect(artifact.fileName, endsWith('.txt'));
      expect(artifact.destination, FormatDestination.bookSources);

      final asTxt = await scanSourceText(
        fileName: artifact.fileName,
        text: artifact.content,
      );
      final asJson = await scanSourceText(
        fileName: 'test_booksource.json',
        text: artifact.content,
      );
      expect(asTxt.configs.length, 1);
      expect(asJson.configs.length, 1);
      expect(asTxt.configs.first.id, asJson.configs.first.id);
      expect(asTxt.configs.first.type, SourceType.novelSource);
      expect(asTxt.errors, isEmpty);
    });

    test('JSON 内容存为 .txt 与 .json 导入结果一致（漫画）', () async {
      final artifact = generateScrapeFormat(
        format: ScrapeGenFormat.txt,
        mode: ScrapeMode.comic,
        result: _result('https://www.manhuaxi.com/list/', _comicHtml),
        siteName: '测试漫画网',
      );
      final asTxt = await scanSourceText(
        fileName: artifact.fileName,
        text: artifact.content,
      );
      final asJson = await scanSourceText(
        fileName: 'test_manga.json',
        text: artifact.content,
      );
      expect(asTxt.configs.length, 1);
      expect(asJson.configs.length, 1);
      expect(asTxt.configs.first.id, asJson.configs.first.id);
      expect(asTxt.configs.first.type, SourceType.mangaSource);
    });

    test('py 内容存为 .txt 认不出 py（故 TXT 不提供 py 版）', () async {
      const pyCode = 'class Spider:\n  def homeContent(self):\n    return {}\n';
      final scanned = await scanSourceText(
        fileName: 'x.txt',
        text: pyCode,
      );
      expect(scanned.pendingPy, isEmpty);
    });
  });

  group('注册去向', () {
    test('书源文本注册进书源登记，重复注册不产生重复', () async {
      final repo = SourceRepository();
      final artifact = generateScrapeFormat(
        format: ScrapeGenFormat.bookJson,
        mode: ScrapeMode.novel,
        result: _result('https://www.biqubu3.com/book/123/1.html', _novelHtml),
        siteName: '测试小说网',
      );
      final config =
          await registerBookSourceText(repo: repo, text: artifact.content);
      expect(config.type, SourceType.novelSource);
      expect(repo.getById(config.id), isNotNull);
      final count = repo.all.length;
      await registerBookSourceText(repo: repo, text: artifact.content);
      expect(repo.all.length, count);
    });

    test('XML 书源文本同样注册进书源登记', () async {
      final repo = SourceRepository();
      final artifact = generateScrapeFormat(
        format: ScrapeGenFormat.bookXml,
        mode: ScrapeMode.novel,
        result: _result('https://www.biqubu3.com/book/123/1.html', _novelHtml),
        siteName: '测试小说网',
      );
      final config =
          await registerBookSourceText(repo: repo, text: artifact.content);
      expect(config.type, SourceType.novelSource);
      expect(repo.getById(config.id), isNotNull);
    });

    test('漫画规则文本注册进漫画源登记', () async {
      final repo = SourceRepository();
      final artifact = generateScrapeFormat(
        format: ScrapeGenFormat.comicJson,
        mode: ScrapeMode.comic,
        result: _result('https://www.manhuaxi.com/list/', _comicHtml),
        siteName: '测试漫画网',
      );
      final config =
          await registerRuleJsonText(repo: repo, text: artifact.content);
      expect(config.type, SourceType.mangaSource);
      expect(repo.getById(config.id), isNotNull);
    });

    test('无效文本注册报真原因', () async {
      final repo = SourceRepository();
      expect(
        registerBookSourceText(repo: repo, text: 'not a source'),
        throwsA(isA<ScrapeFormatException>()),
      );
      expect(
        registerRuleJsonText(repo: repo, text: 'not a source'),
        throwsA(isA<ScrapeFormatException>()),
      );
    });
  });
}
