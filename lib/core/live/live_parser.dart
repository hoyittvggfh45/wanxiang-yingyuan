/// 直播清单解析器：M3U 与文本格式两路（改写自魔蚁 live_parser 口径）。
///
/// M3U：`#EXTINF:-1 tvg-logo="..." group-title="..."，频道名` + 下一行地址。
/// 文本：`分组名,#genre#` 为组头，`频道名,地址` 为条目。
/// 同名同组连续条目合并为一条频道的多地址（主备切换）。
library;

import 'live_models.dart';

class LiveParser {
  static const int maxLines = 30000;

  static const String defaultGroup = '未分组';

  static final RegExp _extinfAttrs = RegExp(r'(\w[\w-]*)="([^"]*)"');

  /// 解析整份清单文本，自动识别 M3U / 文本格式。
  static LiveParseResult parse(String text) {
    final List<String> lines = text.split('\n');
    if (lines.length > maxLines) {
      lines.removeRange(maxLines, lines.length);
    }
    if (lines.isNotEmpty && lines.first.trim().startsWith('#EXTM3U')) {
      return _parseM3u(lines);
    }
    return _parseText(lines);
  }

  static LiveParseResult _parseM3u(List<String> lines) {
    final Map<String, List<LiveChannel>> byGroup =
        <String, List<LiveChannel>>{};
    String pendingName = '';
    String pendingLogo = '';
    String pendingGroup = defaultGroup;
    bool hasPending = false;

    void addChannel(String url) {
      if (!hasPending || pendingName.isEmpty || url.isEmpty) return;
      final List<LiveChannel> list = byGroup.putIfAbsent(
        pendingGroup,
        () => <LiveChannel>[],
      );
      // 同名同组连续条目合并多地址。
      if (list.isNotEmpty &&
          list.last.name == pendingName &&
          list.last.group == pendingGroup) {
        final LiveChannel last = list.removeLast();
        list.add(
          LiveChannel(
            key: last.key,
            name: last.name,
            urls: <String>[...last.urls, url],
            logo: last.logo ?? (pendingLogo.isEmpty ? null : pendingLogo),
            group: last.group,
          ),
        );
      } else {
        list.add(
          LiveChannel(
            key: '$pendingGroup::$pendingName::${list.length}',
            name: pendingName,
            urls: <String>[url],
            logo: pendingLogo.isEmpty ? null : pendingLogo,
            group: pendingGroup,
          ),
        );
      }
      hasPending = false;
    }

    for (final String raw in lines) {
      final String line = raw.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('#EXTINF')) {
        final int comma = line.indexOf(',');
        pendingName = comma >= 0 ? line.substring(comma + 1).trim() : '';
        pendingLogo = '';
        pendingGroup = defaultGroup;
        final String attrPart = comma >= 0 ? line.substring(0, comma) : line;
        for (final RegExpMatch m in _extinfAttrs.allMatches(attrPart)) {
          final String key = m.group(1)!.toLowerCase();
          final String value = m.group(2)!;
          if (key == 'tvg-logo') {
            pendingLogo = value;
          } else if (key == 'group-title') {
            pendingGroup = value.isEmpty ? defaultGroup : value;
          }
        }
        hasPending = true;
      } else if (line.startsWith('#')) {
        continue;
      } else {
        addChannel(line);
      }
    }
    return _toResult(byGroup);
  }

  static LiveParseResult _parseText(List<String> lines) {
    final Map<String, List<LiveChannel>> byGroup =
        <String, List<LiveChannel>>{};
    String group = defaultGroup;
    for (final String raw in lines) {
      final String line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final int comma = line.indexOf(',');
      if (comma < 0) continue;
      final String name = line.substring(0, comma).trim();
      final String rest = line.substring(comma + 1).trim();
      if (rest == '#genre#') {
        group = name.isEmpty ? defaultGroup : name;
        continue;
      }
      if (name.isEmpty || rest.isEmpty) continue;
      final List<LiveChannel> list = byGroup.putIfAbsent(
        group,
        () => <LiveChannel>[],
      );
      list.add(
        LiveChannel(
          key: '$group::$name::${list.length}',
          name: name,
          urls: <String>[rest],
          group: group,
        ),
      );
    }
    return _toResult(byGroup);
  }

  static LiveParseResult _toResult(Map<String, List<LiveChannel>> byGroup) {
    final List<LiveGroup> groups = byGroup.entries
        .map(
          (MapEntry<String, List<LiveChannel>> e) =>
              LiveGroup(name: e.key, channels: e.value),
        )
        .toList();
    int total = 0;
    for (final LiveGroup g in groups) {
      total += g.channels.length;
    }
    return LiveParseResult(groups: groups, totalChannels: total);
  }
}
