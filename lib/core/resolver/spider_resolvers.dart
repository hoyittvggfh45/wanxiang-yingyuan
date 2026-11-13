/// 蜘蛛解析器：把底包解析 API（latest/category/search/detail/episodes/
/// video/categories）翻译成 TVBox 蜘蛛方法调用，再经 [py_contract] 映射回
/// 统一模型。py 与 jar 仅调用层不同（桥与参数），映射逻辑共用。
library;

import '../models/episode.dart';
import '../models/media_item.dart';
import '../models/plugin_config.dart';
import '../spider/py_contract.dart';
import '../spider/py_source_store.dart';
import '../spider/spider_bridges.dart';
import '../spider/spider_errors.dart';
import 'source_resolver.dart';

abstract class _SpiderResolverBase implements SourceResolver {
  const _SpiderResolverBase();

  /// 调用蜘蛛方法，返回蜘蛛的 JSON 结果。
  Future<Map<String, dynamic>> callSpider(
    PluginConfig source,
    String method,
    Map<String, dynamic> args,
  );

  @override
  Future<dynamic> resolve(
    PluginConfig source,
    String apiName, {
    Map<String, String> vars = const {},
    void Function(List<dynamic>)? onProgress,
  }) async {
    switch (apiName) {
      case 'categories':
        final home = await callSpider(source, 'homeContent', <String, dynamic>{
          'filter': <String, dynamic>{},
        });
        final classes = home['class'];
        if (classes is! List) return const <MediaItem>[];
        // fetchCategories 期望 MediaItem 列表（仅 id/title 有意义）。
        return classListToCategories(classes)
            .map(
              (c) => MediaItem(
                id: c.id,
                title: c.title,
                sourceId: source.id,
                sourceType: source.type,
              ),
            )
            .toList();
      case 'latest':
      case 'home':
      case 'explore':
        final category = (vars['category'] ?? '').trim();
        if (category.isNotEmpty) {
          return _category(source, category, vars);
        }
        final home = await callSpider(
          source,
          'homeVideoContent',
          <String, dynamic>{},
        );
        final list = home['list'];
        return list is List
            ? vodListToItems(list, source)
            : const <MediaItem>[];
      case 'category':
        return _category(source, (vars['category'] ?? '').trim(), vars);
      case 'search':
        final result = await callSpider(
          source,
          'searchContent',
          <String, dynamic>{
            'keyword': vars['keyword'] ?? '',
            'page': _page(vars),
            'quick': false,
          },
        );
        final list = result['list'];
        return list is List
            ? vodListToItems(list, source)
            : const <MediaItem>[];
      case 'detail':
        final vod = await _detailVod(source, vars['id'] ?? '');
        return vodToDetailItem(vod, source);
      case 'episodes':
      case 'chapters':
        final vod = await _detailVod(source, vars['id'] ?? '');
        return vodToEpisodes(vod, source);
      case 'video':
        return _video(source, vars['url'] ?? '');
      default:
        throw UnsupportedError('蜘蛛源不支持解析接口：$apiName');
    }
  }

  Future<List<MediaItem>> _category(
    PluginConfig source,
    String category,
    Map<String, String> vars,
  ) async {
    final result = await callSpider(
      source,
      'categoryContent',
      <String, dynamic>{
        'tid': category,
        'page': _page(vars),
        'filter': <String, dynamic>{},
        'ext': <String, dynamic>{},
      },
    );
    final list = result['list'];
    return list is List ? vodListToItems(list, source) : const <MediaItem>[];
  }

  Future<Map<String, dynamic>> _detailVod(
    PluginConfig source,
    String id,
  ) async {
    if (id.isEmpty) throw StateError('详情缺少 id');
    final result = await callSpider(source, 'detailContent', <String, dynamic>{
      'ids': <String>[id],
    });
    final list = result['list'];
    if (list is List && list.isNotEmpty && list.first is Map) {
      return Map<String, dynamic>.from(list.first as Map);
    }
    throw StateError('详情结果为空');
  }

  Future<VideoResult> _video(PluginConfig source, String episodeUrl) async {
    if (episodeUrl.isEmpty) throw StateError('取流缺少播放地址');
    final ctx = SpiderPlayContext.lookup(episodeUrl);
    final result = await callSpider(source, 'playerContent', <String, dynamic>{
      'flag': ctx?.flag ?? '',
      'id': episodeUrl,
      'vipFlag': '',
    });
    return playerResultToVideo(result);
  }

  int _page(Map<String, String> vars) {
    return int.tryParse(vars['page'] ?? '1') ?? 1;
  }
}

/// Python 蜘蛛解析器：源码经 [PySourceStore] 取出后随调用传给原生引擎。
class PyResolver extends _SpiderResolverBase {
  const PyResolver();

  @override
  Future<Map<String, dynamic>> callSpider(
    PluginConfig source,
    String method,
    Map<String, dynamic> args,
  ) async {
    final code = await PySourceStore.readForSource(source);
    if (code == null || code.isEmpty) {
      throw SpiderEngineException('找不到该源的 py 源码，无法调用蜘蛛');
    }
    return PyBridge.call(source.id, method, <String, dynamic>{
      ...args,
      'source': code,
      'ext': source.spiderEngine?.ext ?? '',
    });
  }
}

/// Java（jar）蜘蛛解析器：经 [JarBridge] 调原生 Dex 蜘蛛。
class JarResolver extends _SpiderResolverBase {
  const JarResolver();

  @override
  Future<Map<String, dynamic>> callSpider(
    PluginConfig source,
    String method,
    Map<String, dynamic> args,
  ) async {
    final engine = source.spiderEngine;
    final api = engine?.api ?? '';
    if (api.isEmpty) {
      throw SpiderEngineException('该 jar 源缺少蜘蛛 API（csp_...），无法调用');
    }
    return JarBridge.call(
      source.id,
      api,
      engine?.ext ?? '',
      method,
      <String, dynamic>{...args, 'jarAsset': engine?.asset ?? ''},
    );
  }
}
