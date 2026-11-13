/// 红果数据模型与响应解析。
///
/// 移植自火蚁TV Go 核：`provider_hongguo.go`（剧集解析、路由数据）、
/// `provider_hongguo_detail.go`（详情解析）、`provider_hongguo_catalog.go`
/// （分类分页解析）、`provider_hongguo_native_media.go`（媒体选择）、
/// `provider_hongguo_suggestions.go`（联想记录）、`ui_playback_danmaku.go`
/// （弹幕解析）、`danmaku_emoji.go`（弹幕表情展开）、
/// `provider_hongguo_search.go` / `provider_hongguo_search_seasons.go`
/// （搜索排序与季数解析），以及 Dart 侧 `hongguo_series.dart`（多季分组）。
library;

import 'dart:convert';
import 'dart:math';

/// 红果剧集数字 ID 格式：1 至 32 位数字。
final RegExp hongguoNumericId = RegExp(r'^[0-9]{1,32}$');

/// 从 map 里按优先级取第一个非空字符串字段。
String hongguoMapString(Map<String, dynamic>? map, List<String> keys) {
  if (map == null) return '';
  for (final String key in keys) {
    final Object? value = map[key];
    if (value is String && value.isNotEmpty) return value;
    if (value is num) return value.toString();
    if (value is bool) return value.toString();
  }
  return '';
}

/// 取嵌套 map：沿 [keys] 逐级下钻，缺失返回空 map。
Map<String, dynamic> hongguoNestedMap(Object? value, List<String> keys) {
  Map<String, dynamic>? current;
  if (value is Map<String, dynamic>) {
    current = value;
  } else if (value is Map) {
    current = value.cast<String, dynamic>();
  } else {
    return <String, dynamic>{};
  }
  for (final String key in keys) {
    final Object? next = current?[key];
    if (next is Map<String, dynamic>) {
      current = next;
    } else if (next is Map) {
      current = next.cast<String, dynamic>();
    } else {
      return <String, dynamic>{};
    }
  }
  return current ?? <String, dynamic>{};
}

/// 取列表字段：直接是列表则返回；是 map 则尝试 list/items/data 子键。
List<dynamic> hongguoAnyList(Object? value) {
  if (value is List) return value;
  if (value is Map) {
    for (final String key in <String>['list', 'items', 'data']) {
      final List<dynamic> out = hongguoAnyList(value[key]);
      if (out.isNotEmpty) return out;
    }
  }
  return <dynamic>[];
}

/// 取字符串列表字段。
List<String> hongguoStringList(Map<String, dynamic>? map, String key) {
  final Object? value = map?[key];
  if (value is! List) return <String>[];
  final List<String> out = <String>[];
  for (final Object? item in value) {
    if (item is String && item.isNotEmpty) out.add(item);
  }
  return out;
}

String _firstNonEmpty(List<String> values) {
  for (final String value in values) {
    if (value.isNotEmpty) return value;
  }
  return '';
}

/// 红果剧集。
class HongguoDrama {
  const HongguoDrama({
    required this.id,
    required this.sourceId,
    required this.title,
    this.cover = '',
    this.intro = '',
    this.categoryName = '',
    this.remark = '',
    this.totalEpisode = '',
    this.tags = const <String>[],
    this.releaseStatus = '',
    this.score = '',
    this.views = '',
    this.heat = '',
    this.onlineDate = '',
  });

  /// 内部 ID：`hongguo:<sourceId>`。
  final String id;
  final String sourceId;
  final String title;
  final String cover;
  final String intro;
  final String categoryName;
  final String remark;
  final String totalEpisode;
  final List<String> tags;
  final String releaseStatus;
  final String score;
  final String views;
  final String heat;
  final String onlineDate;

  static String dramaId(String sourceId) => 'hongguo:$sourceId';

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'sourceId': sourceId,
        'title': title,
        'cover': cover,
        'intro': intro,
        'categoryName': categoryName,
        'remark': remark,
        'totalEpisode': totalEpisode,
        'tags': tags,
        'releaseStatus': releaseStatus,
        'score': score,
        'views': views,
        'heat': heat,
        'onlineDate': onlineDate,
      };

  factory HongguoDrama.fromJson(Map<String, dynamic> json) => HongguoDrama(
        id: json['id'] as String? ?? '',
        sourceId: json['sourceId'] as String? ?? '',
        title: json['title'] as String? ?? '',
        cover: json['cover'] as String? ?? '',
        intro: json['intro'] as String? ?? '',
        categoryName: json['categoryName'] as String? ?? '',
        remark: json['remark'] as String? ?? '',
        totalEpisode: json['totalEpisode'] as String? ?? '',
        tags: (json['tags'] as List?)
                ?.map((Object? e) => e.toString())
                .toList() ??
            const <String>[],
        releaseStatus: json['releaseStatus'] as String? ?? '',
        score: json['score'] as String? ?? '',
        views: json['views'] as String? ?? '',
        heat: json['heat'] as String? ?? '',
        onlineDate: json['onlineDate'] as String? ?? '',
      );
}

