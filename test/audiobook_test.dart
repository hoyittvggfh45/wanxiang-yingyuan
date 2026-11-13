/// 听书模块单元测试：章节列表映射、音频地址判定、导航顺序与启动映射。
///
/// 不含 widget 测试：首页 widget 依赖尚未生成的 l10n 文案键
/// （navAudiobook/navLive），导航顺序改测顺序常量与映射函数（纯 Dart）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:wxyy/core/audiobook/audiobook_models.dart';
import 'package:wxyy/core/audiobook/home_destination_order.dart';
import 'package:wxyy/core/models/episode.dart';
import 'package:wxyy/core/settings/general_settings.dart';

void main() {
  group('audiobookChaptersFromEpisodes', () {
    test('keeps order, titles, line names and numbers', () {
      final chapters = audiobookChaptersFromEpisodes(<Episode>[
        const Episode(
          id: 'c1',
          title: '第一章',
          url: 'https://x/1',
          lineName: '线路一',
          number: 1,
        ),
        const Episode(
          id: 'c2',
          title: '第二章',
          url: 'https://x/2',
          lineName: '线路一',
          number: 2,
        ),
      ]);
      expect(chapters.length, 2);
      expect(chapters[0].index, 0);
      expect(chapters[0].title, '第一章');
      expect(chapters[0].lineName, '线路一');
      expect(chapters[0].number, 1);
      expect(chapters[1].index, 1);
      expect(chapters[1].title, '第二章');
      expect(chapters[1].number, 2);
    });

    test('drops episodes with empty url and reindexes', () {
      final chapters = audiobookChaptersFromEpisodes(<Episode>[
        const Episode(id: 'bad', title: '无地址', url: ''),
        const Episode(id: 'c1', title: '第一章', url: 'https://x/1'),
        const Episode(id: 'c2', title: '第二章', url: 'https://x/2'),
      ]);
      expect(
        chapters.map((c) => c.id).toList(),
        <String>['c1', 'c2'],
      );
      expect(chapters[0].index, 0);
      expect(chapters[1].index, 1);
    });

    test('falls back to position-based title and number', () {
      final chapters = audiobookChaptersFromEpisodes(<Episode>[
        const Episode(id: 'bad', title: '', url: ''),
        const Episode(id: 'c1', title: '', url: 'https://x/1'),
        const Episode(id: 'c2', title: '', url: 'https://x/2'),
      ]);
      // 空标题按过滤后位置补「第 N 章」，N 从 1 起。
      expect(chapters[0].title, '第 1 章');
      expect(chapters[1].title, '第 2 章');
      expect(chapters[0].number, 1);
      expect(chapters[1].number, 2);
    });

    test('empty input yields empty list', () {
      expect(audiobookChaptersFromEpisodes(const <Episode>[]), isEmpty);
    });
  });

  group('audio url detection', () {
    test('isAudioUrl recognizes audio extensions', () {
      expect(isAudioUrl('https://cdn/x/chapter1.mp3'), isTrue);
      expect(isAudioUrl('https://cdn/x/chapter1.MP3'), isTrue);
      expect(isAudioUrl('https://cdn/x/a.m4a?token=abc&x=1'), isTrue);
      expect(isAudioUrl('https://cdn/x/a.ogg#frag'), isTrue);
      expect(isAudioUrl('https://cdn/x/a.flac'), isTrue);
      expect(isAudioUrl('https://cdn/x/a.opus'), isTrue);
    });

    test('isAudioUrl rejects video, playlists and extensionless urls', () {
      expect(isAudioUrl('https://cdn/x/a.mp4'), isFalse);
      expect(isAudioUrl('https://cdn/x/a.m3u8'), isFalse);
      expect(isAudioUrl('https://cdn/x/audio/123'), isFalse);
      expect(isAudioUrl(''), isFalse);
      expect(isAudioUrl('https://cdn/x/mp3'), isFalse);
    });

    test('inferAudioType returns lowercase extension or null', () {
      expect(inferAudioType('https://cdn/x/a.MP3'), 'mp3');
      expect(inferAudioType('https://cdn/x/a.m4a?k=v'), 'm4a');
      expect(inferAudioType('https://cdn/x/a.mp4'), isNull);
      expect(inferAudioType('https://cdn/x/a'), isNull);
    });

    test('isAudioResult honors explicit type then url', () {
      const typed = VideoResult(url: 'https://cdn/x/stream', type: 'audio');
      expect(isAudioResult(typed), isTrue);
      const byUrl = VideoResult(url: 'https://cdn/x/a.mp3');
      expect(isAudioResult(byUrl), isTrue);
      const video = VideoResult(url: 'https://cdn/x/a.mp4', type: 'mp4');
      expect(isAudioResult(video), isFalse);
    });
  });

  group('home destination order', () {
    test('order is browse/novel/media/comic/audiobook/live/settings', () {
      expect(
        homeDestinationKeys,
        <String>[
          'browse',
          'novel',
          'media',
          'comic',
          'audiobook',
          'live',
          'settings',
        ],
      );
    });

    test('audiobook sits after comic and before live and settings', () {
      final int comic = homeDestinationKeys.indexOf('comic');
      final int audiobook = homeDestinationKeys.indexOf('audiobook');
      final int live = homeDestinationKeys.indexOf('live');
      final int settings = homeDestinationKeys.indexOf('settings');
      expect(audiobook, audiobookDestinationIndex);
      expect(live, liveDestinationIndex);
      expect(comic, lessThan(audiobook));
      expect(audiobook, lessThan(live));
      expect(live, lessThan(settings));
      expect(settings, homeDestinationKeys.length - 1);
    });

    test('launch tab mapping keeps first four and sends settings last', () {
      expect(
        pageIndexForLaunchTab(LaunchTab.browse, pageCount: 7),
        0,
      );
      expect(
        pageIndexForLaunchTab(LaunchTab.novel, pageCount: 7),
        1,
      );
      expect(
        pageIndexForLaunchTab(LaunchTab.media, pageCount: 7),
        2,
      );
      expect(
        pageIndexForLaunchTab(LaunchTab.comic, pageCount: 7),
        3,
      );
      expect(
        pageIndexForLaunchTab(LaunchTab.settings, pageCount: 7),
        6,
      );
      // settings 恒取最后一页，与页数无关（存量设置值无需迁移）。
      expect(
        pageIndexForLaunchTab(LaunchTab.settings, pageCount: 5),
        4,
      );
    });
  });
}
