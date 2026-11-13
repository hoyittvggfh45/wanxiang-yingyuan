/// 爬取结果打开路由测试：视频地址去向判定与分流载荷构造往返。
///
/// 去向判定只测纯函数 [classifyScrapeVideoUrl]；小说 / 图片去向测
/// 载荷构造器与分流 [classifyPlayback] 的往返（载荷经主播放器直链
/// 模式打开，分流决策即视图去向）。通用链接导航未动相关代码，
/// 不在此重复测。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:wxyy/core/player/playback_shunt.dart';
import 'package:wxyy/core/scraper/scrape_open_router.dart';

void main() {
  group('classifyScrapeVideoUrl', () {
    test('<video> 的 mp4 进播放器', () {
      expect(
        classifyScrapeVideoUrl(
          'https://cdn.example.com/v.mp4',
          fromIframe: false,
        ),
        ScrapeVideoRoute.player,
      );
    });

    test('<video> 的无后缀地址进播放器（页面已声明为视频）', () {
      expect(
        classifyScrapeVideoUrl(
          'https://cdn.example.com/play/12345',
          fromIframe: false,
        ),
        ScrapeVideoRoute.player,
      );
    });

    test('m3u8 带查询串进播放器', () {
      expect(
        classifyScrapeVideoUrl(
          'https://cdn.example.com/live.m3u8?token=abc&e=1',
          fromIframe: false,
        ),
        ScrapeVideoRoute.player,
      );
    });

    test('大写后缀进播放器', () {
      expect(
        classifyScrapeVideoUrl(
          'https://cdn.example.com/V.MP4',
          fromIframe: false,
        ),
        ScrapeVideoRoute.player,
      );
    });

    test('音频地址进播放器（分流接管）', () {
      expect(
        classifyScrapeVideoUrl(
          'https://cdn.example.com/a.mp3',
          fromIframe: false,
        ),
        ScrapeVideoRoute.player,
      );
      expect(
        classifyScrapeVideoUrl(
          'https://cdn.example.com/a.mp3',
          fromIframe: true,
        ),
        ScrapeVideoRoute.player,
      );
    });

    test('iframe 的 mp4 进播放器（媒体直链优先于来源）', () {
      expect(
        classifyScrapeVideoUrl(
          'https://cdn.example.com/e.mp4',
          fromIframe: true,
        ),
        ScrapeVideoRoute.player,
      );
    });

    test('iframe 的网页地址走浏览器', () {
      expect(
        classifyScrapeVideoUrl(
          'https://www.example.com/embed/123.html',
          fromIframe: true,
        ),
        ScrapeVideoRoute.browser,
      );
    });

    test('iframe 的无后缀页地址走浏览器', () {
      expect(
        classifyScrapeVideoUrl(
          'https://player.example.com/embed/abc',
          fromIframe: true,
        ),
        ScrapeVideoRoute.browser,
      );
    });

    test('iframe 的空地址无法打开', () {
      expect(
        classifyScrapeVideoUrl('   ', fromIframe: true),
        ScrapeVideoRoute.unsupported,
      );
    });

    test('blob: 地址无法打开', () {
      expect(
        classifyScrapeVideoUrl(
          'blob:https://www.example.com/uuid',
          fromIframe: false,
        ),
        ScrapeVideoRoute.unsupported,
      );
    });

    test('javascript: 地址无法打开', () {
      expect(
        classifyScrapeVideoUrl('javascript:play()', fromIframe: true),
        ScrapeVideoRoute.unsupported,
      );
    });
  });

  group('分流载荷构造往返', () {
    test('小说载荷经分流进小说视图', () {
      final String payload = buildScrapeNovelPayload(
        title: '第一章',
        content: '正文\n第二段',
      );
      final PlaybackDecision decision = classifyPlayback(url: payload);
      expect(decision.kind, PlaybackKind.novel);
      expect(decision.blocked, isFalse);
      expect(decision.content!.title, '第一章');
      expect(decision.content!.text, '正文\n第二段');
    });

    test('小说载荷含引号与中文往返无损', () {
      final String payload = buildScrapeNovelPayload(
        title: '“引子”',
        content: '他说："你好"',
      );
      final PlaybackDecision decision = classifyPlayback(url: payload);
      expect(decision.blocked, isFalse);
      expect(decision.content!.title, '“引子”');
      expect(decision.content!.text, '他说："你好"');
    });

    test('空正文载荷被分流拦截（报真原因）', () {
      final String payload =
          buildScrapeNovelPayload(title: '空', content: '');
      final PlaybackDecision decision = classifyPlayback(url: payload);
      expect(decision.blocked, isTrue);
      expect(decision.blockedReason, isNotEmpty);
    });

    test('图片载荷经分流进图片视图', () {
      final String payload = buildScrapePicsPayload(<String>[
        'https://img.example.com/1.jpg',
        'https://img.example.com/2.jpg',
      ]);
      final PlaybackDecision decision = classifyPlayback(url: payload);
      expect(decision.kind, PlaybackKind.pics);
      expect(decision.content!.urls, <String>[
        'https://img.example.com/1.jpg',
        'https://img.example.com/2.jpg',
      ]);
    });

    test('图片载荷滤掉空地址', () {
      final String payload = buildScrapePicsPayload(
        <String>['', '  ', 'https://img.example.com/1.jpg'],
      );
      final PlaybackDecision decision = classifyPlayback(url: payload);
      expect(decision.content!.urls, <String>[
        'https://img.example.com/1.jpg',
      ]);
    });

    test('空图列载荷被分流拦截', () {
      final String payload = buildScrapePicsPayload(<String>[]);
      final PlaybackDecision decision = classifyPlayback(url: payload);
      expect(decision.blocked, isTrue);
      expect(decision.blockedReason, isNotEmpty);
    });
  });
}
