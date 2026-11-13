/// MacCMS / 采集 API 解析器。
///
/// 识别 `ac=list` / `ac=videolist` / `ac=detail` 自动推断接口；
/// 拆分 `vod_play_from` / `vod_play_url` 为多「播放线路」；解析动态分类。
library;

import '../models/category_entry.dart';
import '../models/episode.dart';
import '../models/media_item.dart';
import '../models/plugin_config.dart';

class CollectApiParser {
  CollectApiParser._();

  /// 是否疑似采集 API（用于 source 自动识别）。
  static bool looksLikeCollectApi(String url) =>
      url.contains('ac=list') ||
      url.contains('ac=videolist') ||
      url.contains('ac=detail');

  static List<MediaItem> parseList(dynamic json, PluginConfig source) {
    final map = (json is Map) ? json : <String, dynamic>{};
    final list = (map['list'] as List?) ?? [];
    return [
      for (final e in list)
        if (e is Map) _itemFromMap(e, source),
    ];
  }

  static MediaItem parseDetail(dynamic json, PluginConfig source) {
    final map = (json is Map) ? json : <String, dynamic>{};
    final list = (map['list'] as List?) ?? [];
    if (list.isNotEmpty && list.first is Map) {
      return _itemFromMap(list.first as Map, source);
    }
    return _itemFromMap(map, source);
  }

  static MediaItem _itemFromMap(Map<dynamic, dynamic> e, PluginConfig source) {
    final detailUrl =
        '${source.site.baseUrl}/api.php/provide/vod/?ac=detail&ids=${e['vod_id']}';
    return MediaItem(
      id: _s(e['vod_id']),
      title: _s(e['vod_name']),
      coverUrl: _s(e['vod_pic']),
      detailUrl: detailUrl,
      sourceId: source.id,
      sourceType: source.type,
      description: _s(e['vod_content']),
      director: _s(e['vod_director']),
      actors: _s(e['vod_actor']),
      status: _s(e['vod_remarks']),
      year: _s(e['vod_year']),
      tags: _splitTags(e['vod_tag']),
      updatedAt: _parseTime(e['vod_time']),
    );
  }

  /// 拆分播放线路：vod_play_from 与 vod_play_url 以 `$$$` 分行、每行 `#` 分集、`$` 分 [标题$地址]。
  ///
  /// **保留全部线路**：每条线路的每集都原样返回（带 [Episode.lineName]），
  /// 不按集标题跨线路去重——UI 按线路分组展示、播放器按线路切换（
  /// chapter_list_section / player_controller），去重会丢掉同集的备用线路，
  /// 与 HTML 线路模式（lineList 分组解析保留全量）也不一致。总集数统计
  /// 由调用方按 lineName 分组取最大一组（见 unified_progress_repository），
  /// 不需要这里去重。
  static List<Episode> splitPlayLines(dynamic vodPlayFrom, dynamic vodPlayUrl) {
    final froms = (vodPlayFrom as String? ?? '').split(r'$$$');
    final urls = (vodPlayUrl as String? ?? '').split(r'$$$');
    final episodes = <Episode>[];
    for (var i = 0; i < froms.length; i++) {
      final line = froms[i].trim();
      if (line.isEmpty) continue;
      final parts = (urls.length > i ? urls[i] : '').split('#');
      for (final p in parts) {
        final seg = p.split('\$');
        if (seg.length >= 2 && seg[1].isNotEmpty) {
          episodes.add(Episode(
            id: seg[0],
            title: seg[0],
            url: seg[1],
            lineName: line,
          ));
        }
      }
    }
    return episodes;
  }

  static List<CategoryEntry> parseCategories(dynamic json) {
    final map = (json is Map) ? json : <String, dynamic>{};
    final cls = (map['class'] as List?) ?? [];
    return [
      for (final c in cls)
        if (c is Map)
          CategoryEntry.fromJson({
            'id': c['type_id'],
            'title': c['type_name'],
          }),
    ];
  }

  static String _s(dynamic v) => v?.toString() ?? '';
  static List<String>? _splitTags(dynamic v) {
    final s = _s(v);
    if (s.isEmpty) return null;
    return s.split(RegExp(r'[,，/、|\s]+')).where((t) => t.isNotEmpty).toList();
  }

  static DateTime? _parseTime(dynamic v) {
    final s = _s(v);
    if (s.isEmpty) return null;
    return DateTime.tryParse(s);
  }
}