/// 由接口原始记录解析剧集（对应 Go `hongguoDramaFromAny`）。
HongguoDrama? hongguoDramaFromAny(Object? value, String category) {
  if (value is! Map) return null;
  final Map<String, dynamic> m = value.cast<String, dynamic>();
  Map<String, dynamic> vd = hongguoNestedMap(m, <String>['video_data']);
  if (vd.isEmpty) vd = m;
  final String sourceId = _firstNonEmpty(<String>[
    hongguoMapString(vd, <String>['series_id_str', 'series_id']),
    hongguoMapString(m, <String>['series_id_str', 'series_id']),
    hongguoMapString(vd, <String>['keyword']),
    hongguoMapString(m, <String>['keyword']),
  ]);
  if (!hongguoNumericId.hasMatch(sourceId)) return null;
  final String title = _firstNonEmpty(<String>[
    hongguoMapString(vd, <String>['series_title', 'series_name', 'title']),
    hongguoMapString(m, <String>['series_name', 'name']),
    sourceId,
  ]);
  final String cover = _firstNonEmpty(<String>[
    hongguoMapString(vd, <String>['series_cover', 'cover']),
    hongguoMapString(m, <String>['series_cover']),
  ]);
  final String intro = _firstNonEmpty(<String>[
    hongguoMapString(vd, <String>['series_intro', 'video_desc']),
    hongguoMapString(m, <String>['series_intro']),
  ]);
  final String count = _firstNonEmpty(<String>[
    hongguoMapString(vd, <String>['episode_cnt']),
    hongguoMapString(m, <String>['episode_cnt']),
  ]);
  String remark = _firstNonEmpty(<String>[
    hongguoMapString(vd, <String>['episode_right_text']),
    hongguoMapString(m, <String>['episode_right_text']),
  ]);
  String releaseStatus = '';
  if (remark.contains('完结') || remark.contains('全')) {
    releaseStatus = 'finished';
  } else if (remark.contains('更新') || remark.contains('连载')) {
    releaseStatus = 'ongoing';
  }
  if (hongguoMapString(vd, <String>['series_status']) == '1') {
    releaseStatus = 'finished';
  } else if (hongguoMapString(vd, <String>['series_status']) == '0') {
    releaseStatus = 'ongoing';
  }
  if (remark.isEmpty && count.isNotEmpty) remark = '共$count集';
  final List<String> tags = hongguoStringList(vd, 'tags');
  for (final Object? item in hongguoAnyList(vd['category_list'])) {
    if (item is Map) {
      final String name = hongguoMapString(
        item.cast<String, dynamic>(),
        <String>['name'],
      );
      if (name.isNotEmpty && !tags.contains(name)) tags.add(name);
    }
  }
  final String schemaRaw = hongguoMapString(vd, <String>['category_schema']);
  if (schemaRaw.isNotEmpty) {
    try {
      final Object? decoded = jsonDecode(schemaRaw);
      if (decoded is List) {
        for (final Object? item in decoded) {
          if (item is Map) {
            final String name = hongguoMapString(
              item.cast<String, dynamic>(),
              <String>['name'],
            );
            if (name.isNotEmpty && !tags.contains(name)) tags.add(name);
          }
        }
      }
    } on Object {
      // category_schema 解析失败时忽略，不影响主字段。
    }
  }
  String genre = hongguoMapString(
    vd,
    <String>['category_name', 'categoryName', 'category'],
  );
  if (genre.isEmpty && tags.isNotEmpty) genre = tags.first;
  return HongguoDrama(
    id: HongguoDrama.dramaId(sourceId),
    sourceId: sourceId,
    title: title,
    cover: cover,
    intro: intro,
    categoryName: genre.isNotEmpty ? genre : category,
    remark: remark,
    totalEpisode: count,
    tags: tags,
    releaseStatus: releaseStatus,
    score: hongguoMapString(vd, <String>['score']),
    views: hongguoMapString(vd, <String>['series_play_cnt', 'play_cnt']),
    heat: hongguoMapString(vd, <String>['heat', 'heat_text']),
    onlineDate: hongguoMapString(vd, <String>['online_time', 'online_date']),
  );
}

/// 红果单集。
class HongguoEpisode {
  const HongguoEpisode({
    required this.id,
    required this.videoId,
    required this.index,
    required this.title,
    this.vertical,
  });

  final String id;
  final String videoId;
  final int index;
  final String title;
  final bool? vertical;
}

/// 红果详情：剧集信息 + 分集列表。
class HongguoDetail {
  const HongguoDetail({required this.drama, required this.episodes});

  final HongguoDrama drama;
  final List<HongguoEpisode> episodes;
}

/// 解析 App 详情响应（对应 Go `parseHongguoAppDetail`）。
HongguoDetail parseHongguoAppDetail(
  Map<String, dynamic> result,
  String seriesId,
) {
  final Map<String, dynamic> detail = hongguoNestedMap(
    result,
    <String>['data', 'video_data'],
  );
  final String returnedId = hongguoMapString(
    detail,
    <String>['series_id_str', 'series_id'],
  );
  if (returnedId != seriesId) {
    throw const FormatException('红果 App 未返回所请求的剧集');
  }
  final HongguoDrama? drama = hongguoDramaFromAny(detail, '短剧');
  if (drama == null) {
    throw const FormatException('红果 App 未返回所请求的剧集');
  }
  final Set<String> seen = <String>{};
  final Set<int> episodes = <int>{};
  final List<HongguoEpisode> chapters = <HongguoEpisode>[];
  for (final Object? row in hongguoAnyList(detail['video_list'])) {
    if (row is! Map) continue;
    final Map<String, dynamic> video = row.cast<String, dynamic>();
    final String videoId = hongguoMapString(video, <String>['vid']);
    final int? index = int.tryParse(
      hongguoMapString(video, <String>['vid_index']),
    );
    if (index == null || index < 1 || !hongguoNumericId.hasMatch(videoId)) {
      throw const FormatException('红果 App 分集编号或视频 ID 无效');
    }
    final String identifier = hongguoMapString(video, <String>['series_id']);
    if (identifier.isNotEmpty && identifier != seriesId) {
      throw const FormatException('红果 App 返回了其他剧集的分集');
    }
    if (seen.contains(videoId) || episodes.contains(index)) {
      throw const FormatException('红果 App 返回了重复分集');
    }
    seen.add(videoId);
    episodes.add(index);
    final Object? verticalRaw = video['vertical'];
    chapters.add(
      HongguoEpisode(
        id: 'hongguo:$seriesId:$videoId',
        videoId: videoId,
        index: index,
        title: '第$index集',
        vertical: verticalRaw is bool ? verticalRaw : null,
      ),
    );
  }
  chapters.sort(
    (HongguoEpisode a, HongguoEpisode b) => a.index.compareTo(b.index),
  );
  final int total =
      int.tryParse(hongguoMapString(detail, <String>['episode_cnt'])) ?? 0;
  if (chapters.isEmpty || total > chapters.length) {
    throw const FormatException('红果 App 未返回完整分集，已尝试其他详情入口');
  }
  for (int i = 0; i < chapters.length; i++) {
    if (chapters[i].index != i + 1) {
      throw const FormatException('红果 App 分集列表不连续');
    }
  }
  return HongguoDetail(drama: drama, episodes: chapters);
}

