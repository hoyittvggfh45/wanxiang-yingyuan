/// TVBox 蜘蛛结果 → 统一模型的映射（py / jar 共用）。
///
/// 字段口径对齐 TVBox 全协议：`vod_id` / `vod_name` / `vod_pic` /
/// `vod_content` / `vod_actor` / `vod_director` / `vod_year` / `vod_area` /
/// `vod_remarks` / `vod_play_from` / `vod_play_url`（`$$$` 分线路、`#`
/// 分集、`$` 分名址）。播放上下文（线路名）由 [SpiderPlayContext] 暂存，
/// 供取流时还原 `playerContent(flag, id)` 的 flag 参数。
library;

import 'dart:collection';

import '../models/category_entry.dart';
import '../models/episode.dart';
import '../models/media_item.dart';
import '../models/plugin_config.dart';

String _s(Object? v) => v == null ? '' : v.toString();

/// 列表项映射：`list` 数组 → [MediaItem]。
List<MediaItem> vodListToItems(List<dynamic> list, PluginConfig source) {
  final items = <MediaItem>[];
  for (final e in list) {
    if (e is! Map) continue;
    final id = _s(e['vod_id']);
    final title = _s(e['vod_name']);
    if (id.isEmpty || title.isEmpty) continue;
    final tags = <String>[];
    final area = _s(e['vod_area']);
    final typeName = _s(e['type_name']);
    if (area.isNotEmpty) tags.add(area);
    if (typeName.isNotEmpty) tags.add(typeName);
    items.add(
      MediaItem(
        id: id,
        title: title,
        coverUrl: _s(e['vod_pic']).isEmpty ? null : _s(e['vod_pic']),
        sourceId: source.id,
        sourceType: source.type,
        description: _s(e['vod_content']).isEmpty ? null : _s(e['vod_content']),
        director: _s(e['vod_director']).isEmpty ? null : _s(e['vod_director']),
        actors: _s(e['vod_actor']).isEmpty ? null : _s(e['vod_actor']),
        year: _s(e['vod_year']).isEmpty ? null : _s(e['vod_year']),
        tags: tags.isEmpty ? null : tags,
        status: _s(e['vod_remarks']).isEmpty ? null : _s(e['vod_remarks']),
        extra: <String, dynamic>{
          if (e['vod_tag'] != null) 'vod_tag': e['vod_tag'],
        },
      ),
    );
  }
  return items;
}

/// 分类映射：`class` 数组 → [CategoryEntry]。
List<CategoryEntry> classListToCategories(List<dynamic> classes) {
  final entries = <CategoryEntry>[];
  for (final e in classes) {
    if (e is! Map) continue;
    final id = _s(e['type_id']);
    final title = _s(e['type_name']);
    if (id.isEmpty || title.isEmpty) continue;
    entries.add(CategoryEntry(id: id, title: title));
  }
  return entries;
}

/// 详情映射：单个 vod → [MediaItem]（含播放线路信息进 extra，供调试）。
MediaItem vodToDetailItem(Map<String, dynamic> vod, PluginConfig source) {
  final items = vodListToItems(<dynamic>[vod], source);
  if (items.isEmpty) {
    throw StateError('详情结果为空');
  }
  return items.first;
}

/// 详情映射：单个 vod 的播放线路 → 剧集列表。
///
/// 每集的 [Episode.url] 为原始播放地址；线路名经 [SpiderPlayContext] 暂存，
/// 取流时由解析器还原 flag。
List<Episode> vodToEpisodes(Map<String, dynamic> vod, PluginConfig source) {
  final vodId = _s(vod['vod_id']);
  final fromRaw = _s(vod['vod_play_from']);
  final urlRaw = _s(vod['vod_play_url']);
  if (urlRaw.isEmpty) return const <Episode>[];
  final froms = fromRaw.isEmpty ? const <String>[] : fromRaw.split(r'$$$');
  final groups = urlRaw.split(r'$$$');
  final episodes = <Episode>[];
  for (var gi = 0; gi < groups.length; gi++) {
    final flag = gi < froms.length ? froms[gi] : '';
    final parts = groups[gi].split('#');
    for (var i = 0; i < parts.length; i++) {
      final part = parts[i].trim();
      if (part.isEmpty) continue;
      final dollar = part.indexOf(r'$');
      final String name;
      final String playUrl;
      if (dollar >= 0) {
        name = part.substring(0, dollar).trim();
        playUrl = part.substring(dollar + 1).trim();
      } else {
        name = '';
        playUrl = part;
      }
      if (playUrl.isEmpty) continue;
      final title = name.isEmpty ? '第 ${i + 1} 集' : name;
      SpiderPlayContext.remember(playUrl, vodId, flag);
      episodes.add(
        Episode(
          id: '$vodId::$gi::$i',
          title: title,
          url: playUrl,
          lineName: flag.isEmpty ? null : flag,
          number: i + 1,
        ),
      );
    }
  }
  return episodes;
}

/// 取流结果映射：`playerContent` 返回 → [VideoResult]。
///
/// 要求蜘蛛回真直链（`parse: 0`）；`parse: 1` 的结果原样返回地址，
/// 播放器按直链尝试，失败时由播放器诚实报错。
VideoResult playerResultToVideo(Map<String, dynamic> result) {
  final url = _s(result['url']);
  if (url.isEmpty) {
    throw StateError('取流结果为空');
  }
  final headersRaw = result['header'];
  Map<String, String>? headers;
  if (headersRaw is Map) {
    headers = headersRaw.map((k, v) => MapEntry(k.toString(), v.toString()));
  }
  String? type;
  final lower = url.toLowerCase();
  if (lower.contains('.m3u8')) {
    type = 'm3u8';
  } else if (lower.contains('.mp4')) {
    type = 'mp4';
  } else if (lower.contains('.mpd')) {
    type = 'dash';
  }
  return VideoResult(url: url, type: type, headers: headers);
}

/// 播放上下文暂存：播放地址 → （vodId，线路 flag）。
///
/// 容量封顶 500 条，超限淘汰最早写入的条目（单详情会话内足够用）。
class SpiderPlayContext {
  SpiderPlayContext._();

  static final LinkedHashMap<String, ({String vodId, String flag})> _map =
      LinkedHashMap<String, ({String vodId, String flag})>();

  static const int _maxEntries = 500;

  static void remember(String playUrl, String vodId, String flag) {
    _map.remove(playUrl);
    _map[playUrl] = (vodId: vodId, flag: flag);
    while (_map.length > _maxEntries) {
      _map.remove(_map.keys.first);
    }
  }

  static ({String vodId, String flag})? lookup(String playUrl) => _map[playUrl];

  static void clear() => _map.clear();
}
