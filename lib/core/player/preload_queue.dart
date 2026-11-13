/// 播放器预加载队列：后台只解析播放地址并缓存，绝不下载视频字节。
///
/// 规格（用户 2026-11-01 定）：播当前集时，后台解析往后 5 集的播放地址 +
/// 往后 1–3 部影视的首集地址；滑动/切集时队列实时重算、窗口滑动补齐，
/// 总数维持 5 集；开关关闭时不做任何后台解析。
///
/// 可测试设计：解析动作经回调函数注入（不写死 [MediaApiService]），
/// 测试用假解析函数；时间经 [now] 注入，测试用假时钟。
///
/// 缓存有效期默认 15 分钟：播放地址多为有时效的签名地址，常见有效期从
/// 数十分钟到数小时；15 分钟取保守值，避免播出已过期的签名地址。过期
/// 只影响“立刻切集命中率”，不影响正确性——未命中走正常取流重新解析。
library;

import 'dart:async';

import '../models/episode.dart';
import '../models/media_item.dart';

/// 解析某集播放地址（只解析地址，不下载视频字节）。
typedef PreloadEpisodeResolver = Future<VideoResult> Function(Episode episode);

/// 解析某部影视首集的播放地址（详情→取首集→取流）。
///
/// 返回 null 表示该作品无可播首集（源缺失、无剧集、解析失败由调用方
/// 决定是否抛错；抛错时队列静默丢弃，不缓存失败结果）。
typedef PreloadFirstEpisodeResolver = Future<VideoResult?> Function(
  MediaItem item,
);

/// 剧集缓存键生成函数：默认只用剧集地址；同一地址在不同源下可能解析出
/// 不同结果，调用方应把源身份编进键里（见 [PreloadQueue.episodeKey]）。
typedef PreloadEpisodeKeyOf = String Function(Episode episode);

class _PreloadEntry {
  final VideoResult result;
  final DateTime storedAt;

  const _PreloadEntry(this.result, this.storedAt);
}

/// 预加载地址缓存（纯内存 Map，带时间戳）。
///
/// 默认所有队列共用 [shared]：上一个详情页预加载的“后续影视首集”，
/// 在下一个详情页打开首集时才能命中。测试应各自传入新实例以隔离。
class PreloadCache {
  /// 进程内共享缓存实例。
  static final PreloadCache shared = PreloadCache();

  /// 缓存条目上限：超出时淘汰最早存入的条目，避免无界增长。
  static const int maxEntries = 32;

  final Map<String, _PreloadEntry> _entries = <String, _PreloadEntry>{};

  PreloadCache();

  /// 查缓存：命中且未过期返回结果；过期条目当场清除并返回 null。
  VideoResult? lookup(
    String key, {
    required DateTime now,
    required Duration ttl,
  }) {
    final _PreloadEntry? entry = _entries[key];
    if (entry == null) return null;
    if (now.difference(entry.storedAt) >= ttl) {
      _entries.remove(key);
      return null;
    }
    return entry.result;
  }

  /// 存入缓存（重复存入刷新时间戳并移到最新位置）。
  void store(String key, VideoResult result, {required DateTime now}) {
    _entries.remove(key);
    _entries[key] = _PreloadEntry(result, now);
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
  }

  void remove(String key) => _entries.remove(key);

  void clear() => _entries.clear();

  List<String> get keys => _entries.keys.toList(growable: false);

  int get length => _entries.length;
}

class _PreloadJob {
  final String key;
  final Episode? episode;
  final MediaItem? item;

  const _PreloadJob.episode(this.key, this.episode) : item = null;

  const _PreloadJob.firstEpisode(this.key, this.item) : episode = null;

  Future<VideoResult?> run(
    PreloadEpisodeResolver resolveEpisode,
    PreloadFirstEpisodeResolver? resolveFirstEpisode,
  ) {
    final Episode? ep = episode;
    if (ep != null) return resolveEpisode(ep);
    return resolveFirstEpisode!(item!);
  }
}