/// 分类分页游标（对应 Go `hongguoCatalogCursor`）。
class HongguoCatalogCursor {
  const HongguoCatalogCursor({
    this.offset = 0,
    this.sessionId = '',
    this.lastId = '',
    this.pageSignature = '',
    this.initialized = false,
    this.exhausted = false,
    this.updatedAt,
  });

  final int offset;
  final String sessionId;
  final String lastId;
  final String pageSignature;
  final bool initialized;
  final bool exhausted;
  final DateTime? updatedAt;

  HongguoCatalogCursor copyWith({
    int? offset,
    String? sessionId,
    String? lastId,
    String? pageSignature,
    bool? initialized,
    bool? exhausted,
    DateTime? updatedAt,
  }) =>
      HongguoCatalogCursor(
        offset: offset ?? this.offset,
        sessionId: sessionId ?? this.sessionId,
        lastId: lastId ?? this.lastId,
        pageSignature: pageSignature ?? this.pageSignature,
        initialized: initialized ?? this.initialized,
        exhausted: exhausted ?? this.exhausted,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'offset': offset,
        'sessionId': sessionId,
        'lastId': lastId,
        'pageSignature': pageSignature,
        'initialized': initialized,
        'exhausted': exhausted,
        'updatedAt': updatedAt?.millisecondsSinceEpoch,
      };

  factory HongguoCatalogCursor.fromJson(Map<String, dynamic> json) =>
      HongguoCatalogCursor(
        offset: json['offset'] as int? ?? 0,
        sessionId: json['sessionId'] as String? ?? '',
        lastId: json['lastId'] as String? ?? '',
        pageSignature: json['pageSignature'] as String? ?? '',
        initialized: json['initialized'] as bool? ?? false,
        exhausted: json['exhausted'] as bool? ?? false,
        updatedAt: json['updatedAt'] is int
            ? DateTime.fromMillisecondsSinceEpoch(json['updatedAt'] as int)
            : null,
      );
}

/// 分类页解析结果。
class HongguoCatalogPage {
  const HongguoCatalogPage({required this.dramas, required this.cursor});

  final List<HongguoDrama> dramas;
  final HongguoCatalogCursor cursor;
}

/// 解析 App 分类页响应（对应 Go `parseHongguoCatalogPage`）。
///
/// [pageSignature] 由调用方传入：本页剧集 ID 排序后拼接的 SHA-256 十六进制。
HongguoCatalogPage parseHongguoCatalogPage(
  Map<String, dynamic> result,
  HongguoCatalogCursor cursor,
  String category, {
  required String Function(List<String> sortedIds) pageSignature,
}) {
  final Map<String, dynamic> data = hongguoNestedMap(result, <String>['data']);
  final Object? rowsRaw = data['video_data'];
  if (rowsRaw is! List) {
    throw const FormatException('App 分类数据格式异常');
  }
  final List<HongguoDrama> items = <HongguoDrama>[];
  final List<String> ids = <String>[];
  final Set<String> seen = <String>{};
  for (final Object? row in rowsRaw) {
    final HongguoDrama? drama = hongguoDramaFromAny(row, category);
    if (drama != null) {
      items.add(drama);
      if (seen.add(drama.id)) ids.add(drama.id);
    }
  }
  if (rowsRaw.isNotEmpty && items.isEmpty) {
    throw const FormatException('App 分类未返回可识别的剧集');
  }
  final int? next = int.tryParse(
    hongguoMapString(data, <String>['next_offset']),
  );
  final Object? hasMoreRaw = data['has_more'];
  if (hasMoreRaw is! bool || (hasMoreRaw && next == null)) {
    throw const FormatException('App 分页标记无效，已保留上次位置');
  }
  final bool hasMore = hasMoreRaw;
  final int nextOffset = next ?? (cursor.offset + rowsRaw.length);
  String lastId = '';
  String signature = '';
  if (items.isNotEmpty) {
    lastId = items.last.id;
    ids.sort();
    signature = pageSignature(ids);
  }
  if (hasMore &&
      (items.isEmpty ||
          nextOffset <= cursor.offset ||
          nextOffset > 1000000 ||
          signature == cursor.pageSignature)) {
    throw const FormatException('App 分页未前进，已保留上次位置');
  }
  final int resolvedNext =
      (!hasMore && (nextOffset < cursor.offset || nextOffset > 1000000))
          ? cursor.offset
          : nextOffset;
  final String session = hongguoMapString(data, <String>['session_id']);
  if (session.length > 4096 || session.contains(RegExp(r'[\r\n\x00]'))) {
    throw const FormatException('App 分页会话无效，已保留上次位置');
  }
  return HongguoCatalogPage(
    dramas: items,
    cursor: cursor.copyWith(
      exhausted: !hasMore,
      initialized: true,
      offset: resolvedNext,
      sessionId: session,
      lastId: lastId,
      pageSignature: signature,
      updatedAt: DateTime.now(),
    ),
  );
}

