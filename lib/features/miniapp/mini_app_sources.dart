import 'dart:convert';

import 'package:wxyy/core/models/category_entry.dart';
import 'package:wxyy/core/models/episode.dart';
import 'package:wxyy/core/models/media_item.dart';
import 'package:wxyy/core/models/plugin_config.dart';
import 'package:wxyy/core/scraper/media_api_service.dart';
import 'package:wxyy/core/services/source_repository.dart';

/// 采集源桥的失败，code 沿用 window.ant 契约的错误码，桥层会原样
/// 转成 MiniAppApiException 交给 JS 侧 reject。
class MiniAppSourceFailure implements Exception {
  const MiniAppSourceFailure(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => '$code: $message';
}

/// 小程序 source.* 接口的宿主实现契约。
///
/// 返回形状按 window.ant 契约：list 是 [{key, name, type, searchable,
/// available}]；home/category/detail/search 返回 TVBox 形态的 vod_* 数据；
/// play 返回 {url, header, parse?, jx?}。
abstract class MiniAppSourceProvider {
  Future<List<Map<String, dynamic>>> listSites();

  Future<Map<String, dynamic>> home(String siteKey);

  Future<Map<String, dynamic>> category({
    required String siteKey,
    required String tid,
    required int page,
    Map<String, dynamic> ext = const {},
  });

  Future<Map<String, dynamic>> detail({
    required String siteKey,
    required String id,
  });

  Future<Map<String, dynamic>> play({
    required String siteKey,
    required String flag,
    required String id,
  });

  Future<Map<String, dynamic>> search({
    required String siteKey,
    required String wd,
    required int page,
  });
}

/// 默认实现：复用底包同一套源体系，不另起注册表。
///
/// 站点来自 [SourceRepository.activeSources]，只列影视源
/// （[SourceType.animeSource]，与魔蚁版只列视频站的口径一致）；
/// 取数走 [MediaApiService]（fetchCategories / fetchApiResults /
/// fetchDetail / fetchEpisodes / fetchVideoUrl），py / jar / 声明式 /
/// 脚本源由底包解析器注册表统一分流，本文件不直接碰蜘蛛引擎。
/// 仓库或服务未注入时（宿主 Provider 拿不到）：listSites 返回空列表，
/// 其余调用报 SITE_UNAVAILABLE，不编假数据。
class HostMiniAppSourceProvider implements MiniAppSourceProvider {
  HostMiniAppSourceProvider({
    SourceRepository? repository,
    MediaApiService? service,
    Duration callTimeout = const Duration(seconds: 60),
  })  : _repository = repository,
        _service = service,
        _callTimeout = callTimeout;

  /// 契约上限：单次调用 60 秒超时，最多 3 个并发。
  static const int maxConcurrent = 3;

  final SourceRepository? _repository;
  final MediaApiService? _service;
  final Duration _callTimeout;

  int _active = 0;

  MediaApiService get _api {
    final service = _service;
    if (service == null) {
      throw const MiniAppSourceFailure(
        'SITE_UNAVAILABLE',
        '媒体服务未接通：宿主没有拿到 MediaApiService',
      );
    }
    return service;
  }

  @override
  Future<List<Map<String, dynamic>>> listSites() async {
    final repository = _repository;
    if (repository == null) return const [];
    final sites = <Map<String, dynamic>>[];
    for (final config in repository.activeSources) {
      if (config.type != SourceType.animeSource) continue;
      sites.add(<String, dynamic>{
        'key': config.id,
        'name': config.name,
        'type': _siteType(config),
        'searchable': config.routes.containsKey('search'),
        'available': config.isEnabled,
      });
    }
    return sites;
  }

  @override
  Future<Map<String, dynamic>> home(String siteKey) async {
    final config = _resolveSite(siteKey);
    return _guarded(() async {
      final categories = await _api.fetchCategories(config);
      final route = MediaApiService.routeForCategory(config, null);
      final items = await _api.fetchApiResults(
        config,
        route,
        vars: const <String, String>{'page': '1'},
      );
      return withClassesAlias(<String, dynamic>{
        'class': _classesJson(categories),
        'list': items.map(_vodCard).toList(),
        'page': 1,
        'total': items.length,
      });
    });
  }

  @override
  Future<Map<String, dynamic>> category({
    required String siteKey,
    required String tid,
    required int page,
    Map<String, dynamic> ext = const {},
  }) async {
    final config = _resolveSite(siteKey);
    final safePage = page < 1 ? 1 : page;
    return _guarded(() async {
      final category = tid.isEmpty ? null : tid;
      final route = MediaApiService.routeForCategory(config, category);
      final vars = <String, String>{
        'page': '$safePage',
        if (category != null) 'category': category,
        ..._stringifyExt(ext),
      };
      final items = await _api.fetchApiResults(config, route, vars: vars);
      return <String, dynamic>{
        'list': items.map(_vodCard).toList(),
        'page': safePage,
        'total': items.length,
      };
    });
  }