/// 预加载队列：窗口重算、并发有界、过期取消、失败静默。
class PreloadQueue {
  /// 默认窗口：往后 5 集。
  static const int defaultWindowSize = 5;

  /// 默认后续影视部数上限：往后 1–3 部。
  static const int defaultMaxUpcomingTitles = 3;

  /// 默认并发上限：同时最多 2 个后台解析。
  static const int defaultMaxConcurrent = 2;

  /// 默认缓存有效期：15 分钟（见文件头注释的理由）。
  static const Duration defaultTtl = Duration(minutes: 15);

  /// 剧集缓存键：源 id + 剧集地址，避免不同源同地址撞键。
  static String episodeKey(String sourceId, Episode episode) =>
      'ep:$sourceId:${episode.url}';

  /// 某部影视首集的缓存键：源 id + 作品 id。
  static String firstEpisodeKey(MediaItem item) =>
      'first:${item.sourceId ?? ''}:${item.id}';

  final PreloadEpisodeResolver _resolveEpisode;
  final PreloadFirstEpisodeResolver? _resolveFirstEpisode;
  final PreloadCache _cache;
  final PreloadEpisodeKeyOf _keyOfEpisode;
  final int windowSize;
  final int maxUpcomingTitles;
  final int maxConcurrent;
  final Duration ttl;
  final DateTime Function() _now;

  bool _enabled;
  bool _disposed = false;

  /// 排队等待执行的任务（插入顺序 = 优先级：先近集、后后续影视）。
  final Map<String, _PreloadJob> _pending = <String, _PreloadJob>{};

  /// 正在执行的任务键集合。
  final Set<String> _active = <String>{};

  /// 当前窗口想要的键集合：执行中的任务完成时，只有键仍在集合里
  /// 才写入缓存——切集后过期的任务结果就此作废。
  Set<String> _wanted = <String>{};

  PreloadQueue({
    required PreloadEpisodeResolver resolveEpisode,
    PreloadFirstEpisodeResolver? resolveFirstEpisode,
    PreloadCache? cache,
    PreloadEpisodeKeyOf? keyOfEpisode,
    bool enabled = true,
    this.windowSize = defaultWindowSize,
    this.maxUpcomingTitles = defaultMaxUpcomingTitles,
    this.maxConcurrent = defaultMaxConcurrent,
    this.ttl = defaultTtl,
    DateTime Function()? now,
  })  : assert(maxConcurrent >= 1, 'maxConcurrent must be >= 1'),
        assert(windowSize >= 0, 'windowSize must be >= 0'),
        assert(maxUpcomingTitles >= 0, 'maxUpcomingTitles must be >= 0'),
        _resolveEpisode = resolveEpisode,
        _resolveFirstEpisode = resolveFirstEpisode,
        _cache = cache ?? PreloadCache.shared,
        _keyOfEpisode = keyOfEpisode ?? ((Episode e) => 'ep:${e.url}'),
        _enabled = enabled,
        _now = now ?? DateTime.now;

  bool get enabled => _enabled;

  /// 排队中的任务数（测试与诊断用）。
  int get pendingCount => _pending.length;

  /// 正在执行的任务数（测试与诊断用）。
  int get activeCount => _active.length;

  /// 排队中的任务键（测试用）。
  List<String> get pendingKeys => _pending.keys.toList(growable: false);

  /// 当前缓存的键（测试用）。
  List<String> get cachedKeys => _cache.keys;

  /// 开关：关闭时排队任务全部取消、执行中的任务结果作废且不再写入
  /// 缓存；重新打开后需再调用 [update] 才会重新排队。
  void setEnabled(bool value) {
    if (_enabled == value) return;
    _enabled = value;
    if (!value) {
      _pending.clear();
      _wanted = <String>{};
    }
  }

