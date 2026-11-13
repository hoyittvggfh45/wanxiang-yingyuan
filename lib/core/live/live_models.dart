/// 直播频道模型：频道 + 分组。
library;

/// 单个直播频道（一条可播条目，可带多条备用地址）。
class LiveChannel {
  /// 唯一键（分组 + 名称 + 首地址的组合，避免重名冲突）。
  final String key;
  final String name;

  /// 播放地址列表（首条为主地址，其余为备用）。
  final List<String> urls;
  final String? logo;
  final String group;

  const LiveChannel({
    required this.key,
    required this.name,
    required this.urls,
    this.logo,
    required this.group,
  });

  /// 是否可播（至少一条 http(s) 地址）。
  bool get playable => urls.any(
    (String u) => u.startsWith('http://') || u.startsWith('https://'),
  );

  String get url => urls.isEmpty ? '' : urls.first;
}

/// 频道分组（M3U 的 group-title / 文本格式的 #genre# 头）。
class LiveGroup {
  final String name;
  final List<LiveChannel> channels;

  const LiveGroup({required this.name, required this.channels});
}

/// 解析结果：分组列表 + 频道总数。
class LiveParseResult {
  final List<LiveGroup> groups;
  final int totalChannels;

  const LiveParseResult({required this.groups, required this.totalChannels});

  bool get isEmpty => totalChannels == 0;
}