/// 播放媒体：一条可播地址 + 清晰度变体 + 可选 CENC 密钥。
class HongguoMedia {
  const HongguoMedia({
    required this.url,
    this.referer = '',
    this.duration,
    this.quality = 0,
    this.cencKey,
    this.variants = const <HongguoMedia>[],
    this.seriesId = '',
    this.videoId = '',
  });

  final String url;
  final String referer;
  final Duration? duration;
  final int quality;
  final List<int>? cencKey;
  final List<HongguoMedia> variants;
  final String seriesId;
  final String videoId;

  bool get encrypted => cencKey != null;

  HongguoMedia copyWith({
    String? url,
    String? referer,
    Duration? duration,
    int? quality,
    List<int>? cencKey,
    List<HongguoMedia>? variants,
    String? seriesId,
    String? videoId,
  }) =>
      HongguoMedia(
        url: url ?? this.url,
        referer: referer ?? this.referer,
        duration: duration ?? this.duration,
        quality: quality ?? this.quality,
        cencKey: cencKey ?? this.cencKey,
        variants: variants ?? this.variants,
        seriesId: seriesId ?? this.seriesId,
        videoId: videoId ?? this.videoId,
      );
}

/// 从媒体信息里提取播放地址（对应 Go `hongguoMediaAddresses`）。
List<String> hongguoMediaAddresses(
  Map<String, dynamic> info, {
  required bool Function(String url) isMediaUrl,
  required String? Function(String value) tryBase64Decode,
}) {
  final List<String> addresses = <String>[];
  final Set<String> seen = <String>{};
  void add(Object? value) {
    if (value is String) {
      String address = value.trim();
      if (address.length > 8192) return;
      if (!isMediaUrl(address)) {
        final String? decoded = tryBase64Decode(address);
        if (decoded == null) return;
        address = decoded.trim();
      }
      if (isMediaUrl(address) && seen.add(address)) addresses.add(address);
    } else if (value is List) {
      for (final Object? item in value) {
        add(item);
      }
    }
  }

  for (final String key in <String>[
    'main_url',
    'backup_url',
    'backup_url_1',
    'backup_url_2',
    'backup_urls',
    'url_list',
  ]) {
    add(info[key]);
  }
  return addresses;
}

/// 从 App video_model 里选出最佳媒体（对应 Go `selectHongguoAppMedia`）。
///
/// 跳过 bytevc2 编码（底包播放器不兼容）；h264 优先；清晰度取高。
/// [contentKey] 负责把 spade_a 解成 CENC 密钥，解不出时该变体跳过。
HongguoMedia selectHongguoAppMedia(
  Map<String, dynamic> model, {
  required bool Function(String url) isMediaUrl,
  required String? Function(String value) tryBase64Decode,
  required List<int> Function(String spadeA) contentKey,
}) {
  List<dynamic> variants = hongguoAnyList(model['video_list']);
  if (variants.isEmpty && model['video_list'] is Map) {
    final Map<String, dynamic> rows =
        (model['video_list'] as Map).cast<String, dynamic>();
    final List<String> keys = rows.keys.toList()..sort();
    variants = keys.map((String key) => rows[key]).toList();
  }
  final double durationSeconds = double.tryParse(
        hongguoMapString(model, <String>['video_duration', 'duration']),
      ) ??
      0;
  final Duration duration = Duration(
    milliseconds: (durationSeconds * 1000).round(),
  );
  Object? keyError;
  final List<({HongguoMedia media, int score})> choices =
      <({HongguoMedia media, int score})>[];
  for (final Object? row in variants) {
    if (row is! Map) continue;
    final Map<String, dynamic> variant = row.cast<String, dynamic>();
    final Map<String, dynamic> meta = hongguoNestedMap(
      variant,
      <String>['video_meta'],
    );
    final String codec = hongguoMapString(
      meta,
      <String>['codec_type'],
    ).toLowerCase();
    if (codec == 'bytevc2' ||
        hongguoMapString(
          variant,
          <String>['gear_des_key'],
        ).toLowerCase().contains('bytevc2')) {
      continue;
    }
    final List<String> addresses = hongguoMediaAddresses(
      variant,
      isMediaUrl: isMediaUrl,
      tryBase64Decode: tryBase64Decode,
    );
    if (addresses.isEmpty) continue;
    List<int>? cencKey;
    final Map<String, dynamic> encryption = hongguoNestedMap(
      variant,
      <String>['encrypt_info'],
    );
    final String spade = hongguoMapString(encryption, <String>['spade_a']);
    if (spade.isNotEmpty ||
        encryption['encrypt'] == true ||
        hongguoMapString(
              encryption,
              <String>['encryption_method'],
            ) ==
            'cenc-aes-ctr') {
      try {
        cencKey = contentKey(spade);
      } on Object catch (error) {
        keyError = error;
        continue;
      }
    }
    int height = int.tryParse(hongguoMapString(meta, <String>['vheight'])) ?? 0;
    final String definition = hongguoMapString(meta, <String>['definition']);
    final RegExpMatch? digits = RegExp(r'[0-9]+').firstMatch(definition);
    if (digits != null) {
      final int parsed = int.tryParse(digits.group(0)!) ?? 0;
      if (parsed > 0) height = parsed;
    } else {
      final int width =
          int.tryParse(hongguoMapString(meta, <String>['vwidth'])) ?? 0;
      if (width > 0 && (height == 0 || width < height)) height = width;
    }
    int score = height * 10;
    if (codec == 'h264' || codec == 'avc1') score++;
    for (final String address in addresses) {
      choices.add((
        media: HongguoMedia(
          url: address,
          referer: 'https://novel.snssdk.com/',
          duration: duration,
          quality: height,
          cencKey: cencKey,
        ),
        score: score,
      ));
    }
  }
  if (choices.isNotEmpty) {
    choices.sort((a, b) => b.score.compareTo(a.score));
    final HongguoMedia selected = choices.first.media;
    return selected.copyWith(
      variants: choices.map((choice) => choice.media).toList(),
    );
  }
  if (keyError != null) {
    throw StateError('红果 App 媒体密钥不可用: $keyError');
  }
  throw StateError('红果 App 未返回兼容的媒体，已跳过不支持的编码');
}

