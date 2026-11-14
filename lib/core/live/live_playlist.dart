/// 直播房间的选台状态：纯 Dart，不依赖播放器内核，可单元测试。
///
/// 语义对照魔蚁 `LivePlaybackController` 的选台部分：同一份频道表内
/// 上一台 / 下一台越界环绕；切台时线路归零；多地址频道可在台内换线路。
/// 播放器本体由房间页持有（见 `live_room_screen.dart`），这里只管“播哪条”。
library;

import 'live_models.dart';

/// 频道选台表：频道顺序 + 当前下标 + 当前线路下标。
class LivePlaylist {
  LivePlaylist({
    required List<LiveChannel> channels,
    int index = 0,
    int route = 0,
  }) : _channels = List<LiveChannel>.unmodifiable(channels),
       _index = channels.isEmpty
           ? 0
           : index.clamp(0, channels.length - 1),
       _route = route < 0 ? 0 : route;

  final List<LiveChannel> _channels;
  int _index;
  int _route;

  /// 全部频道（建表顺序：各分组按清单顺序拼平）。
  List<LiveChannel> get channels => _channels;

  /// 频道总数。
  int get length => _channels.length;

  bool get isEmpty => _channels.isEmpty;

  /// 当前频道下标。
  int get index => _index;

  /// 当前线路下标（当前频道地址列表内的位置）。
  int get route => _route;

  /// 当前频道；表空时为 null。
  LiveChannel? get channel => _channels.isEmpty ? null : _channels[_index];

  /// 当前要播的地址（当前频道 + 当前线路）；无地址时为空字符串。
  String get url {
    final LiveChannel? current = channel;
    if (current == null || current.urls.isEmpty) return '';
    return current.urls[_route.clamp(0, current.urls.length - 1)];
  }

  /// 当前频道是否有可换的备用线路。
  bool get hasMultipleRoutes {
    final LiveChannel? current = channel;
    return current != null && current.urls.length > 1;
  }

  /// 当前频道是否可播（至少一条 http(s) 地址）。
  bool get playable => channel?.playable ?? false;

  /// 按 key 找下标，找不到返回 -1。
  int indexOfKey(String key) =>
      _channels.indexWhere((LiveChannel c) => c.key == key);

  /// 播第 [index] 个频道（越界 clamp），线路归零。
  void play(int index) {
    if (_channels.isEmpty) return;
    _index = index.clamp(0, _channels.length - 1);
    _route = 0;
  }

  /// 上一台 / 下一台：[delta] 为 -1 / +1，越界环绕；切台后线路归零。
  void switchBy(int delta) {
    if (_channels.length < 2) return;
    _index = (_index + delta + _channels.length) % _channels.length;
    _route = 0;
  }

  /// 换到当前频道的第 [route] 条线路（越界 clamp）。
  void playRoute(int route) {
    final LiveChannel? current = channel;
    if (current == null || current.urls.isEmpty) return;
    _route = route.clamp(0, current.urls.length - 1);
  }

  /// 是否还有没试过的备用线路（出错自动换线用）。
  bool get hasUntriedRoute {
    final LiveChannel? current = channel;
    return current != null && _route + 1 < current.urls.length;
  }
}

/// 把分组按清单顺序拼平成一张频道表（房间页上一台 / 下一台的范围）。
List<LiveChannel> flattenLiveGroups(List<LiveGroup> groups) {
  final List<LiveChannel> all = <LiveChannel>[];
  for (final LiveGroup g in groups) {
    all.addAll(g.channels);
  }
  return all;
}
