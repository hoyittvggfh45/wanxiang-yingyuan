/// 播放器预加载队列单测：窗口 5 集、滑动补齐、缓存有效期、开关关闭零
/// 解析、切集取消过期任务、后续影视首集解析、失败静默、并发有界。
///
/// 解析动作全部用假函数注入，不碰网络与 [MediaApiService]；时间用假时钟。
///
/// 末尾另附「视频默认竖屏」默认值单测（新装默认竖屏、缺键回落竖屏、
/// 已存横屏不被覆盖、预加载开关默认开），与预加载同批落地、共用此文件。
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:wxyy/core/models/episode.dart';
import 'package:wxyy/core/models/media_item.dart';
import 'package:wxyy/core/player/preload_queue.dart';
import 'package:wxyy/core/settings/player_settings.dart';

Episode _ep(int i) =>
    Episode(id: 'ep$i', title: '第$i集', url: 'https://example.com/ep$i');

MediaItem _item(int i) => MediaItem(id: 'm$i', title: '作品$i', sourceId: 's1');

VideoResult _result(String url) => VideoResult(url: url);

/// 等待条件成立（后台任务是 unawaited 的异步链，需让出执行权）。
Future<void> _waitUntil(bool Function() cond) async {
  for (int i = 0; i < 500 && !cond(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(cond(), isTrue, reason: '等待后台预加载任务完成超时');
}

void main() {
  test('窗口 5 集：只解析当前集往后 5 集', () async {
    final List<Episode> episodes = List<Episode>.generate(10, _ep);
    final List<String> called = <String>[];
    final PreloadQueue queue = PreloadQueue(
      resolveEpisode: (Episode ep) async {
        called.add(ep.url);
        return _result('https://cdn.example.com/${ep.id}.m3u8');
      },
      cache: PreloadCache(),
    );
    queue.update(episodes: episodes, currentIndex: 0);
    await _waitUntil(() => called.length == 5);
    expect(
      called,
      <String>[
        'https://example.com/ep1',
        'https://example.com/ep2',
        'https://example.com/ep3',
        'https://example.com/ep4',
        'https://example.com/ep5',
      ],
    );
    expect(queue.lookupEpisode(episodes[1])?.url,
        'https://cdn.example.com/ep1.m3u8');
    expect(queue.lookupEpisode(episodes[6]), isNull);
    queue.dispose();
  });

  test('滑动补齐：窗口滑动后只补新增集，已缓存的不重复解析', () async {
    final List<Episode> episodes = List<Episode>.generate(10, _ep);
    final List<String> called = <String>[];
    final PreloadQueue queue = PreloadQueue(
      resolveEpisode: (Episode ep) async {
        called.add(ep.url);
        return _result('https://cdn.example.com/${ep.id}.m3u8');
      },
      cache: PreloadCache(),
    );
    queue.update(episodes: episodes, currentIndex: 0);
    await _waitUntil(() => called.length == 5);
    queue.update(episodes: episodes, currentIndex: 2);
    await _waitUntil(() => called.length == 7);
    // 窗口从 1..5 滑到 3..7：只新增 ep6、ep7，ep3/ep4/ep5 不重复解析。
    expect(called.sublist(5),
        <String>['https://example.com/ep6', 'https://example.com/ep7']);
    expect(queue.lookupEpisode(episodes[7]), isNotNull);
    queue.dispose();
  });

  test('缓存有效期：15 分钟后过期失效，过期后重新解析', () async {
    DateTime fakeNow = DateTime(2026, 11, 13, 0, 0);
    final List<Episode> episodes = List<Episode>.generate(10, _ep);
    int calls = 0;
    final PreloadQueue queue = PreloadQueue(
      resolveEpisode: (Episode ep) async {
        calls++;
        return _result('https://cdn.example.com/${ep.id}.m3u8');
      },
      cache: PreloadCache(),
      now: () => fakeNow,
    );
    queue.update(episodes: episodes, currentIndex: 0);
    await _waitUntil(() => calls == 5);
    expect(queue.lookupEpisode(episodes[1]), isNotNull);
    // 14 分钟后仍有效。
    fakeNow = fakeNow.add(const Duration(minutes: 14));
    expect(queue.lookupEpisode(episodes[1]), isNotNull);
    // 15 分钟后过期失效。
    fakeNow = fakeNow.add(const Duration(minutes: 1));
    expect(queue.lookupEpisode(episodes[1]), isNull);
    // 过期后重算窗口会重新解析该集。
    queue.update(episodes: episodes, currentIndex: 0);
    await _waitUntil(() => calls == 10);
    expect(queue.lookupEpisode(episodes[1]), isNotNull);
    queue.dispose();
  });

  test('开关关闭：零后台解析、查询恒为空', () async {
    final List<Episode> episodes = List<Episode>.generate(10, _ep);
    int calls = 0;
    final PreloadQueue queue = PreloadQueue(
      resolveEpisode: (Episode ep) async {
        calls++;
        return _result('https://cdn.example.com/${ep.id}.m3u8');
      },
      cache: PreloadCache(),
      enabled: false,
    );
    queue.update(episodes: episodes, currentIndex: 0);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(calls, 0);
    expect(queue.pendingCount, 0);
    expect(queue.lookupEpisode(episodes[1]), isNull);
    // 打开开关后需再 update 才排队，之前 update 时不欠账。
    queue.setEnabled(true);
    queue.update(episodes: episodes, currentIndex: 0);
    await _waitUntil(() => calls == 5);
    queue.dispose();
  });

  test('开关关闭取消排队任务：执行中的结果也不写入缓存', () async {
    final List<Episode> episodes = List<Episode>.generate(10, _ep);
    final Completer<VideoResult> gate = Completer<VideoResult>();
    final PreloadQueue queue = PreloadQueue(
      resolveEpisode: (Episode ep) => gate.future,
      cache: PreloadCache(),
    );
    queue.update(episodes: episodes, currentIndex: 0);
    await _waitUntil(() => queue.activeCount == 2);
    expect(queue.pendingCount, 3);
    queue.setEnabled(false);
    expect(queue.pendingCount, 0);
    gate.complete(_result('https://cdn.example.com/late.m3u8'));
    await _waitUntil(() => queue.activeCount == 0);
    expect(queue.cachedKeys, isEmpty);
    queue.dispose();
  });

  test('切集取消过期任务：旧窗口任务完成时结果作废', () async {
    final List<Episode> episodes = List<Episode>.generate(12, _ep);
    final Map<String, Completer<VideoResult>> gates =
        <String, Completer<VideoResult>>{};
    final PreloadQueue queue = PreloadQueue(
      resolveEpisode: (Episode ep) {
        final Completer<VideoResult> c = Completer<VideoResult>();
        gates[ep.url] = c;
        return c.future;
      },
      cache: PreloadCache(),
    );
    queue.update(episodes: episodes, currentIndex: 0);
    await _waitUntil(() => queue.activeCount == 2);
    expect(queue.pendingCount, 3);
    // 切到第 8 集：窗口变成 9..11，旧窗口排队任务取消。
    queue.update(episodes: episodes, currentIndex: 8);
    expect(
      queue.pendingKeys,
      isNot(contains('ep:https://example.com/ep3')),
    );
    // 旧窗口执行中的任务完成：结果作废，不进缓存。
    gates['https://example.com/ep1']!
        .complete(_result('https://cdn.example.com/stale1.m3u8'));
    gates['https://example.com/ep2']!
        .complete(_result('https://cdn.example.com/stale2.m3u8'));
    // 腾出的两个并发位启动 ep9、ep10；完成它们后 ep11 才启动。
    await _waitUntil(() => gates.length == 4);
    gates['https://example.com/ep9']!
        .complete(_result('https://cdn.example.com/ep9.m3u8'));
    gates['https://example.com/ep10']!
        .complete(_result('https://cdn.example.com/ep10.m3u8'));
    await _waitUntil(() => gates.length == 5);
    gates['https://example.com/ep11']!
        .complete(_result('https://cdn.example.com/ep11.m3u8'));
    await _waitUntil(() => queue.activeCount == 0 && queue.pendingCount == 0);
    expect(queue.lookupEpisode(episodes[1]), isNull);
    expect(queue.lookupEpisode(episodes[2]), isNull);
    expect(queue.lookupEpisode(episodes[9]), isNotNull);
    expect(queue.lookupEpisode(episodes[10]), isNotNull);
    expect(queue.lookupEpisode(episodes[11]), isNotNull);
    queue.dispose();
  });

  test('后续影视首集解析：最多 3 部，首集可查缓存', () async {
    final List<Episode> episodes = List<Episode>.generate(3, _ep);
    final List<String> firstCalls = <String>[];
    final PreloadQueue queue = PreloadQueue(
      resolveEpisode: (Episode ep) async =>
          _result('https://cdn.example.com/${ep.id}.m3u8'),
      resolveFirstEpisode: (MediaItem item) async {
        firstCalls.add(item.id);
        return _result('https://cdn.example.com/first-${item.id}.m3u8');
      },
      cache: PreloadCache(),
    );
    final List<MediaItem> upcoming = List<MediaItem>.generate(4, _item);
    queue.update(
      episodes: episodes,
      currentIndex: 0,
      upcomingItems: upcoming,
    );
    await _waitUntil(() => firstCalls.length == 3);
    // 第 4 部超出上限，不解析。
    expect(firstCalls, <String>['m0', 'm1', 'm2']);
    expect(queue.lookupFirstEpisode(upcoming[0])?.url,
        'https://cdn.example.com/first-m0.m3u8');
    expect(queue.lookupFirstEpisode(upcoming[3]), isNull);
    queue.dispose();
  });

  test('后续影视首集解析返回 null 时不缓存、不影响其它任务', () async {
    final List<Episode> episodes = List<Episode>.generate(2, _ep);
    final PreloadQueue queue = PreloadQueue(
      resolveEpisode: (Episode ep) async =>
          _result('https://cdn.example.com/${ep.id}.m3u8'),
      resolveFirstEpisode: (MediaItem item) async => item.id == 'm0'
          ? null
          : _result('https://cdn.example.com/first-${item.id}.m3u8'),
      cache: PreloadCache(),
    );
    queue.update(
      episodes: episodes,
      currentIndex: 0,
      upcomingItems: <MediaItem>[_item(0), _item(1)],
    );
    await _waitUntil(() => queue.lookupFirstEpisode(_item(1)) != null);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(queue.lookupFirstEpisode(_item(0)), isNull);
    expect(queue.lookupEpisode(episodes[1]), isNotNull);
    queue.dispose();
  });

  test('失败静默：某集解析抛错不缓存、不阻塞其它集', () async {
    final List<Episode> episodes = List<Episode>.generate(10, _ep);
    final PreloadQueue queue = PreloadQueue(
      resolveEpisode: (Episode ep) async {
        if (ep.id == 'ep2') throw StateError('解析失败');
        return _result('https://cdn.example.com/${ep.id}.m3u8');
      },
      cache: PreloadCache(),
    );
    queue.update(episodes: episodes, currentIndex: 0);
    await _waitUntil(
      () => queue.lookupEpisode(episodes[5]) != null,
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(queue.lookupEpisode(episodes[2]), isNull);
    expect(queue.lookupEpisode(episodes[1]), isNotNull);
    expect(queue.lookupEpisode(episodes[3]), isNotNull);
    queue.dispose();
  });

  test('并发有界：同时最多 2 个后台解析', () async {
    final List<Episode> episodes = List<Episode>.generate(10, _ep);
    int active = 0;
    int maxActive = 0;
    final PreloadQueue queue = PreloadQueue(
      resolveEpisode: (Episode ep) async {
        active++;
        if (active > maxActive) maxActive = active;
        await Future<void>.delayed(const Duration(milliseconds: 10));
        active--;
        return _result('https://cdn.example.com/${ep.id}.m3u8');
      },
      cache: PreloadCache(),
    );
    queue.update(episodes: episodes, currentIndex: 0);
    await _waitUntil(() => queue.lookupEpisode(episodes[5]) != null);
    expect(maxActive, 2);
    expect(maxActive, lessThanOrEqualTo(2));
    queue.dispose();
  });

  test('销毁后 update 与查询全部失效', () async {
    final List<Episode> episodes = List<Episode>.generate(10, _ep);
    int calls = 0;
    final PreloadQueue queue = PreloadQueue(
      resolveEpisode: (Episode ep) async {
        calls++;
        return _result('https://cdn.example.com/${ep.id}.m3u8');
      },
      cache: PreloadCache(),
    );
    queue.dispose();
    queue.update(episodes: episodes, currentIndex: 0);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(calls, 0);
    expect(queue.lookupEpisode(episodes[1]), isNull);
  });

  group('视频默认竖屏 + 预加载开关默认', () {
    test('新装默认：竖屏 + 预加载开', () {
      const PlayerSettings fresh = PlayerSettings();
      expect(fresh.lockOrientation, PlayerLockOrientation.portrait);
      expect(fresh.preloadEnabled, isTrue);
    });

    test('JSON 缺键回落新默认（竖屏 + 预加载开）', () {
      final PlayerSettings s = PlayerSettings.fromJson(<String, dynamic>{});
      expect(s.lockOrientation, PlayerLockOrientation.portrait);
      expect(s.preloadEnabled, isTrue);
    });

    test('JSON 非法方向值回落竖屏', () {
      final PlayerSettings s = PlayerSettings.fromJson(
        <String, dynamic>{'lockOrientation': 'sideways'},
      );
      expect(s.lockOrientation, PlayerLockOrientation.portrait);
    });

    test('已存值原样保留：已存横屏/预加载关不被默认覆盖', () {
      final PlayerSettings s = PlayerSettings.fromJson(<String, dynamic>{
        'lockOrientation': 'landscape',
        'preloadEnabled': false,
      });
      expect(s.lockOrientation, PlayerLockOrientation.landscape);
      expect(s.preloadEnabled, isFalse);
    });

    test('copyWith/toJson 往返保留方向与预加载开关', () {
      const PlayerSettings base = PlayerSettings();
      final PlayerSettings changed = base.copyWith(
        lockOrientation: PlayerLockOrientation.auto,
        preloadEnabled: false,
      );
      final PlayerSettings roundTripped =
          PlayerSettings.fromJson(changed.toJson());
      expect(roundTripped.lockOrientation, PlayerLockOrientation.auto);
      expect(roundTripped.preloadEnabled, isFalse);
      expect(
        base.copyWith().lockOrientation,
        PlayerLockOrientation.portrait,
      );
    });
  });
}