/// 网页 `_ROUTER_DATA` 解析（对应 Go `parseRouterData`）。
Map<String, dynamic> parseHongguoRouterData(String raw) {
  final RegExp pattern = RegExp(r'(?:window\.)?_ROUTER_DATA\s*=\s*');
  final RegExpMatch? match = pattern.firstMatch(raw);
  if (match == null) return <String, dynamic>{};
  final String rest = raw.substring(match.end);
  try {
    final Object? decoded = jsonDecode(_longestJsonPrefix(rest));
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is Map) return decoded.cast<String, dynamic>();
  } on Object {
    return <String, dynamic>{};
  }
  return <String, dynamic>{};
}

/// 取 JSON 文本的最长合法前缀（路由数据后常跟 `</script>` 等尾巴）。
String _longestJsonPrefix(String rest) {
  int depth = 0;
  bool inString = false;
  bool escaped = false;
  for (int i = 0; i < rest.length; i++) {
    final String ch = rest[i];
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (ch == r'\') {
        escaped = true;
      } else if (ch == '"') {
        inString = false;
      }
      continue;
    }
    if (ch == '"') {
      inString = true;
    } else if (ch == '{' || ch == '[') {
      depth++;
    } else if (ch == '}' || ch == ']') {
      depth--;
      if (depth == 0) return rest.substring(0, i + 1);
    }
  }
  return rest;
}

/// 取 loaderData 里命中的页面数据（对应 Go `routerLoaderMap`）。
Map<String, dynamic> hongguoRouterLoaderMap(
  Map<String, dynamic> data,
  List<String> names,
) {
  final Map<String, dynamic> loader = hongguoNestedMap(
    data,
    <String>['loaderData'],
  );
  for (final String name in names) {
    final Map<String, dynamic> page = hongguoNestedMap(loader, <String>[name]);
    if (page.isNotEmpty) return page;
  }
  for (final MapEntry<String, dynamic> entry in loader.entries) {
    for (final String name in names) {
      final String prefix =
          name.endsWith(r'$') ? name.substring(0, name.length - 1) : name;
      if (prefix.isNotEmpty && entry.key.startsWith(prefix)) {
        final Map<String, dynamic> page = hongguoNestedMap(
          loader,
          <String>[entry.key],
        );
        if (page.isNotEmpty) return page;
      }
    }
  }
  return <String, dynamic>{};
}

/// 搜索联想词条。
class HongguoSuggestion {
  const HongguoSuggestion({required this.name, this.type = ''});

  final String name;
  final String type;
}

/// 联想原始记录（含剧集数据，供名称检索用）。
class HongguoSuggestionRecord {
  const HongguoSuggestionRecord({
    required this.name,
    required this.wordType,
    required this.keyword,
    required this.videoData,
  });

  final String name;
  final String wordType;
  final Object? keyword;
  final Map<String, dynamic> videoData;

  factory HongguoSuggestionRecord.fromJson(Map<String, dynamic> json) {
    final Object? videoData = json['video_data'];
    return HongguoSuggestionRecord(
      name: json['name'] as String? ?? '',
      wordType: json['word_type'] as String? ?? '',
      keyword: json['keyword'],
      videoData: videoData is Map<String, dynamic>
          ? videoData
          : videoData is Map
              ? videoData.cast<String, dynamic>()
              : <String, dynamic>{},
    );
  }
}

/// 解析联想响应体（对应 Go `fetchHongguoSuggestionRecords` 的解码部分）。
List<HongguoSuggestionRecord> parseHongguoSuggestionRecords(String body) {
  final Object? decoded = jsonDecode(body);
  if (decoded is! Map) {
    throw const FormatException('红果搜索联想未返回有效数据');
  }
  final Map<String, dynamic> map = decoded.cast<String, dynamic>();
  List<dynamic>? items =
      map['suggest_list'] is List ? map['suggest_list'] as List : null;
  items ??= hongguoNestedMap(map, <String>['data'])['suggest_list'] is List
      ? hongguoNestedMap(map, <String>['data'])['suggest_list'] as List
      : null;
  if (items == null) {
    throw const FormatException('红果搜索联想未返回有效数据');
  }
  final List<HongguoSuggestionRecord> records = <HongguoSuggestionRecord>[];
  for (final Object? item in items) {
    if (item is Map<String, dynamic>) {
      records.add(HongguoSuggestionRecord.fromJson(item));
    } else if (item is Map) {
      records.add(
        HongguoSuggestionRecord.fromJson(item.cast<String, dynamic>()),
      );
    }
  }
  return records;
}