  @override
  Future<Map<String, dynamic>> detail({
    required String siteKey,
    required String id,
  }) async {
    if (id.isEmpty) {
      throw const MiniAppSourceFailure(
        'INVALID_PARAMS',
        'source.detail 缺少 id',
      );
    }
    final config = _resolveSite(siteKey);
    return _guarded(() async {
      final detailUrl = _asDetailUrl(id);
      final detail = await _api.fetchDetail(
        config,
        id,
        detailUrl: detailUrl,
      );
      final episodes = await _api.fetchEpisodes(
        config,
        id,
        title: detail.title,
        detailUrl: detailUrl,
      );
      return <String, dynamic>{
        'list': <Map<String, dynamic>>[_vodDetail(detail, episodes)],
      };
    });
  }

  @override
  Future<Map<String, dynamic>> play({
    required String siteKey,
    required String flag,
    required String id,
  }) async {
    if (id.isEmpty) {
      throw const MiniAppSourceFailure('INVALID_PARAMS', 'source.play 缺少 id');
    }
    final config = _resolveSite(siteKey);
    return _guarded(() async {
      final result = await _api.fetchVideoUrl(config, id);
      return normalizePlayResult(<String, dynamic>{
        'url': result.url,
        'header': result.headers ?? const <String, String>{},
        if (flag.isNotEmpty) 'flag': flag,
      });
    });
  }

  @override
  Future<Map<String, dynamic>> search({
    required String siteKey,
    required String wd,
    required int page,
  }) async {
    if (wd.isEmpty) {
      throw const MiniAppSourceFailure(
        'INVALID_PARAMS',
        'source.search 缺少 wd',
      );
    }
    final config = _resolveSite(siteKey);
    if (!config.routes.containsKey('search')) {
      throw MiniAppSourceFailure(
        'SITE_UNAVAILABLE',
        '站点「${config.name}」没有声明 search 路由',
      );
    }
    final safePage = page < 1 ? 1 : page;
    return _guarded(() async {
      final items = await _api.fetchApiResults(
        config,
        'search',
        vars: <String, String>{'keyword': wd, 'page': '$safePage'},
      );
      return <String, dynamic>{
        'list': items.map(_vodCard).toList(),
        'page': safePage,
        'total': items.length,
      };
    });
  }

  /// 只认源仓库里的影视源 id；其它类型源与未知 id 一律报 SITE_NOT_FOUND。
  PluginConfig _resolveSite(String siteKey) {
    final key = siteKey.trim();
    if (key.isEmpty) {
      throw const MiniAppSourceFailure(
        'INVALID_PARAMS',
        '缺少 siteKey',
      );
    }
    final repository = _repository;
    final config = repository?.getById(key);
    if (config == null || config.type != SourceType.animeSource) {
      throw MiniAppSourceFailure('SITE_NOT_FOUND', '未找到影视源：$key');
    }
    return config;
  }

  Future<T> _guarded<T>(Future<T> Function() run) async {
    if (_active >= maxConcurrent) {
      throw const MiniAppSourceFailure(
        'TOO_MANY_REQUESTS',
        '采集源并发调用已满（最多 3 个），请稍后重试',
      );
    }
    _active++;
    try {
      return await run().timeout(_callTimeout, onTimeout: () {
        throw const MiniAppSourceFailure(
          'TIMEOUT',
          '采集源调用超时（60 秒）',
        );
      });
    } on MiniAppSourceFailure {
      rethrow;
    } catch (error) {
      throw MiniAppSourceFailure('SOURCE_FAILED', '采集源调用失败：$error');
    } finally {
      _active--;
    }
  }

  static String _siteType(PluginConfig config) {
    if (config.isPySource) return 'py';
    if (config.isJarSource) return 'jar';
    return 'rule';
  }

  static List<Map<String, dynamic>> _classesJson(
    List<CategoryEntry> categories,
  ) {
    return [
      for (final entry in categories)
        <String, dynamic>{
          'type_id': entry.id,
          'type_name': entry.title,
        },
    ];
  }

  /// 列表卡片：只填源真实返回的字段，没有的字段留空串，不编假值。
  /// vod_id 优先用条目 id；id 为空时退回详情链接（detail 侧按链接认回）。
  static Map<String, dynamic> _vodCard(MediaItem item) {
    final id = item.id.isNotEmpty ? item.id : (item.detailUrl ?? '');
    return <String, dynamic>{
      'vod_id': id,
      'vod_name': item.title,
      'vod_pic': item.coverUrl ?? '',
      'vod_content': item.description ?? '',
      'vod_remarks': item.status ?? '',
      'vod_year': item.year ?? '',
      'vod_actor': item.actors ?? '',
      'vod_director': item.director ?? '',
      'vod_tag': (item.tags ?? const <String>[]).join(','),
      if (item.detailUrl != null && item.detailUrl!.isNotEmpty)
        'detailUrl': item.detailUrl,
    };
  }

