// 网页爬取服务测试：真实 loopback 服务器 + 真实 HttpFetcher。
//
// 覆盖「爬取不动任何资源」的两处修复：
// 1. 空页面 / HTTP 错误必须抛错（而不是静默空结果）；
// 2. 视频模式除 <video>/<iframe> 标签外，还要捞到 <script>/JSON 里的
//    流媒体直链（m3u8/mp4 等），否则 JS 站永远是空结果。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wxyy/core/scraper/http_fetcher.dart';
import 'package:wxyy/core/scraper/verification_detector.dart';
import 'package:wxyy/core/scraper/web_scrape_service.dart';
import 'package:wxyy/core/services/config_loader.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues(<String, Object>{});

  setUpAll(() {
    // 恢复真实网络：flutter test 的绑定默认全局假 HttpClient（一律 400）。
    HttpOverrides.global = null;
    // 关掉隐身延迟（同 http_fetcher_403_retry_test 范式）。
    ConfigLoader.instance.setStealthMode(false);
  });

  setUp(() {
    HttpFetcher.instance.setVerifyCooldown(
      '127.0.0.1',
      DateTime.now().subtract(const Duration(seconds: 1)),
    );
  });

  /// 起一个固定应答的 loopback 服务器，返回 (url, 关闭钩子)。
  Future<(String, Future<void> Function())> startServer({
    required int status,
    required String body,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      req.response.statusCode = status;
      req.response.headers.set('content-type', 'text/html; charset=utf-8');
      req.response.add(utf8.encode(body));
      await req.response.close();
    });
    return (
      'http://127.0.0.1:${server.port}/page',
      () async => server.close(force: true),
    );
  }

  test('general 模式抽链接并解析相对地址', () async {
    final (url, close) = await startServer(
      status: 200,
      body: '<html><head><title>测试页</title></head><body>'
          '<a href="/a/1">第一条</a><a href="https://x.example.com/b">第二条</a>'
          '</body></html>',
    );
    try {
      final result =
          await WebScrapeService.instance.scrape(url, ScrapeMode.general);
      expect(result.pageTitle, '测试页');
      expect(result.links, hasLength(2));
      expect(result.links.first.text, '第一条');
      expect(result.links.first.url, startsWith('http://127.0.0.1:'));
      expect(result.links.first.url, endsWith('/a/1'));
      expect(result.links.last.url, 'https://x.example.com/b');
      expect(result.isEmpty, isFalse);
    } finally {
      await close();
    }
  });

  test('video 模式：video 标签、iframe 与脚本内 m3u8 直链都捞到', () async {
    final (url, close) = await startServer(
      status: 200,
      body: '<html><head><title>播</title></head><body>'
          '<video src="/v/movie.mp4"></video>'
          '<iframe src="https://player.example.com/embed/1"></iframe>'
          '<script>var src="https://cdn.example.com/hls/play.m3u8?token=abc";</script>'
          '</body></html>',
    );
    try {
      final result =
          await WebScrapeService.instance.scrape(url, ScrapeMode.video);
      final urls = result.videoUrls.map((v) => v.url).toList();
      expect(
        urls.any((u) => u.endsWith('/v/movie.mp4')),
        isTrue,
        reason: 'video 标签地址应被抽到',
      );
      expect(
        urls,
        contains('https://cdn.example.com/hls/play.m3u8?token=abc'),
        reason: '脚本内的 m3u8 直链应被兜底扫到',
      );
      expect(urls, contains('https://player.example.com/embed/1'));
      expect(
        result.videoUrls
            .firstWhere((v) => v.url.endsWith('/embed/1'))
            .fromIframe,
        isTrue,
      );
    } finally {
      await close();
    }
  });

  test('novel 模式抽段落', () async {
    final (url, close) = await startServer(
      status: 200,
      body: '<html><body><p>第一段正文</p><p>第二段正文</p></body></html>',
    );
    try {
      final result =
          await WebScrapeService.instance.scrape(url, ScrapeMode.novel);
      expect(result.paragraphs, ['第一段正文', '第二段正文']);
    } finally {
      await close();
    }
  });

  test('空页面抛错而不是静默空结果', () async {
    final (url, close) = await startServer(status: 200, body: '');
    try {
      await expectLater(
        WebScrapeService.instance.scrape(url, ScrapeMode.general),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('空页面'),
          ),
        ),
      );
    } finally {
      await close();
    }
  });

  test('HTTP 404 抛错而不是静默空结果', () async {
    final (url, close) = await startServer(
      status: 404,
      body: '<html><body>not found</body></html>',
    );
    try {
      await expectLater(
        WebScrapeService.instance.scrape(url, ScrapeMode.general),
        throwsA(isA<HttpStatusException>()),
      );
    } finally {
      await close();
    }
  });
}