/// 联想记录转展示词条（对应 Go `fetchHongguoSearchSuggestions`）。
List<HongguoSuggestion> hongguoSuggestionsFromRecords(
  List<HongguoSuggestionRecord> records, {
  int limit = 10,
}) {
  const Set<String> knownTypes = <String>{
    'short_play_name',
    'short_play_category',
    'common_query',
    'actor_name',
    'short_play_actor',
  };
  final List<HongguoSuggestion> items = <HongguoSuggestion>[];
  final Set<String> seen = <String>{};
  for (final HongguoSuggestionRecord record in records) {
    final String name = validateHongguoSearchKeyword(
      record.name,
      throwOnInvalid: false,
    );
    if (name.isEmpty) continue;
    final String key = name.toLowerCase();
    if (!seen.add(key)) continue;
    items.add(
      HongguoSuggestion(
        name: name,
        type: knownTypes.contains(record.wordType) ? record.wordType : '',
      ),
    );
    if (items.length == limit) break;
  }
  return items;
}

/// 搜索词校验（对应 Go `hongguoSearchKeyword`）：去空白、1 至 80 字、无控制字符。
String validateHongguoSearchKeyword(
  String keyword, {
  bool throwOnInvalid = true,
}) {
  final String cleaned = keyword.trim();
  final bool valid = cleaned.isNotEmpty &&
      cleaned.runes.length <= 80 &&
      !cleaned.runes.any((int rune) => rune < 0x20 || rune == 0x7f);
  if (!valid) {
    if (throwOnInvalid) {
      throw const FormatException('请输入 1 至 80 个字符的搜索词');
    }
    return '';
  }
  return cleaned;
}

/// 搜索文本归一：去空白与标点、转小写（对应 Go `hongguoSearchText`）。
String hongguoSearchText(String text) {
  final StringBuffer out = StringBuffer();
  for (final int rune in text.runes) {
    final String ch = String.fromCharCode(rune);
    if (RegExp(r'\s').hasMatch(ch)) continue;
    if (RegExp(r'[^\w\u4e00-\u9fff]').hasMatch(ch)) continue;
    out.write(ch.toLowerCase());
  }
  final String normalized = out.toString();
  return normalized.isEmpty ? text.trim().toLowerCase() : normalized;
}

/// 标题与搜索词的匹配等级（对应 Go `hongguoTitleSearchRank`）：越小越匹配。
int hongguoTitleSearchRank(String title, String query) {
  final List<String> words = query
      .split(RegExp(r'[\s\p{P}]', unicode: true))
      .where((String word) => word.isNotEmpty)
      .toList();
  final String normalizedQuery = hongguoSearchText(query);
  final String normalizedTitle = hongguoSearchText(title);
  if (normalizedTitle == normalizedQuery) return 0;
  if (normalizedTitle.startsWith(normalizedQuery)) return 1;
  if (normalizedTitle.contains(normalizedQuery)) return 2;
  int matches = 0;
  for (final String word in words) {
    if (normalizedTitle.contains(hongguoSearchText(word))) matches++;
  }
  if (words.isNotEmpty && matches == words.length) return 3;
  return 4;
}

/// 弹幕单条。
class HongguoDanmakuItem {
  const HongguoDanmakuItem({
    required this.id,
    required this.text,
    required this.timeMs,
  });

  final String id;
  final String text;
  final int timeMs;
}

/// 弹幕一页（30 秒窗口）。
class HongguoDanmakuPage {
  const HongguoDanmakuPage({
    required this.episodeId,
    required this.items,
    required this.startMs,
    required this.nextMs,
    required this.total,
  });

  final String episodeId;
  final List<HongguoDanmakuItem> items;
  final int startMs;
  final int nextMs;
  final int total;
}

/// 弹幕表情短码展开表（移植自 Go `danmaku_emoji.go`）。
const Map<String, String> hongguoDanmakuEmoji = <String, String>{
  '[笑哭]': '😂',
  '[大笑]': '😆',
  '[微笑]': '🙂',
  '[呲牙]': '😁',
  '[偷笑]': '🤭',
  '[捂脸]': '🤦',
  '[害羞]': '😊',
  '[调皮]': '😜',
  '[爱慕]': '😍',
  '[色]': '😍',
  '[酷]': '😎',
  '[白眼]': '🙄',
  '[抠鼻]': '🤨',
  '[鄙视]': '😒',
  '[思考]': '🤔',
  '[什么]': '🤔',
  '[惊讶]': '😲',
  '[尴尬]': '😅',
  '[汗]': '😅',
  '[闭嘴]': '🤐',
  '[嘘]': '🤫',
  '[困]': '😴',
  '[睡]': '😴',
  '[哈欠]': '🥱',
  '[流泪]': '😢',
  '[大哭]': '😭',
  '[委屈]': '🥺',
  '[可怜]': '🥺',
  '[没看够]': '🥺',
  '[抓狂]': '😫',
  '[发怒]': '😡',
  '[吐]': '🤮',
  '[打脸]': '🤦',
  '[灵光一闪]': '💡',
  '[赞]': '👍',
  '[强]': '👍',
  '[给力]': '👍',
  '[弱]': '👎',
  '[鼓掌]': '👏',
  '[ok]': '👌',
  '[胜利]': '✌️',
  '[耶]': '✌️',
  '[奋斗]': '💪',
  '[加油]': '💪',
  '[威武]': '💪',
  '[抱抱]': '🤗',
  '[比心]': '🫰',
  '[心]': '❤️',
  '[爱心]': '❤️',
  '[送花]': '🌹',
  '[玫瑰]': '🌹',
  '[鲜花]': '💐',
  '[钱]': '💰',
  '[狗头]': '🐶',
  '[doge]': '🐶',
};