  /// 详情：选集按线路名分组，拼成 TVBox 的 vod_play_from / vod_play_url
  /// （线路间 $$$，集间 #，集内 标题$地址）。无线路名时归入“默认”组
  /// （仅作分组标签，不改地址本身）。
  static Map<String, dynamic> _vodDetail(
    MediaItem detail,
    List<Episode> episodes,
  ) {
    final groups = <String, List<Episode>>{};
    for (final episode in episodes) {
      final line = (episode.lineName ?? '').trim();
      final key = line.isEmpty ? '默认' : line;
      groups.putIfAbsent(key, () => <Episode>[]).add(episode);
    }
    final fromParts = <String>[];
    final urlParts = <String>[];
    for (final entry in groups.entries) {
      fromParts.add(entry.key);
      urlParts.add(
        entry.value.map((e) {
          final address = e.url.isNotEmpty ? e.url : e.id;
          return '${e.title}\$$address';
        }).join('#'),
      );
    }
    final card = _vodCard(detail);
    return <String, dynamic>{
      ...card,
      'vod_play_from': fromParts.join('\$\$\$'),
      'vod_play_url': urlParts.join('\$\$\$'),
    };
  }

  /// 扩展筛选参数一律转字符串后透传给解析器（源不支持的字段由
  /// 解析器忽略，与底包筛选透传口径一致）。
  static Map<String, String> _stringifyExt(Map<String, dynamic> ext) {
    final vars = <String, String>{};
    ext.forEach((key, value) {
      if (value != null) vars[key] = value.toString();
    });
    return vars;
  }

  /// vod_id 本身是链接时，detail / episodes 调用同时把它当详情链接传，
  /// 否则只按 id 查（解析器按路由模板拼地址）。
  static String? _asDetailUrl(String id) {
    if (id.startsWith('http://') || id.startsWith('https://')) return id;
    return null;
  }

  /// 蜘蛛首页用 TVBox 惯例的 `class` 键；契约文字写的是 `classes`，
  /// 两个键都给，读哪边都行，值是同一份真实数据。
  static Map<String, dynamic> withClassesAlias(Map<String, dynamic> raw) {
    final copy = Map<String, dynamic>.from(raw);
    if (!copy.containsKey('classes') && copy['class'] is List) {
      copy['classes'] = copy['class'];
    }
    return copy;
  }

  /// 取流结果归一成契约形状：url（取不到时看 playUrl）、header 一律
  /// Map、parse/jx 有则归一成 '1'/'0' 字符串、无则不编。解析线路
  /// 的 playUrl/jxFrom/key/flag 有则原样带上，宿主播放桥靠它们决定
  /// 嗅探目标；没有就不编，不替蜘蛛编解析服务地址。
  static Map<String, dynamic> normalizePlayResult(Map<String, dynamic> raw) {
    var url = raw['url']?.toString() ?? '';
    if (url.isEmpty) url = raw['playUrl']?.toString() ?? '';
    if (url.isEmpty) {
      throw const MiniAppSourceFailure(
        'SOURCE_FAILED',
        '采集源取流未返回播放地址',
      );
    }
    final result = <String, dynamic>{
      'url': url,
      'header': normalizeHeaders(raw['header']),
    };
    if (raw.containsKey('parse')) {
      result['parse'] = _parseFlagString(raw['parse']);
    }
    if (raw.containsKey('jx')) {
      result['jx'] = _parseFlagString(raw['jx']);
    }
    for (final key in const ['playUrl', 'jxFrom', 'key', 'flag']) {
      final value = raw[key];
      if (value != null && value.toString().isNotEmpty) {
        result[key] = value.toString();
      }
    }
    return result;
  }

  /// header 三种形态（Map / JSON 字符串 / 键值对列表）都收成 Map。
  static Map<String, String> normalizeHeaders(Object? raw) {
    final headers = <String, String>{};
    if (raw is Map) {
      raw.forEach((key, value) {
        if (value != null) headers[key.toString()] = value.toString();
      });
    } else if (raw is String) {
      final trimmed = raw.trim();
      if (trimmed.startsWith('{')) {
        try {
          final decoded = jsonDecode(trimmed);
          if (decoded is Map) {
            decoded.forEach((key, value) {
              if (value != null) headers[key.toString()] = value.toString();
            });
          }
        } catch (_) {}
      }
    } else if (raw is List) {
      for (final row in raw) {
        if (row is List && row.length >= 2) {
          headers[row[0].toString()] = row[1].toString();
        } else if (row is Map) {
          final key = row['key'] ?? row['name'];
          final value = row['value'];
          if (key != null && value != null) {
            headers[key.toString()] = value.toString();
          }
        }
      }
    }
    return headers;
  }

  static String _parseFlagString(Object? value) {
    if (value == true) return '1';
    if (value is num) return value.toInt() == 1 ? '1' : '0';
    final text = value?.toString().trim().toLowerCase() ?? '';
    return text == '1' || text == 'true' ? '1' : '0';
  }
}
