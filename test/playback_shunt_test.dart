/// 播放协议分流决策测试：novel / pics / 音频 / 视频 / 空内容 / 非法地址 /
// `$` 前缀形态 / vod_tag 双认。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wxyy/core/player/playback_shunt.dart';

void main() {
  group('novel://', () {
    test('标准 JSON 载荷分流为小说', () {
      final decision = classifyPlayback(
        url: 'novel://${jsonEncode({'title': '第一章', 'content': '正文内容'})}',
      );
      expect(decision.kind, PlaybackKind.novel);
      expect(decision.shunted, isTrue);
      expect(decision.blocked, isFalse);
      expect(decision.content!.title, '第一章');
      expect(decision.content!.text, '正文内容');
    });

    test('带 \$ 前缀的“阅读\$novel://”形态同样分流', () {
      final decision = classifyPlayback(
        url: '阅读\$novel://${jsonEncode({'title': 'T', 'content': 'C'})}',
      );
      expect(decision.kind, PlaybackKind.novel);
      expect(decision.content!.text, 'C');
    });

    test('id 里只有 ctype 前缀、无协议载荷时不误判', () {
      final decision = classifyPlayback(
        url: 'https://example.com/play',
        episodeId: 'novel#1#slug::0::0',
      );
      expect(decision.kind, PlaybackKind.video);
    });

    test('协议在 id 候选里出现时分流', () {
      final decision = classifyPlayback(
        url: '',
        episodeId: 'novel://${jsonEncode({'title': 'T', 'content': 'C'})}',
      );
      expect(decision.kind, PlaybackKind.novel);
    });

    test('novel:// 后不是 JSON 时拦截不送解码', () {
      final decision = classifyPlayback(url: 'novel://just-plain-text');
      expect(decision.kind, PlaybackKind.novel);
      expect(decision.blocked, isTrue);
      expect(decision.content, isNull);
      expect(decision.blockedReason, isNotEmpty);
    });

    test('JSON 损坏时拦截', () {
      final decision = classifyPlayback(url: 'novel://{broken json');
      expect(decision.kind, PlaybackKind.novel);
      expect(decision.blocked, isTrue);
    });

    test('正文为空时拦截', () {
      final decision = classifyPlayback(
        url: 'novel://${jsonEncode({'title': 'T', 'content': ''})}',
      );
      expect(decision.kind, PlaybackKind.novel);
      expect(decision.blocked, isTrue);
    });

    test('无标题时用 fallback 标题', () {
      final decision = classifyPlayback(
        url: 'novel://${jsonEncode({'content': 'C'})}',
        fallbackTitle: '备用标题',
      );
      expect(decision.content!.title, '备用标题');
    });
  });

  group('pics://', () {
    test('多图 && 分隔分流为图片', () {
      final decision = classifyPlayback(
        url: 'pics://https://a/1.jpg&&https://a/2.jpg&&https://a/3.jpg',
      );
      expect(decision.kind, PlaybackKind.pics);
      expect(decision.content!.urls, <String>[
        'https://a/1.jpg',
        'https://a/2.jpg',
        'https://a/3.jpg',
      ]);
    });

    test('带 \$ 前缀的“查看\$pics://”形态同样分流', () {
      final decision = classifyPlayback(
        url: '查看\$pics://https://a/1.jpg&&https://a/2.jpg',
      );
      expect(decision.kind, PlaybackKind.pics);
      expect(decision.content!.urls.length, 2);
    });

    test('空段被丢弃', () {
      final decision = classifyPlayback(
        url: 'pics://https://a/1.jpg&&  &&https://a/2.jpg',
      );
      expect(decision.content!.urls.length, 2);
    });

    test('pics:// 后无地址时拦截', () {
      final decision = classifyPlayback(url: 'pics://');
      expect(decision.kind, PlaybackKind.pics);
      expect(decision.blocked, isTrue);
    });

    test('请求头原样透传给图片加载', () {
      final decision = classifyPlayback(
        url: 'pics://https://a/1.jpg',
        headers: const {'Referer': 'https://example.com/'},
      );
      expect(decision.content!.headers['Referer'], 'https://example.com/');
    });
  });

  group('vod_tag 双认', () {
    test('text 标签无协议载荷时拦截为小说', () {
      final decision = classifyPlayback(
        url: 'https://example.com/chapter',
        vodTag: 'text',
      );
      expect(decision.kind, PlaybackKind.novel);
      expect(decision.blocked, isTrue);
    });

    test('image 标签无协议载荷时拦截为图片', () {
      final decision = classifyPlayback(
        url: 'https://example.com/album',
        vodTag: 'image',
      );
      expect(decision.kind, PlaybackKind.pics);
      expect(decision.blocked, isTrue);
    });

    test('text 标签 + novel 协议时协议优先、载荷可用', () {
      final decision = classifyPlayback(
        url: 'novel://${jsonEncode({'title': 'T', 'content': 'C'})}',
        vodTag: 'text',
      );
      expect(decision.kind, PlaybackKind.novel);
      expect(decision.blocked, isFalse);
    });

    test('标签大小写与多标签不影响识别', () {
      final decision = classifyPlayback(
        url: 'https://example.com/x',
        vodTag: 'Drama, TEXT',
      );
      expect(decision.kind, PlaybackKind.novel);
      expect(decision.blocked, isTrue);
    });

    test('无关标签不触发分流', () {
      final decision = classifyPlayback(
        url: 'https://example.com/v.mp4',
        vodTag: 'drama',
      );
      expect(decision.kind, PlaybackKind.video);
    });
  });

  group('音频', () {
    test('常见音频后缀分流为音频', () {
      for (final ext in <String>[
        'mp3',
        'm4a',
        'aac',
        'opus',
        'ogg',
        'oga',
        'wav',
        'flac',
      ]) {
        final decision =
            classifyPlayback(url: 'https://example.com/a.$ext');
        expect(decision.kind, PlaybackKind.audio, reason: ext);
        expect(decision.content!.urls, <String>['https://example.com/a.$ext']);
      }
    });

    test('带查询串与锚点的音频地址同样识别', () {
      final decision = classifyPlayback(
        url: 'https://example.com/a.MP3?token=abc#frag',
      );
      expect(decision.kind, PlaybackKind.audio);
    });

    test('本地音频文件路径同样识别', () {
      final decision =
          classifyPlayback(url: '/storage/emulated/0/music/song.m4a');
      expect(decision.kind, PlaybackKind.audio);
    });
  });

  group('视频与兜底', () {
    test('普通视频地址走视频', () {
      for (final url in <String>[
        'https://example.com/v.m3u8',
        'https://example.com/v.mp4',
        'https://example.com/v.mpd',
        'https://example.com/play?id=123',
        '/storage/emulated/0/movie.mkv',
      ]) {
        expect(classifyPlayback(url: url).kind, PlaybackKind.video,
            reason: url);
      }
    });

    test('空地址回视频（由调用方原有空地址错误处理）', () {
      expect(classifyPlayback(url: '').kind, PlaybackKind.video);
      expect(classifyPlayback(url: '   ').kind, PlaybackKind.video);
    });

    test('非法地址不误判为分流', () {
      expect(classifyPlayback(url: '::::').kind, PlaybackKind.video);
      expect(classifyPlayback(url: 'not a url').kind, PlaybackKind.video);
    });

    test('视频地址含 novel 字样但无协议时不误判', () {
      final decision = classifyPlayback(
        url: 'https://example.com/novel-drama.mp4',
      );
      expect(decision.kind, PlaybackKind.video);
    });
  });
}