  /// 查某集的缓存地址：开关关闭、已销毁、未命中、已过期都返回 null。
  VideoResult? lookupEpisode(Episode episode) {
    if (!_enabled || _disposed) return null;
    return _cache.lookup(_keyOfEpisode(episode), now: _now(), ttl: ttl);
  }

  /// 查某部影视首集的缓存地址（由“后续影视首集”预加载写入）。
  VideoResult? lookupFirstEpisode(MediaItem item) {
    if (!_enabled || _disposed) return null;
    return _cache.lookup(firstEpisodeKey(item), now: _now(), ttl: ttl);
  }

  /// 按当前集下标重算窗口：往后 [windowSize] 集 + 往后
  /// [maxUpcomingTitles] 部影视的首集。
  ///
  /// 已缓存（未过期）的键不再重复解析；不再属于窗口的排队任务取消；
  /// 执行中的过期任务完成时结果作废（见 [_wanted]）。开关关闭时
  /// 拒绝一切后台解析：不排队、不执行。
  void update({
    required List<Episode> episodes,
    required int currentIndex,
    List<MediaItem> upcomingItems = const <MediaItem>[],
  }) {
    if (_disposed) return;
    final Map<String, _PreloadJob> wanted = <String, _PreloadJob>{};
    final DateTime now = _now();
    for (int i = currentIndex + 1;
        i <= currentIndex + windowSize && i < episodes.length;
        i++) {
      final Episode ep = episodes[i];
      if (ep.url.isEmpty) continue;
      final String key = _keyOfEpisode(ep);
      if (_cache.lookup(key, now: now, ttl: ttl) != null) continue;
      wanted[key] = _PreloadJob.episode(key, ep);
    }
    final PreloadFirstEpisodeResolver? firstResolver = _resolveFirstEpisode;
    if (firstResolver != null) {
      for (final MediaItem item in upcomingItems.take(maxUpcomingTitles)) {
        final String key = firstEpisodeKey(item);
        if (_cache.lookup(key, now: now, ttl: ttl) != null) continue;
        wanted[key] = _PreloadJob.firstEpisode(key, item);
      }
    }
    _wanted = wanted.keys.toSet();
    if (!_enabled) {
      _pending.clear();
      return;
    }
    // 取消不再属于窗口的排队任务；执行中的任务由完成时检查作废。
    _pending.removeWhere((String key, _) => !wanted.containsKey(key));
    for (final MapEntry<String, _PreloadJob> entry in wanted.entries) {
      if (_active.contains(entry.key) || _pending.containsKey(entry.key)) {
        continue;
      }
      _pending[entry.key] = entry.value;
    }
    _pump();
  }

  /// 取消全部排队与过期任务（执行中的任务完成时结果作废）。
  void cancelAll() {
    _pending.clear();
    _wanted = <String>{};
  }

  /// 销毁：取消一切任务，此后 [update] 与查询全部失效。
  void dispose() {
    _disposed = true;
    _pending.clear();
    _wanted = <String>{};
  }

  void _pump() {
    if (_disposed || !_enabled) return;
    while (_active.length < maxConcurrent && _pending.isNotEmpty) {
      final String key = _pending.keys.first;
      final _PreloadJob job = _pending.remove(key)!;
      _active.add(key);
      unawaited(_runJob(job));
    }
  }

  Future<void> _runJob(_PreloadJob job) async {
    VideoResult? result;
    try {
      result = await job.run(_resolveEpisode, _resolveFirstEpisode);
    } on Object {
      // 失败静默：不缓存失败结果，不抛错，不阻塞其它任务。
      result = null;
    }
    _active.remove(job.key);
    if (_disposed) return;
    if (result != null &&
        result.url.isNotEmpty &&
        _enabled &&
        _wanted.contains(job.key)) {
      _cache.store(job.key, result, now: _now());
    }
    _pump();
  }
}