/// 展开弹幕文本里的表情短码（对应 Go `expandDanmakuEmoji`）。
String expandHongguoDanmakuEmoji(String text) {
  if (!text.contains('[')) return text;
  return text.replaceAllMapped(RegExp(r'\[[^\[\]\s]{1,10}\]'), (Match match) {
    final String token = match.group(0)!;
    return hongguoDanmakuEmoji[token.toLowerCase()] ?? token;
  });
}

/// 截断弹幕文本，不切断 emoji 修饰符与连接符（对应 Go `trimDanmakuText`）。
String trimHongguoDanmakuText(String text, int limit) {
  final List<int> runes = text.runes.toList();
  if (runes.length <= limit) return text;
  int cut = limit;
  while (cut > 0) {
    bool retreat = false;
    if (cut < runes.length && (runes[cut] == 0xfe0f || runes[cut] == 0xfe0e)) {
      cut--;
      retreat = true;
    }
    final bool priorIsJoiner = cut > 0 && runes[cut - 1] == 0x200d;
    final bool nextIsJoiner = cut < runes.length && runes[cut] == 0x200d;
    if (priorIsJoiner || nextIsJoiner) {
      cut = priorIsJoiner ? max(0, cut - 2) : cut - 1;
      retreat = true;
    }
    if (!retreat) break;
  }
  return String.fromCharCodes(runes.sublist(0, cut));
}

/// 解析弹幕响应（对应 Go `parseHongguoDanmaku`）。
HongguoDanmakuPage parseHongguoDanmaku(
  Map<String, dynamic> result,
  String videoId,
  int startMs,
  int durationMs,
) {
  const int maxDurationMs = 24 * 60 * 60 * 1000;
  final Map<String, dynamic> data = hongguoNestedMap(result, <String>['data']);
  final Object? rowsRaw = data['data_list'];
  final int? next = int.tryParse(
    hongguoMapString(
      hongguoNestedMap(data, <String>['extra']),
      <String>['next_query_danmaku_list_time'],
    ),
  );
  if (rowsRaw is! List ||
      next == null ||
      next <= startMs ||
      next > maxDurationMs) {
    throw const FormatException('红果弹幕时间段格式无效');
  }
  final int nextMs = min(next, durationMs);
  int total = 0;
  final String cursorRaw = hongguoMapString(
    hongguoNestedMap(data, <String>['common_list_info']),
    <String>['cursor'],
  );
  if (cursorRaw.length <= 8192) {
    try {
      final Object? cursor = jsonDecode(cursorRaw);
      if (cursor is Map && cursor['danmaku_count'] is num) {
        final int parsed = (cursor['danmaku_count'] as num).toInt();
        if (parsed >= 0) total = parsed;
      }
    } on Object {
      // cursor 解析失败时总数保持 0。
    }
  }
  final List<HongguoDanmakuItem> items = <HongguoDanmakuItem>[];
  final Set<String> seen = <String>{};
  for (final Object? raw in rowsRaw) {
    if (raw is! Map) continue;
    final Map<String, dynamic> row = raw.cast<String, dynamic>();
    final Map<String, dynamic> comment = hongguoNestedMap(
      row,
      <String>['comment'],
    );
    final Map<String, dynamic> common = hongguoNestedMap(
      comment,
      <String>['common'],
    );
    if (hongguoMapString(common, <String>['group_id']) != videoId ||
        hongguoMapString(common, <String>['status']) != '1') {
      continue;
    }
    final int? position = int.tryParse(
      hongguoMapString(
        hongguoNestedMap(comment, <String>['expand']),
        <String>['offset_time'],
      ),
    );
    String text = hongguoMapString(
      hongguoNestedMap(common, <String>['content']),
      <String>['text'],
    );
    text = expandHongguoDanmakuEmoji(text);
    text = text.runes
        .map((int rune) {
          if (rune < 0x20 || rune == 0x2028 || rune == 0x2029) return ' ';
          return String.fromCharCode(rune);
        })
        .join()
        .trim();
    final String id = hongguoMapString(comment, <String>['comment_id']);
    if (position == null ||
        position < startMs ||
        position >= nextMs ||
        text.isEmpty ||
        id.isEmpty ||
        id.length > 120 ||
        !seen.add(id)) {
      continue;
    }
    if (text.runes.length > 180) {
      text = '${trimHongguoDanmakuText(text, 180)}…';
    }
    items.add(HongguoDanmakuItem(id: id, text: text, timeMs: position));
    if (items.length == 90) break;
  }
  items.sort(
    (HongguoDanmakuItem a, HongguoDanmakuItem b) =>
        a.timeMs.compareTo(b.timeMs),
  );
  return HongguoDanmakuPage(
    episodeId: videoId,
    items: items,
    startMs: startMs,
    nextMs: nextMs,
    total: total,
  );
}

/// 多季信息（移植自 Dart 侧 `hongguo_series.dart`）。
class HongguoSeriesInfo {
  const HongguoSeriesInfo({
    required this.baseTitle,
    required this.key,
    required this.season,
    required this.unit,
    required this.explicit,
  });

  final String baseTitle;
  final String key;
  final int season;
  final String unit;
  final bool explicit;
}

/// 多季条目。
class HongguoSeriesEntry {
  const HongguoSeriesEntry({
    required this.drama,
    required this.season,
    required this.unit,
  });

  final HongguoDrama drama;
  final int season;
  final String unit;

  String get label => '第 $season $unit';
}

const int _hongguoSeriesLimit = 200;

final RegExp _seasonSuffix = RegExp(
  r'第\s*([0-9零〇一二两兩三四五六七八九十百]+)\s*([季部])[\s\u3000，。！？、：；·「」『』（）《》“”‘’.,!?:;\-_/()\[\]{}]*$',
);

int? _seasonNumber(String label) {
  final int? numeric = int.tryParse(label);
  if (numeric != null) {
    return numeric >= 1 && numeric <= _hongguoSeriesLimit ? numeric : null;
  }
  const Map<String, int> digits = <String, int>{
    '零': 0,
    '〇': 0,
    '一': 1,
    '二': 2,
    '两': 2,
    '兩': 2,
    '三': 3,
    '四': 4,
    '五': 5,
    '六': 6,
    '七': 7,
    '八': 8,
    '九': 9,
  };
  int number = 0;
  if (!label.contains(RegExp('[十百]'))) {
    for (final int rune in label.runes) {
      final int? digit = digits[String.fromCharCode(rune)];
      if (digit == null) return null;
      number = number * 10 + digit;
      if (number > _hongguoSeriesLimit) return null;
    }
    return number >= 1 ? number : null;
  }
  int digit = 0;
  int previous = 1000;
  for (final int rune in label.runes) {
    final String character = String.fromCharCode(rune);
    final int? value = digits[character];
    if (value != null) {
      digit = digit * 10 + value;
      continue;
    }
    final int multiplier = character == '百' ? 100 : 10;
    if (multiplier >= previous || digit > 9) return null;
    number += (digit == 0 ? 1 : digit) * multiplier;
    digit = 0;
    previous = multiplier;
  }
  number += digit;
  return number >= 1 && number <= _hongguoSeriesLimit ? number : null;
}

/// 解析剧集标题里的季数信息（对应 `hongguoSeriesInfo`）。
HongguoSeriesInfo? hongguoSeriesInfo(HongguoDrama drama, {String? unit}) {
  final String title = drama.title.trim();
  final RegExpMatch? match = _seasonSuffix.firstMatch(title);
  if (match == null) {
    if (unit == null || title.isEmpty) return null;
    return HongguoSeriesInfo(
      baseTitle: title,
      key: hongguoSearchText(title),
      season: 1,
      unit: unit,
      explicit: false,
    );
  }
  final String base = title.substring(0, match.start).trim();
  final int? season = _seasonNumber(match[1]!);
  if (base.isEmpty || season == null) return null;
  return HongguoSeriesInfo(
    baseTitle: base,
    key: hongguoSearchText(base),
    season: season,
    unit: match[2]!,
    explicit: true,
  );
}

/// 以 [anchor] 为锚，把同名多季剧集按季排序（对应 `hongguoSeriesEntries`）。
List<HongguoSeriesEntry> hongguoSeriesEntries(
  HongguoDrama anchor,
  Iterable<HongguoDrama> candidates,
) {
  HongguoSeriesInfo? anchorInfo = hongguoSeriesInfo(anchor);
  late final String key;
  late final String unit;
  late final int anchorSeason;
  if (anchorInfo == null) {
    final String baseKey = hongguoSearchText(anchor.title);
    final Map<String, List<HongguoSeriesInfo>> groups =
        <String, List<HongguoSeriesInfo>>{};
    for (final HongguoDrama drama in candidates) {
      final HongguoSeriesInfo? info = hongguoSeriesInfo(drama);
      if (info != null && info.key == baseKey) {
        (groups[info.unit] ??= <HongguoSeriesInfo>[]).add(info);
      }
    }
    if (groups.isEmpty) return const <HongguoSeriesEntry>[];
    final List<MapEntry<String, List<HongguoSeriesInfo>>> best =
        groups.entries.toList()
          ..sort((a, b) {
            final int count = b.value.length.compareTo(a.value.length);
            if (count != 0) return count;
            final int maxA = a.value.fold<int>(
              0,
              (int value, HongguoSeriesInfo info) =>
                  value > info.season ? value : info.season,
            );
            final int maxB = b.value.fold<int>(
              0,
              (int value, HongguoSeriesInfo info) =>
                  value > info.season ? value : info.season,
            );
            return maxB.compareTo(maxA);
          });
    key = baseKey;
    unit = best.first.key;
    anchorSeason = 1;
    anchorInfo = hongguoSeriesInfo(anchor, unit: unit);
  } else {
    key = anchorInfo.key;
    unit = anchorInfo.unit;
    anchorSeason = anchorInfo.season;
  }
  if (anchorInfo == null) return const <HongguoSeriesEntry>[];
  final Map<String, HongguoSeriesEntry> byId = <String, HongguoSeriesEntry>{};
  for (final HongguoDrama drama in <HongguoDrama>[anchor, ...candidates]) {
    final HongguoSeriesInfo? info = hongguoSeriesInfo(drama, unit: unit);
    if (info == null || info.key != key || info.unit != unit) continue;
    byId[drama.id] = HongguoSeriesEntry(
      drama: drama,
      season: drama.id == anchor.id ? anchorSeason : info.season,
      unit: unit,
    );
  }
  final List<HongguoSeriesEntry> entries = byId.values.toList()
    ..sort((HongguoSeriesEntry a, HongguoSeriesEntry b) {
      final int season = a.season.compareTo(b.season);
      return season != 0 ? season : a.drama.title.compareTo(b.drama.title);
    });
  return entries.length > 1 ? entries : const <HongguoSeriesEntry>[];
}
